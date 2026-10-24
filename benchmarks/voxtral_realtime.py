"""Frozen Voxtral 4-bit compatibility/quality replay; no shipping model changes.

Run with PYTHONPATH=backend. Preparation is separate; inference is cache-only.
Packet replay is unpaced and does not measure microphone or word-relative delay.
"""
import argparse
import datetime
import gzip
import hashlib
import importlib.metadata
import json
from pathlib import Path
import platform
import subprocess
import time

import numpy as np
from huggingface_hub import snapshot_download

from ospr_backend.audio import read_audio, SAMPLE_RATE
from run import summarize

ROOT = Path(__file__).resolve().parents[1]
PROTOCOL = ROOT / "benchmarks/fixtures/voxtral-realtime-protocol.json"


def sha(path):
    with path.open("rb") as file:
        return hashlib.file_digest(file, "sha256").hexdigest()


def checked_model(spec):
    path = Path(snapshot_download(spec["repo"], revision=spec["revision"],
                                 allow_patterns=list(spec["required_files"]), local_files_only=True))
    for name, expected in spec["required_files"].items():
        file = path / name
        assert file.stat().st_size == expected["bytes"] and sha(file) == expected["sha256"], name
    return path


def stream(model, audio, options):
    import mlx.core as mx

    started = time.perf_counter()
    session = model.create_streaming_session(max_tokens=options["max_tokens"], temperature=options["temperature"],
        transcription_delay_ms=options["transcription_delay_ms"])
    assert session.input_sample_rate == SAMPLE_RATE
    text, events, accepted = "", [], 0
    for start in range(0, len(audio), options["packet_samples"]):
        if session.done:
            break  # Never feed after EOS. Preserve early completion as a failure.
        chunk = audio[start:start + options["packet_samples"]]
        began = time.perf_counter()
        session.feed(chunk)
        accepted += len(chunk)
        text += "".join(session.step(max_decode_tokens=options["step_max_decode_tokens"]))
        events.append(dict(audio_samples=accepted, audio_position_ms=accepted / SAMPLE_RATE * 1000,
                           step_ms=(time.perf_counter() - began) * 1000, text=text))
    ended_early = accepted != len(audio)
    session.close()
    flush = time.perf_counter()
    steps = 0
    while not session.done:
        if time.perf_counter() - flush > options["final_timeout_seconds"]:
            raise TimeoutError("Streaming finalization exceeded protocol deadline")
        text += "".join(session.step(max_decode_tokens=options["step_max_decode_tokens"]))
        steps += 1
        if steps > 10000:
            raise TimeoutError("Streaming finalization exceeded step budget")
    mx.synchronize()
    return dict(text=text.strip(), wall_ms=(time.perf_counter() - started) * 1000,
                final_flush_ms=(time.perf_counter() - flush) * 1000, final_steps=steps,
                first_partial_audio_ms=next((event["audio_position_ms"] for event in events if event["text"].strip()), None),
                accepted_samples=accepted, source_samples=len(audio), early_completion=ended_early, events=events)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--phase", choices=["smoke", "study"], required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    assert not args.output.exists() and not args.output.with_suffix(".traces.json.gz").exists()
    assert not subprocess.check_output(["git", "diff", "--name-only", "HEAD"], cwd=ROOT)
    protocol = json.loads(PROTOCOL.read_text())
    assert importlib.metadata.version("mlx-audio") == protocol["runtime"]["mlx_audio"]
    assert sha(ROOT / "uv.lock") == protocol["runtime"]["uv_lock_sha256"]
    for name, digest in protocol["dataset_manifests"].items():
        assert sha(ROOT / name) == digest
    assert sha(ROOT / "benchmarks/results/neural-final-edges.traces.json.gz") == protocol["negative_traces_sha256"]
    path = checked_model(protocol["model"])
    from mlx_audio.stt.utils import load
    import mlx.core as mx
    import mlx_audio.stt.models.voxtral_realtime as runtime

    runtime_path = Path(runtime.__file__).parent
    runtime_hashes = {file.name: sha(file) for file in sorted(runtime_path.glob("*.py"))}
    loading = time.perf_counter()
    model = load(str(path), strict=True)
    mx.synchronize()
    load_ms = (time.perf_counter() - loading) * 1000
    items = protocol["smoke"] if args.phase == "smoke" else protocol["items"]
    records = []
    archive = args.output.with_suffix(".traces.json.gz")
    for index, item in enumerate(items):
        source = ROOT / "benchmarks" / item["path"]
        assert sha(source) == item["sha256"]
        audio = read_audio(str(source))
        before = hashlib.sha256(memoryview(audio.astype("<f4", copy=False))).hexdigest()
        for route in protocol["routes"]:
            mx.reset_peak_memory()
            began = time.perf_counter()
            try:
                if route == "offline":
                    output = model.generate(audio, max_tokens=protocol["options"]["max_tokens"],
                        temperature=protocol["options"]["temperature"],
                        transcription_delay_ms=protocol["options"]["transcription_delay_ms"])
                    result = dict(text=output.text, wall_ms=(time.perf_counter() - began) * 1000)
                else:
                    result = stream(model, audio, protocol["options"])
                mx.synchronize()
                result["wall_ms"] = (time.perf_counter() - began) * 1000
                result.update(peak_gpu_bytes=mx.get_peak_memory(), active_gpu_bytes=mx.get_active_memory())
            except Exception as error:
                result = dict(error=f"{type(error).__name__}: {error}", text="", wall_ms=(time.perf_counter() - began) * 1000)
            after = hashlib.sha256(memoryview(audio.astype("<f4", copy=False))).hexdigest()
            assert before == after, "Model mutated the source waveform"
            record = dict(item, route=route, normalized_samples=len(audio), pcm_sha256=before, **result)
            records.append(record)
            print(f"{index + 1}/{len(items)} {item['id']} {route}: {result.get('error', result['text'])}", flush=True)
            # Keep partial evidence after every real call, including failures.
            archive.write_bytes(gzip.compress(json.dumps(records, ensure_ascii=False).encode(), mtime=0))
    summary = {route: summarize([row for row in records if row["route"] == route]) for route in protocol["routes"]}
    streamed = [row for row in records if row["route"] == "stream" and "error" not in row]
    first = [row["first_partial_audio_ms"] for row in streamed if row["first_partial_audio_ms"] is not None and row["expected_speech"]]
    stream_timings = {}
    for suite in sorted({row["suite"] for row in streamed}):
        rows = [row for row in streamed if row["suite"] == suite]
        partials = [row["first_partial_audio_ms"] for row in rows if row["first_partial_audio_ms"] is not None]
        stream_timings[suite] = dict(cases=len(rows), early_completions=sum(row["early_completion"] for row in rows),
            p50_first_partial_audio_ms=float(np.median(partials)) if partials else None,
            p50_final_flush_ms=float(np.median([row["final_flush_ms"] for row in rows])),
            max_step_ms=max(event["step_ms"] for row in rows for event in row["events"]))
    receipt = dict(status="completed-research-not-shipping-promotion", timestamp=datetime.datetime.now(datetime.UTC).isoformat(),
        git_commit=subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(), tracked_changes=False,
        phase=args.phase, model=protocol["model"], protocol_sha256=sha(PROTOCOL), harness_sha256=sha(Path(__file__)),
        dependency_lock_sha256=sha(ROOT / "uv.lock"), installed_adapter_sha256=runtime_hashes,
        host=dict(machine=platform.machine(), macos=platform.mac_ver()[0], device=str(mx.default_device())),
        load_ms=load_ms, options=protocol["options"], cases=len(items), actual_routes=len(records),
        errors=sum("error" in row for row in records), early_stream_completions=sum(row["early_completion"] for row in streamed),
        summary=summary, stream_timings=stream_timings, p50_first_partial_audio_ms=float(np.median(first)) if first else None,
        p50_final_flush_ms=float(np.median([row["final_flush_ms"] for row in streamed])) if streamed else None,
        traces_file=archive.name, traces_sha256=sha(archive), boundary=protocol["boundary"])
    assert checked_model(protocol["model"]) == path
    assert not subprocess.check_output(["git", "diff", "--name-only", "HEAD"], cwd=ROOT)
    args.output.write_text(json.dumps(receipt, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps({k: receipt[k] for k in ["cases", "actual_routes", "errors", "early_stream_completions", "p50_first_partial_audio_ms", "p50_final_flush_ms"]}, indent=2))


if __name__ == "__main__":
    main()
