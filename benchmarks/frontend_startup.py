"""Paired worker startup and prepared-request controls at file/microphone rates.

Uses public file input, not live capture. Fresh workers, primed OS caches, three
serial trials per rate/mode/build. Explicit preparation includes resampling/JIT.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import random
import selectors
import signal
import subprocess
import tempfile
import time

import numpy as np
from scipy.signal import resample_poly
import soundfile as sf

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def trial(app, audio, prepared):
    environment = dict(os.environ, HF_HUB_OFFLINE="1", HF_HUB_DISABLE_TELEMETRY="1")
    with tempfile.TemporaryDirectory(prefix="ospr-frontend-control-") as directory:
        with (Path(directory) / "stderr.log").open("wb") as errors:
            began = time.perf_counter()
            process = subprocess.Popen([str(app / "Contents/Resources/Engine/.venv/bin/python"),
                "-u", "-m", "ospr_backend.worker"], cwd=directory, env=environment,
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=errors, start_new_session=True, bufsize=0)
            selector = selectors.DefaultSelector()
            selector.register(process.stdout, selectors.EVENT_READ)

            def request(action, **kwargs):
                process.stdin.write((json.dumps(dict(action=action, id=action, **kwargs)) + "\n").encode())
                deadline = time.perf_counter() + 60
                while True:
                    remaining = deadline - time.perf_counter()
                    assert remaining > 0 and selector.select(timeout=remaining), "Worker control deadline"
                    frame = json.loads(process.stdout.readline())
                    assert frame["id"] == action
                    if frame.get("event") == "progress":
                        continue
                    assert frame["ok"], "Worker rejected control request"
                    return frame["result"]

            try:
                request("ping")
                boot_ms = (time.perf_counter() - began) * 1000
                prime_started = time.perf_counter()
                prime = request("warm", model="parakeet-v3") if prepared else None
                preparation_ms = (time.perf_counter() - prime_started) * 1000 if prepared else None
                request_started = time.perf_counter()
                response = request("transcribe", model="parakeet-v3", path=str(audio))
                request_ms = (time.perf_counter() - request_started) * 1000
                assert response["warm"] == prepared and response["text"].strip()
                process.stdin.close()
                assert process.wait(timeout=10) == 0
                return dict(boot_ms=boot_ms, preparation_ms=preparation_ms, preparation=prime,
                    request_ms=request_ms, response=response)
            finally:
                selector.close()
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGTERM)
                    try:
                        process.wait(timeout=2)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.wait()
                if not process.stdin.closed:
                    process.stdin.close()
                process.stdout.close()

    
def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--before", required=True, type=Path)
    parser.add_argument("--after", required=True, type=Path)
    parser.add_argument("--output", type=Path, default=ROOT / "benchmarks/results/frontend-startup.json")
    args = parser.parse_args()
    apps = {key: value.resolve(strict=True) for key, value in (("before", args.before), ("after", args.after))}
    item = json.loads((ROOT / "benchmarks/fixtures/manifest.json").read_text())["items"][0]
    source = ROOT / "benchmarks" / item["path"]
    assert sha(source) == item["sha256"]
    audio, rate = sf.read(source, dtype="float32")
    assert rate == 16000 and audio.ndim == 1
    records = []
    with tempfile.TemporaryDirectory(prefix="ospr-public-rates-") as directory:
        inputs = {}
        for target in (16000, 48000):
            path = Path(directory) / f"public-{target}.wav"
            sf.write(path, audio if target == rate else resample_poly(audio, 3, 1), target, subtype="FLOAT")
            inputs[target] = path
        jobs = [(build, rate, prepared, repeat) for build in apps for rate in inputs
                for prepared in (False, True) for repeat in range(3)]
        random.Random(20261022).shuffle(jobs)
        for build, rate, prepared, repeat in jobs:
            result = trial(apps[build], inputs[rate], prepared)
            records.append(dict(build=build, sample_rate=rate, prepared=prepared, repeat=repeat, **result))
            print(json.dumps(dict(done=len(records), total=len(jobs))), flush=True)
        for rate in inputs:
            texts = {record["response"]["text"] for record in records if record["sample_rate"] == rate}
            assert len(texts) == 1, "Text changed between builds or preparation modes"
        input_hashes = {str(rate): sha(path) for rate, path in inputs.items()}
    summary = []
    for build in apps:
        for rate in (16000, 48000):
            for prepared in (False, True):
                rows = [r for r in records if (r["build"], r["sample_rate"], r["prepared"]) == (build, rate, prepared)]
                summary.append(dict(build=build, sample_rate=rate, prepared=prepared, trials=len(rows),
                    **{key: float(np.median([r[key] for r in rows])) for key in ("boot_ms", "request_ms")},
                    preparation_ms=float(np.median([r["preparation_ms"] for r in rows])) if prepared else None))
    for app in apps.values():
        subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    receipt = dict(status="passed", verified_at=datetime.datetime.now(datetime.UTC).isoformat(),
        builds={name: json.loads((app / "Contents/Resources/build-info.json").read_text()) for name, app in apps.items()},
        fixture_id=item["id"], source_sha256=item["sha256"], input_sha256=input_hashes,
        harness_sha256=sha(Path(__file__)), summary=summary, records=records,
        boundary="24 seeded-random serial fresh workers, three trials per build/rate/preparation combination. Public 16 kHz speech and its 48 kHz resampling; explicit warm precedes prepared requests. No Swift, GUI, actual microphone, endpointing, insertion or uncached OS startup. Shared active Mac; three trials establish a control, not a latency SLA.")
    args.output.write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(dict(status="passed", summary=summary)))


if __name__ == "__main__":
    main()
