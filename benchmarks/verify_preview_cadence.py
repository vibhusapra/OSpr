"""Verify frozen cadence schedules, source PCM and real-session text metrics."""

import argparse
import gzip
import hashlib
import json
from pathlib import Path
import subprocess

import jiwer
import numpy as np
from ospr_backend.audio import read_audio, SAMPLE_RATE
from run import normalize

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--result", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    assert not args.output.exists()
    receipt = json.loads(args.result.read_text())
    protocol_path = ROOT / "benchmarks/fixtures/preview-cadence-protocol.json"
    protocol = json.loads(protocol_path.read_text())
    assert sha(protocol_path) == receipt["protocol_sha256"]
    source = subprocess.check_output(
        ["git", "show", receipt["git_commit"] + ":benchmarks/preview_cadence.py"], cwd=ROOT
    )
    assert hashlib.sha256(source).hexdigest() == receipt["harness_sha256"]
    assert sha(ROOT / "Sources/OSprCore/PreviewCadence.swift") == receipt["core_scheduler_sha256"]
    assert sha(ROOT / "Sources/OSpr/AppModel.swift") == receipt["application_preview_sha256"]
    for schedule in receipt["schedules"]:
        interval, work = schedule["interval_ms"], schedule["work_ms"]
        for policy, step in [("legacy", interval + work), ("deadline", max(interval, work))]:
            assert schedule["schedules_ms"][policy] == list(range(interval, schedule["stop_ms"], step))
    path = ROOT / "benchmarks" / protocol["source"]["path"]
    assert sha(path) == protocol["source"]["sha256"]
    original = read_audio(str(path))
    audio = np.tile(
        np.pad(original, (0, protocol["block_seconds"] * SAMPLE_RATE - len(original))),
        protocol["repetitions"],
    )
    expected = " ".join([protocol["source"]["reference"]] * protocol["repetitions"])
    pcm = hashlib.sha256(memoryview(audio.astype("<f4", copy=False))).hexdigest()
    assert len(audio) == receipt["normalized_samples"] and pcm == receipt["pcm_sha256"]
    archive = args.result.with_name(receipt["traces_file"])
    assert sha(archive) == receipt["traces_sha256"]
    rows = json.loads(gzip.decompress(archive.read_bytes()))
    assert len(rows) == receipt["actual_asr_sessions"] == 6
    for row in rows:
        assert row["input_samples"] == len(audio) and row["supplied_pcm_sha256"] == pcm
        plan = next(
            s
            for s in receipt["schedules"]
            if s["interval_ms"] == 320 and s["work_ms"] == row["modeled_work_ms"]
        )
        assert [e["input_ms"] for e in row["events"]] == plan["schedules_ms"][row["policy"]]
        assert row["live_requests"] == len(row["events"])
        for event in row["events"]:
            assert event["modeled_delivery_ms"] == event["input_ms"] + row["modeled_work_ms"]
            assert event["end_sample"] == round(event["input_ms"] * SAMPLE_RATE / 1000)
        first = next((e for e in row["events"] if e["text"]), None)
        assert row["first_partial_input_ms"] == (first["input_ms"] if first else None)
        assert row["first_partial_modeled_delivery_ms"] == (first["modeled_delivery_ms"] if first else None)
        scored = jiwer.process_words(normalize(expected), normalize(row["text"]))
        assert row["reference"] == expected and scored.wer == row["wer"]
        assert (scored.substitutions, scored.deletions, scored.insertions) == (
            row["substitutions"],
            row["deletions"],
            row["insertions"],
        )
    pairs = []
    for work in protocol["modeled_work_ms"]:
        a = next(r for r in rows if r["modeled_work_ms"] == work and r["policy"] == "legacy")
        b = next(r for r in rows if r["modeled_work_ms"] == work and r["policy"] == "deadline")
        pairs.append(
            dict(
                modeled_work_ms=work,
                text_identical=a["text"] == b["text"],
                legacy_wer=a["wer"],
                deadline_wer=b["wer"],
            )
        )
    assert pairs == receipt["summary"]
    result = dict(
        status="passed-schedule-source-and-metric-checks-not-native-latency",
        source_result_sha256=sha(args.result),
        verifier_sha256=sha(Path(__file__)),
        actual_sessions=6,
        normalized_samples_each=len(audio),
        identical_text_pairs=sum(row["text_identical"] for row in pairs),
        first_partial_modeled_regressions=[
            work
            for work in protocol["modeled_work_ms"]
            if next(r for r in rows if r["modeled_work_ms"] == work and r["policy"] == "deadline")[
                "first_partial_modeled_delivery_ms"
            ]
            > next(r for r in rows if r["modeled_work_ms"] == work and r["policy"] == "legacy")[
                "first_partial_modeled_delivery_ms"
            ]
        ],
        boundary="Closed-form fixed-cost schedules match the actual Core probe; source PCM and raw text/WER counts check. More frequent requests do not guarantee an earlier first partial: phase-dependent regressions are retained. No native/device, energy, actual latency or non-16k packet-normalization acceptance.",
    )
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
