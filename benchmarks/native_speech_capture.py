"""Functional replay of the bounded native speech capture path; no microphone.

Reuses every frozen VAD validation case at three input formats and two packet
patterns. It does not retune a detector or measure ASR/product latency.
"""

import argparse
import datetime
import gzip
import hashlib
import json
from math import gcd
from pathlib import Path
import subprocess

from huggingface_hub.constants import HF_HUB_CACHE
import numpy as np
from scipy.io import wavfile
from scipy.signal import resample_poly
import soundfile as sf

ROOT = Path(__file__).resolve().parent
FORMATS = [("16k-mono", 16000, 1), ("44k1-stereo", 44100, 2), ("48k-stereo", 48000, 2)]
PATTERNS = {"steady1024": [1024], "irregular": [137, 509, 1024, 2048]}


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def stats(values):
    return dict(count=len(values), p50=float(np.median(values)), p95=float(np.percentile(values, 95)),
                maximum=float(max(values))) if values else None


def command(cli, args):
    result = subprocess.run([str(cli), *map(str, args)], text=True, capture_output=True, timeout=120)
    if result.returncode:
        raise RuntimeError(result.stderr[-2000:])
    return json.loads(result.stdout)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    cli = args.cli.resolve(strict=True)
    traces_path = args.output.with_suffix(".traces.json.gz")
    assert not args.output.exists() and not traces_path.exists()
    cli_sha = sha(cli)
    protocol_path = ROOT / "fixtures/vad-causal8-validation-protocol.json"
    catalog_path = ROOT / "fixtures/vad-models.json"
    protocol = json.loads(protocol_path.read_text())
    spec = json.loads(catalog_path.read_text())["models"]["coreml-32-v6.0"]
    base = Path(HF_HUB_CACHE) / ("models--" + spec["repo"].replace("/", "--")) / "snapshots" / spec["revision"]
    for file in spec["files"]:
        assert sha(base / file["path"]) == file["sha256"]
    model = base / spec["subfolder"]
    source = protocol["items"][0]
    probes = command(cli, ["_benchmark-speech-probes", ROOT / source["path"], model])
    assert probes["status"] == "passed"
    derived = ROOT / "fixtures/audio/vad-native-capture"
    derived.mkdir(parents=True, exist_ok=True)
    rows, traces = [], []
    for item in protocol["items"]:
        path = ROOT / item["path"]
        assert sha(path) == item["sha256"]
        audio, rate = sf.read(path, dtype="float32")
        assert rate == 16000 and len(audio) == item["samples"]
        for format_id, rate, channels in FORMATS:
            if rate == 16000:
                prepared, samples = path, len(audio)
            else:
                divisor = gcd(rate, 16000)
                signal = resample_poly(audio, rate // divisor, 16000 // divisor).astype(np.float32)
                # Unequal channel gains exercise real downmix; their mean is
                # the source signal apart from float rounding. No extra clip.
                stereo = np.stack([signal * 0.5, signal * 1.5], axis=1)
                prepared = derived / (item["id"] + "-" + format_id + ".wav")
                wavfile.write(prepared, rate, stereo)
                samples = len(stereo)
            fingerprint = sha(prepared)
            for pattern_id, sizes in PATTERNS.items():
                key = item["id"] + "/" + format_id + "/" + pattern_id
                record = dict(id=item["id"], suite=item["suite"], format=format_id, pattern=pattern_id,
                              source_sha256=item["sha256"], input_sha256=fingerprint,
                              input_samples=samples, input_sample_rate=rate, input_channels=channels)
                try:
                    result = command(cli, ["_benchmark-speech-capture", prepared, model, ",".join(map(str, sizes)), "1.2"])
                    assert result["input_samples"] == samples and result["input_sample_rate"] == rate
                    assert result["input_channels"] == channels
                    assert result["records"][-1]["input_samples"] == samples
                    first = result["first_finish"]
                    source_end = item.get("source_end_sample")
                    record.update(status="completed", preparation_ms=result["preparation_ms"],
                                  blocks=len(result["records"]), normalized_samples=result["records"][-1]["normalized_samples"],
                                  has_speech=any(r["has_speech"] for r in result["records"]),
                                  finished=first is not None,
                                  first_finish_input_samples=first["input_samples"] if first else None,
                                  finish_minus_source_end_seconds=(first["input_samples"] / rate - source_end / 16000)
                                  if first and source_end is not None else None,
                                  enqueue_through_drain_ms=stats([r["enqueue_through_drain_ms"] for r in result["records"]]))
                    traces.append(dict(key=key, **result))
                except (RuntimeError, subprocess.TimeoutExpired, AssertionError) as error:
                    record.update(status="failed", error=str(error)[-2000:])
                rows.append(record)
                print(json.dumps(dict(key=key, status=record["status"])), flush=True)
            assert sha(prepared) == fingerprint
    summaries = {}
    for format_id, _, _ in FORMATS:
        summaries[format_id] = {}
        for pattern in PATTERNS:
            summaries[format_id][pattern] = {}
            for suite in sorted({r["suite"] for r in rows}):
                chosen = [r for r in rows if r["format"] == format_id and r["pattern"] == pattern and r["suite"] == suite]
                complete = [r for r in chosen if r["status"] == "completed"]
                delays = [r["finish_minus_source_end_seconds"] for r in complete if r["finish_minus_source_end_seconds"] is not None]
                summaries[format_id][pattern][suite] = dict(cases=len(chosen), completed=len(complete),
                    has_speech=sum(r["has_speech"] for r in complete), finished=sum(r["finished"] for r in complete),
                    finished_before_source_end=sum(d < 0 for d in delays), finish_minus_source_end_seconds=stats(delays))
    assert len(rows) == len(protocol["items"]) * len(FORMATS) * len(PATTERNS) == 624
    assert sha(cli) == cli_sha
    payload = json.dumps(traces, separators=(",", ":")).encode()
    packed = gzip.compress(payload, mtime=0)
    receipt = dict(status="completed-functional-replay" if all(r["status"] == "completed" for r in rows) else "completed-with-failed-routes",
                   timestamp=datetime.datetime.now(datetime.UTC).isoformat(),
                   git_commit=subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
                   tracked_changes=bool(subprocess.check_output(["git", "diff", "--name-only", "HEAD"], cwd=ROOT)),
                   cli_sha256=cli_sha, protocol_sha256=sha(protocol_path), catalog_sha256=sha(catalog_path),
                   harness_sha256=sha(Path(__file__)), dependency_lock_sha256=sha(ROOT.parent / "uv.lock"),
                   cases=len(rows), formats=FORMATS, packet_patterns=PATTERNS, probes=probes,
                   rows=rows, summaries=summaries,
                   traces=dict(path=traces_path.name, sha256=hashlib.sha256(packed).hexdigest(),
                               uncompressed_sha256=hashlib.sha256(payload).hexdigest(), bytes=len(packed)),
                   boundary="Reuses all 104 prior VAD validation cases; not fresh calibration or an ASR holdout. Real native model, queue, continuous resampling, downmix and tail probes. Serial accelerated blocks drain before the next admission, so there is no contention or hardware scheduling claim. Unequal stereo channels and rate conversion alter the waveform; final ASR uses a separate SciPy path. No ASR recognition, physical microphone, UI, energy or product ranking. Every failed route is retained; sample delays use source clip-end proxies. GUI routing remains unchanged.")
    traces_path.write_bytes(packed)
    args.output.write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(dict(status=receipt["status"], cases=len(rows), traces_bytes=len(packed))), flush=True)


if __name__ == "__main__":
    main()
