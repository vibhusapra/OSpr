"""Offline public-file Parakeet AppModel import/retry/restart; no native UI."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import uuid

from durable_import_common import application_fingerprint, digest, prepare_probe


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package-root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--engine", type=Path, required=True)
    parser.add_argument("--audio", type=Path, required=True, help="Public speech WAV; its bytes are preserved")
    parser.add_argument("--output", type=Path, required=True, help="New private directory, never overwritten")
    args = parser.parse_args()
    package, engine, audio, output = [p.resolve() for p in [args.package_root, args.engine, args.audio, args.output]]
    source_files = sorted(p for p in (package / "backend/ospr_backend").rglob("*") if p.suffix in {".py", ".json", ".npy"})
    if not (engine / ".venv/bin/python").is_file() or not audio.is_file():
        raise ValueError("Expected an installed local engine and public speech WAV")
    hashes = {str(p.relative_to(package / "backend")): digest(p) for p in source_files}
    for name, expected in hashes.items():
        if digest(engine / "backend" / name) != expected:
            raise ValueError(f"Installed backend differs from source: {name}")
    output.mkdir(parents=True, mode=0o700, exist_ok=False)
    profile = output / ("ospr-real-import-" + str(uuid.uuid4()))
    audio_hash = digest(audio)
    protocol = {"stages": ["import-retry", "restart"], "model": "parakeet-v3", "provider": "local", "offline": True,
                "audio_name": audio.name, "audio_sha256": audio_hash, "backend_sha256": hashes,
                "swift_probe_sha256": digest(package / "benchmarks/durable_import_real.swift"), "runner_sha256": digest(Path(__file__)),
                "build": prepare_probe(package, output, "durable_import_real.swift", "DurableImportRealTemporary")}
    (output / "protocol.json").write_text(json.dumps(protocol, indent=2) + "\n")
    command = [subprocess.check_output(["xcrun", "--find", "xctest"], text=True).strip(), "-XCTest",
               "OSprPlatformTests.DurableImportRealTemporary/testStage", str(package / ".build/debug/OSprPackageTests.xctest")]
    records = []
    try:
        for stage in protocol["stages"]:
            env = os.environ | {"OSPR_REAL_IMPORT_STAGE": stage, "OSPR_REAL_IMPORT_ROOT": str(profile),
                                "OSPR_REAL_IMPORT_ENGINE": str(engine), "OSPR_REAL_IMPORT_AUDIO": str(audio), "HF_HUB_OFFLINE": "1"}
            with (output / f"{stage}.log").open("w") as log:
                result = subprocess.run(command, cwd=package, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=240)
            if result.returncode != 0:
                raise RuntimeError(f"Real import stage {stage} failed: {result.returncode}; logs retained")
            records.append({"stage": stage, "exit": result.returncode, "observed": json.loads((profile / f"{stage}-result.json").read_text())})
        if digest(audio) != audio_hash:
            raise RuntimeError("The original public fixture changed")
        if application_fingerprint(package) != protocol["build"]["application_source_sha256"]:
            raise RuntimeError("Application source changed during the real-ASR control")
    except Exception as error:
        (output / "failure.json").write_text(json.dumps({"status": "failed", "error": str(error), "completed": records}, indent=2) + "\n")
        raise
    receipt = {"status": "passed-real-local-import-retry-and-restart", "protocol": protocol, "records": records,
               "original_public_fixture_unchanged": True,
               "boundary": "Real local ASR/media recovery and headless AppModel/history/journal. No native UI, microphone, insertion or timing/product ranking."}
    (output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt, indent=2))


if __name__ == "__main__":
    main()
