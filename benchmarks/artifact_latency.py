"""Counterbalanced, offline timings of two preserved signed CLI artifacts.

Every terminal attempt is retained, including failures. CPU/GPU observations do
not isolate this shared Mac; GPU utilization includes the owned inference. Each
request starts a new process/model, without clearing filesystem or driver caches.
No native UI, microphone, provider account, power setting or normal profile edit.
"""
import argparse
import datetime
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import plistlib
import signal
import statistics
import subprocess
import tempfile
import threading
import time

import jiwer

from run import normalize

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def write_new(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("x") as output:
        json.dump(value, output, indent=2, allow_nan=False)
        output.write("\n")


def snapshot(root_pid=None):
    """Publish aggregates only, with neither process names nor PID inventories."""
    result = dict(timestamp=datetime.datetime.now(datetime.UTC).isoformat(), load_average=list(os.getloadavg()))
    try:
        rows = [line.split() for line in subprocess.check_output(
            ["ps", "-A", "-o", "pid=,ppid=,%cpu="], text=True, timeout=5).splitlines()]
        owned = {root_pid} if root_pid else set()
        while True:
            expanded = owned | {int(pid) for pid, parent, _ in rows if int(parent) in owned}
            if expanded == owned:
                break
            owned = expanded
        result["ps_reported_external_cpu_percent"] = sum(float(cpu) for pid, _, cpu in rows if int(pid) not in owned)
        result["ps_reported_owned_cpu_percent"] = sum(float(cpu) for pid, _, cpu in rows if int(pid) in owned)
    except (subprocess.SubprocessError, ValueError) as error:
        result["cpu_observation_error"] = type(error).__name__
    try:
        raw = subprocess.check_output(["ioreg", "-a", "-r", "-c", "AGXAccelerator"], timeout=5)
        stats = plistlib.loads(raw)
        names = ("Device Utilization %", "Renderer Utilization %", "Tiler Utilization %")
        result["driver_gpu_statistics"] = [{key: row.get("PerformanceStatistics", {}).get(key) for key in names} for row in stats]
    except (subprocess.SubprocessError, plistlib.InvalidFileException, ValueError) as error:
        result["gpu_observation_error"] = type(error).__name__
    return result


def group_summary(records):
    groups = {}
    for row in records:
        key = row["group"] + "/" + row["artifact"]
        group = groups.setdefault(key, dict(attempts=0, successful=0, failures=0, wall_ms=[]))
        group["attempts"] += 1
        group["successful" if row["status"] == "completed" else "failures"] += 1
        if row["status"] == "completed":
            group["wall_ms"].append(row["wall_ms"])
    for group in groups.values():
        values = group["wall_ms"]
        group["successful_wall_ms_median"] = statistics.median(values) if values else None
    return groups


def stop_owned(child):
    """Stop only this CLI's observed descendants, including worker sessions."""
    rows = [line.split() for line in subprocess.check_output(["ps", "-A", "-o", "pid=,ppid="], text=True).splitlines()]
    owned = {child.pid}
    while True:
        expanded = owned | {int(pid) for pid, parent in rows if int(parent) in owned}
        if expanded == owned:
            break
        owned = expanded
    for pid in sorted(owned - {child.pid}) + [child.pid]:
        try:
            if os.getpgid(pid) == pid:
                os.killpg(pid, signal.SIGTERM)
            else:
                os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    try:
        return child.wait(timeout=3)
    except subprocess.TimeoutExpired:
        child.kill()
        return child.wait(timeout=3)


def verify_result(protocol, result):
    """Check retained records, including failure denominators, without models."""
    assert result["status"] == "completed-counterbalanced-artifact-observations"
    assert result["artifacts"] == protocol["artifacts"]
    assert set(result["device_preflight"]) == set(protocol["artifacts"])
    assert all(value["metal_available"] and value["device"].startswith("Device(gpu") and value["value"] == 2
               for value in result["device_preflight"].values())
    assert len(result["records"]) == len(protocol["cases"])
    for expected, row in zip(protocol["cases"], result["records"], strict=True):
        assert all(row[key] == value for key, value in expected.items())
        assert row["status"] in {"completed", "failed", "timeout", "invalid-response"}
        assert math.isfinite(row["wall_ms"]) and row["wall_ms"] >= 0
        assert row["signature_valid_after"] and row["normal_baseline_unchanged"]
        assert row["cli_sha256"] == protocol["artifacts"][row["artifact"]]["cli_sha256"]
        assert row["fixture_sha256"] == protocol["fixtures"][row["fixture"]]["sha256"]
        if row["status"] == "completed":
            response = row["response"]
            assert row["return_code"] == 0 and response["model"] == row["model"] and response["warm"] is False
            assert abs(response["audio_seconds"] - protocol["fixtures"][row["fixture"]]["seconds"]) <= 1 / 16000
            for key in ("load_ms", "decode_ms", "total_ms"):
                assert math.isfinite(response[key]) and response[key] >= 0
            score = jiwer.process_words(normalize(protocol["fixtures"][row["fixture"]]["reference"]), normalize(response["text"]))
            assert row["word_errors"] == score.substitutions + score.deletions + score.insertions
            assert row["wer"] == score.wer
        else:
            assert row["return_code"] != 0 or row["status"] in {"timeout", "invalid-response"}
            assert "response" not in row
    assert result["groups"] == group_summary(result["records"])
    assert all(row["protocol_sha256"] == result["protocol_sha256"] and row["harness_sha256"] == protocol["harness_sha256"] for row in result["records"])
    assert result["harness_sha256"] == protocol["harness_sha256"]
    assert result["all_attempts_retained"] is True
    return dict(attempts=len(result["records"]), failures=sum(row["status"] != "completed" for row in result["records"]))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--protocol", type=Path, default=ROOT / "benchmarks/fixtures/artifact-latency-protocol.json")
    parser.add_argument("--output", type=Path, default=ROOT / "benchmarks/results/artifact-latency-control.json")
    parser.add_argument("--normal-baseline", type=Path)
    parser.add_argument("--only", nargs="+", help="Resume only remaining case IDs after diagnosing an interrupted invocation")
    parser.add_argument("--verify", type=Path, help="Verify an existing aggregate without running inference")
    args = parser.parse_args()
    protocol = json.loads(args.protocol.read_text())
    if args.verify:
        result = json.loads(args.verify.read_text())
        assert result["protocol_sha256"] == sha(args.protocol)
        print(json.dumps(verify_result(protocol, result)))
        return
    if args.normal_baseline is None:
        parser.error("An owned normal-file SHA baseline is required; its paths/contents are never published.")
    assert not args.output.exists(), "Refusing to replace an aggregate"
    baseline = json.loads(args.normal_baseline.read_text())

    def unchanged():
        return bool(baseline) and all(sha(Path(path)) == digest for path, digest in baseline.items())

    assert unchanged(), "Normal baseline changed before inference"
    assert sha(Path(__file__)) == protocol["harness_sha256"]
    assert sha(ROOT / "benchmarks/run.py") == protocol["scorer_source_sha256"]
    assert sha(ROOT / "uv.lock") == protocol["lock_sha256"]
    artifacts = {}
    devices = {}
    environment = dict(protocol["environment"], HOME=str(Path.home()))
    for name, expected in protocol["artifacts"].items():
        app = ROOT / expected["relative_path"]
        resources = app / "Contents/Resources"
        cli = app / "Contents/MacOS/ospr-cli"
        assert sha(cli) == expected["cli_sha256"] and sha(app / "Contents/MacOS/OSpr") == expected["gui_sha256"]
        assert sha(resources / "dependencies.json") == expected["dependencies_sha256"]
        assert json.loads((resources / "build-info.json").read_text()) == expected["build"]
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
        preflight = "import json,mlx.core as mx; x=mx.array([1])+1; mx.eval(x); print(json.dumps(dict(device=str(mx.default_device()),metal_available=mx.metal.is_available(),value=x.item())))"
        devices[name] = json.loads(subprocess.check_output([str(resources / "Engine/.venv/bin/python"), "-c", preflight], env=environment, text=True, timeout=30))
        assert devices[name]["metal_available"] and devices[name]["device"].startswith("Device(gpu") and devices[name]["value"] == 2
        artifacts[name] = (app, cli)
    for fixture in protocol["fixtures"].values():
        assert sha(ROOT / fixture["path"]) == fixture["sha256"]
    selected = [row for row in protocol["cases"] if not args.only or row["id"] in args.only]
    assert selected and (not args.only or len(selected) == len(args.only)), "Unknown or duplicate case IDs"
    case_directory = args.output.with_suffix("")
    case_directory.mkdir(parents=True, exist_ok=True)
    for case in selected:
        assert not (case_directory / (case["id"] + ".json")).exists(), "Case already completed; select only remaining cases"
    private = ROOT / ".local/artifact-latency-control"
    private.mkdir(parents=True, exist_ok=True, mode=0o700)
    private.chmod(0o700)
    baseline_samples = []
    for _ in range(protocol["baseline_seconds"]):
        baseline_samples.append(snapshot())
        time.sleep(1)
    for case in selected:
        assert unchanged(), "Normal baseline changed; original files will not be restored or edited"
        app, cli = artifacts[case["artifact"]]
        fixture = protocol["fixtures"][case["fixture"]]
        print("START " + case["id"], flush=True)
        samples = [snapshot()]
        stop = threading.Event()
        # Keep private attempts even if this invocation is interrupted before a
        # terminal case can be committed. Never restart an observed live child.
        logs = Path(tempfile.mkdtemp(prefix=case["id"] + "-", dir=private))
        with tempfile.TemporaryDirectory(prefix="ospr-artifact-latency-") as cwd:
            stdout_path, stderr_path = logs / "stdout", logs / "stderr"
            with stdout_path.open("w") as stdout, stderr_path.open("w") as stderr:
                started = time.perf_counter()
                child = subprocess.Popen([str(cli), protocol["command"], str(ROOT / fixture["path"]), case["model"]], cwd=cwd,
                                         env=environment, stdout=stdout, stderr=stderr, start_new_session=True)

                def observe(stop_event, observations, pid):
                    while not stop_event.wait(protocol["telemetry_interval_seconds"]):
                        observations.append(snapshot(pid))

                observer = threading.Thread(target=observe, args=(stop, samples, child.pid), daemon=True)
                observer.start()
                timed_out = False
                try:
                    code = child.wait(timeout=protocol["process_timeout_seconds"])
                except subprocess.TimeoutExpired:
                    timed_out = True
                    code = stop_owned(child)
                except BaseException:
                    stop_owned(child)
                    raise
                finally:
                    elapsed = (time.perf_counter() - started) * 1000
                    stop.set()
                    observer.join(timeout=12)
            raw = stdout_path.read_text()
            stderr = stderr_path.read_bytes()
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
        row = dict(case, status="timeout" if timed_out else "completed" if code == 0 else "failed",
                   timestamp=datetime.datetime.now(datetime.UTC).isoformat(), wall_ms=elapsed, return_code=code,
                   cli_sha256=sha(cli), fixture_sha256=sha(ROOT / fixture["path"]), signature_valid_after=True,
                   normal_baseline_unchanged=unchanged(), observations=samples + [snapshot()],
                   stderr_sha256=hashlib.sha256(stderr).hexdigest(), stderr_bytes=len(stderr),
                   protocol_sha256=sha(args.protocol), harness_sha256=sha(Path(__file__)))
        if row["status"] == "completed":
            try:
                response = json.loads(raw)
                assert response["model"] == case["model"] and response["warm"] is False
                assert abs(response["audio_seconds"] - fixture["seconds"]) <= 1 / 16000
                assert all(math.isfinite(response[key]) and response[key] >= 0 for key in ("load_ms", "decode_ms", "total_ms"))
                scored = jiwer.process_words(normalize(fixture["reference"]), normalize(response["text"]))
                row.update(response=response, wer=scored.wer, word_errors=scored.substitutions + scored.deletions + scored.insertions)
            except (ValueError, TypeError, KeyError, AssertionError) as error:
                row.update(status="invalid-response", payload_error=type(error).__name__, stdout_sha256=hashlib.sha256(raw.encode()).hexdigest())
        write_new(case_directory / (case["id"] + ".json"), row)
        print(json.dumps({key: row[key] for key in ("id", "status", "wall_ms")}), flush=True)
        assert row["normal_baseline_unchanged"], "Normal files changed; no restoration attempted"
        assert row["fixture_sha256"] == fixture["sha256"], "Public source changed; stop before further requests"
    paths = [case_directory / (case["id"] + ".json") for case in protocol["cases"]]
    if not all(path.exists() for path in paths):
        print("Partial invocation retained; aggregate requires every frozen case.")
        return
    records = [json.loads(path.read_text()) for path in paths]
    assert all(row["protocol_sha256"] == sha(args.protocol) and row["harness_sha256"] == sha(Path(__file__)) for row in records)
    result = dict(status="completed-counterbalanced-artifact-observations", protocol_sha256=sha(args.protocol),
                  harness_sha256=sha(Path(__file__)), artifacts=protocol["artifacts"], records=records,
                  groups=group_summary(records), baseline_observations=baseline_samples,
                  device_preflight=devices,
                  hardware=dict(machine=platform.machine(), macos=platform.mac_ver()[0], logical_cpus=os.cpu_count()),
                  all_attempts_retained=True, boundary=protocol["boundary"],
                  observation_limit="Driver GPU utilization includes this inference; ps CPU percentages are OS-reported observations, not isolated CPU time or energy. No thermal, power or background-work control.")
    verify_result(protocol, result)
    write_new(args.output, result)
    print(json.dumps(group_summary(records)), flush=True)


if __name__ == "__main__":
    main()
