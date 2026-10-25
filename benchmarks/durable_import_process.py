"""Intentional owned-process interruption/restart; synthetic IPC, no ASR/UI."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import time
import uuid

from durable_import_common import application_fingerprint, digest, prepare_probe


def run(package: Path, output: Path) -> dict:
    root = output / ("ospr-batch-process-" + str(uuid.uuid4()))
    xctest = subprocess.check_output(["xcrun", "--find", "xctest"], text=True).strip()
    command = [xctest, "-XCTest", "OSprPlatformTests.DurableImportProcessTemporary/testStage", str(package / ".build/debug/OSprPackageTests.xctest")]
    protocol = {
        "stages": ["admit-and-kill", "resume", "verify", "privacy"],
        "scope": "Synthetic worker/AppModel/history/journal. No native UI or recognition model.",
        "swift_probe_sha256": digest(package / "benchmarks/durable_import_process.swift"),
        "runner_sha256": digest(Path(__file__)),
        "command": command,
        "build": prepare_probe(package, output, "durable_import_process.swift", "DurableImportProcessTemporary"),
    }
    (output / "protocol.json").write_text(json.dumps(protocol, indent=2) + "\n")
    records = []

    def start(stage):
        env = os.environ | {"OSPR_BATCH_PROCESS_STAGE": stage, "OSPR_BATCH_PROCESS_ROOT": str(root)}
        log = (output / f"{stage}.log").open("w")
        process = subprocess.Popen(command, cwd=package, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        return process, log

    def stop_verified_worker(pid):
        check = subprocess.run(["ps", "-p", str(pid), "-o", "args="], capture_output=True, text=True)
        if check.returncode != 0:
            return
        cwd = subprocess.check_output(["/usr/sbin/lsof", "-a", "-p", str(pid), "-d", "cwd", "-Fn"], text=True)
        if "n" + str(root / "engine") not in cwd.splitlines() or not check.stdout.strip().endswith("-u -m ospr_backend.worker"):
            raise RuntimeError("Fixture worker identity changed; refusing to kill it")
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass

    process, log = start("admit")
    owned_worker = None
    try:
        deadline = time.monotonic() + 45
        while not (root / "admit-ready.json").is_file():
            if process.poll() is not None:
                raise RuntimeError("Admission process exited before the planned interruption")
            if time.monotonic() >= deadline:
                raise TimeoutError("Admission marker did not arrive while the process was live")
            time.sleep(0.05)
        if process.poll() is not None:
            raise RuntimeError("Admission process is no longer live; refusing to label this an intentional kill")
        before = json.loads((root / "admit-ready.json").read_text())
        if before["test_pid"] != process.pid:
            raise RuntimeError("Test PID differs from the owned process; refusing an ambiguous kill")
        candidate_worker = int(before["worker_pid"])
        cwd = subprocess.check_output(["/usr/sbin/lsof", "-a", "-p", str(candidate_worker), "-d", "cwd", "-Fn"], text=True)
        parent = subprocess.check_output(["ps", "-p", str(candidate_worker), "-o", "ppid="], text=True).strip()
        if parent != str(process.pid) or "n" + str(root / "engine") not in cwd.splitlines():
            raise RuntimeError("Fixture worker ownership does not match this test")
        owned_worker = candidate_worker
        os.killpg(process.pid, signal.SIGKILL)
        code = process.wait(timeout=10)
        if code != -signal.SIGKILL:
            raise RuntimeError(f"Unexpected interruption exit {code}")
        # Foundation Process gives its child a separate process group on macOS.
        # Clean only this verified fixture worker, after interrupting the parent.
        stop_verified_worker(owned_worker)
        owned_worker = None
        before["verified_fixture_worker_cleanup"] = True
        records.append({"stage": "admit", "outcome": "intentional-live-process-group-sigkill", "exit": code, "observed": before})
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=10)
        if owned_worker is not None:
            stop_verified_worker(owned_worker)
        log.close()
    settings_path = root / "settings.json"
    settings = json.loads(settings_path.read_text())
    settings.update(model="parakeet-v3", language="fr")
    settings_path.write_text(json.dumps(settings, indent=2) + "\n")
    (root / "engine/allow-slow").touch()
    for stage in ["resume", "verify", "privacy"]:
        if stage == "privacy":
            settings["saveHistory"] = False
            settings_path.write_text(json.dumps(settings, indent=2) + "\n")
        process, log = start(stage)
        try:
            code = process.wait(timeout=45)
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=10)
            log.close()
        if code != 0:
            raise RuntimeError(f"Stage {stage} failed with exit {code}; logs retained")
        value = json.loads((root / f"{stage}-result.json").read_text())
        records.append({"stage": stage, "exit": code, "observed": value})
    if application_fingerprint(package) != protocol["build"]["application_source_sha256"]:
        raise RuntimeError("Application source changed during the process control")
    return {"status": "passed-intentional-process-interruption-and-restart", "protocol": protocol, "records": records}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package-root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--output", type=Path, required=True, help="New private directory; never overwritten")
    args = parser.parse_args()
    # Refuse an existing directory before entering failure-report publication.
    # Failed/repeated invocations must not mutate a retained earlier run.
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=False)
    try:
        receipt = run(args.package_root.resolve(), args.output.resolve())
    except Exception as error:
        receipt = {"status": "failed", "error": str(error), "boundary": "All existing stage logs retained; failure is not a successful interruption."}
        if args.output.is_dir():
            (args.output / "failure.json").write_text(json.dumps(receipt, indent=2) + "\n")
        raise
    (args.output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt, indent=2))


if __name__ == "__main__":
    main()
