"""Check frozen validation evidence without rerunning neural or ASR inference."""

import argparse
import gzip
import hashlib
import json
import math
from pathlib import Path
import platform
import subprocess
import tempfile

from huggingface_hub.constants import HF_HUB_CACHE
import jiwer
import numpy as np
import soundfile as sf

from ospr_backend.audio import speech_bounds
from run import normalize

ROOT = Path(__file__).resolve().parent


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def edges(row):
    starts = [i for i, p in enumerate(row["probabilities"]) if p >= 0.5]
    ends = [i for i, p in enumerate(row["probabilities"]) if p >= 0.35]
    if not starts:
        return 0, 0
    return max(0, starts[0] * row["chunk_samples"] - 2560), min(
        row["audio_samples"], (ends[-1] + 1) * row["chunk_samples"] + 2560
    )


def cut(row):
    return next((e["observedThroughSample"] for e in row["events"] if e["kind"] == "finished"),
                row["audio_samples"])


def stats(values):
    if not values:
        return None
    return dict(count=len(values), p50=float(np.median(values)),
                p95=float(np.percentile(values, 95)), maximum=max(values))


def reference_events(row, silence):
    """Independent one-shot hysteresis reference, including real partial frames."""
    pending = None
    last = 0
    armed = False
    events = []
    for i, p in enumerate(row["probabilities"]):
        start = i * row["chunk_samples"]
        end = min(start + row["chunk_samples"], row["audio_samples"])
        if not armed:
            pending = (start if pending is None else pending) if p >= 0.5 else None
            if pending is not None and end - pending >= math.ceil(0.096 * 16000):
                armed, last = True, end
                events.append(dict(kind="speechStarted", boundarySample=pending, observedThroughSample=end))
        elif p >= 0.35:
            last = end
        elif end - last >= math.ceil(silence * 16000):
            events.append(dict(kind="finished", boundarySample=last, observedThroughSample=end))
            break
    return events


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--receipt", type=Path, required=True)
    parser.add_argument("--cli", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    assert not args.output.exists()
    receipt = json.loads(args.receipt.read_text())
    paths = dict(protocol_sha256=ROOT / "fixtures/vad-causal8-validation-protocol.json",
                 catalog_sha256=ROOT / "fixtures/vad-models.json",
                 asr_model_lock_sha256=ROOT.parent / "backend/ospr_backend/models.lock.json",
                 dependency_lock_sha256=ROOT.parent / "uv.lock",
                 harness_sha256=ROOT / "vad_causal_validation.py", cli_sha256=args.cli)
    for key, path in paths.items():
        assert sha(path) == receipt[key], key
    assert receipt["huggingface_offline_at_import"] and not receipt["tracked_changes"]
    protocol = json.loads(paths["protocol_sha256"].read_text())
    assert len(protocol["validation_speakers"]) == receipt["speakers"] == 33
    assert not set(protocol["validation_speakers"]) & set(protocol["excluded_development_speakers"])
    expected = {item["id"]: item for item in protocol["items"]}
    assert len(expected) == len(protocol["items"]) == receipt["cases"] == 104
    for item in expected.values():
        assert sha(ROOT / item["path"]) == item["sha256"]
    model_files = 0
    for spec in json.loads(paths["catalog_sha256"].read_text())["models"].values():
        base = Path(HF_HUB_CACHE) / ("models--" + spec["repo"].replace("/", "--")) / "snapshots" / spec["revision"]
        for entry in spec["files"]:
            file = base / entry["path"]
            assert sha(file) == entry["sha256"] and file.stat().st_size == entry["size"]
            model_files += 1
    archive = args.receipt.parent / receipt["raw_traces"]["path"]
    assert sha(archive) == receipt["raw_traces"]["sha256"]
    payload = gzip.decompress(archive.read_bytes())
    assert hashlib.sha256(payload).hexdigest() == receipt["raw_traces"]["uncompressed_sha256"]
    raw = json.loads(payload)
    indexed = {name: {row["id"]: row for row in rows} for name, rows in raw.items()}
    for name, rows in raw.items():
        assert len(rows) == len(expected) and set(indexed[name]) == set(expected)
        for row in rows:
            assert row["audio_samples"] == expected[row["id"]]["samples"]
            assert len(row["probabilities"]) == math.ceil(row["audio_samples"] / row["chunk_samples"])
            assert all(math.isfinite(p) and 0 <= p <= 1 for p in row["probabilities"])
    frame_count = 0
    for item in expected.values():
        probabilities = indexed["raw"][item["id"]]["probabilities"]
        scores = []
        for i in range(len(probabilities)):
            complement = 1.0
            for p in probabilities[max(0, i - 7):i + 1]:
                complement *= 1 - p
            scores.append(1 - complement)
        assert scores == indexed["causal8"][item["id"]]["probabilities"]
        assert probabilities == indexed["raw-history-control"][item["id"]]["probabilities"]
        frame_count += len(scores)
    with tempfile.TemporaryDirectory(prefix="ospr-causal8-check-") as tmp:
        path = Path(tmp) / "raw.json"
        path.write_text(json.dumps(raw["raw"]))
        for policy in protocol["policies"]:
            output = subprocess.check_output([
                str(args.cli.resolve()), "_benchmark-speech-endpoints", str(path),
                str(policy["silence_seconds"]), str(policy["window_frames"])
            ], text=True, timeout=30)
            for actual, stored in zip(json.loads(output)["records"], raw[policy["id"]], strict=True):
                assert actual["id"] == stored["id"] and actual["events"] == stored["events"]
                assert stored["events"] == reference_events(stored, policy["silence_seconds"])
    times = [t for row in raw["raw"] for t in row["prediction_ms"]]
    assert len(times) == frame_count and all(math.isfinite(t) and t >= 0 for t in times)
    assert stats(times) == receipt["raw_model_prediction_ms"]
    for name, rows in raw.items():
        for suite, stored in receipt["policy_summaries"][name].items():
            selected = [row for row in rows if expected[row["id"]]["suite"] == suite]
            completed = [row for row in selected if any(e["kind"] == "finished" for e in row["events"])]
            delays = [(cut(row) - expected[row["id"]]["source_end_sample"]) / 16000
                      for row in completed if "source_end_sample" in expected[row["id"]]]
            checked = dict(cases=len(selected), edge_empty=sum(edges(row) == (0, 0) for row in selected),
                           speech_started=sum(any(e["kind"] == "speechStarted" for e in row["events"]) for row in selected),
                           finished=len(completed), finished_before_source_end=sum(d < 0 for d in delays),
                           finish_minus_source_end_seconds=stats(delays))
            assert checked == stored, (name, suite)
    records = receipt["asr"]["records"]
    assert len(records) == len({(r["model"], r["id"], r["route"]) for r in records}) == 3432
    losses = []
    for model in protocol["asr_models"]:
        by_key = {(r["id"], r["route"]): r for r in records if r["model"] == model}
        cache = {}
        inferred = bypassed = 0
        for item in protocol["items"]:
            audio, rate = sf.read(ROOT / item["path"], dtype="float32")
            assert rate == 16000 and len(audio) == item["samples"]
            name = item["id"]
            trace = indexed["causal8"][name]
            stop = cut(trace)
            prefix = dict(trace, audio_samples=stop, probabilities=trace["probabilities"][:math.ceil(stop / 512)])
            rms_stop = cut(indexed["rms-default"][name])
            choices = {"full-no-trim": (0, len(audio)),
                       "rms-default-edge": speech_bounds(audio, threshold=0.003),
                       "rms-low-edge": speech_bounds(audio, threshold=0.0005),
                       "raw-edge": edges(indexed["raw"][name]), "causal8-edge": edges(trace),
                       "rms-default-endpoint": (0, rms_stop),
                       "raw-endpoint": (0, cut(indexed["raw"][name])),
                       "raw-history-control-endpoint": (0, cut(indexed["raw-history-control"][name])),
                       "causal8-endpoint": (0, stop),
                       "rms-default-chain": speech_bounds(audio[:rms_stop], threshold=0.003),
                       "causal8-chain": edges(prefix)}
            assert list(choices) == protocol["asr_input_policies"]
            for route, (start, end) in choices.items():
                row = by_key[name, route]
                assert (row["start_sample"], row["end_sample"]) == (start, end)
                assert 0 <= start <= end <= len(audio) and row["reference"] == item["reference"]
                assert abs(jiwer.wer(normalize(row["reference"]), normalize(row["text"])) - row["wer"]) < 1e-12
                key = item["sha256"], int(start), int(end)
                assert row["equal_input_reused"] == (key in cache)
                assert row["inference_bypassed"] == (end - start < 320)
                value = row["text"], row["inference_bypassed"]
                if key in cache:
                    assert value == cache[key]
                else:
                    cache[key] = value
                    bypassed += row["inference_bypassed"]
                    inferred += not row["inference_bypassed"]
                if route in ["raw-edge", "causal8-edge", "causal8-endpoint", "causal8-chain"]:
                    if item["expected_speech"] and by_key[name, "full-no-trim"]["text"].strip() and not row["text"].strip():
                        losses.append(dict(model=model, id=name, suite=item["suite"], route=route))
        assert receipt["asr"]["actual_inference_counts"][model] == dict(
            inferred=inferred, unique_bypassed=bypassed, unique_inputs=len(cache))
        for suite, routes in receipt["asr"]["scores"][model].items():
            for route, score in routes.items():
                rows = [r for r in records if r["model"] == model and r["suite"] == suite and r["route"] == route]
                assert len(rows) == score["cases"]
                assert jiwer.wer([normalize(r["reference"]) for r in rows], [normalize(r["text"]) for r in rows]) == score["wer"]
                assert sum(not r["text"].strip() for r in rows) == score["empty"]
                assert sum(bool(r["text"].strip()) for r in rows if not r["reference"]) == score["hallucinated_negative"]
    assert losses == receipt["asr"]["new_empty_vs_full"]
    result = dict(status="passed-stored-evidence-checks", receipt_sha256=sha(args.receipt),
                  cli_sha256=sha(args.cli), protocol_sha256=receipt["protocol_sha256"],
                  raw_archive_sha256=sha(archive), source_commit=receipt["git_commit"],
                  verifier_sha256=sha(Path(__file__)), input_audio_files_checked=len(expected),
                  model_files_checked=model_files, exact_causal_score_frames=frame_count,
                  native_and_reference_event_traces_replayed=len(protocol["policies"]) * len(expected),
                  asr_quality_records=len(records),
                  actual_asr_inferences=sum(v["inferred"] for v in receipt["asr"]["actual_inference_counts"].values()),
                  unique_bypasses=sum(v["unique_bypassed"] for v in receipt["asr"]["actual_inference_counts"].values()),
                  hardware=dict(model=subprocess.check_output(["sysctl", "-n", "hw.model"], text=True).strip(),
                                chip=subprocess.check_output(["sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip(),
                                memory_bytes=int(subprocess.check_output(["sysctl", "-n", "hw.memsize"], text=True)),
                                macos=platform.mac_ver()[0]),
                  boundary="Rechecks hashes, stored probabilities, exact score formula, native and independent endpoint decisions, finish/delay summaries, every ASR input range, cache reuse and WER arithmetic. No neural/ASR rerun, real microphone, queue scheduling, phoneme timing, power or product-ranking acceptance.")
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
