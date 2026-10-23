"""Pinned native/MLX VAD replay, timing probes, and downstream ASR controls.

Only public fixtures are read. Core ML eligibility settings are not measurements
of actual device placement. No physical capture or product latency claim.
"""

import argparse
import datetime
import gzip
import hashlib
import json
import math
import os
from pathlib import Path
import random
import subprocess
import tempfile
import time

from huggingface_hub import hf_hub_download
import jiwer
import numpy as np
import soundfile as sf

from ospr_backend.audio import speech_bounds
from ospr_backend.engine import Engine
from run import normalize

ROOT = Path(__file__).resolve().parent
RATE = 16000


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def native(cli, args):
    begin = time.perf_counter()
    result = subprocess.run(
        [str(cli), *map(str, args)],
        env=dict(os.environ, HF_HUB_OFFLINE="1"),
        capture_output=True,
        text=True,
        timeout=600,
        check=False,
    )
    if result.returncode:
        raise RuntimeError(result.stderr[-2000:])
    value = json.loads(result.stdout)
    value["command_wall_ms"] = (time.perf_counter() - begin) * 1000
    return value


def statistics(values):
    return dict(
        count=len(values),
        p50=float(np.median(values)),
        p95=float(np.percentile(values, 95)),
        maximum=float(max(values)),
    )


def rms_trace(audio, threshold):
    padded = np.pad(audio, (0, -len(audio) % 320))
    levels = np.sqrt(np.mean(padded.reshape(-1, 320) ** 2, axis=1))
    has_speech, last_voice, finished = False, 0, False
    events = []
    for index, rms in enumerate(levels):
        end = min(len(audio), (index + 1) * 320)
        if rms > threshold:
            if not has_speech:
                events.append(
                    dict(kind="speechStarted", boundarySample=index * 320, observedThroughSample=end)
                )
            has_speech = True
            last_voice = end
        # Approximate shipping 10Hz polling in contiguous, accelerated audio time.
        if not finished and has_speech and end % 1600 == 0 and end - last_voice >= 19200:
            events.append(dict(kind="finished", boundarySample=last_voice, observedThroughSample=end))
            finished = True
    return dict(
        probabilities=(levels > threshold).astype(float).tolist(),
        chunk_samples=320,
        audio_samples=len(audio),
        events=events,
    )


def bounds(trace):
    probabilities = np.asarray(trace["probabilities"])
    start = np.flatnonzero(probabilities >= 0.5)
    end = np.flatnonzero(probabilities >= 0.35)
    if not len(start):
        return 0, 0
    return (
        max(0, int(start[0]) * trace["chunk_samples"] - 2560),
        min(trace["audio_samples"], (int(end[-1]) + 1) * trace["chunk_samples"] + 2560),
    )


def finish(trace):
    return next(
        (event["observedThroughSample"] for event in trace["events"] if event["kind"] == "finished"),
        trace["audio_samples"],
    )


def prepare_models(catalog):
    paths = {}
    for identifier, spec in catalog["models"].items():
        snapshot = None
        for file in spec["files"]:
            path = Path(hf_hub_download(spec["repo"], file["path"], revision=spec["revision"], token=False))
            assert path.stat().st_size == file["size"] and sha(path) == file["sha256"], file["path"]
            if snapshot is None:
                snapshot = path
                for _ in Path(file["path"]).parts:
                    snapshot = snapshot.parent
        paths[identifier] = snapshot / spec["subfolder"]
    return paths


def native_controls(cli, model, first, temporary):
    audio, rate = sf.read(first, dtype="float32")
    chunk = 4096 if "256ms" in model.name else 512
    partial = temporary / "partial.wav"
    samples = audio[: len(audio) - ((len(audio) - 1) % chunk)]
    sf.write(partial, samples, rate, subtype="FLOAT")
    padded = temporary / "padded.wav"
    sf.write(padded, np.pad(samples, (0, -len(samples) % chunk)), rate, subtype="FLOAT")
    excited = temporary / "speech-state-exciter.wav"
    sf.write(excited, audio[RATE : 3 * RATE], rate, subtype="FLOAT")
    manifest = temporary / "reset-control.json"
    manifest.write_text(
        json.dumps(
            [
                dict(id=name, path=str(path))
                for name, path in [
                    ("first", partial),
                    ("padded", padded),
                    ("excited", excited),
                    ("repeated", partial),
                ]
            ]
        )
    )
    rows = native(cli, ["_benchmark-speech-detector", manifest, model, "cpu"])["records"]
    assert rows[0]["probabilities"] == rows[3]["probabilities"]
    assert rows[0]["events"] == rows[3]["events"]
    assert rows[0]["chunk_samples"] == chunk
    assert rows[0]["probabilities"] == rows[1]["probabilities"]
    checks = ["recurrent-reset", "partial-frame-padding"]
    bad = temporary / "invalid.wav"
    for name, samples, rate in [
        ("non-finite", np.array([np.nan] * 512, dtype=np.float32), RATE),
        ("wrong-rate", np.zeros(512, dtype=np.float32), 44100),
        ("stereo", np.zeros((512, 2), dtype=np.float32), RATE),
        ("empty", np.zeros(0, dtype=np.float32), RATE),
    ]:
        sf.write(bad, samples, rate, subtype="FLOAT")
        result = subprocess.run(
            [str(cli), "analyze-speech", str(bad), str(model)], capture_output=True, text=True, timeout=30
        )
        assert result.returncode != 0 and not result.stdout, name
        checks.append(name + "-rejected")
    return checks


def mlx_replay(path, items):
    import mlx.core as mx
    from mlx_audio.vad.models.silero_vad.config import ModelConfig
    from mlx_audio.vad.models.silero_vad.silero_vad import SileroVADBranch

    begin = time.perf_counter()
    with mx.stream(mx.cpu):
        config = ModelConfig.from_dict(json.loads((path / "config.json").read_text()))
        branch = SileroVADBranch(config.branch_16k)
        weights = mx.load(str(path / "model.safetensors"))
        assert len(weights) == 14 and all(key.startswith("vad_16k.") for key in weights)
        branch.load_weights(
            [(key.removeprefix("vad_16k."), value) for key, value in weights.items()], strict=True
        )
        mx.eval(branch.parameters())
        compiled = mx.compile(lambda window, state: branch(window, state=state))
        load_ms = (time.perf_counter() - begin) * 1000
        prime_begin = time.perf_counter()
        for _ in range(3):
            p, s = compiled(mx.zeros((1, 576)), mx.zeros((2, 1, 128)))
            mx.eval(p, s)
        prime_ms = (time.perf_counter() - prime_begin) * 1000
        records = []
        compile_delta = 0.0
        for item_index, item in enumerate(items):
            audio, rate = sf.read(ROOT / item["path"], dtype="float32")
            assert rate == RATE and audio.ndim == 1
            state = mx.zeros((2, 1, 128))
            context = np.zeros(64, dtype=np.float32)
            eager_state = mx.zeros((2, 1, 128))
            probabilities, times = [], []
            for offset in range(0, len(audio), 512):
                chunk = np.pad(audio[offset : offset + 512], (0, max(0, offset + 512 - len(audio))))
                window = mx.array(np.concatenate([context, chunk])[None, :], dtype=mx.float32)
                start = time.perf_counter()
                probability, state = compiled(window, state)
                mx.eval(probability, state)
                value = float(probability.item())
                times.append((time.perf_counter() - start) * 1000)
                assert math.isfinite(value) and 0 <= value <= 1
                probabilities.append(value)
                if item_index == 0:
                    eager, eager_state = branch(window, state=eager_state)
                    mx.eval(eager, eager_state)
                    compile_delta = max(compile_delta, abs(float(eager.item()) - value))
                context = chunk[-64:].copy()
            records.append(
                dict(
                    id=item["id"],
                    chunk_samples=512,
                    audio_samples=len(audio),
                    probabilities=probabilities,
                    prediction_ms=times,
                )
            )
        assert compile_delta < 1e-5, compile_delta
    return dict(
        records=records,
        load_ms=load_ms,
        prime_ms=prime_ms,
        compiled_vs_eager_max_probability_delta=compile_delta,
        requested_stream="mlx.cpu",
    )


def summarize(protocol, records):
    indexed = {row["id"]: row for row in records}
    groups = {}
    for suite in sorted({item["suite"] for item in protocol["items"]}):
        selected = [item for item in protocol["items"] if item["suite"] == suite]
        rows = [indexed[item["id"]] for item in selected]
        armed = sum(any(e["kind"] == "speechStarted" for e in row["events"]) for row in rows)
        groups[suite] = dict(
            cases=len(rows),
            speech_started=armed,
            no_high_probability=sum(not any(p >= 0.5 for p in row["probabilities"]) for row in rows),
            edge_empty=sum(bounds(row) == (0, 0) for row in rows),
            finished=sum(any(e["kind"] == "finished" for e in row["events"]) for row in rows),
        )
        if suite in ["original", "quiet40db", "noise10db"]:
            groups[suite]["finished_before_source_clip_end"] = sum(
                finish(row) < item["source_end_sample"] for row, item in zip(rows, selected, strict=True)
            )
    proxies = {}
    for reference in ["only_words", "manual_segments"]:
        tp = fp = fn = tn = 0
        for item in [row for row in protocol["items"] if row["suite"] == "ami"]:
            trace = indexed[item["id"]]
            centers = (np.arange(0, item["samples"], 160) + 80) / RATE
            truth = np.zeros(len(centers), dtype=bool)
            for turn in item[reference]:
                truth |= (centers >= turn["start"]) & (centers < turn["end"])
            p = np.asarray(trace["probabilities"])
            predicted = (
                p[np.minimum((centers * RATE / trace["chunk_samples"]).astype(int), len(p) - 1)] >= 0.5
            )
            tp += int(np.sum(predicted & truth))
            fp += int(np.sum(predicted & ~truth))
            fn += int(np.sum(~predicted & truth))
            tn += int(np.sum(~predicted & ~truth))
        proxies[reference] = dict(
            tp=tp,
            fp=fp,
            fn=fn,
            tn=tn,
            precision=tp / max(1, tp + fp),
            recall=tp / max(1, tp + fn),
            f1=2 * tp / max(1, 2 * tp + fp + fn),
        )
    times = [ms for row in records for ms in row.get("prediction_ms", [])]
    return dict(
        groups=groups, ami_10ms_annotation_proxy=proxies, prediction_ms=statistics(times) if times else None
    )


def asr_quality(protocol, routes, temporary):
    engine = Engine()
    results, cache = [], {}
    for item in protocol["items"]:
        if item["suite"] not in ["original", "quiet40db", "noise10db", "synthetic-negative"]:
            continue
        audio, rate = sf.read(ROOT / item["path"], dtype="float32")
        selected = [
            ("full-no-trim", (0, len(audio))),
            ("rms-default-edge", speech_bounds(audio, threshold=0.003)),
            ("rms-low-edge", speech_bounds(audio, threshold=0.0005)),
            ("coreml32-edge", bounds(routes["coreml32-cpu"][item["id"]])),
            ("rms-default-endpoint", (0, finish(routes["rms-default"][item["id"]]))),
            ("coreml32-endpoint", (0, finish(routes["coreml32-cpu"][item["id"]]))),
        ]
        for route, (start, end) in selected:
            start, end = int(start), int(end)
            key = (item["sha256"], start, end)
            cached = key in cache
            if not cached:
                if end - start < 320:
                    value = dict(text="", inference_bypassed=True)
                else:
                    path = temporary / "public-asr-input.wav"
                    sf.write(path, audio[start:end], RATE, subtype="FLOAT")
                    response = engine.transcribe(str(path), "parakeet-v3", language="en", trim=False)
                    value = dict(text=response["text"], inference_bypassed=False)
                cache[key] = value
            value = cache[key]
            score = jiwer.process_words(normalize(item["reference"]), normalize(value["text"]))
            results.append(
                dict(
                    id=item["id"],
                    suite=item["suite"],
                    route=route,
                    reference=item["reference"],
                    start_sample=start,
                    end_sample=end,
                    equal_sample_input_reused=cached,
                    wer=score.wer,
                    **value,
                )
            )
        print(json.dumps(dict(stage="asr", id=item["id"], unique_inputs=len(cache))), flush=True)
    scores = {}
    for suite in sorted({row["suite"] for row in results}):
        scores[suite] = {}
        for route in sorted({row["route"] for row in results}):
            selected = [row for row in results if row["suite"] == suite and row["route"] == route]
            score = jiwer.process_words(
                [normalize(row["reference"]) for row in selected],
                [normalize(row["text"]) for row in selected],
            )
            scores[suite][route] = dict(
                cases=len(selected),
                wer=score.wer,
                empty=sum(not row["text"].strip() for row in selected),
                hallucinated_negative=sum(
                    bool(row["text"].strip()) for row in selected if not row["reference"]
                ),
            )
    return dict(
        model="parakeet-v3",
        language="en",
        unique_inferred_or_bypassed_inputs=len(cache),
        scores=scores,
        records=results,
        boundary="Quality only. Identical sample ranges/settings reuse the same actual model hypothesis; no latency comparison. Full source references include content after a potential early endpoint. Neural edges use first >=0.5 frame, last >=0.35 frame and 160ms padding, without removing interior silence. This candidate edge policy is not shipped.",
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", type=Path, default=ROOT.parent / ".build/release/ospr-cli")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--skip-asr", action="store_true")
    args = parser.parse_args()
    assert not args.output.exists(), "Choose a fresh output path"
    traces_path = args.output.with_suffix(".traces.json.gz")
    assert not traces_path.exists(), "Choose a fresh trace output path"
    cli = args.cli.resolve(strict=True)
    cli_sha = sha(cli)
    protocol_path = ROOT / "fixtures/vad-protocol.json"
    protocol = json.loads(protocol_path.read_text())
    catalog_path = ROOT / "fixtures/vad-models.json"
    catalog = json.loads(catalog_path.read_text())
    models = prepare_models(catalog)
    for item in protocol["items"]:
        assert sha(ROOT / item["path"]) == item["sha256"]
    raw, probes, controls = {}, [], {}
    with tempfile.TemporaryDirectory(prefix="ospr-vad-public-") as tmp:
        temporary = Path(tmp)
        manifest = temporary / "inputs.json"
        manifest.write_text(
            json.dumps([dict(id=row["id"], path=str(ROOT / row["path"])) for row in protocol["items"]])
        )
        first = ROOT / protocol["items"][0]["path"]
        for model in ["coreml-32-v6.0", "coreml-256-v6.2.1"]:
            controls[model] = native_controls(cli, models[model], first, temporary)
        order = [
            (model, units, repeat)
            for model in ["coreml-32-v6.0", "coreml-256-v6.2.1"]
            for units in ["cpu", "gpu", "ane", "all"]
            for repeat in range(3)
        ]
        random.Random(20261023).shuffle(order)
        for model, units, repeat in order:
            response = native(cli, ["analyze-speech", first, models[model], units])
            probes.append(dict(model=model, units=units, repeat=repeat, **response))
        for name, model in [("coreml32-cpu", "coreml-32-v6.0"), ("coreml256-cpu", "coreml-256-v6.2.1")]:
            response = native(cli, ["_benchmark-speech-detector", manifest, models[model], "cpu"])
            assert len(response["records"]) == len(protocol["items"])
            raw[name] = response
            print(json.dumps(dict(stage="native", route=name, cases=len(response["records"]))), flush=True)
        mlx = mlx_replay(models["mlx-32-v6.2.1"], protocol["items"])
        traces = temporary / "traces.json"
        traces.write_text(json.dumps(mlx["records"]))
        endpoints = native(cli, ["_benchmark-speech-endpoints", traces])["records"]
        for row, event in zip(mlx["records"], endpoints, strict=True):
            assert row["id"] == event["id"]
            row["events"] = event["events"]
        raw["mlx32-cpu"] = mlx
        for name, threshold in [("rms-default", 0.003), ("rms-low", 0.0005)]:
            rows = []
            for item in protocol["items"]:
                audio, _ = sf.read(ROOT / item["path"], dtype="float32")
                rows.append(dict(id=item["id"], **rms_trace(audio, threshold)))
            raw[name] = dict(
                records=rows,
                threshold=threshold,
                boundary="Amplitude reference: 20ms RMS frames and 100ms endpoint polling in audio time. This approximates the shipping tap/timer behavior; it is not a device or native CapturePipeline replay.",
            )
        for response in raw.values():
            for row, item in zip(response["records"], protocol["items"], strict=True):
                assert row["id"] == item["id"] and row["audio_samples"] == item["samples"]
                assert len(row["probabilities"]) == math.ceil(item["samples"] / row["chunk_samples"])
                assert all(math.isfinite(p) and 0 <= p <= 1 for p in row["probabilities"])
            response["summary"] = summarize(protocol, response["records"])
        quality = (
            None
            if args.skip_asr
            else asr_quality(
                protocol,
                {name: {r["id"]: r for r in value["records"]} for name, value in raw.items()},
                temporary,
            )
        )
    assert sha(cli) == cli_sha, "CLI changed during the experiment"
    archive = dict(routes={name: value.pop("records") for name, value in raw.items()}, timing_probes=probes)
    probe_summary = []
    for row in probes:
        probe_summary.append(
            {
                **{key: value for key, value in row.items() if key not in ["prediction_ms", "probabilities"]},
                "prediction_ms": statistics(row["prediction_ms"]),
            }
        )
    payload = json.dumps(archive, ensure_ascii=False, separators=(",", ":")).encode()
    compressed = gzip.compress(payload, mtime=0)
    receipt = dict(
        status="passed-replay-not-product-acceptance",
        timestamp=datetime.datetime.now(datetime.UTC).isoformat(),
        git_commit=subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        tracked_changes=bool(subprocess.check_output(["git", "diff", "--name-only", "HEAD"], cwd=ROOT)),
        cli_sha256=cli_sha,
        protocol_sha256=sha(protocol_path),
        catalog_sha256=sha(catalog_path),
        harness_sha256=sha(Path(__file__)),
        cases=len(protocol["items"]),
        native_controls=controls,
        timing_probes=probe_summary,
        routes=raw,
        asr=quality,
        raw_traces=dict(
            path=traces_path.name,
            sha256=hashlib.sha256(compressed).hexdigest(),
            uncompressed_sha256=hashlib.sha256(payload).hexdigest(),
            bytes=len(compressed),
            uncompressed_bytes=len(payload),
            encoding="gzip-compressed UTF-8 JSON",
        ),
        limitations=protocol["limitations"]
        + [
            "Resident serial inference timing on a shared active Mac; model loading/priming reported separately. No physical microphone, route changes, sustained real-time queue or power attribution.",
            "New Core ML model/endpoint primitives and CLI are research integration. The GUI and delivered preview still use their existing behavior.",
        ],
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    traces_path.write_bytes(compressed)
    args.output.write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + "\n")
    print(
        json.dumps(dict(status=receipt["status"], cases=receipt["cases"], output=str(args.output))),
        flush=True,
    )


if __name__ == "__main__":
    main()
