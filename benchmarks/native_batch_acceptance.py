"""Prepare/verify an owned real-ASR batch around separately recorded native UI QA.

Does not launch apps, press buttons or establish native acceptance by itself.
Only manifest-bound public speech and an explicitly selected signed app are used.
All output is private by default; publish a reviewed projection, never this root.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess

from durable_import_common import application_fingerprint, digest, prepare_probe


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stage", choices=("prepare", "verify-resumed", "verify-dismissed", "verify-cancelled"), required=True)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    package = Path(__file__).resolve().parents[1]
    app, output = args.app.resolve(strict=True), args.output.resolve()
    engine = app / "Contents/Resources/Engine"
    build = json.loads((app / "Contents/Resources/build-info.json").read_text())
    if application_fingerprint(package) != build["application_source_sha256"]:
        raise ValueError("Selected native app does not contain the current application source")
    for path in (package / "backend/ospr_backend").rglob("*"):
        if path.suffix in {".py", ".json", ".npy"}:
            if digest(path) != digest(engine / "backend" / path.relative_to(package / "backend")):
                raise ValueError("Bundled backend differs from current source")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    if args.stage == "prepare":
        output.mkdir(parents=True, mode=0o700, exist_ok=False)
        item = json.loads((package / "benchmarks/fixtures/manifest.json").read_text())["items"][0]
        audio = package / "benchmarks" / item["path"]
        if digest(audio) != item["sha256"]:
            raise ValueError("Public speech fixture hash differs")
        inputs = output / "inputs"
        inputs.mkdir(mode=0o700)
        for name in ("Resume Alpha.wav", "Resume Omega.wav"):
            shutil.copy2(audio, inputs / name)
        (inputs / "Resume Repair.wav").write_bytes(b"Public malformed native-batch fixture.\n")
        temporary = package / "Tests/OSprPlatformTests/NativeBatchAcceptanceTemporary.swift"
        if temporary.exists():
            raise ValueError("A native batch probe source already exists")
        try:
            shutil.copy2(package / "benchmarks/native_batch_acceptance.swift", temporary)
            binding = prepare_probe(package, output, "native_batch_acceptance.swift", "NativeBatchAcceptanceTemporary")
        finally:
            temporary.unlink(missing_ok=True)
        protocol = dict(app_build=build, app_executable_sha256=digest(app / "Contents/MacOS/OSpr"),
                        engine_backend_matches_source=True, probe_binding=binding, fixture_id=item["id"],
                        original_audio=str(audio), original_audio_sha256=item["sha256"], runner_sha256=digest(Path(__file__)))
        (output / "protocol-private.json").write_text(json.dumps(protocol, indent=2) + "\n")
    else:
        protocol = json.loads((output / "protocol-private.json").read_text())
        if protocol["app_build"] != build or protocol["runner_sha256"] != digest(Path(__file__)):
            raise ValueError("App or runner changed after fixture preparation")
        if protocol["app_executable_sha256"] != digest(app / "Contents/MacOS/OSpr"):
            raise ValueError("Native app executable changed after fixture preparation")
        if protocol["probe_binding"]["probe_sha256"] != digest(package / "benchmarks/native_batch_acceptance.swift"):
            raise ValueError("Swift probe source changed after fixture preparation")
        if (output / f"{args.stage}-result.json").exists():
            raise ValueError("Verification receipt already exists; never silently replace an attempt")
    executable = package / ".build/debug/OSprPackageTests.xctest/Contents/MacOS/OSprPackageTests"
    if digest(executable) != protocol["probe_binding"]["test_executable_sha256"]:
        raise ValueError("Compiled test probe changed; do not substitute a stale executable")
    command = [subprocess.check_output(["xcrun", "--find", "xctest"], text=True).strip(), "-XCTest",
               "OSprPlatformTests.NativeBatchAcceptanceTemporary/testStage", str(executable.parents[2])]
    environment = os.environ | {"HF_HUB_OFFLINE": "1", "OSPR_NATIVE_BATCH_STAGE": args.stage,
                                "OSPR_NATIVE_BATCH_OUTPUT": str(output), "OSPR_NATIVE_BATCH_ENGINE": str(engine)}
    with (output / f"{args.stage}.log").open("w") as log:
        result = subprocess.run(command, cwd=package, env=environment, stdout=log, stderr=subprocess.STDOUT, timeout=180)
    if result.returncode:
        raise RuntimeError(f"Stage {args.stage} failed; original log/profile retained")
    if digest(Path(protocol["original_audio"])) != protocol["original_audio_sha256"]:
        raise ValueError("Original public input changed")
    if args.stage == "prepare":
        shutil.copy2(protocol["original_audio"], output / "inputs/Resume Repair.wav")
    print(json.dumps(dict(status="passed-" + args.stage, native_interaction_proven=False,
                          profile=str(output / "ospr-native-batch-profile"))))


if __name__ == "__main__":
    main()
