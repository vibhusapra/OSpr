"""Bind a strict release archive and all 18 standalone gates to one app build.

Reads existing evidence; does not rerun inference, launch UI or use API accounts.
A private --normal-baseline maps absolute owned paths to pre-test SHA256 values;
only the unchanged boolean is published, never those paths or file contents.
"""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import re
import subprocess
import zipfile

from preview_package_gates import JOBS, ROOT, sha


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--release-manifest", type=Path, required=True)
    parser.add_argument("--prefix", required=True)
    parser.add_argument("--normal-baseline", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,47}", args.prefix):
        parser.error("Use a lowercase filename prefix of at most 48 characters.")
    assert not args.output.exists(), "Refusing to replace an existing public manifest"
    app = args.app.resolve(strict=True)
    resources = app / "Contents/Resources"
    build = json.loads((resources / "build-info.json").read_text())
    assert not build["tracked_changes"]
    executable = sha(app / "Contents/MacOS/OSpr")
    cli = sha(app / "Contents/MacOS/ospr-cli")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    fingerprint = hashlib.sha256()
    for path in sorted((ROOT / "Sources").rglob("*.swift")) + sorted(
        path for path in (ROOT / "backend/ospr_backend").rglob("*") if path.suffix in {".py", ".json", ".npy"}
    ):
        fingerprint.update(str(path.relative_to(ROOT)).encode())
        fingerprint.update(path.read_bytes())
        if path.is_relative_to(ROOT / "backend"):
            assert path.read_bytes() == (resources / "Engine" / path.relative_to(ROOT)).read_bytes()
    assert fingerprint.hexdigest() == build["application_source_sha256"]
    for name in ("pyproject.toml", "uv.lock"):
        assert (ROOT / name).read_bytes() == (resources / "Engine" / name).read_bytes()
    for name in ("LICENSE", "NOTICE"):
        assert (ROOT / name).read_bytes() == (resources / name).read_bytes()
    dependencies = {x["name"].lower().replace("_", "-") for x in json.loads((resources / "dependencies.json").read_text())}
    assert not {"xgrammar", "apache-tvm-ffi"} & dependencies
    results, bindings = {}, {}
    for name, (script, _, _) in JOBS.items():
        receipt = ROOT / f"benchmarks/results/{args.prefix}-{name}.json"
        sidecar = receipt.with_name(receipt.stem + "-binding.json")
        data, binding = json.loads(receipt.read_text()), json.loads(sidecar.read_text())
        assert data["status"].startswith("passed"), name
        assert binding["build"] == build and binding["executable_sha256"] == executable and binding["cli_sha256"] == cli, name
        assert binding["gate"] == name and binding["signature_valid_after_gate"], name
        assert binding["receipt_sha256"] == sha(receipt), name
        assert binding["harness_sha256"] == (sha(ROOT / "benchmarks" / script) if script else None), name
        if "build" in data:
            assert data["build"] == build, name
        for key in ("cli_sha256", "cli_executable_sha256"):
            if key in data:
                assert data[key] == cli, name
        results[name] = data
        bindings[name] = dict(receipt_sha256=sha(receipt), binding_sha256=sha(sidecar))
    for name, count in (("preparation", 11), ("choice-cli", 12), ("summary-cli", 11), ("rewrite", 21), ("azure", 12), ("gemini", 8)):
        assert len(results[name]["cases"]) == count, name
    assert len(results["profiles"]["records"]) == 17
    assert len(results["choice-mcp"]["records"]) == 2 and len(results["summary-mcp"]["tools"]) == 4
    paired = results["paired-preparation"]
    assert len(paired["records"]) == 4 and not paired["paired_output_mismatches"]
    assert all(r["same_worker_pid"] and r["asr_resident"] and r["warm_asr_text_unchanged"] for r in paired["records"])
    cache = results["cache"]
    assert set(cache["rejected_models"]) == {"rewrite-quality", "meeting-quality"}
    assert all(cache[key] for key in ("asr_resident_after_rejection", "same_worker_pid", "warm_asr_text_unchanged",
                                     "isolated_cache_only_parakeet", "private_cache_removed", "no_text_download"))
    limit = results["limit"]
    assert limit["expected_failure"] == "text-output-limit" and limit["same_worker_pid"] and limit["warm_asr_text_unchanged"]
    for name, neural in (("native-long", False), ("neural-long", True)):
        assert results[name]["neural_edges"] == neural and results[name]["signature_valid_after_inference"]
        assert {r["model"] for r in results[name]["records"]} == {"parakeet-v3", "qwen3-asr"}
        assert all(r["wer"] < 0.05 for r in results[name]["records"])
    release = json.loads(args.release_manifest.read_text())
    assert release["build"] == build and release["crc_passed"] and release["extracted_signature_verified"]
    assert release["tests"] == dict(swift=438, python=355)
    archive = args.release_manifest.parent / release["archive"]
    assert sha(archive) == release["sha256"] and archive.stat().st_size == release["bytes"]
    for field, name in (("portable_receipt_sha256", "portable"), ("native_long_receipt_sha256", "native-long"),
                        ("upload_receipt_sha256", "upload-compatible"), ("deepgram_upload_receipt_sha256", "upload-deepgram"),
                        ("soniox_upload_receipt_sha256", "upload-soniox")):
        assert release[field] == bindings[name]["receipt_sha256"]
    with zipfile.ZipFile(archive) as zipped:
        assert zipped.testzip() is None
        for name, digest in (("OSpr", executable), ("ospr-cli", cli)):
            with zipped.open(f"OSpr.app/Contents/MacOS/{name}") as entry:
                assert hashlib.file_digest(entry, "sha256").hexdigest() == digest
    baseline = json.loads(args.normal_baseline.read_text())
    assert baseline and all(sha(Path(path)) == digest for path, digest in baseline.items())
    receipt = dict(status="passed-v0-review-development-package", timestamp=datetime.datetime.now(datetime.UTC).isoformat(),
                   build=build, executable_sha256=executable, cli_sha256=cli, archive=release["archive"],
                   archive_bytes=release["bytes"], archive_sha256=release["sha256"],
                   release_manifest=release, receipt_bindings=bindings, functional_gates=len(JOBS),
                   bundled_help_relative_links=results["portable"]["bundled_help_relative_links"],
                   application_source_and_backend_bytes_match=True, lock_license_notice_bytes_match=True,
                   research_grammar_dependencies_absent=True, archived_executables_identical=True,
                   normal_data_and_app_unchanged=True, scoring_helper_sha256=sha(ROOT / "benchmarks/run.py"),
                   boundary="Apple Development signed macOS26.6.2 arm64 developer preview; weights separate, not notarized. "
                   "18 exact-bundle functional gates; loopback providers use synthetic responses and no real accounts. "
                   "Long-file WER is a repeated public-speech regression fixture, not natural-meeting accuracy or latency ranking. "
                   "Bundled help is a frozen 358-link source snapshot. Native final-footer, current target-app insertion, "
                   "physical shortcut/device/acoustic, VoiceOver, representative semantic quality, isolated energy/latency, "
                   "consumer comparison and clean-Mac/older-OS/Developer-ID acceptance remain open.")
    args.output.write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps({k: receipt[k] for k in ("status", "functional_gates", "archive_bytes", "archive_sha256")}))


if __name__ == "__main__":
    main()
