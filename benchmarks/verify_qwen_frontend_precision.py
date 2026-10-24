"""Recompute the upstream Torch/NumPy feature hashes without model inference."""

import argparse
import hashlib
import json
from pathlib import Path
import subprocess

import numpy as np
import soundfile as sf
import torch
from transformers import WhisperFeatureExtractor

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--result", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    assert not args.output.exists()
    receipt = json.loads(args.result.read_text())
    frozen = subprocess.check_output(["git", "show", receipt["git_commit"] + ":benchmarks/qwen_frontend_precision.py"], cwd=ROOT)
    assert hashlib.sha256(frozen).hexdigest() == receipt["harness_sha256"]
    protocol = ROOT / "benchmarks/fixtures/runtime-footprint-full-protocol.json"
    assert sha(protocol) == receipt["source_protocol_sha256"]
    case = next(r for r in json.loads(protocol.read_text())["cases"] if r["id"] == "qwen3-asr:1089-134686-0004")
    path = ROOT / "benchmarks" / case["path"]
    assert sha(path) == receipt["source_sha256"] == case["sha256"]
    audio, rate = sf.read(path, dtype="float32")
    assert rate == 16000 and audio.ndim == 1
    # The pinned Qwen post-load hook's exact fallback configuration. Hash/shape
    # checks below also reject any mismatch against the actual model's capture.
    extractor = WhisperFeatureExtractor(feature_size=128, sampling_rate=16000, hop_length=160, n_fft=400)
    options = dict(sampling_rate=16000, return_attention_mask=True, truncation=False, padding=True, return_tensors="np")
    torch_features = np.asarray(extractor(audio, **options)["input_features"], dtype=np.float32)
    extractor._torch_extract_fbank_features = extractor._np_extract_fbank_features
    numpy_features = np.asarray(extractor(audio, **options)["input_features"], dtype=np.float32)
    expected = {"torch": torch_features, "numpy": numpy_features}
    assert hashlib.sha256(torch.hann_window(400).numpy().astype("<f4").tobytes()).hexdigest() == receipt["window_sha256"]
    rows = receipt["records"]
    assert [r["variant"] for r in rows] == ["torch", "numpy", "scipy-f32", "scipy-f32", "numpy", "torch"]
    for row in rows:
        assert row["feature_extractions"] == 2
        if row["variant"] in expected:
            feature = expected[row["variant"]]
            assert row["shape"] == list(feature.shape)
            assert row["features_sha256"] == hashlib.sha256(feature.astype("<f4").tobytes()).hexdigest()
            assert row["max_abs_feature_difference_from_torch"] == float(np.max(np.abs(feature - torch_features)))
            assert row["features_identical_to_torch"] == (feature.tobytes() == torch_features.tobytes())
    for variant in ["torch", "numpy", "scipy-f32"]:
        selected = [r for r in rows if r["variant"] == variant]
        assert selected[0]["text"] == selected[1]["text"]
        assert selected[0]["features_sha256"] == selected[1]["features_sha256"]
    assert rows[0]["text"] != rows[1]["text"] and rows[1]["text"] == rows[2]["text"]
    result = dict(status="verified-upstream-feature-hashes-and-repeat-controls-not-model-rerun",
        source_result_sha256=sha(args.result), verifier_sha256=sha(Path(__file__)),
        recomputed_frontends=["torch", "numpy"], observed_asr_calls=6,
        upstream_max_abs_difference=float(np.max(np.abs(numpy_features - torch_features))),
        repeated_feature_extractions_each=2,
        boundary="Recomputes upstream Torch/NumPy F32 feature arrays and hashes against model-captured receipts; checks repeat text/hash controls and frozen source. SciPy numeric values are producer evidence, not an independently reimplemented FFT. Does not rerun recognition or certify another corpus/runtime.")
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
