"""Isolate a known Qwen spelling change at its feature-extraction boundary.

The input is intentionally the changed case from the Torch-absence study, not
an accuracy evaluation. One resident model, alternating six frontend calls.
"""

import argparse
from contextlib import redirect_stdout
import datetime
import hashlib
import json
from pathlib import Path
import subprocess
import sys

import mlx.core as mx
import numpy as np
from scipy.fft import rfft
import torch

from ospr_backend.engine import Engine

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def scipy_features(waveform, extractor, window):
    assert extractor.dither == 0
    width, hop = extractor.n_fft, extractor.hop_length
    wave = np.asarray(waveform, dtype=np.float32)
    padded = np.pad(wave, ((0, 0), (width // 2, width // 2)), mode="reflect")
    frames = np.lib.stride_tricks.sliding_window_view(padded, width, axis=-1)[:, ::hop, :]
    spectrum = rfft(frames * window, axis=-1, workers=1)
    power = np.ascontiguousarray((np.abs(spectrum) ** np.float32(2)).transpose(0, 2, 1)[..., :-1])
    mel = extractor.mel_filters.astype(np.float32).T @ power
    log = np.log10(np.maximum(mel, np.float32(1e-10)))
    log = np.maximum(log, log.max(axis=(1, 2), keepdims=True) - np.float32(8))
    return (log + np.float32(4)) / np.float32(4)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    assert not args.output.exists()
    assert not subprocess.check_output(["git", "diff", "--name-only", "HEAD"], cwd=ROOT)
    protocol = ROOT / "benchmarks/fixtures/runtime-footprint-full-protocol.json"
    case = next(r for r in json.loads(protocol.read_text())["cases"]
                if r["id"] == "qwen3-asr:1089-134686-0004")
    audio = ROOT / "benchmarks" / case["path"]
    assert sha(audio) == case["sha256"]
    with redirect_stdout(sys.stderr):
        engine = Engine()
        engine.warm("qwen3-asr")
        model, _ = engine._load("qwen3-asr")
        extractor = model._feature_extractor
        original = extractor._torch_extract_fbank_features
        window = torch.hann_window(extractor.n_fft).numpy().copy()
        rows, captured = [], []
        for variant in ["torch", "numpy", "scipy-f32", "scipy-f32", "numpy", "torch"]:
            features = []

            def extract(waveform, device="cpu", variant=variant):
                if variant == "torch":
                    value = original(waveform, device)
                elif variant == "numpy":
                    value = extractor._np_extract_fbank_features(waveform, device)
                else:
                    assert device == "cpu"
                    value = scipy_features(waveform, extractor, window)
                features.append(np.asarray(value, dtype=np.float32).copy())
                return value

            extractor._torch_extract_fbank_features = extract
            mx.random.seed(20261024)
            result = engine.transcribe(str(audio), "qwen3-asr", language="en")
            assert len(features) == 1
            captured.append(features[0])
            rows.append(dict(variant=variant, text=result["text"], shape=list(features[0].shape),
                features_sha256=hashlib.sha256(features[0].astype("<f4", copy=False).tobytes()).hexdigest(), result=result))
        extractor._torch_extract_fbank_features = original
    reference = captured[0]
    for row, feature in zip(rows, captured, strict=True):
        assert feature.shape == reference.shape
        row["max_abs_feature_difference_from_torch"] = float(np.max(np.abs(feature - reference)))
        row["features_identical_to_torch"] = feature.tobytes() == reference.tobytes()
    receipt = dict(status="completed-known-regression-frontend-diagnostic-not-quality-promotion",
        timestamp=datetime.datetime.now(datetime.UTC).isoformat(),
        git_commit=subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        harness_sha256=sha(Path(__file__)), source_protocol_sha256=sha(protocol), source_sha256=case["sha256"],
        reference=case["reference"], window_sha256=hashlib.sha256(window.astype("<f4").tobytes()).hexdigest(),
        records=rows, boundary=__doc__.strip() + " SciPy candidate uses the pinned Torch-generated Hann window as a diagnostic constant; this process still has Torch installed. No package/default change or held-out accuracy claim.")
    args.output.write_text(json.dumps(receipt, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps([{key: row[key] for key in ["variant", "text", "max_abs_feature_difference_from_torch"]} for row in rows], indent=2))


if __name__ == "__main__":
    main()
