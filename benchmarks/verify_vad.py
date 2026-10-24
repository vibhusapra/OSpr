"""Independently check stored VAD traces, events, timing and ASR score arithmetic."""

import argparse
import gzip
import hashlib
import importlib.metadata
import json
import math
from pathlib import Path
import platform
import re
import subprocess
import tempfile

from huggingface_hub.constants import HF_HUB_CACHE
import jiwer
import numpy as np

from run import normalize

ROOT = Path(__file__).resolve().parent


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--receipt", type=Path, required=True)
    parser.add_argument("--cli", type=Path, required=True)
    parser.add_argument("--swift-log", type=Path, required=True)
    parser.add_argument("--python-log", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    assert not args.output.exists()
    receipt = json.loads(args.receipt.read_text())
    assert sha(args.cli) == receipt["cli_sha256"]
    protocol = ROOT / "fixtures/vad-protocol.json"
    catalog = ROOT / "fixtures/vad-models.json"
    assert sha(protocol) == receipt["protocol_sha256"] and sha(catalog) == receipt["catalog_sha256"]
    items = json.loads(protocol.read_text())["items"]
    expected = {row["id"]: row for row in items}
    assert len(expected) == len(items) == receipt["cases"] == 179
    for item in items:
        assert sha(ROOT / item["path"]) == item["sha256"]
    archive = args.receipt.parent / receipt["raw_traces"]["path"]
    assert sha(archive) == receipt["raw_traces"]["sha256"]
    payload = gzip.decompress(archive.read_bytes())
    assert hashlib.sha256(payload).hexdigest() == receipt["raw_traces"]["uncompressed_sha256"]
    raw = json.loads(payload)
    model_files = 0
    for entry in json.loads(catalog.read_text())["models"].values():
        directory = (
            Path(HF_HUB_CACHE)
            / ("models--" + entry["repo"].replace("/", "--"))
            / "snapshots"
            / entry["revision"]
        )
        for file in entry["files"]:
            path = directory / file["path"]
            assert path.stat().st_size == file["size"] and sha(path) == file["sha256"]
            model_files += 1
    frames = {}
    with tempfile.TemporaryDirectory(prefix="ospr-vad-verify-") as tmp:
        for route, rows in raw["routes"].items():
            assert {row["id"] for row in rows} == set(expected) and len(rows) == len(expected)
            prediction_times = []
            frames[route] = 0
            for row in rows:
                item = expected[row["id"]]
                assert row["audio_samples"] == item["samples"]
                count = math.ceil(item["samples"] / row["chunk_samples"])
                assert len(row["probabilities"]) == count
                assert all(math.isfinite(p) and 0 <= p <= 1 for p in row["probabilities"])
                frames[route] += count
                events = row["events"]
                assert [e["kind"] for e in events] in [[], ["speechStarted"], ["speechStarted", "finished"]]
                assert all(
                    0 <= e["boundarySample"] <= e["observedThroughSample"] <= item["samples"] for e in events
                )
                if "prediction_ms" in row:
                    assert len(row["prediction_ms"]) == count and all(
                        math.isfinite(t) and t >= 0 for t in row["prediction_ms"]
                    )
                    prediction_times.extend(row["prediction_ms"])
            if prediction_times:
                stored = receipt["routes"][route]["summary"]["prediction_ms"]
                assert stored["count"] == len(prediction_times)
                assert abs(stored["p50"] - float(np.median(prediction_times))) < 1e-12
                assert abs(stored["p95"] - float(np.percentile(prediction_times, 95))) < 1e-12
            if not route.startswith("rms-"):
                path = Path(tmp) / "traces.json"
                path.write_text(
                    json.dumps(
                        [{key: value for key, value in row.items() if key != "prediction_ms"} for row in rows]
                    )
                )
                result = subprocess.run(
                    [str(args.cli.resolve()), "_benchmark-speech-endpoints", str(path)],
                    capture_output=True,
                    text=True,
                    check=True,
                    timeout=30,
                )
                events = json.loads(result.stdout)["records"]
                assert all(
                    a["id"] == b["id"] and a["events"] == b["events"]
                    for a, b in zip(events, rows, strict=True)
                )
    records = receipt["asr"]["records"]
    assert len(records) == 750
    assert len({(row["id"], row["route"]) for row in records}) == 750
    for row in records:
        assert row["reference"] == expected[row["id"]]["reference"]
        assert 0 <= row["start_sample"] <= row["end_sample"] <= expected[row["id"]]["samples"]
    for suite, routes in receipt["asr"]["scores"].items():
        for route, score in routes.items():
            selected = [row for row in records if row["suite"] == suite and row["route"] == route]
            assert len(selected) == score["cases"]
            measured = jiwer.wer(
                [normalize(row["reference"]) for row in selected],
                [normalize(row["text"]) for row in selected],
            )
            assert abs(measured - score["wer"]) < 1e-12
            assert sum(not row["text"].strip() for row in selected) == score["empty"]
    swift = args.swift_log.read_text()
    python = args.python_log.read_text()
    assert "Test Suite 'All tests' passed" in swift and "105 passed" in python
    assert re.findall(r"Executed (\d+) tests, with 0 failures", swift)[-1] == "256"
    inferred = sum(not row["equal_sample_input_reused"] and not row["inference_bypassed"] for row in records)
    result = dict(
        status="passed-stored-evidence-checks",
        receipt_sha256=sha(args.receipt),
        raw_archive_sha256=sha(archive),
        cli_sha256=sha(args.cli),
        model_files_checked=model_files,
        input_audio_files_checked=len(items),
        cases=len(expected),
        frame_counts=frames,
        native_event_traces_replayed=3 * len(expected),
        asr_quality_records=len(records),
        distinct_model_inferences=inferred,
        swift_tests=256,
        python_tests=105,
        swift_log_sha256=sha(args.swift_log),
        python_log_sha256=sha(args.python_log),
        hardware=dict(
            model=subprocess.check_output(["sysctl", "-n", "hw.model"], text=True).strip(),
            chip=subprocess.check_output(["sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip(),
            memory_bytes=int(subprocess.check_output(["sysctl", "-n", "hw.memsize"], text=True)),
            macos=platform.mac_ver()[0],
        ),
        versions={
            name: importlib.metadata.version(name)
            for name in ["mlx", "mlx-audio", "parakeet-mlx", "numpy", "scipy", "jiwer", "soundfile"]
        },
        boundary="Recomputes stored trace integrity, probability/time domains, native event decisions and WER arithmetic; verifies model files remain unchanged. This does not rerun neural/ASR inference, establish semantic correctness, validate real-time capture, or resolve corpus/annotation limitations.",
    )
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
