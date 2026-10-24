"""Real final-ASR edge orchestration on every frozen VAD validation fixture.

Six local engines compare complete audio with the opt-in native edge path. The
same 33 known English speakers and five synthetic negatives are reused, plus six
transport fixtures. This is pipeline/quality evidence, not new held-out data or
comparative latency, power, microphone or insertion acceptance.
"""
import argparse
import datetime
import gzip
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess

import jiwer
import numpy as np
from scipy.signal import resample_poly
import soundfile as sf

from ospr_backend.audio import read_audio
from ospr_backend.engine import PUBLIC_MODELS
from ospr_backend.speech_edges import pcm_sha256
from run import normalize
from vad_candidate import bounds

ROOT = Path(__file__).resolve().parents[1]
BENCH = ROOT / "benchmarks"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def summarize(records, items):
    metadata = {item["id"]: item for item in items}
    summary = {}
    for model in PUBLIC_MODELS:
        rows = [row for row in records if row["model"] == model]
        suites = {}
        for suite in sorted({metadata[row["id"]]["suite"] for row in rows}):
            selected = [row for row in rows if metadata[row["id"]]["suite"] == suite]
            routes = {}
            for route in ["full", "neural_edges"]:
                speech = [row for row in selected if metadata[row["id"]]["reference"]]
                score = jiwer.process_words([normalize(metadata[row["id"]]["reference"]) for row in speech],
                                           [normalize(row[route]["text"]) for row in speech]) if speech else None
                routes[route] = dict(cases=len(selected), wer=score.wer if score else None,
                    substitutions=score.substitutions if score else None, deletions=score.deletions if score else None,
                    insertions=score.insertions if score else None,
                    empty=sum(not row[route]["text"].strip() for row in selected),
                    nonempty_negatives=sum(bool(row[route]["text"].strip()) and not metadata[row["id"]]["reference"] for row in selected),
                    detector_abstentions=sum(row[route].get("detector_abstained", False) for row in selected))
            suites[suite] = routes
        speech = [row for row in rows if metadata[row["id"]]["reference"]]
        changes = dict(better=0, equal=0, worse=0)
        regressions = []
        for row in speech:
            reference = normalize(metadata[row["id"]]["reference"])
            full = jiwer.wer(reference, normalize(row["full"]["text"]))
            edge = jiwer.wer(reference, normalize(row["neural_edges"]["text"]))
            changes["better" if edge < full else "worse" if edge > full else "equal"] += 1
            if edge > full:
                regressions.append(dict(id=row["id"], reference=metadata[row["id"]]["reference"],
                                        full=row["full"]["text"], neural_edges=row["neural_edges"]["text"]))
        summary[model] = dict(suites=suites, speech_changes=changes, regressions=regressions,
            new_empty_speech=sum(bool(row["full"]["text"].strip()) and not row["neural_edges"]["text"].strip() for row in speech))
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--work", type=Path, required=True)
    args = parser.parse_args()
    assert not args.output.exists() and not args.work.exists()
    assert not subprocess.check_output(["git", "diff", "--name-only", "HEAD"], cwd=ROOT)
    cli = args.cli.resolve(strict=True)
    cli_sha = sha(cli)
    env = dict(os.environ, HF_HUB_OFFLINE="1", HF_HUB_DISABLE_TELEMETRY="1", OSPR_ROOT=str(ROOT))
    protocol = BENCH / "fixtures/vad-causal8-validation-protocol.json"
    previous = BENCH / "results/vad-causal8-validation.traces.json.gz"
    frozen = {row["id"]: row for row in json.loads(gzip.decompress(previous.read_bytes()))["causal8"]}
    items = json.loads(protocol.read_text())["items"]
    assert len(items) == len(frozen) == 104
    args.work.mkdir(parents=True)
    items = [dict(item, original_path=item["path"], path=str((BENCH / item["path"]).resolve()), language="en") for item in items]
    for item in items:
        assert sha(Path(item["path"])) == item["sha256"]
        item["expected_bounds"] = list(bounds(frozen[item["id"]]))
    seeds = [items[0], next(item for item in items if item["suite"] == "quiet40db"),
             next(item for item in items if item["id"] == "synthetic-tone440hz")]
    # Two actual native-rate, unequal-gain stereo inputs per seed. The worker
    # downmixes/resamples these; live AVAudioConverter ranges are never reused.
    for seed in seeds:
        samples = read_audio(seed["path"])
        for rate in [44100, 48000]:
            from math import gcd

            divisor = gcd(rate, 16000)
            native = resample_poly(samples, rate // divisor, 16000 // divisor).astype(np.float32)
            path = args.work.resolve() / f"transport-{rate}-{seed['id']}.wav"
            sf.write(path, np.stack([native * 0.5, native * 1.5], axis=1), rate, subtype="FLOAT")
            normalized = read_audio(str(path))
            normalized_path = path.with_suffix(".normalized.wav")
            sf.write(normalized_path, normalized, 16000, subtype="FLOAT")
            # Independent raw-score replay + Python causal aggregation/bounds.
            prepared = subprocess.run([str(cli), "verify-speech-detector"], cwd=ROOT, env=env,
                                      capture_output=True, text=True, check=True, timeout=120)
            model = json.loads(prepared.stdout)["model_path"]
            replay = subprocess.run([str(cli), "analyze-speech", str(normalized_path), model, "cpu"],
                                    cwd=ROOT, env=env, capture_output=True, text=True, check=True, timeout=120)
            trace = json.loads(replay.stdout)
            probabilities = trace["probabilities"]
            activity = []
            for index in range(len(probabilities)):
                complement = 1.0
                for probability in probabilities[max(0, index - 7):index + 1]:
                    complement *= 1 - probability
                activity.append(1 - complement)
            expected = bounds(dict(trace, probabilities=activity))
            items.append(dict(id=path.stem, path=str(path), sha256=sha(path),
                suite=f"transport-{rate}-{seed['suite']}", reference=seed["reference"], language="en",
                samples=len(normalized), expected_bounds=list(expected), source_id=seed["id"],
                normalized_wav_sha256=sha(normalized_path)))
    for item in items:
        audio = read_audio(item["path"])
        assert len(audio) == item["samples"]
        item["pcm_sha256"] = pcm_sha256(audio)
    manifest = args.work / "manifest.json"
    manifest.write_text(json.dumps([{key: item[key] for key in ["id", "path", "language"]} for item in items]))
    all_records = []
    for model in PUBLIC_MODELS:
        output, log = args.work / f"{model}.json", args.work / f"{model}.log"
        with output.open("x") as stdout, log.open("x") as stderr:
            result = subprocess.run([str(cli), "_benchmark-neural-edges", str(manifest.resolve()), model],
                                    cwd=ROOT, env=env, stdout=stdout, stderr=stderr, timeout=2400)
        assert result.returncode == 0, f"{model}: inspect {log}"
        rows = json.loads(output.read_text())["records"]
        assert len(rows) == len(items) and [row["id"] for row in rows] == [item["id"] for item in items]
        for row, item in zip(rows, items, strict=True):
            edges = row["neural_edges"]["speech_edges"]
            assert [edges["start_sample"], edges["end_sample"]] == item["expected_bounds"], item["id"]
            assert edges["pcm_sha256"] == item["pcm_sha256"] and edges["audio_samples"] == item["samples"]
            assert edges["method"] == "silero-causal8-v1" and edges["sample_rate"] == 16000
            assert row["neural_edges"]["audio_seconds"] == row["full"]["audio_seconds"] == item["samples"] / 16000
            for route in ["full", "neural_edges"]:
                assert isinstance(row[route]["text"], str) and row[route]["model"] == model
                for segment in row[route].get("segments", []):
                    assert 0 <= segment["start"] <= segment["end"]
                if route == "neural_edges":
                    offset = edges["start_sample"] / 16000
                    assert all(segment["start"] >= offset for segment in row[route].get("segments", []))
            all_records.append(dict(row, model=model))
        print(f"{model}: {len(rows)} complete/full edge pairs verified", flush=True)
    for item in items:
        assert sha(Path(item["path"])) == item["sha256"]
    assert cli_sha == sha(cli)
    assert not subprocess.check_output(["git", "diff", "--name-only", "HEAD"], cwd=ROOT)
    metadata = [{key: value for key, value in item.items() if key != "path"} for item in items]
    raw = dict(items=metadata, records=all_records)
    archive = args.output.with_suffix(".traces.json.gz")
    assert not archive.exists()
    archive.write_bytes(gzip.compress(json.dumps(raw, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode(), mtime=0))
    receipt = dict(status="completed-real-final-edge-pipeline-not-native-acceptance",
        timestamp=datetime.datetime.now(datetime.UTC).isoformat(),
        git_commit=subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(), tracked_changes=False,
        cli_sha256=cli_sha, harness_sha256=sha(Path(__file__)), protocol_sha256=sha(protocol),
        previous_traces_sha256=sha(previous), dependency_lock_sha256=sha(ROOT / "uv.lock"),
        asr_lock_sha256=sha(ROOT / "backend/ospr_backend/models.lock.json"),
        detector_lock_sha256=sha(ROOT / "backend/ospr_backend/speech-detector.lock.json"),
        models=list(PUBLIC_MODELS), cases=len(items), frozen_cases=104, transport_cases=len(items) - 104,
        pairs=len(all_records), routes=2 * len(all_records),
        actual_asr=sum(not row[route].get("silence", False) for row in all_records for route in ["full", "neural_edges"]),
        edge_abstentions=sum(row["neural_edges"].get("detector_abstained", False) for row in all_records),
        exact_range_and_hash_checks=len(all_records), summary=summarize(all_records, metadata),
        traces_file=archive.name, traces_sha256=sha(archive), traces_uncompressed_bytes=len(gzip.decompress(archive.read_bytes())),
        host=dict(machine=platform.machine(), macos=platform.mac_ver()[0],
                  hardware=subprocess.check_output(["sysctl", "-n", "hw.model"], text=True).strip()),
        boundary=__doc__.strip() + " All ASR is actual current-source inference with no output reuse. Native edge ranges match frozen reference bounds for all 104 known inputs and independent raw-score/Python bounds on six new transport inputs. Full and selected audio share the original normalized timeline and full PCM hash. Timing fields are diagnostic only; no end-to-end latency or product ranking. No private audio, cloud provider, microphone or insertion. Defaults remain unchanged.")
    args.output.write_text(json.dumps(receipt, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps({key: receipt[key] for key in ["status", "models", "cases", "pairs", "routes", "actual_asr", "edge_abstentions"]}), flush=True)


if __name__ == "__main__":
    main()
