"""Replay audio in 320ms packets through the actual cached Nemotron session.

No real-time sleeps: first-partial *audio position* and compute timings are
reported separately. This is a protocol/decoder replay, not microphone latency.
"""

import argparse
import datetime
import json
from pathlib import Path
import tempfile
import time

import numpy as np
import soundfile as sf

from ospr_backend.audio import read_audio, SAMPLE_RATE
from ospr_backend.engine import Engine
from run import summarize

ROOT = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--limit", type=int, default=20)
    parser.add_argument("--context-frames", type=int, choices=[0, 1, 6, 13])
    args = parser.parse_args()
    manifest = json.loads((ROOT / "fixtures/test-clean.json").read_text())
    items = manifest["items"][: args.limit]
    engine = Engine()
    model, _ = engine._load("nemotron-streaming")
    original_context = model.default_att_context_size
    if args.context_frames is not None:
        # Deliberate research ablation, not an accepted production setting. The
        # low-level streaming implementation accepts alternate right context.
        model.default_att_context_size = [original_context[0], args.context_frames]
    records = []
    for item in items:
        audio = read_audio(str(ROOT / item["path"]))
        state = engine.stream_begin("en")
        identifier = state["session_id"]
        events = []
        begin = time.perf_counter()
        with tempfile.NamedTemporaryFile(suffix=".wav") as file:
            for start in range(0, len(audio), 5120):
                chunk = audio[start : start + 5120]
                sf.write(file.name, chunk, SAMPLE_RATE, subtype="FLOAT")
                event = engine.stream_feed(file.name, session_id=identifier)
                event["audio_position_ms"] = (start + len(chunk)) / SAMPLE_RATE * 1000
                events.append(event)
            final = engine.stream_feed(final=True, session_id=identifier)
        records.append(
            dict(
                item,
                text=final["text"],
                wall_ms=(time.perf_counter() - begin) * 1000,
                tail_ms=final["processing_ms"],
                events=events,
                first_partial_audio_ms=next((e["audio_position_ms"] for e in events if e["text"]), None),
            )
        )
        print(
            item["id"],
            records[-1]["first_partial_audio_ms"],
            final["processing_ms"],
            final["text"][:90],
            flush=True,
        )
    name = "default" if args.context_frames is None else str(args.context_frames)
    result = dict(
        timestamp=datetime.datetime.now(datetime.UTC).isoformat(),
        model="Nemotron 3.5 cached streaming",
        packet_ms=320,
        original_context=original_context,
        tested_context=model.default_att_context_size,
        summary=summarize(records),
        records=records,
        p50_final_flush_ms=float(np.median([r["tail_ms"] for r in records])),
        p95_final_flush_ms=float(np.percentile([r["tail_ms"] for r in records], 95)),
        p50_first_partial_audio_ms=float(
            np.median(
                [r["first_partial_audio_ms"] for r in records if r["first_partial_audio_ms"] is not None]
            )
        ),
        limitations=[
            "Replay without wall-clock pacing; excludes microphone, IPC and UI.",
            "Only first 20 test-clean clips; acoustic first-word durations vary.",
            "Context changes are experimental and may exceed the model's validated training configuration.",
        ],
    )
    (ROOT / "results" / f"stream-nemotron-{name}.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({k: v for k, v in result.items() if k not in {"records"}}, indent=2))


if __name__ == "__main__":
    main()
