"""Research-only Voxtral MLX packet replay; never changes the shipping model list.

Same first twenty public clips/320 ms packets as the Nemotron replay. Audio
positions and compute time are separate; there is no wall-clock capture pacing.
"""
import argparse
import datetime
import hashlib
import importlib.metadata
import json
from pathlib import Path
import platform
import resource
import subprocess
import time

import mlx.core as mx
from mlx_audio.stt.utils import load_model
import numpy as np

from ospr_backend.audio import read_audio, SAMPLE_RATE
from run import summarize

ROOT = Path(__file__).resolve().parent


def replay(model, audio, delay):
    session = model.create_streaming_session(temperature=0.0, transcription_delay_ms=delay, max_tokens=4096)
    text = ""
    events = []
    started = time.perf_counter()
    for start in range(0, len(audio), 5120):
        chunk = audio[start:start + 5120]
        packet_start = time.perf_counter()
        session.feed(chunk)
        # Drain all available tokens before admitting another packet. Decoding
        # can advance on blank deltas, so inspect the public generated-token list.
        for _ in range(64):
            before = len(session.generated)
            text += "".join(session.step(max_decode_tokens=64))
            if session.done or len(session.generated) == before:
                break
        else:
            raise RuntimeError("Packet decoder did not reach an audio boundary")
        mx.synchronize()
        events.append(dict(text=text, audio_position_ms=(start + len(chunk)) / SAMPLE_RATE * 1000,
                           processing_ms=(time.perf_counter() - packet_start) * 1000, tokens=len(session.generated)))
        if session.done and start + len(chunk) < len(audio):
            raise RuntimeError("Unexpected EOS before all audio was admitted")
    tail_start = time.perf_counter()
    session.close()
    deadline = time.monotonic() + 60
    while not session.done:
        text += "".join(session.step(max_decode_tokens=64))
        if time.monotonic() > deadline:
            raise TimeoutError("Final cache flush exceeded 60 seconds")
    mx.synchronize()
    return dict(text=text.strip(), wall_ms=(time.perf_counter() - started) * 1000,
                tail_ms=(time.perf_counter() - tail_start) * 1000, events=events,
                first_partial_audio_ms=next((event["audio_position_ms"] for event in events if event["text"].strip()), None))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-path", required=True, type=Path)
    parser.add_argument("--model-manifest", required=True, type=Path)
    parser.add_argument("--limit", type=int, default=20)
    args = parser.parse_args()
    spec = json.loads(args.model_manifest.read_text())
    assert args.model_path.name == spec["revision"], "Use the pinned hub snapshot directory"
    files = {}
    for entry in spec["files"]:
        path = args.model_path / entry["name"]
        if entry["name"].endswith((".json", ".safetensors")):
            assert path.stat().st_size == entry["bytes"]
            with path.open("rb") as file:
                files[entry["name"]] = hashlib.file_digest(file, "sha256").hexdigest()
            if entry.get("lfs_sha256"):
                assert files[entry["name"]] == entry["lfs_sha256"], "Weight checksum differs from the pinned hub metadata"
    items = json.loads((ROOT / "fixtures/test-clean.json").read_text())["items"][:args.limit]
    started = time.perf_counter()
    model = load_model(str(args.model_path), strict=True)
    cold = replay(model, read_audio(str(ROOT / items[0]["path"])), 480)
    cold["load_and_first_replay_ms"] = (time.perf_counter() - started) * 1000
    result = dict(timestamp=datetime.datetime.now(datetime.UTC).isoformat(), research_only=True,
                  model="Voxtral Mini 4B Realtime / MLX 4-bit", model_spec=spec, artifact_sha256=files,
                  source_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                  git_commit=subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
                  tracked_changes=bool(subprocess.check_output(["git", "diff", "--name-only"], text=True).strip()),
                  versions={name: importlib.metadata.version(name) for name in ["mlx", "mlx-audio", "numpy"]},
                  platform=platform.platform(), hardware=subprocess.check_output(["/usr/sbin/sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip(),
                  packet_ms=320, cold=cold, delays={}, limitations=[
                      "First twenty test-clean clips only; not a full-corpus score or product ranking.",
                      "No real-time pacing; first partial is audio position, excluding capture/IPC/UI/insertion.",
                      "This direct-array replay excludes Nemotron harness temporary-WAV overhead.",
                      "Single process, fixed delay order, desktop background work and no thermal/energy isolation."])
    output = ROOT / "results/voxtral-realtime-candidate.json"
    for delay in [160, 480, 960]:
        records = []
        for item in items:
            path = ROOT / item["path"]
            assert hashlib.sha256(path.read_bytes()).hexdigest() == item["sha256"]
            record = dict(item)
            try:
                record.update(replay(model, read_audio(str(path)), delay))
            except Exception as error:
                record.update(text="", wall_ms=0, error=f"{type(error).__name__}: {error}")
            records.append(record)
            print(delay, item["id"], record.get("first_partial_audio_ms"), record["text"][:80], record.get("error", ""), flush=True)
        good = [row for row in records if "error" not in row]
        first = [row["first_partial_audio_ms"] for row in good if row["first_partial_audio_ms"] is not None]
        result["delays"][str(delay)] = dict(summary=summarize(records), records=records,
            p50_first_partial_audio_ms=float(np.median(first)) if first else None,
            p50_final_flush_ms=float(np.median([row["tail_ms"] for row in good])) if good else None,
            p95_final_flush_ms=float(np.percentile([row["tail_ms"] for row in good], 95)) if good else None)
        result["peak_gpu_bytes"] = mx.get_peak_memory()
        result["process_max_rss_bytes"] = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
        output.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n")


if __name__ == "__main__":
    main()
