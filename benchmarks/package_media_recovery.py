"""Bind real Swift WorkerClient media rejection/recovery to a standalone app.

Uses only cached models and one public speech fixture. No GUI, microphone,
provider credentials or comparative timing. Existing receipts are immutable;
--models can resume only a remaining model after diagnosing an earlier failure.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

from preview_package_gates import ROOT, sha


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--prefix", required=True)
    parser.add_argument("--models", nargs="+", choices=("whisper-small", "parakeet-v3"),
                        default=["whisper-small", "parakeet-v3"])
    args = parser.parse_args()
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,47}", args.prefix):
        parser.error("Use a lowercase filename prefix of at most 48 characters.")
    if len(set(args.models)) != len(args.models):
        parser.error("Each model may run only once.")
    app = args.app.resolve(strict=True)
    resources = app / "Contents/Resources"
    build = json.loads((resources / "build-info.json").read_text())
    assert not build["tracked_changes"]
    fingerprint = hashlib.sha256()
    for path in sorted((ROOT / "Sources").rglob("*.swift")) + sorted(
        path for path in (ROOT / "backend/ospr_backend").rglob("*") if path.suffix in {".py", ".json", ".npy"}
    ):
        fingerprint.update(str(path.relative_to(ROOT)).encode())
        fingerprint.update(path.read_bytes())
        if path.is_relative_to(ROOT / "backend"):
            assert path.read_bytes() == (resources / "Engine" / path.relative_to(ROOT)).read_bytes()
    assert fingerprint.hexdigest() == build["application_source_sha256"]
    results = ROOT / "benchmarks/results"
    for model in args.models:
        path = results / f"{args.prefix}-media-recovery-{model}.json"
        assert not path.exists() and not path.with_name(path.stem + "-binding.json").exists(), "Receipt already exists"
    harness = ROOT / "benchmarks/media_recovery.swift"
    worker = ROOT / "Sources/OSprCore/WorkerClient.swift"
    binding = dict(build=build, executable_sha256=sha(app / "Contents/MacOS/OSpr"),
                   cli_sha256=sha(app / "Contents/MacOS/ospr-cli"), engine_binding="bundled",
                   harness_sha256=sha(harness), worker_client_sha256=sha(worker),
                   runner_sha256=sha(Path(__file__)))
    environment = dict(os.environ, HF_HUB_OFFLINE="1", HF_HUB_DISABLE_TELEMETRY="1")
    environment.pop("OSPR_ROOT", None)
    with tempfile.TemporaryDirectory(prefix="ospr-package-media-") as temporary:
        staging = Path(temporary)
        executable = staging / "media-recovery"
        invalid = staging / "invalid.wav"
        invalid.write_bytes(b"Invalid public synthetic audio fixture.\n")
        subprocess.run(["swiftc", "-O", "-parse-as-library", str(worker), str(harness), "-o", str(executable)], check=True)
        for model in args.models:
            path = results / f"{args.prefix}-media-recovery-{model}.json"
            print("START " + model, flush=True)
            subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
            subprocess.run([str(executable), str(resources / "Engine"),
                            str(ROOT / "benchmarks/fixtures/audio/1272-128104-0000.wav"),
                            str(invalid), model, str(path)], cwd=staging, env=environment, check=True, timeout=600)
            subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
            path.with_name(path.stem + "-binding.json").write_text(json.dumps(
                dict(binding, receipt_sha256=sha(path), signature_valid_after_gate=True), indent=2) + "\n")
            print("PASS " + model, flush=True)


if __name__ == "__main__":
    main()
