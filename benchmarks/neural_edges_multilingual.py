"""Pinned multilingual final-edge check on existing public FLEURS slices.

Uses the delivered bundled CLI, actual six-engine recognition within documented
language coverage, and an earlier frozen raw-score CLI as a range control. The
same fifty known clips are tested at original gain and -40 dB; this is not a new
holdout, real whispering, microphone acceptance or a latency comparison.
"""
import argparse
import datetime
import gzip
import hashlib
import json
import os
from pathlib import Path
import subprocess

import jiwer
import numpy as np
import soundfile as sf
from huggingface_hub.constants import HF_HUB_CACHE

from ospr_backend.audio import read_audio
from ospr_backend.speech_edges import pcm_sha256
from run import normalize

ROOT = Path(__file__).resolve().parents[1]
BENCH = ROOT / "benchmarks"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def score(reference, text, metric):
    reference, text = normalize(reference), normalize(text)
    if metric == "cer":
        return jiwer.process_characters("".join(reference.split()), "".join(text.split()))
    return jiwer.process_words(reference, text)


def rate(value, metric):
    return value.cer if metric == "cer" else value.wer


def summarize(records, items, protocol):
    indexed = {item["id"]: item for item in items}
    output = {}
    for model, languages in protocol["model_languages"].items():
        rows = [row for row in records if row["model"] == model]
        groups = {}
        regressions = []
        changes = dict(better=0, equal=0, worse=0)
        for row in rows:
            item = indexed[row["id"]]
            metric = protocol["languages"][item["language"]]["metric"]
            values = [rate(score(item["reference"], row[route]["text"], metric), metric) for route in ["full", "neural_edges"]]
            change = "better" if values[1] < values[0] else "worse" if values[1] > values[0] else "equal"
            changes[change] += 1
            if change == "worse":
                regressions.append(dict(id=row["id"], metric=metric, full_rate=values[0], edge_rate=values[1],
                                        reference=item["reference"], full=row["full"]["text"], neural_edges=row["neural_edges"]["text"]))
        for language in languages:
            metric = protocol["languages"][language]["metric"]
            for variant in protocol["variants"]:
                selected = [row for row in rows if indexed[row["id"]]["language"] == language and indexed[row["id"]]["variant"] == variant]
                assert len(selected) == 10
                routes = {}
                for route in ["full", "neural_edges"]:
                    scores = [score(indexed[row["id"]]["reference"], row[route]["text"], metric) for row in selected]
                    substitutions = sum(value.substitutions for value in scores)
                    deletions = sum(value.deletions for value in scores)
                    insertions = sum(value.insertions for value in scores)
                    units = sum(value.hits + value.substitutions + value.deletions for value in scores)
                    routes[route] = dict(cases=len(selected), metric=metric, rate=(substitutions + deletions + insertions) / units,
                        reference_units=units, substitutions=substitutions, deletions=deletions, insertions=insertions,
                        empty=sum(not row[route]["text"].strip() for row in selected),
                        detector_abstentions=sum(row[route].get("detector_abstained", False) for row in selected))
                groups[f"{language}/{variant}"] = routes
        output[model] = dict(groups=groups, changes=changes, regressions=regressions,
            new_empty=sum(bool(row["full"]["text"].strip()) and not row["neural_edges"]["text"].strip() for row in rows),
            new_empty_ids=[row["id"] for row in rows if row["full"]["text"].strip() and not row["neural_edges"]["text"].strip()])
    return output


def command(cli, arguments, env):
    result = subprocess.run([str(cli), *map(str, arguments)], cwd=ROOT, env=env, capture_output=True, text=True, timeout=180)
    if result.returncode:
        raise RuntimeError(result.stderr[-3000:])
    return json.loads(result.stdout)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--control-cli", type=Path, required=True)
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    assert not args.work.exists() and not args.output.exists()
    assert not subprocess.check_output(["git", "diff", "--name-only", "HEAD"], cwd=ROOT)
    protocol_path = BENCH / "fixtures/neural-edges-multilingual-protocol.json"
    protocol = json.loads(protocol_path.read_text())
    dataset = BENCH / protocol["dataset_manifest"]
    assert sha(dataset) == protocol["dataset_manifest_sha256"]
    source_items = json.loads(dataset.read_text())["items"]
    assert len(source_items) == 50 and {item["language"] for item in source_items} == set(protocol["languages"])
    app = args.app.resolve(strict=True)
    cli = app / "Contents/MacOS/ospr-cli"
    control = args.control_cli.resolve(strict=True)
    previous = json.loads((BENCH / "results/vad-causal8-validation.json").read_text())
    assert sha(control) == previous["cli_sha256"]
    cli_sha, control_sha = sha(cli), sha(control)
    build = json.loads((app / "Contents/Resources/build-info.json").read_text())
    packaged_engine = app / "Contents/Resources/Engine"
    lock_path = ROOT / "backend/ospr_backend/models.lock.json"
    assert sha(packaged_engine / "backend/ospr_backend/models.lock.json") == sha(lock_path)
    assert sha(packaged_engine / "uv.lock") == sha(ROOT / "uv.lock")
    model_lock = json.loads(lock_path.read_text())
    for identifier, pin in protocol["config_pins"].items():
        locked = model_lock[identifier]
        assert pin["repo"] == locked["repo"] and pin["revision"] == locked["revision"]
        cached = Path(HF_HUB_CACHE) / ("models--" + pin["repo"].replace("/", "--")) / "snapshots" / pin["revision"]
        if locked.get("subfolder"):
            cached /= locked["subfolder"]
        assert sha(cached / "config.json") == pin["config_sha256"]
    env = dict(os.environ, HF_HUB_OFFLINE="1", HF_HUB_DISABLE_TELEMETRY="1")
    env.pop("OSPR_ROOT", None)  # Actual bundled engine, not the checkout override.
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    prepared = command(cli, ["verify-speech-detector"], env)
    assert prepared["native_integrity_verified"]
    model = Path(prepared["model_path"])
    spec_path = ROOT / "backend/ospr_backend/speech-detector.lock.json"
    spec = json.loads(spec_path.read_text())
    for entry in spec["files"]:
        path = model.parent / entry["path"]
        assert path.stat().st_size == entry["size"] and sha(path) == entry["sha256"]
    args.work.mkdir(parents=True)
    work = args.work.resolve()
    items, controls = [], []
    for source in source_items:
        source_path = BENCH / source["path"]
        assert sha(source_path) == source["sha256"]
        original = read_audio(str(source_path))
        for variant, gain in protocol["variants"].items():
            identifier = f"{source['id']}-{variant}"
            samples = original.copy() if gain == 1 else original * np.float32(gain)
            path = source_path.resolve() if gain == 1 else work / f"{identifier}.wav"
            if gain != 1:
                sf.write(path, samples, 16000, subtype="FLOAT")
            normalized = work / f"{identifier}.normalized.wav"
            sf.write(normalized, samples, 16000, subtype="FLOAT")
            trace = command(control, ["analyze-speech", normalized, model, "cpu"], env)
            assert trace["audio_samples"] == len(samples) and trace["chunk_samples"] == 512
            probabilities = trace["probabilities"]
            activity = []
            for index in range(len(probabilities)):
                complement = 1.0
                for probability in probabilities[max(0, index - 7):index + 1]:
                    complement *= 1 - probability
                activity.append(1 - complement)
            first = next((index for index, value in enumerate(activity) if value >= 0.5), None)
            last = next((index for index in range(len(activity) - 1, -1, -1) if activity[index] >= 0.35), None)
            start, end = (0, 0) if first is None else (max(0, first * 512 - 2560), min(len(samples), (last + 1) * 512 + 2560))
            item = dict(id=identifier, source_id=source["id"], original_path=source["path"], source_sha256=source["sha256"],
                path=str(path), sha256=sha(path), normalized_wav_sha256=sha(normalized), samples=len(samples),
                pcm_sha256=pcm_sha256(samples), language=source["language"], variant=variant,
                reference=source["reference"], expected_bounds=[start, end])
            items.append(item)
            controls.append(dict(id=identifier, probabilities=probabilities, activity_scores=activity))
    all_records = []
    for model_id, languages in protocol["model_languages"].items():
        selected = [item for item in items if item["language"] in languages]
        manifest = work / f"{model_id}-manifest.json"
        manifest.write_text(json.dumps([{key: item[key] for key in ["id", "path", "language"]} for item in selected]))
        with (work / f"{model_id}.json").open("x") as output, (work / f"{model_id}.log").open("x") as log:
            result = subprocess.run([str(cli), "_benchmark-neural-edges", str(manifest), model_id], cwd=ROOT,
                                    env=env, stdout=output, stderr=log, timeout=2400)
        assert result.returncode == 0, f"{model_id}: inspect {work / (model_id + '.log')}"
        rows = json.loads((work / f"{model_id}.json").read_text())["records"]
        assert [row["id"] for row in rows] == [item["id"] for item in selected]
        for row, item in zip(rows, selected, strict=True):
            edges = row["neural_edges"]["speech_edges"]
            assert edges == dict(method="silero-causal8-v1", sample_rate=16000, audio_samples=item["samples"],
                                 pcm_sha256=item["pcm_sha256"], start_sample=item["expected_bounds"][0], end_sample=item["expected_bounds"][1])
            for route in ["full", "neural_edges"]:
                value = row[route]
                assert isinstance(value["text"], str) and value["model"] == model_id
                assert value["audio_seconds"] == item["samples"] / 16000
                offset = edges["start_sample"] / 16000 if route == "neural_edges" else 0
                assert all(segment["start"] >= offset and segment["end"] >= segment["start"] for segment in value.get("segments", []))
            all_records.append(dict(row, model=model_id))
        print(f"{model_id}: {len(rows)} multilingual pairs verified", flush=True)
    for item in items:
        assert sha(Path(item["path"])) == item["sha256"]
        assert sha(BENCH / item["original_path"]) == item["source_sha256"]
    assert sha(cli) == cli_sha and sha(control) == control_sha
    assert not subprocess.check_output(["git", "diff", "--name-only", "HEAD"], cwd=ROOT)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    metadata = [{key: value for key, value in item.items() if key != "path"} for item in items]
    archive = args.output.with_suffix(".traces.json.gz")
    assert not archive.exists()
    raw = json.dumps(dict(items=metadata, controls=controls, records=all_records), ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
    archive.write_bytes(gzip.compress(raw, mtime=0))
    receipt = dict(status="completed-known-multilingual-edge-study-not-native-acceptance",
        timestamp=datetime.datetime.now(datetime.UTC).isoformat(),
        git_commit=subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(), tracked_changes=False,
        engine_binding="bundled", build=build, cli_sha256=cli_sha,
        control_cli_sha256=control_sha, control_source_git=previous["git_commit"],
        protocol_sha256=sha(protocol_path), dataset_manifest_sha256=sha(dataset), harness_sha256=sha(Path(__file__)),
        detector_lock_sha256=sha(spec_path), asr_lock_sha256=sha(ROOT / "backend/ospr_backend/models.lock.json"),
        dependency_lock_sha256=sha(ROOT / "uv.lock"), source_utterances=50, conditions=len(items),
        pairs=len(all_records), routes=len(all_records) * 2,
        actual_asr=sum(not row[route]["silence"] for row in all_records for route in ["full", "neural_edges"]),
        abstentions=sum(row["neural_edges"].get("detector_abstained", False) for row in all_records),
        summary=summarize(all_records, metadata, protocol), traces_file=archive.name, traces_sha256=sha(archive),
        traces_uncompressed_bytes=len(raw), boundary=__doc__.strip() + " Language hints are explicit. Parakeet excludes Hindi/Japanese/Mandarin; Cohere excludes Hindi before seeing outputs. All ASR is actual inference without output reuse. Every native range matches the earlier raw-score control with full PCM hashes. All references and hypotheses, including losses, remain in the archive. No default or model-promotion change; weights/cache and the delivered app signature are unchanged.")
    args.output.write_text(json.dumps(receipt, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps({key: receipt[key] for key in ["status", "pairs", "routes", "actual_asr", "abstentions"]}), flush=True)


if __name__ == "__main__":
    main()
