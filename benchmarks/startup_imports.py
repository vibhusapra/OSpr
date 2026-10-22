"""Instrument a bundled worker's imports to locate startup cost.

Import-time tracing perturbs timing. This is a diagnostic, not a latency result.
Only pinned public audio is supplied; filtered module timing records are saved.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--model", default="parakeet-v3")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    app = args.app.resolve(strict=True)
    engine = app / "Contents/Resources/Engine"
    manifest = ROOT / "benchmarks/fixtures/manifest.json"
    item = json.loads(manifest.read_text())["items"][0]
    audio = ROOT / "benchmarks" / item["path"]
    assert sha(audio) == item["sha256"]
    environment = dict(os.environ, HF_HUB_OFFLINE="1", HF_HUB_DISABLE_TELEMETRY="1", PYTHONDONTWRITEBYTECODE="1")
    environment.pop("PYTHONPROFILEIMPORTTIME", None)
    with tempfile.TemporaryDirectory(prefix="ospr-import-profile-") as temporary:
        log = Path(temporary) / "imports.log"
        with log.open("wb") as stderr:
            began = time.perf_counter()
            process = subprocess.Popen([str(engine / ".venv/bin/python"), "-X", "importtime", "-u", "-m", "ospr_backend.worker"],
                cwd=temporary, env=environment, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr, start_new_session=True)
            selector = selectors.DefaultSelector()
            selector.register(process.stdout, selectors.EVENT_READ)

            def request(value):
                process.stdin.write((json.dumps(value) + "\n").encode())
                process.stdin.flush()
                assert selector.select(timeout=60), "Worker response deadline"
                response = json.loads(process.stdout.readline())
                assert response["id"] == value["id"] and response["ok"], "Worker rejected the public diagnostic"
                return response["result"]

            try:
                request(dict(action="ping", id="boot"))
                boot_ms = (time.perf_counter() - began) * 1000
                boot_log_bytes = log.stat().st_size
                began_inference = time.perf_counter()
                response = request(dict(action="transcribe", id="speech", model=args.model, path=str(audio)))
                request_ms = (time.perf_counter() - began_inference) * 1000
                inference_log_bytes = log.stat().st_size
                assert response["warm"] is False and response["text"].strip()
                began_exit = time.perf_counter()
                process.stdin.close()
                assert process.wait(timeout=10) == 0
                exit_ms = (time.perf_counter() - began_exit) * 1000
            finally:
                selector.close()
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGTERM)
                    try:
                        process.wait(timeout=2)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.wait()
                process.stdout.close()
        raw = log.read_bytes()
    records = []
    offset = 0
    for line in raw.splitlines(keepends=True):
        match = re.match(rb"import time:\s+(\d+)\s+\|\s+(\d+)\s+\|\s+(.+?)\s*$", line)
        if match:
            phase = "boot" if offset < boot_log_bytes else "first-transcription" if offset < inference_log_bytes else "exit"
            records.append(dict(module=match[3].decode(), self_ms=int(match[1]) / 1000,
                                cumulative_ms=int(match[2]) / 1000, phase=phase))
        offset += len(line)
    assert records
    result = dict(status="passed", verified_at=datetime.datetime.now(datetime.UTC).isoformat(),
        git_commit=subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        build=json.loads((app / "Contents/Resources/build-info.json").read_text()), model=args.model,
        fixture=item["id"], fixture_sha256=item["sha256"], manifest_sha256=sha(manifest),
        diagnostic_boot_ms=boot_ms, diagnostic_first_request_ms=request_ms, diagnostic_exit_ms=exit_ms,
        engine_reported_ms={key: response[key] for key in ("load_ms", "preprocess_ms", "decode_ms", "total_ms") if key in response},
        recognized_text=response["text"], imports=records, harness_sha256=sha(Path(__file__)),
        boundary="Bundled Python worker, -X importtime, one cold public request and EOF exit. No Swift/GUI/capture. Instrumentation perturbs timings; cumulative imports overlap and must not be summed. Not a product latency benchmark.")
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    output = args.output or ROOT / f"benchmarks/results/startup-imports-{args.model}.json"
    output.write_text(json.dumps(result, indent=2) + "\n")
    top = sorted((row for row in records if row["phase"] == "boot"), key=lambda row: row["cumulative_ms"], reverse=True)[:8]
    print(json.dumps(dict(status="passed", diagnostic_boot_ms=boot_ms, diagnostic_request_ms=request_ms, diagnostic_exit_ms=exit_ms, boot_imports=top)))


if __name__ == "__main__":
    main()
