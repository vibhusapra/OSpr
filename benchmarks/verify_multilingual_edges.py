"""Recompute multilingual edge ranges and metrics from stored public evidence."""
import argparse
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
    parser.add_argument("--result", type=Path, default=ROOT / "benchmarks/results/neural-edges-multilingual-v1.json")
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--control-cli", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    assert not args.output.exists()
    result = json.loads(args.result.read_text())
    protocol_path = ROOT / "benchmarks/fixtures/neural-edges-multilingual-protocol.json"
    assert sha(protocol_path) == result["protocol_sha256"]
    protocol = json.loads(protocol_path.read_text())
    dataset = ROOT / "benchmarks" / protocol["dataset_manifest"]
    assert sha(dataset) == result["dataset_manifest_sha256"] == protocol["dataset_manifest_sha256"]
    sources = {item["id"]: item for item in json.loads(dataset.read_text())["items"]}
    archive = args.result.with_name(result["traces_file"])
    assert sha(archive) == result["traces_sha256"]
    raw = gzip.decompress(archive.read_bytes())
    assert len(raw) == result["traces_uncompressed_bytes"]
    traces = json.loads(raw)
    items = {item["id"]: item for item in traces["items"]}
    controls = {item["id"]: item for item in traces["controls"]}
    assert len(items) == len(controls) == 100 and len(sources) == result["source_utterances"] == 50
    assert sha(args.app / "Contents/MacOS/ospr-cli") == result["cli_sha256"]
    assert sha(args.control_cli) == result["control_cli_sha256"]
    assert json.loads((args.app / "Contents/Resources/build-info.json").read_text()) == result["build"]
    for relative, key in [("backend/ospr_backend/models.lock.json", "asr_lock_sha256"),
                          ("backend/ospr_backend/speech-detector.lock.json", "detector_lock_sha256"),
                          ("uv.lock", "dependency_lock_sha256"), ("benchmarks/neural_edges_multilingual.py", "harness_sha256")]:
        assert sha(ROOT / relative) == result[key]
    expected_ranges = {}
    for identifier, item in items.items():
        source = sources[item["source_id"]]
        assert source["reference"] == item["reference"] and source["language"] == item["language"]
        assert source["path"] == item["original_path"] and source["sha256"] == item["source_sha256"]
        source_path = ROOT / "benchmarks" / source["path"]
        assert sha(source_path) == source["sha256"]
        audio = read_audio(str(source_path))
        variant = item["variant"]
        gain = protocol["variants"][variant]
        assert identifier == f"{source['id']}-{variant}"
        if gain != 1:
            audio = audio * np.float32(gain)
        actual_path = source_path if gain == 1 else args.work / f"{identifier}.wav"
        actual = read_audio(str(actual_path))
        assert np.array_equal(actual.view(np.uint32), audio.view(np.uint32))
        assert sha(actual_path) == item["sha256"] and len(audio) == item["samples"]
        assert hashlib.sha256(memoryview(audio.astype("<f4", copy=False))).hexdigest() == item["pcm_sha256"]
        assert sha(args.work / f"{identifier}.normalized.wav") == item["normalized_wav_sha256"]
        raw_scores = controls[identifier]["probabilities"]
        assert len(raw_scores) == (len(audio) + 511) // 512
        scores = []
        for index in range(len(raw_scores)):
            complement = 1.0
            for probability in raw_scores[max(0, index - 7):index + 1]:
                assert np.isfinite(probability) and 0 <= probability <= 1
                complement *= 1 - probability
            scores.append(1 - complement)
        assert scores == controls[identifier]["activity_scores"]
        first = next((index for index, value in enumerate(scores) if value >= 0.5), None)
        last = next((index for index in range(len(scores) - 1, -1, -1) if scores[index] >= 0.35), None)
        pair = [0, 0] if first is None else [max(0, first * 512 - 2560), min(len(audio), (last + 1) * 512 + 2560)]
        assert pair == item["expected_bounds"]
        expected_ranges[identifier] = pair
    rows = traces["records"]
    expected_pairs = {(model, identifier) for model, languages in protocol["model_languages"].items()
                      for identifier, item in items.items() if item["language"] in languages}
    assert len(rows) == result["pairs"] == len(expected_pairs) == 520
    assert {(row["model"], row["id"]) for row in rows} == expected_pairs
    actual_asr = abstentions = 0
    timing_issues = []
    for row in rows:
        item = items[row["id"]]
        edge = row["neural_edges"]["speech_edges"]
        assert [edge["start_sample"], edge["end_sample"]] == expected_ranges[row["id"]]
        assert edge["pcm_sha256"] == item["pcm_sha256"] and edge["audio_samples"] == item["samples"]
        assert edge["method"] == "silero-causal8-v1" and edge["sample_rate"] == 16000
        for route in ["full", "neural_edges"]:
            value = row[route]
            assert value["audio_seconds"] == item["samples"] / 16000 and value["model"] == row["model"]
            actual_asr += not value["silence"]
            abstentions += bool(value.get("detector_abstained"))
            offset = edge["start_sample"] / 16000 if route == "neural_edges" else 0
            stop = edge["end_sample"] / 16000 if route == "neural_edges" else value["audio_seconds"]
            for segment in value.get("segments", []):
                assert np.isfinite(segment["start"]) and np.isfinite(segment["end"])
                assert segment["start"] >= offset and segment["end"] >= segment["start"]
                if segment["end"] > stop + 1e-6:
                    timing_issues.append(dict(model=row["model"], id=row["id"], route=route,
                        start=segment["start"], end=segment["end"], analyzed_start=offset, analyzed_end=stop,
                        past_original_end=segment["end"] > value["audio_seconds"] + 1e-6))
    assert actual_asr == result["actual_asr"] and abstentions == result["abstentions"]
    for model, languages in protocol["model_languages"].items():
        selected = [row for row in rows if row["model"] == model]
        summary = result["summary"][model]
        changes = dict(better=0, equal=0, worse=0)
        new_empty = []
        for row in selected:
            item = items[row["id"]]
            ref = normalize(item["reference"])
            texts = [normalize(row[route]["text"]) for route in ["full", "neural_edges"]]
            if protocol["languages"][item["language"]]["metric"] == "cer":
                values = [jiwer.cer("".join(ref.split()), "".join(text.split())) for text in texts]
            else:
                values = [jiwer.wer(ref, text) for text in texts]
            changes["better" if values[1] < values[0] else "worse" if values[1] > values[0] else "equal"] += 1
            if row["full"]["text"].strip() and not row["neural_edges"]["text"].strip():
                new_empty.append(row["id"])
        assert changes == summary["changes"]
        assert new_empty == summary["new_empty_ids"] and len(new_empty) == summary["new_empty"]
        for language in languages:
            for variant in protocol["variants"]:
                group = [row for row in selected if items[row["id"]]["language"] == language and items[row["id"]]["variant"] == variant]
                assert len(group) == 10
                metric = protocol["languages"][language]["metric"]
                for route in ["full", "neural_edges"]:
                    refs = [normalize(items[row["id"]]["reference"]) for row in group]
                    texts = [normalize(row[route]["text"]) for row in group]
                    value = jiwer.process_characters(["".join(ref.split()) for ref in refs], ["".join(text.split()) for text in texts]) if metric == "cer" else jiwer.process_words(refs, texts)
                    published = summary["groups"][f"{language}/{variant}"][route]
                    assert published["rate"] == (value.cer if metric == "cer" else value.wer)
                    for key in ["substitutions", "deletions", "insertions"]:
                        assert published[key] == getattr(value, key)
                    assert published["reference_units"] == value.hits + value.substitutions + value.deletions
                    assert published["empty"] == sum(not row[route]["text"].strip() for row in group)
                    assert published["detector_abstentions"] == sum(row[route].get("detector_abstained", False) for row in group)
    output = dict(status="passed-stored-evidence-with-quality-and-timing-failures", result_sha256=sha(args.result),
        checker_sha256=sha(Path(__file__)), traces_sha256=sha(archive), waveforms_checked=100, manifests_checked=520,
        reference_control_frames=sum(len(row["probabilities"]) for row in controls.values()), actual_asr=actual_asr,
        detector_abstentions=abstentions, new_empty_by_model={model:summary["new_empty"] for model,summary in result["summary"].items()},
        timing_issues=timing_issues,
        boundary="Rehashes sources/derived arrays, exact PCM ranges, old-CLI probabilities, score aggregation and corpus metrics; this does not rerun ASR or establish semantic truth. Passing arithmetic checks do not mean the detector passed quality acceptance. New empty outputs and source-range timestamp overruns remain visible.")
    args.output.write_text(json.dumps(output,indent=2,ensure_ascii=False) + "\n")
    print(f"Checked 100 waveforms / 520 manifests; {sum(output['new_empty_by_model'].values())} new empty outputs; {len(timing_issues)} out-of-range intervals")


if __name__ == "__main__":
    main()
