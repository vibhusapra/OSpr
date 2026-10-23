"""Frozen-policy validation on speakers excluded from VAD development.

Three local ASR models test complete input, edges and endpoint cuts. This is not
a sealed ASR holdout or a live microphone/queue acceptance test.
"""

import argparse
import datetime
import gzip
import hashlib
import importlib.metadata
import json
from pathlib import Path
import subprocess
import tempfile

from huggingface_hub.constants import HF_HUB_OFFLINE
import jiwer
import soundfile as sf

from ospr_backend.audio import speech_bounds
from ospr_backend.engine import Engine
from run import normalize
from vad_candidate import bounds, finish, native, prepare_models, rms_trace, statistics

ROOT = Path(__file__).resolve().parent
RATE = 16000


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def evaluate_asr(protocol, routes, temporary):
    records, counters = [], {}
    for model in protocol["asr_models"]:
        engine = Engine()
        cache = {}
        inferred = bypassed = 0
        for item in protocol["items"]:
            audio, rate = sf.read(ROOT / item["path"], dtype="float32")
            assert rate == RATE
            rms_cut = finish(routes["rms-default"][item["id"]])
            causal = routes["causal8"][item["id"]]
            causal_cut = finish(causal)
            cut_trace = dict(
                causal,
                audio_samples=causal_cut,
                probabilities=causal["probabilities"][: (causal_cut + 511) // 512],
            )
            choices = [
                ("full-no-trim", (0, len(audio))),
                ("rms-default-edge", speech_bounds(audio, threshold=0.003)),
                ("rms-low-edge", speech_bounds(audio, threshold=0.0005)),
                ("raw-edge", bounds(routes["raw"][item["id"]])),
                ("causal8-edge", bounds(routes["causal8"][item["id"]])),
                ("rms-default-endpoint", (0, rms_cut)),
                ("raw-endpoint", (0, finish(routes["raw"][item["id"]]))),
                ("raw-history-control-endpoint", (0, finish(routes["raw-history-control"][item["id"]]))),
                ("causal8-endpoint", (0, finish(routes["causal8"][item["id"]]))),
                ("rms-default-chain", speech_bounds(audio[:rms_cut], threshold=0.003)),
                ("causal8-chain", bounds(cut_trace)),
            ]
            assert [route for route, _ in choices] == protocol["asr_input_policies"]
            for route, pair in choices:
                start, end = map(int, pair)
                key = item["sha256"], start, end
                reused = key in cache
                if not reused:
                    if end - start < 320:
                        cache[key] = dict(text="", inference_bypassed=True)
                        bypassed += 1
                    else:
                        path = temporary / "public-asr-input.wav"
                        sf.write(path, audio[start:end], RATE, subtype="FLOAT")
                        value = engine.transcribe(str(path), model, language="en", trim=False)
                        cache[key] = dict(text=value["text"], inference_bypassed=False)
                        inferred += 1
                value = cache[key]
                score = jiwer.process_words(normalize(item["reference"]), normalize(value["text"]))
                records.append(
                    dict(
                        id=item["id"],
                        suite=item["suite"],
                        model=model,
                        route=route,
                        reference=item["reference"],
                        start_sample=start,
                        end_sample=end,
                        equal_input_reused=reused,
                        wer=score.wer,
                        **value,
                    )
                )
            print(json.dumps(dict(stage="asr", model=model, id=item["id"], inferred=inferred)), flush=True)
        counters[model] = dict(inferred=inferred, unique_bypassed=bypassed, unique_inputs=len(cache))
        engine = None
    scores, losses = {}, []
    for model in protocol["asr_models"]:
        scores[model] = {}
        indexed = {(row["id"], row["route"]): row for row in records if row["model"] == model}
        for item in protocol["items"]:
            if item["expected_speech"] and indexed[item["id"], "full-no-trim"]["text"].strip():
                for route in ["raw-edge", "causal8-edge", "causal8-endpoint", "causal8-chain"]:
                    if not indexed[item["id"], route]["text"].strip():
                        losses.append(dict(model=model, id=item["id"], suite=item["suite"], route=route))
        for suite in sorted({row["suite"] for row in protocol["items"]}):
            scores[model][suite] = {}
            for route in sorted({row["route"] for row in records}):
                selected = [
                    row
                    for row in records
                    if row["model"] == model and row["suite"] == suite and row["route"] == route
                ]
                result = jiwer.process_words(
                    [normalize(row["reference"]) for row in selected],
                    [normalize(row["text"]) for row in selected],
                )
                scores[model][suite][route] = dict(
                    cases=len(selected),
                    wer=result.wer,
                    empty=sum(not row["text"].strip() for row in selected),
                    hallucinated_negative=sum(
                        bool(row["text"].strip()) for row in selected if not row["reference"]
                    ),
                )
    return dict(
        records=records,
        scores=scores,
        new_empty_vs_full=losses,
        actual_inference_counts=counters,
        boundary="Quality only: each model runs serially and reuses only its own identical sample ranges/settings. Empty ranges bypass inference. All ASR edge/cut requests disable further trimming, isolating the evaluated policy. No ASR latency comparison.",
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not HF_HUB_OFFLINE:
        parser.error(
            "Run with HF_HUB_OFFLINE=1 from process start; prepare the pinned models separately first."
        )
    trace_path = args.output.with_suffix(".traces.json.gz")
    assert not args.output.exists() and not trace_path.exists()
    cli = args.cli.resolve(strict=True)
    cli_sha = sha(cli)
    protocol_path = ROOT / "fixtures/vad-causal8-validation-protocol.json"
    catalog_path = ROOT / "fixtures/vad-models.json"
    protocol = json.loads(protocol_path.read_text())
    assert len(protocol["validation_speakers"]) == 33
    assert not set(protocol["validation_speakers"]) & set(protocol["excluded_development_speakers"])
    for item in protocol["items"]:
        assert sha(ROOT / item["path"]) == item["sha256"]
    catalog = json.loads(catalog_path.read_text())
    models = prepare_models(catalog)
    # Hub constants are read on import; process-start offline mode is required
    # rather than changing an environment variable after importing the library.
    raw = {}
    with tempfile.TemporaryDirectory(prefix="ospr-vad-validation-public-") as tmp:
        temporary = Path(tmp)
        manifest = temporary / "inputs.json"
        manifest.write_text(
            json.dumps([dict(id=row["id"], path=str(ROOT / row["path"])) for row in protocol["items"]])
        )
        native_result = native(cli, ["_benchmark-speech-detector", manifest, models["coreml-32-v6.0"], "cpu"])
        raw["raw"] = native_result["records"]
        trace_input = temporary / "traces.json"
        trace_input.write_text(
            json.dumps([{k: v for k, v in row.items() if k != "prediction_ms"} for row in raw["raw"]])
        )
        for policy in protocol["policies"]:
            response = native(
                cli,
                [
                    "_benchmark-speech-endpoints",
                    trace_input,
                    policy["silence_seconds"],
                    policy["window_frames"],
                ],
            )
            rows = []
            for source, result in zip(raw["raw"], response["records"], strict=True):
                assert source["id"] == result["id"]
                row = {k: v for k, v in source.items() if k != "prediction_ms"}
                row["events"] = result["events"]
                if policy["window_frames"] == 8:
                    expected = []
                    p = source["probabilities"]
                    for index in range(len(p)):
                        complement = 1.0
                        for value in p[max(0, index - 7) : index + 1]:
                            complement *= 1 - value
                        expected.append(1 - complement)
                    assert result["activity_scores"] == expected, "Native score differs from frozen formula"
                    row["probabilities"] = result["activity_scores"]
                rows.append(row)
            if policy["id"] == "raw":
                assert all(a["events"] == b["events"] for a, b in zip(rows, raw["raw"], strict=True))
                for row, source in zip(rows, raw["raw"], strict=True):
                    row["prediction_ms"] = source["prediction_ms"]
            raw[policy["id"]] = rows
        for name, threshold in [("rms-default", 0.003), ("rms-low", 0.0005)]:
            rows = []
            for item in protocol["items"]:
                audio, _ = sf.read(ROOT / item["path"], dtype="float32")
                rows.append(dict(id=item["id"], **rms_trace(audio, threshold)))
            raw[name] = rows
        summaries = {}
        for name, rows in raw.items():
            summary = {}
            for suite in sorted({row["suite"] for row in protocol["items"]}):
                selected = [
                    (item, row)
                    for item, row in zip(protocol["items"], rows, strict=True)
                    if item["suite"] == suite
                ]
                assert all(
                    item["id"] == row["id"] and item["samples"] == row["audio_samples"]
                    for item, row in selected
                )
                completed = [
                    (item, row)
                    for item, row in selected
                    if any(e["kind"] == "finished" for e in row["events"])
                ]
                delays = [
                    (finish(row) - item["source_end_sample"]) / RATE
                    for item, row in completed
                    if "source_end_sample" in item
                ]
                summary[suite] = dict(
                    cases=len(selected),
                    edge_empty=sum(bounds(row) == (0, 0) for _, row in selected),
                    speech_started=sum(
                        any(e["kind"] == "speechStarted" for e in row["events"]) for _, row in selected
                    ),
                    finished=len(completed),
                    finished_before_source_end=sum(
                        finish(row) < item["source_end_sample"]
                        for item, row in completed
                        if "source_end_sample" in item
                    ),
                    finish_minus_source_end_seconds=statistics(delays) if delays else None,
                )
            summaries[name] = summary
        quality = evaluate_asr(
            protocol, {name: {r["id"]: r for r in rows} for name, rows in raw.items()}, temporary
        )
    assert sha(cli) == cli_sha
    for item in protocol["items"]:
        assert sha(ROOT / item["path"]) == item["sha256"]
    payload = json.dumps(raw, separators=(",", ":")).encode()
    compressed = gzip.compress(payload, mtime=0)
    prediction_times = [value for row in raw["raw"] for value in row["prediction_ms"]]
    receipt = dict(
        status="completed-excluded-speaker-quality-study-not-product-acceptance",
        timestamp=datetime.datetime.now(datetime.UTC).isoformat(),
        git_commit=subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        tracked_changes=bool(subprocess.check_output(["git", "diff", "--name-only", "HEAD"], cwd=ROOT)),
        cli_sha256=cli_sha,
        protocol_sha256=sha(protocol_path),
        catalog_sha256=sha(catalog_path),
        asr_model_lock_sha256=sha(ROOT.parent / "backend/ospr_backend/models.lock.json"),
        dependency_lock_sha256=sha(ROOT.parent / "uv.lock"),
        huggingface_offline_at_import=HF_HUB_OFFLINE,
        harness_sha256=sha(Path(__file__)),
        cases=len(protocol["items"]),
        speakers=33,
        model_load_ms=native_result["load_ms"],
        model_prime_ms=native_result["prime_ms"],
        raw_model_prediction_ms=statistics(prediction_times),
        policy_summaries=summaries,
        asr=quality,
        raw_traces=dict(
            path=trace_path.name,
            sha256=hashlib.sha256(compressed).hexdigest(),
            uncompressed_sha256=hashlib.sha256(payload).hexdigest(),
            bytes=len(compressed),
        ),
        versions={
            name: importlib.metadata.version(name)
            for name in ["mlx", "mlx-audio", "parakeet-mlx", "jiwer", "soundfile"]
        },
        limitations=protocol["limitations"]
        + [
            "The native Swift causal score matches the fixed reference formula on every frame. Synthetic gain/noise, shared active hardware and clip-end proxies do not prove device endpoint quality. GUI/default routing remains unchanged."
        ],
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    trace_path.write_bytes(compressed)
    args.output.write_text(json.dumps(receipt, indent=2, ensure_ascii=False) + "\n")
    print(
        json.dumps(dict(status=receipt["status"], cases=receipt["cases"], output=str(args.output))),
        flush=True,
    )


if __name__ == "__main__":
    main()
