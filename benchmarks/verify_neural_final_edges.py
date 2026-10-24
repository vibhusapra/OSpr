"""Check stored final-edge evidence and source waveforms; no model inference."""
import argparse
import datetime
import gzip
import hashlib
import json
from pathlib import Path

import jiwer
import numpy as np

from ospr_backend.audio import read_audio
from run import normalize

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--result", type=Path, default=ROOT / "benchmarks/results/neural-final-edges.json")
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument("--cli", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--transport-control", type=Path, default=ROOT / "benchmarks/results/neural-final-edges-transport-control.json.gz")
    args = parser.parse_args()
    assert not args.output.exists()
    result = json.loads(args.result.read_text())
    archive = args.result.with_name(result["traces_file"])
    compressed = archive.read_bytes()
    assert sha(archive) == result["traces_sha256"]
    decoded = gzip.decompress(compressed)
    assert len(decoded) == result["traces_uncompressed_bytes"]
    data = json.loads(decoded)
    assert sha(args.cli) == result["cli_sha256"]
    for relative, key in [("uv.lock", "dependency_lock_sha256"),
                          ("backend/ospr_backend/models.lock.json", "asr_lock_sha256"),
                          ("backend/ospr_backend/speech-detector.lock.json", "detector_lock_sha256"),
                          ("benchmarks/fixtures/vad-causal8-validation-protocol.json", "protocol_sha256"),
                          ("benchmarks/results/vad-causal8-validation.traces.json.gz", "previous_traces_sha256"),
                          ("benchmarks/neural_edge_validation.py", "harness_sha256")]:
        assert sha(ROOT / relative) == result[key], relative
    items = {item["id"]: item for item in data["items"]}
    protocol = json.loads((ROOT / "benchmarks/fixtures/vad-causal8-validation-protocol.json").read_text())
    frozen = {row["id"]: row for row in json.loads(gzip.decompress(
        (ROOT / "benchmarks/results/vad-causal8-validation.traces.json.gz").read_bytes()))["causal8"]}
    control = json.loads(gzip.decompress(args.transport_control.read_bytes()))
    old_result = json.loads((ROOT / "benchmarks/results/vad-causal8-validation.json").read_text())
    assert control["git_commit"] == old_result["git_commit"] and control["cli_sha256"] == old_result["cli_sha256"]
    assert control["detector_lock_sha256"] == result["detector_lock_sha256"]
    transport = {row["id"]: row for row in control["records"]}
    assert len(transport) == 6
    input_paths = {item["id"]: ROOT / "benchmarks" / item["path"] for item in protocol["items"]}
    expected = {}
    for identifier, item in items.items():
        path = input_paths.get(identifier, args.work / f"{identifier}.wav")
        assert sha(path) == item["sha256"], identifier
        audio = read_audio(str(path))
        digest = hashlib.sha256(memoryview(audio.astype("<f4", copy=False))).hexdigest()
        assert digest == item["pcm_sha256"] and len(audio) == item["samples"]
        pair = item["expected_bounds"]
        if identifier in frozen:
            trace = frozen[identifier]
            first = next((index for index, value in enumerate(trace["probabilities"]) if value >= 0.5), None)
            last = next((index for index in range(len(trace["probabilities"]) - 1, -1, -1)
                         if trace["probabilities"][index] >= 0.35), None)
            derived = [0, 0] if first is None else [max(0, first * 512 - 2560),
                                                       min(len(audio), (last + 1) * 512 + 2560)]
            assert pair == derived
        else:
            assert sha(path.with_suffix(".normalized.wav")) == item["normalized_wav_sha256"]
            raw = transport[identifier]
            assert raw["normalized_wav_sha256"] == item["normalized_wav_sha256"]
            assert raw["audio_samples"] == len(audio) and raw["chunk_samples"] == 512
            probabilities = raw["probabilities"]
            assert len(probabilities) == (len(audio) + 511) // 512
            activity = []
            for index in range(len(probabilities)):
                complement = 1.0
                for probability in probabilities[max(0, index - 7):index + 1]:
                    assert np.isfinite(probability) and 0 <= probability <= 1
                    complement *= 1 - probability
                activity.append(1 - complement)
            first = next((index for index, value in enumerate(activity) if value >= 0.5), None)
            last = next((index for index in range(len(activity) - 1, -1, -1) if activity[index] >= 0.35), None)
            derived = [0, 0] if first is None else [max(0, first * 512 - 2560), min(len(audio), (last + 1) * 512 + 2560)]
            assert pair == derived
        expected[identifier] = dict(method="silero-causal8-v1", sample_rate=16000, audio_samples=len(audio),
                                    pcm_sha256=digest, start_sample=pair[0], end_sample=pair[1])
    records = data["records"]
    assert len(items) == result["cases"] == 110 and result["frozen_cases"] == 104 and result["transport_cases"] == 6
    assert len(records) == result["pairs"] == len(items) * len(result["models"])
    assert len({(row["model"], row["id"]) for row in records}) == len(records)
    actual_asr = abstained = 0
    recomputed = {}
    for model in result["models"]:
        rows = [row for row in records if row["model"] == model]
        assert {row["id"] for row in rows} == set(items)
        changes = dict(better=0, equal=0, worse=0)
        new_empty = 0
        for row in rows:
            item = items[row["id"]]
            edges = row["neural_edges"]["speech_edges"]
            assert edges == expected[row["id"]]
            assert row["neural_edges"]["speech_seconds"] == (edges["end_sample"] - edges["start_sample"]) / 16000
            for route in ["full", "neural_edges"]:
                value = row[route]
                assert value["audio_seconds"] == item["samples"] / 16000 and value["model"] == model
                actual_asr += not value["silence"]
                abstained += bool(value.get("detector_abstained"))
                for segment in value.get("segments", []):
                    assert np.isfinite(segment["start"]) and np.isfinite(segment["end"])
                    assert 0 <= segment["start"] <= segment["end"]
                    if route == "neural_edges":
                        assert segment["start"] >= edges["start_sample"] / 16000
            if item["reference"]:
                reference = normalize(item["reference"])
                scores = [jiwer.wer(reference, normalize(row[route]["text"])) for route in ["full", "neural_edges"]]
                changes["better" if scores[1] < scores[0] else "worse" if scores[1] > scores[0] else "equal"] += 1
                new_empty += bool(row["full"]["text"].strip()) and not row["neural_edges"]["text"].strip()
        summary = result["summary"][model]
        assert changes == summary["speech_changes"] and new_empty == summary["new_empty_speech"]
        for suite, routes in summary["suites"].items():
            selected = [row for row in rows if items[row["id"]]["suite"] == suite]
            for route, totals in routes.items():
                assert totals["cases"] == len(selected)
                assert totals["empty"] == sum(not row[route]["text"].strip() for row in selected)
                assert totals["nonempty_negatives"] == sum(bool(row[route]["text"].strip()) and not items[row["id"]]["reference"] for row in selected)
                assert totals["detector_abstentions"] == sum(row[route].get("detector_abstained", False) for row in selected)
                speech = [row for row in selected if items[row["id"]]["reference"]]
                if speech:
                    score = jiwer.process_words([normalize(items[row["id"]]["reference"]) for row in speech],
                                               [normalize(row[route]["text"]) for row in speech])
                    assert score.wer == totals["wer"]
                    for attribute in ["substitutions", "deletions", "insertions"]:
                        assert getattr(score, attribute) == totals[attribute]
        recomputed[model] = dict(changes=changes, new_empty_speech=new_empty)
    assert actual_asr == result["actual_asr"] and abstained == result["edge_abstentions"]
    args.output.write_text(json.dumps(dict(status="passed-stored-evidence-checks", timestamp=datetime.datetime.now(datetime.UTC).isoformat(),
        source_result_sha256=sha(args.result), traces_sha256=sha(archive), checker_sha256=sha(Path(__file__)),
        cli_sha256=sha(args.cli), audio_files_checked=len(items), native_manifests_checked=len(records),
        transport_control_sha256=sha(args.transport_control), transport_control_cli_sha256=control["cli_sha256"],
        actual_asr_records=actual_asr, abstention_records=abstained, summaries=recomputed,
        boundary="Rehashes 110 source/derived waveforms, the frozen CLI/source locks and stored traces; independently recomputes PCM hashes, original-timeline ranges, transcript-score arithmetic and aggregate counts. Bounds use frozen stored scores for 104 inputs and six separate raw-probability controls from the preserved earlier CLI. This checker does not rerun models, verify spoken content manually, or accept microphone/UI/insertion behavior."), indent=2) + "\n")
    print(f"Passed: {len(items)} waveforms, {len(records)} manifests, {actual_asr} inference records, {abstained} abstentions")


if __name__ == "__main__":
    main()
