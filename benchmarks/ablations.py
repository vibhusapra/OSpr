"""Paired front-end latency and RMS threshold experiments on development fixtures."""

import json
from pathlib import Path
import tempfile
import time

import jiwer
import mlx.core as mx
import numpy as np
import soundfile as sf
from parakeet_mlx.audio import get_logmel

from ospr_backend.audio import read_audio, SAMPLE_RATE, speech_bounds
from ospr_backend.engine import Engine
from run import normalize

ROOT = Path(__file__).resolve().parent


def main():
    manifest = json.loads((ROOT / "fixtures/manifest.json").read_text())
    engine = Engine()
    model, _ = engine._load("parakeet-v3")
    source = ROOT / manifest["items"][0]["path"]
    audio = read_audio(str(source))
    start, end = speech_bounds(audio)
    audio = audio[start:end]
    timings = {"direct_mel": [], "file_ffmpeg": []}
    outputs = {key: [] for key in timings}
    with tempfile.NamedTemporaryFile(suffix=".wav") as file:
        sf.write(file.name, audio, SAMPLE_RATE)
        # Warm both routes, then alternate their order to reduce simple order bias.
        for index in range(22):
            for route in list(timings) if index % 2 == 0 else list(reversed(timings)):
                begin = time.perf_counter()
                if route == "direct_mel":
                    text = model.generate(
                        get_logmel(mx.array(audio, dtype=mx.float32), model.preprocessor_config)
                    )[0].text
                else:
                    text = model.transcribe(file.name).text
                mx.synchronize()
                if index >= 2:
                    timings[route].append((time.perf_counter() - begin) * 1000)
                    outputs[route].append(text)
    threshold_rows = []
    cases = [
        item for item in manifest["items"] if item["suite"] in {"human-quiet", "human-noise10db", "silence"}
    ] + manifest["items"][:12]
    for threshold in [0.0005, 0.001, 0.003, 0.01]:
        rows = []
        for case in cases:
            result = engine.transcribe(str(ROOT / case["path"]), "parakeet-v3", threshold=threshold)
            rows.append(dict(id=case["id"], suite=case["suite"], reference=case["reference"], **result))
        scores = {}
        for suite in sorted({r["suite"] for r in rows}):
            selected = [r for r in rows if r["suite"] == suite]
            scores[suite] = dict(
                wer=jiwer.wer(
                    [normalize(r["reference"]) for r in selected], [normalize(r["text"]) for r in selected]
                ),
                empty=sum(not r["text"] for r in selected),
                p50_ms=float(np.median([r["total_ms"] for r in selected])),
            )
        threshold_rows.append(dict(threshold=threshold, scores=scores, records=rows))
        print(threshold, scores, flush=True)
    results = dict(
        frontend={
            key: dict(
                p50_ms=float(np.median(value)), p95_ms=float(np.percentile(value, 95)), trials=len(value)
            )
            for key, value in timings.items()
        },
        frontend_raw_ms=timings,
        frontend_texts=outputs,
        rms_thresholds=threshold_rows,
        limitations=[
            "Front-end comparison is one 5.9-second development recording; file route includes FFmpeg spawn but excludes initial temp-file write.",
            "RMS sweep is 38 development cases, not a neural VAD benchmark or unseen acceptance set.",
        ],
    )
    (ROOT / "results/ablations.json").write_text(json.dumps(results, indent=2) + "\n")
    print(results["frontend"])


if __name__ == "__main__":
    main()
