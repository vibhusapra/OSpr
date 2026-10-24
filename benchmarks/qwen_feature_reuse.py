"""Paired Qwen frontend reuse: exact outputs, counted work, native warm timings."""

import argparse
import datetime
import gzip
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time

import numpy as np
import soundfile as sf
from ospr_backend.engine import Engine
from ospr_backend.temporary import private_audio_file

ROOT = Path(__file__).resolve().parents[1]
PROTOCOL = ROOT / "benchmarks/fixtures/qwen-feature-reuse-protocol.json"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def payload(value):
    return {key: value.get(key) for key in ["text", "language", "audio_seconds", "speech_seconds", "segments", "words"]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    assert not args.output.exists()
    assert not subprocess.check_output(["git", "diff", "--name-only", "HEAD"], cwd=ROOT)
    protocol = json.loads(PROTOCOL.read_text())
    cli = args.cli.resolve(strict=True)
    assert sha(ROOT / "uv.lock") == protocol["dependency_lock_sha256"]
    assert sha(ROOT / "backend/ospr_backend/models.lock.json") == protocol["model_lock_sha256"]
    os.environ["OSPR_QWEN_FEATURE_REUSE"] = "0"
    engine = Engine()
    engine.warm("qwen3-asr")
    records, blocks, inputs = [], [], []
    archive = args.output.with_suffix(".traces.json.gz")

    def save():
        archive.write_bytes(gzip.compress(json.dumps(dict(records=records, native_blocks=blocks), ensure_ascii=False).encode(), mtime=0))

    for index, case in enumerate(protocol["cases"]):
        source = ROOT / "benchmarks" / case["path"]
        assert sha(source) == case["sha256"]
        audio, rate = sf.read(source, dtype="float32")
        assert rate == 16000 and audio.ndim == 1
        audio *= np.float32(case.get("amplitude", 1))
        digest = hashlib.sha256(np.clip(audio, -1, 1).astype("<f4").tobytes()).hexdigest()
        if case.get("pcm_sha256"):
            assert digest == case["pcm_sha256"]
        inputs.append(dict(id=case["id"], samples=len(audio), pcm_sha256=digest))
        with private_audio_file() as file:
            sf.write(file.name, audio, rate, subtype="FLOAT")
            decoded, decoded_rate = sf.read(file.name, dtype="float32")
            assert decoded_rate == rate and decoded.tobytes() == audio.tobytes()
            for repeat in range(protocol["paired_repeats"]):
                order = ["baseline", "reuse"] if (index + repeat) % 2 == 0 else ["reuse", "baseline"]
                pair = {}
                for policy in order:
                    os.environ["OSPR_QWEN_FEATURE_REUSE"] = "0" if policy == "baseline" else "1"
                    start = time.perf_counter()
                    result = engine.transcribe(file.name, "qwen3-asr", language=case["language"])
                    pair[policy] = dict(result=result, actual_wall_ms=(time.perf_counter() - start) * 1000)
                records.append(dict(id=case["id"], repeat=repeat, order=order, **pair))
                save()
                assert payload(pair["baseline"]["result"]) == payload(pair["reuse"]["result"]), case["id"]
                baseline = pair["baseline"]["result"].get("frontend_evaluations", 0)
                optimized = pair["reuse"]["result"].get("frontend_evaluations", 0)
                hits = pair["reuse"]["result"].get("frontend_cache_hits", 0)
                assert optimized <= baseline and optimized + hits == baseline, (case["id"], baseline, optimized, hits)
        print(json.dumps(dict(completed_cases=index + 1, cases=len(protocol["cases"]), id=case["id"])), flush=True)
    source = ROOT / "benchmarks" / protocol["native_source"]["path"]
    assert sha(source) == protocol["native_source"]["sha256"]
    for index, policy in enumerate(protocol["native_policy_order"]):
        environment = dict(os.environ, OSPR_ROOT=str(ROOT), HF_HUB_OFFLINE="1", OSPR_DEBUG_LOG="0",
                           OSPR_QWEN_FEATURE_REUSE="0" if policy == "baseline" else "1")
        result = subprocess.run([str(cli), "benchmark", str(source), "qwen3-asr", str(protocol["native_warm_repeats"])],
                                cwd=ROOT, env=environment, capture_output=True, text=True, timeout=120)
        assert result.returncode == 0, result.stderr
        native = json.loads(result.stdout)
        blocks.append(dict(index=index, policy=policy, result=native))
        save()
        assert native["warm_trials"] == protocol["native_warm_repeats"]
        assert len(native["runs"]) == protocol["native_warm_repeats"] + 1
        for row in native["runs"]:
            assert row["frontend_evaluations"] == (2 if policy == "baseline" else 1)
            assert row["frontend_cache_hits"] == (0 if policy == "baseline" else 1)
        print(json.dumps(dict(native_block=index + 1, policy=policy, p50_ms=native["p50_ms"])), flush=True)
    text_controls = [payload(row) for block in blocks for row in block["result"]["runs"]]
    assert all(row == text_controls[0] for row in text_controls)
    times = {policy: [row["native_wall_ms"] for block in blocks if block["policy"] == policy
                     for row in block["result"]["runs"][1:]] for policy in ["baseline", "reuse"]}
    summary = {policy: dict(warm_samples=len(values), p50_ms=float(np.percentile(values, 50)),
                           p95_ms=float(np.percentile(values, 95))) for policy, values in times.items()}
    gain = 1 - summary["reuse"]["p50_ms"] / summary["baseline"]["p50_ms"]
    performance_gate = (gain > 0 and summary["reuse"]["p95_ms"] <= summary["baseline"]["p95_ms"] * 1.05)
    receipt = dict(status="completed-real-paired-output-and-native-timing-study", timestamp=datetime.datetime.now(datetime.UTC).isoformat(),
        git_commit=subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        tracked_changes=False, harness_sha256=sha(Path(__file__)), protocol_sha256=sha(PROTOCOL),
        cli_sha256=sha(cli), source_sha256={name: sha(ROOT / name) for name in ["backend/ospr_backend/qwen_features.py",
            "backend/ospr_backend/qwen.py", "backend/ospr_backend/engine.py", "uv.lock"]},
        cases=len(inputs), source_inputs=inputs, paired_runs=len(records), payload_pairs_identical=len(records),
        native_blocks=len(blocks), native_warm_samples_each=len(times["baseline"]), native_summary=summary,
        native_p50_reduction=gain, predeclared_native_performance_gate=performance_gate,
        traces_file=archive.name, traces_sha256=sha(archive), boundary=protocol["boundary"])
    assert not subprocess.check_output(["git", "diff", "--name-only", "HEAD"], cwd=ROOT)
    args.output.write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(dict(native_summary=summary, p50_reduction=gain, performance_gate=performance_gate), indent=2))


if __name__ == "__main__":
    main()
