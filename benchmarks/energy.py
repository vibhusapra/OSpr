"""Exploratory rootless whole-system power under sustained warm ASR.

Requires Homebrew mactop. Publishes only an allowlist of counters, never the
process/port/network inventories emitted by the monitoring tool. No server,
screen capture, fan control, elevated privileges or app permissions are used.
"""

import argparse
import datetime
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import random
import shutil
import subprocess
import threading
import time

from ospr_backend.engine import Engine, MODELS, PUBLIC_MODELS

ROOT = Path(__file__).resolve().parent
POWER = ("cpu_power", "gpu_power", "ane_power", "dram_power", "total_power")
COUNTERS = (*POWER, "cpu_temp", "gpu_temp", "gpu_active")
TOOL_REVISION = "1e314f047dd7b494f286b7118fea80b3006c41be"


class Monitor:
    def __init__(self, executable):
        self.samples = []
        self.errors = []
        self.process = subprocess.Popen(
            [executable, "--headless", "--interval", "1000"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
        )
        self.reader = threading.Thread(target=self.read, daemon=True)
        self.reader.start()

    def read(self):
        for line in self.process.stdout:
            arrival = time.monotonic()
            try:
                row = json.loads(line)
                soc = row["soc_metrics"]
                clean = {k: float(soc[k]) for k in COUNTERS}
                if not all(math.isfinite(v) and v >= 0 for v in clean.values()):
                    raise ValueError("Nonfinite or negative monitoring counter")
                self.samples.append(dict(monotonic=arrival, timestamp=row["timestamp"],
                                         thermal_state=row["thermal_state"], counters=clean))
            except (ValueError, TypeError, KeyError):
                self.errors.append("Invalid telemetry sample")

    def stop(self):
        self.process.terminate()
        self.process.wait(timeout=15)
        self.reader.join(timeout=5)
        self.process.stdout.close()


def summarize(samples, start, end, inset=3):
    # Tool timestamps have one-second resolution and collection adds overhead.
    # Exclude both transitions rather than assigning mixed windows to a phase.
    rows = [r for r in samples if start + inset <= r["monotonic"] <= end - inset]
    if len(rows) < 3:
        raise ValueError("Too few interior telemetry samples; increase phase duration")
    return dict(samples=len(rows), start_monotonic=start, end_monotonic=end,
                interior_seconds=end - start - 2 * inset,
                mean={k: math.fsum(r["counters"][k] for r in rows) / len(rows) for k in COUNTERS},
                thermal_states=sorted({str(r["thermal_state"]) for r in rows}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--models", nargs="+", choices=MODELS, default=list(PUBLIC_MODELS))
    parser.add_argument("--seconds", type=float, default=30)
    parser.add_argument("--idle-seconds", type=float, default=20)
    parser.add_argument("--output", type=Path, default=ROOT / "results/energy.json")
    args = parser.parse_args()
    if args.seconds < 15 or args.idle_seconds < 15:
        parser.error("Each phase must last at least 15 seconds")
    executable = shutil.which("mactop")
    if not executable:
        raise SystemExit("Install the official Homebrew mactop formula first")
    version = subprocess.check_output([executable, "--version"], text=True).strip()
    # The documented sampling boundary was inspected at this exact tool version.
    if version != "mactop version: v2.1.6":
        raise SystemExit("Inspect the new tool sampling boundary before changing the version guard")
    manifest = json.loads((ROOT / "fixtures/test-clean.json").read_text())
    items = manifest["items"]
    for item in items:
        if hashlib.sha256((ROOT / item["path"]).read_bytes()).hexdigest() != item["sha256"]:
            raise ValueError("Public speech fixture checksum mismatch")
    order = list(args.models)
    random.Random(20261022).shuffle(order)
    engine = Engine()
    result = dict(timestamp=datetime.datetime.now(datetime.UTC).isoformat(),
                  platform=platform.platform(), hardware=subprocess.check_output(
                      ["/usr/sbin/sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip(),
                  tool=dict(version=version, upstream_revision=TOOL_REVISION,
                            executable_sha256=hashlib.sha256(Path(executable).read_bytes()).hexdigest(),
                            source="https://github.com/metaspartan/mactop/tree/" + TOOL_REVISION),
                  source_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                  corpus=dict(manifest="test-clean.json", manifest_sha256=hashlib.sha256(
                      (ROOT / "fixtures/test-clean.json").read_bytes()).hexdigest(),
                      license=manifest["license"], selection=manifest["selection"]),
                  model_lock=json.loads((ROOT.parent / "backend/ospr_backend/models.lock.json").read_text()),
                  backend_sha256=hashlib.sha256(b"".join(
                      p.name.encode() + b"\0" + p.read_bytes()
                      for p in sorted((ROOT.parent / "backend/ospr_backend").glob("*.py")))).hexdigest(),
                  git_commit=subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
                  offline=os.environ.get("HF_HUB_OFFLINE") == "1", order=order, trials=[],
                  boundary="Warm Engine.transcribe on preverified public WAV files, sustained serial throughput; rootless mactop whole-system counters. Excludes model load, microphone, IPC, UI and insertion.",
                  limitations=["One block per model, randomized fixed order, one shared Mac; no thermal or other-process isolation.",
                               "OS/private-API power estimates, not a calibrated wall meter or battery test; includes observer and all other system activity.",
                               "Interior sample means times phase duration estimate joules; collection is sparse and transitions are excluded by 3 seconds.",
                               "Idle-subtracted energy is signed and can be confounded by idle drift; do not rank products from this exploratory run.",
                               "Maximum-throughput repeated public read speech differs from human-paced dictation. No consumer app comparison."])
    for model in order:
        engine.transcribe(str(ROOT / items[0]["path"]), model, language="en")
        monitor = Monitor(executable)
        try:
            idle_start = time.monotonic()
            time.sleep(args.idle_seconds)
            active_start = time.monotonic()
            requests = []
            while time.monotonic() - active_start < args.seconds:
                item = items[len(requests) % len(items)]
                started = time.monotonic()
                decoded = engine.transcribe(str(ROOT / item["path"]), model, language="en")
                requests.append(dict(id=item["id"], seconds=item["seconds"],
                                     wall_ms=(time.monotonic() - started) * 1000,
                                     text=decoded["text"]))
            active_end = time.monotonic()
            time.sleep(args.idle_seconds)
            idle_end = time.monotonic()
        finally:
            monitor.stop()
        if monitor.errors:
            raise ValueError(monitor.errors)
        before = summarize(monitor.samples, idle_start, active_start)
        active = summarize(monitor.samples, active_start, active_end)
        after = summarize(monitor.samples, active_end, idle_end)
        duration = active_end - active_start
        audio_seconds = sum(r["seconds"] for r in requests)
        baseline = {k: (before["mean"][k] + after["mean"][k]) / 2 for k in POWER}
        gross = {k: active["mean"][k] * duration for k in POWER}
        incremental = {k: (active["mean"][k] - baseline[k]) * duration for k in POWER}
        trial = dict(model=model, model_spec=MODELS[model], idle_before=before,
                     active=active, idle_after=after, active_seconds=duration,
                     audio_seconds=audio_seconds, requests=len(requests),
                     aggregate_rtf=duration / audio_seconds,
                     gross_joules_estimate=gross, idle_subtracted_joules_estimate=incremental,
                     incremental_joules_per_audio_minute={k: v * 60 / audio_seconds for k, v in incremental.items()},
                     telemetry=monitor.samples, outputs=requests)
        result["trials"].append(trial)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps({k: trial[k] for k in ("model", "requests", "audio_seconds", "aggregate_rtf", "incremental_joules_per_audio_minute")}), flush=True)


if __name__ == "__main__":
    main()
