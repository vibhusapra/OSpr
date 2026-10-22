"""Verify the optimized loader against pinned upstream weights and public speech.

Compares every parameter, preprocessing values, and decoded timed output. This is
a numerical regression check, not a speed benchmark or new quality evaluation.
"""
import dataclasses
import datetime
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

import mlx.core as mx
from mlx.utils import tree_flatten
import numpy as np
from parakeet_mlx import from_pretrained

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "backend"))
os.environ["HF_HUB_OFFLINE"] = "1"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    from ospr_backend.engine import Engine, resolve_model
    from ospr_backend.parakeet_loader import FILTER_PATH, load_parakeet

    path = resolve_model("parakeet-v3")
    upstream, candidate = from_pretrained(path), load_parakeet(path)
    assert not upstream.training and not candidate.training
    assert dataclasses.asdict(upstream.preprocessor_config) == dataclasses.asdict(candidate.preprocessor_config)
    assert np.array_equal(np.array(upstream.preprocessor_config._filterbanks),
                          np.array(candidate.preprocessor_config._filterbanks))
    original = dict(tree_flatten(upstream.parameters()))
    updated = dict(tree_flatten(candidate.parameters()))
    assert original.keys() == updated.keys()
    elements = 0
    for name, value in original.items():
        other = updated[name]
        assert value.shape == other.shape and value.dtype == other.dtype, name
        assert bool(mx.array_equal(value, other).item()), name
        elements += value.size
    engines = [Engine(), Engine()]
    for engine, model in zip(engines, (upstream, candidate), strict=True):
        engine.models["parakeet-v3"] = model
    records, manifests = [], {}
    for suite in ("manifest", "test-clean", "test-other", "fleurs"):
        manifest = ROOT / f"benchmarks/fixtures/{suite}.json"
        manifests[suite] = sha(manifest)
        for item in json.loads(manifest.read_text())["items"]:
            audio = ROOT / "benchmarks" / item["path"]
            assert sha(audio) == item["sha256"]
            outputs = []
            for engine in engines:
                mx.random.seed(20261022)
                output = engine.transcribe(str(audio), "parakeet-v3",
                                           language=item.get("language", "en"), word_timestamps=True)
                outputs.append({key: output[key] for key in ("text", "segments", "words") if key in output})
            assert outputs[0] == outputs[1], f"Decoded output differs: {suite}/{item['id']}"
            records.append(dict(suite=suite, id=item["id"], output_sha256=hashlib.sha256(
                json.dumps(outputs[0], sort_keys=True).encode()).hexdigest()))
            if len(records) % 50 == 0:
                print(json.dumps(dict(verified=len(records))), flush=True)
    assert len(records) == 515
    result = dict(status="passed", verified_at=datetime.datetime.now(datetime.UTC).isoformat(),
        git_commit=subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        working_tree_dirty=bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT, text=True).strip()),
        source_sha256={str(p.relative_to(ROOT)): sha(p) for p in
                       (ROOT / "backend/ospr_backend/parakeet_loader.py", FILTER_PATH, Path(__file__))},
        parameter_arrays=len(original), parameter_elements=elements, parameter_dtype="bfloat16",
        model_revision=json.loads((ROOT / "backend/ospr_backend/models.lock.json").read_text())["parakeet-v3"]["revision"],
        manifests_sha256=manifests, cases=len(records), records=records,
        boundary="Every weight, preprocessor value and filter is identical to pinned upstream loading. All 515 public-suite texts, segments and word timings match exactly with a fixed per-request random seed. No latency or new accuracy claim.")
    (ROOT / "benchmarks/results/parakeet-loader-equivalence.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({key: result[key] for key in ("status", "parameter_arrays", "parameter_elements", "cases")}))


if __name__ == "__main__":
    main()
