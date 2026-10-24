"""Verify capture replay hashes, packet/frontier invariants and summary arithmetic."""

import argparse
import gzip
import hashlib
import importlib.metadata
import json
import math
from pathlib import Path
import platform
import subprocess

from huggingface_hub.constants import HF_HUB_CACHE
import numpy as np

ROOT = Path(__file__).resolve().parent


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def stats(values):
    return dict(count=len(values), p50=float(np.median(values)), p95=float(np.percentile(values, 95)),
                maximum=float(max(values))) if values else None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--receipt", type=Path, required=True)
    parser.add_argument("--cli", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    assert not args.output.exists()
    receipt = json.loads(args.receipt.read_text())
    for key, path in dict(cli_sha256=args.cli, protocol_sha256=ROOT / "fixtures/vad-causal8-validation-protocol.json",
                          catalog_sha256=ROOT / "fixtures/vad-models.json", harness_sha256=ROOT / "native_speech_capture.py",
                          dependency_lock_sha256=ROOT.parent / "uv.lock").items():
        assert sha(path) == receipt[key], key
    assert not receipt["tracked_changes"]
    archive = args.receipt.parent / receipt["traces"]["path"]
    assert sha(archive) == receipt["traces"]["sha256"]
    data = gzip.decompress(archive.read_bytes())
    assert hashlib.sha256(data).hexdigest() == receipt["traces"]["uncompressed_sha256"]
    traces = json.loads(data)
    protocol = json.loads((ROOT / "fixtures/vad-causal8-validation-protocol.json").read_text())
    expected = {item["id"]: item for item in protocol["items"]}
    indexed = {row["key"]: row for row in traces}
    assert len(indexed) == len(traces) == len(receipt["rows"]) == receipt["cases"] == 624
    assert len({(r["id"], r["format"], r["pattern"]) for r in receipt["rows"]}) == 624
    assets = json.loads((ROOT / "fixtures/vad-models.json").read_text())["models"]["coreml-32-v6.0"]
    base = Path(HF_HUB_CACHE) / ("models--" + assets["repo"].replace("/", "--")) / "snapshots" / assets["revision"]
    for file in assets["files"]:
        assert sha(base / file["path"]) == file["sha256"]
    files = set()
    packets_checked = candidates_checked = 0
    summaries, performance = {}, {}
    for row in receipt["rows"]:
        assert row["status"] == "completed"
        item = expected[row["id"]]
        assert row["suite"] == item["suite"] and row["source_sha256"] == item["sha256"]
        path = ROOT / item["path"] if row["format"] == "16k-mono" else ROOT / "fixtures/audio/vad-native-capture" / (row["id"] + "-" + row["format"] + ".wav")
        assert sha(ROOT / item["path"]) == item["sha256"]
        assert sha(path) == row["input_sha256"]
        files.add(path)
        key = "/".join([row["id"], row["format"], row["pattern"]])
        trace = indexed[key]
        assert trace["input_samples"] == row["input_samples"]
        assert trace["input_sample_rate"] == row["input_sample_rate"]
        assert trace["input_channels"] == row["input_channels"]
        pattern = receipt["packet_patterns"][row["pattern"]]
        assert trace["packet_sizes"] == pattern
        previous_input = previous_normalized = 0
        first = None
        for i, packet in enumerate(trace["records"]):
            through = packet["input_samples"]
            normalized = packet["normalized_samples"]
            assert 0 < through - previous_input <= pattern[i % len(pattern)]
            assert through <= row["input_samples"] and normalized >= previous_normalized
            assert normalized <= math.ceil(through * 16000 / row["input_sample_rate"]) + 1
            assert packet["incomplete_frame_samples"] == normalized % 512
            assert math.isfinite(packet["enqueue_through_drain_ms"]) and packet["enqueue_through_drain_ms"] >= 0
            if "candidate" in packet:
                event = packet["candidate"]
                assert packet["has_speech"] and event["kind"] == "finished"
                assert 0 <= event["boundarySample"] <= event["observedThroughSample"] == normalized
                if first is None:
                    first = packet
                candidates_checked += 1
            previous_input, previous_normalized = through, normalized
            packets_checked += 1
        assert previous_input == row["input_samples"] and previous_normalized == row["normalized_samples"]
        assert len(trace["records"]) == row["blocks"]
        assert row["has_speech"] == any(r["has_speech"] for r in trace["records"])
        assert first == trace["first_finish"]
        assert row["finished"] == (first is not None)
        assert row["first_finish_input_samples"] == (first["input_samples"] if first else None)
        delay = first["input_samples"] / row["input_sample_rate"] - item["source_end_sample"] / 16000 if first and "source_end_sample" in item else None
        assert delay == row["finish_minus_source_end_seconds"]
        assert stats([r["enqueue_through_drain_ms"] for r in trace["records"]]) == row["enqueue_through_drain_ms"]
    for format_id, rate, _ in receipt["formats"]:
        summaries[format_id], performance[format_id] = {}, {}
        for pattern in receipt["packet_patterns"]:
            summaries[format_id][pattern] = {}
            selected = [r for r in receipt["rows"] if r["format"] == format_id and r["pattern"] == pattern]
            measured = [p["enqueue_through_drain_ms"] for r in selected for p in indexed["/".join([r["id"], format_id, pattern])]["records"]]
            lag = [r["input_samples"] * 16000 / rate - r["normalized_samples"] for r in selected]
            performance[format_id][pattern] = dict(enqueue_through_drain_ms=stats(measured),
                                                   final_filter_lag_normalized_samples=dict(minimum=min(lag), maximum=max(lag)))
            for suite in sorted({r["suite"] for r in selected}):
                chosen = [r for r in selected if r["suite"] == suite]
                delays = [r["finish_minus_source_end_seconds"] for r in chosen if r["finish_minus_source_end_seconds"] is not None]
                summaries[format_id][pattern][suite] = dict(cases=len(chosen), completed=len(chosen),
                    has_speech=sum(r["has_speech"] for r in chosen), finished=sum(r["finished"] for r in chosen),
                    finished_before_source_end=sum(d < 0 for d in delays), finish_minus_source_end_seconds=stats(delays))
    assert summaries == receipt["summaries"]
    result = dict(status="passed-stored-evidence-checks", receipt_sha256=sha(args.receipt),
                  raw_archive_sha256=sha(archive), source_commit=receipt["git_commit"],
                  cli_sha256=sha(args.cli), verifier_sha256=sha(Path(__file__)),
                  input_audio_files_checked=len(files), model_files_checked=len(assets["files"]),
                  routes_checked=len(receipt["rows"]), packets_checked=packets_checked,
                  candidate_frontiers_checked=candidates_checked, performance=performance,
                  hardware_at_verification=dict(model=subprocess.check_output(["sysctl", "-n", "hw.model"], text=True).strip(),
                      chip=subprocess.check_output(["sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip(),
                      memory_bytes=int(subprocess.check_output(["sysctl", "-n", "hw.memsize"], text=True)), macos=platform.mac_ver()[0]),
                  versions={name: importlib.metadata.version(name) for name in ["numpy", "scipy", "soundfile"]},
                  boundary="Rehashes source/derived audio, pinned model data and raw traces; checks all packet sizes, received/normalized frontiers, candidate bounds, recorded first finish, delays and summary/cost arithmetic. Does not rerun inference or independently validate model scores, ASR, phonemes, real-time contention, physical microphone or UI. Hardware is read at verification on the replay host.")
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
