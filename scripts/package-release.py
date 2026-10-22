"""Package the standalone Mac app only after relocated/offline runtime verification.

Uses ditto so executable bits, symlinks and hidden runtime files survive delivery.
The previously published local archive is replaced only after every check passes.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import zipfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=Path("dist/standalone/OSpr.app"))
    parser.add_argument("--receipt", type=Path, default=Path("benchmarks/results/portable-app-smoke.json"))
    parser.add_argument("--native-long-receipt", type=Path, default=Path("benchmarks/results/native-long-files.json"))
    parser.add_argument("--upload-receipt", type=Path, default=Path("benchmarks/results/upload-parts.json"))
    parser.add_argument("--swift-log", type=Path, required=True)
    parser.add_argument("--python-log", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=Path("dist"))
    args = parser.parse_args()
    app = args.app.resolve(strict=True)
    swift = args.swift_log.read_text()
    python = args.python_log.read_text()
    assert "Test Suite 'All tests' passed" in swift, "A successful native test receipt is required"
    swift_counts = re.findall(r"Executed (\d+) tests?, with 0 failures", swift)
    python_counts = re.findall(r"(?:^|\n)(\d+) passed(?: in|,)", python)
    assert swift_counts and python_counts and not re.search(r"\d+ failed", python)
    receipt = json.loads(args.receipt.read_text())
    assert receipt.get("bundled_help_relative_links", 0) > 0, "Bundled research/help links were not verified"
    executable_sha = hashlib.sha256((app / "Contents/MacOS/OSpr").read_bytes()).hexdigest()
    assert receipt["status"] == "passed" and receipt["executable_sha256"] == executable_sha, "Portable receipt is for a different app"
    build = json.loads((app / "Contents/Resources/build-info.json").read_text())
    assert receipt["build"] == build, "Portable receipt build metadata differs"
    long_receipt = json.loads(args.native_long_receipt.read_text())
    assert long_receipt["status"] == "passed" and long_receipt["build"] == build, "Bundled long-file receipt differs"
    assert len(long_receipt["records"]) == 2 and {r["model"] for r in long_receipt["records"]} == {"parakeet-v3", "qwen3-asr"}
    assert long_receipt["cli_executable_sha256"] == hashlib.sha256((app / "Contents/MacOS/ospr-cli").read_bytes()).hexdigest()
    assert long_receipt["signature_valid_after_inference"], "Long-file inference changed the signed app"
    upload_receipt = json.loads(args.upload_receipt.read_text())
    assert upload_receipt["status"] == "passed" and upload_receipt["engine_binding"] == "bundled"
    assert upload_receipt["build"] == build, "Upload receipt is for a different build"
    assert upload_receipt["cli_sha256"] == long_receipt["cli_executable_sha256"], "Upload receipt CLI differs"
    assert upload_receipt["signature_valid_after_upload"] and upload_receipt["workspace_removed"] and upload_receipt["source_preserved"]
    assert upload_receipt["seconds"] == 4800 and sum(row["frames"] for row in upload_receipt["requests"]) == 4800 * 16000
    assert all(row["request_bytes"] < 25_000_000 for row in upload_receipt["requests"])
    with (app / "Contents/Info.plist").open("rb") as file:
        info = plistlib.load(file)
    version = info["CFBundleShortVersionString"]
    name = f"OSpr-v{version}-macOS{info['LSMinimumSystemVersion']}-arm64.zip"
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    with tempfile.TemporaryDirectory(prefix="ospr-package-", dir=output) as temporary:
        staging = Path(temporary)
        archive = staging / name
        subprocess.run(["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(archive)], check=True)
        with zipfile.ZipFile(archive) as zipped:
            assert zipped.testzip() is None, "Archive CRC failed"
            entries = len(zipped.infolist())
        extracted = staging / "Extracted with spaces"
        subprocess.run(["/usr/bin/ditto", "-x", "-k", str(archive), str(extracted)], check=True)
        moved = extracted / app.name
        subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(moved)], check=True)
        environment = dict(HOME=str(Path.home()), PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", HF_HUB_OFFLINE="1")
        result = subprocess.run([str(moved / "Contents/MacOS/ospr-cli"), "doctor"], cwd=staging,
                                env=environment, capture_output=True, text=True, timeout=30, check=True)
        assert len(json.loads(result.stdout)["models"]) == 6
        subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(moved)], check=True)
        with archive.open("rb") as file:
            sha = hashlib.file_digest(file, "sha256").hexdigest()
        manifest = dict(version=version, timestamp=datetime.datetime.now(datetime.UTC).isoformat(),
                        archive=name, bytes=archive.stat().st_size, sha256=sha, entries=entries, build=build,
                        crc_passed=True, extracted_signature_verified=True, extracted_cli_six_models=True,
                        portable_receipt_sha256=hashlib.sha256(args.receipt.read_bytes()).hexdigest(),
                        native_long_receipt_sha256=hashlib.sha256(args.native_long_receipt.read_bytes()).hexdigest(),
                        upload_receipt_sha256=hashlib.sha256(args.upload_receipt.read_bytes()).hexdigest(),
                        upload_parts=len(upload_receipt["requests"]),
                        native_long_models=[r["model"] for r in long_receipt["records"]],
                        tests=dict(swift=int(swift_counts[-1]), python=int(python_counts[-1])),
                        native_interaction_pending="Packaging does not exercise microphone, permissions or native target-app interaction. See docs/data/parity.json.")
        staged_manifest = staging / "release-manifest.json"
        staged_manifest.write_text(json.dumps(manifest, indent=2) + "\n")
        staged_sha = staging / (name + ".sha256")
        staged_sha.write_text(f"{sha}  {name}\n")
        os.replace(archive, output / name)
        os.replace(staged_sha, output / staged_sha.name)
        os.replace(staged_manifest, output / staged_manifest.name)
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()
