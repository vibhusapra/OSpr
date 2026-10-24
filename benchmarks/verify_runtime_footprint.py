"""Verify archived runtime source pins, source PCM and paired text metrics."""

import argparse
import gzip
import hashlib
import json
from pathlib import Path
import subprocess

import numpy as np
import soundfile as sf
from run import normalize

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def distance(a, b):
    previous = list(range(len(b) + 1))
    for index, word in enumerate(a, 1):
        current = [index]
        for other, target in enumerate(b, 1):
            current.append(min(current[-1] + 1, previous[other] + 1,
                               previous[other - 1] + (word != target)))
        previous = current
    return previous[-1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--result", required=True, type=Path)
    parser.add_argument("--protocol", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    assert not args.output.exists()
    receipt = json.loads(args.result.read_text())
    assert sha(args.protocol) == receipt["protocol_sha256"]
    protocol = json.loads(args.protocol.read_text())
    frozen = subprocess.check_output(["git", "show", receipt["git_commit"] + ":benchmarks/runtime_footprint.py"], cwd=ROOT)
    assert hashlib.sha256(frozen).hexdigest() == receipt["harness_sha256"]
    for name, digest in protocol.get("dataset_sha256", {}).items():
        assert sha(ROOT / name) == digest
    assert sha(ROOT / "uv.lock") == protocol["dependency_lock_sha256"]
    assert sha(ROOT / "backend/ospr_backend/models.lock.json") == protocol["model_lock_sha256"]
    cases = protocol.get("cases", [])
    if cases:
        assert len(cases) == 202 and len(receipt["source_inputs"]) == 202
        for case in cases:
            path = ROOT / "benchmarks" / case["path"]
            assert sha(path) == case["sha256"]
            audio, rate = sf.read(path, dtype="float32")
            assert rate == 16000 and audio.ndim == 1
            audio *= np.float32(case.get("amplitude", 1))
            digest = hashlib.sha256(np.clip(audio, -1, 1).astype("<f4").tobytes()).hexdigest()
            actual = next(r for r in receipt["source_inputs"] if r["id"] == case["id"])
            assert actual["normalized_samples"] == len(audio) and actual["pcm_sha256"] == digest
            if case.get("pcm_sha256"):
                assert case["pcm_sha256"] == digest
    archive = args.result.with_name(receipt["traces_file"])
    assert sha(archive) == receipt["traces_sha256"]
    traces = json.loads(gzip.decompress(archive.read_bytes()))
    assert [r["variant"] for r in traces] == protocol["variant_order"]
    base = next(r for r in traces if r["variant"] == "baseline")
    candidate = next(r for r in traces if r["variant"] == "without-torch")
    assert base["returncode"] == candidate["returncode"] == 0
    assert base["torch_spec_present"] is True and base["torch_metadata_version"] == receipt["torch_version"]
    assert candidate["torch_spec_present"] is False and candidate["torch_metadata_version"] is None
    assert base["default_device"] == candidate["default_device"] == "Device(gpu, 0)"
    assert set(receipt["excluded_top_level_entries"]) == {"torch", "functorch", "torchgen", "torch-" + receipt["torch_version"] + ".dist-info"}
    assert len(base["records"]) == len(candidate["records"]) == receipt["requests_each"]
    expected_ids = {r["id"] for r in cases} if cases else {"asr-" + m for m in protocol["models"]}
    expected_ids |= {"warm-" + m for m in protocol["models"]} | {"notes", "meeting", "stream"}
    assert len(expected_ids) == receipt["requests_each"]
    for trace in [base, candidate]:
        assert {r["id"] for r in trace["records"]} == expected_ids
    pairs = []
    for before, after in zip(base["records"], candidate["records"], strict=True):
        assert before["id"] == after["id"] and before["action"] == after["action"]
        assert after["torch_imported"] is False
        text_action = before["action"] in {"transcribe", "meeting", "stream"}
        pairs.append(dict(id=before["id"], baseline_error=before["error"], candidate_error=after["error"],
            text_identical=((before["result"] or {}).get("text") == (after["result"] or {}).get("text")) if text_action else None,
            excerpts_identical=((before["result"] or {}).get("excerpts") == (after["result"] or {}).get("excerpts")) if before["action"] == "notes" else None,
            candidate_torch_imported=False))
    assert pairs == receipt["summary"]
    metrics = []
    for model in protocol["models"]:
        selected = [case for case in cases if case["model"] == model and case["suite"] == "librispeech-test-clean"]
        if not selected:
            continue
        row = dict(model=model, english_cases=len(selected))
        units = sum(len(normalize(case["reference"]).split()) for case in selected)
        for key, trace in [("baseline", base), ("without_torch", candidate)]:
            errors = sum(distance(normalize(case["reference"]).split(), normalize(next(
                r["result"]["text"] for r in trace["records"] if r["id"] == case["id"])).split()) for case in selected)
            row[key + "_errors"] = errors
            row[key + "_wer"] = errors / units
        row["reference_words"] = units
        metrics.append(row)
    source_pairs = {row["id"]: row for row in pairs}
    result = dict(status="verified-runtime-evidence-not-quality-promotion", source_result_sha256=sha(args.result),
        verifier_sha256=sha(Path(__file__)), requests_each=receipt["requests_each"], normalized_case_hashes=len(cases),
        api_errors=sum(bool(r["error"]) for v in traces for r in v["records"]),
        text_pairs=sum(row["text_identical"] is not None for row in pairs),
        text_differences=[row["id"] for row in pairs if row["text_identical"] is False], metrics=metrics,
        multilingual_cases=sum(r["suite"].startswith("fleurs-") for r in cases),
        multilingual_text_matches=sum(source_pairs[r["id"]]["text_identical"] for r in cases if r["suite"].startswith("fleurs-")),
        nonspeech_cases=sum(not r["expected_speech"] for r in cases),
        nonspeech_text_matches=sum(source_pairs[r["id"]]["text_identical"] for r in cases if not r["expected_speech"]),
        boundary="Frozen producer source, protocol/dependency/model pins, PCM recipes, Torch absence and raw text/control metrics check. Does not rerun model inference, reconstruct ephemeral WAV headers, prove latency/energy/RAM improvement or promote a reduced distributable.")
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
