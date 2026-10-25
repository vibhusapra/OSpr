"""Check native stop caller ordering, text controls, PCM recipes and source pins.

Does not repeat inference or claim that a GPU kernel was active at cancellation.
Ephemeral WAV hashes identify the producer's checked files, not archived bytes.
"""

import argparse
import gzip
import hashlib
import json
from math import gcd
from pathlib import Path
import subprocess

import numpy as np
import soundfile as sf
from scipy.signal import resample_poly
from run import normalize

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def pcm(audio):
    return hashlib.sha256(audio.astype("<f4", copy=False).tobytes()).hexdigest()


def edit_distance(a, b):
    previous = list(range(len(b) + 1))
    for index, word in enumerate(a, 1):
        current = [index]
        for other, target in enumerate(b, 1):
            current.append(min(current[-1] + 1, previous[other] + 1,
                               previous[other - 1] + (word != target)))
        previous = current
    return previous[-1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--result", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    assert not args.output.exists()
    receipt = json.loads(args.result.read_text())
    protocol_path = ROOT / "benchmarks/fixtures/native-stream-stop-protocol.json"
    assert sha(protocol_path) == receipt["protocol_sha256"]
    protocol = json.loads(protocol_path.read_text())
    assert sha(ROOT / "backend/ospr_backend/models.lock.json") == protocol["model_lock_sha256"]
    assert sha(ROOT / "uv.lock") == protocol["dependency_lock_sha256"]
    sources = dict(receipt["source_sha256"], **{
        "benchmarks/native_stream_stop.py": receipt["harness_sha256"],
        "benchmarks/native_stream_stop.swift": receipt["swift_harness_sha256"],
        "Sources/OSprCore/WorkerClient.swift": receipt["worker_client_sha256"],
    })
    if "worker_lifetime_sha256" in receipt:
        sources["Sources/OSprCore/WorkerLifetime.swift"] = receipt["worker_lifetime_sha256"]
    for name, digest in sources.items():
        frozen = subprocess.check_output(["git", "show", receipt["git_commit"] + ":" + name], cwd=ROOT)
        assert hashlib.sha256(frozen).hexdigest() == digest
    expected_compile = ["swiftc", "-O", "-swift-version", "5", "-parse-as-library", "Sources/OSprCore/WorkerClient.swift"]
    if "worker_lifetime_sha256" in receipt:
        expected_compile.append("Sources/OSprCore/WorkerLifetime.swift")
    expected_compile += ["benchmarks/native_stream_stop.swift", "-o", "<temporary-owned-probe>"]
    assert receipt["compile_arguments"] == expected_compile
    decoded = {}
    for key in ["source", "replacement_source"]:
        item = protocol[key]
        path = ROOT / "benchmarks" / item["path"]
        assert sha(path) == item["sha256"]
        audio, rate = sf.read(path, dtype="float32")
        assert rate == 16000 and audio.ndim == 1
        decoded[key] = audio
    for row in receipt["source_packets"]:
        rate = row["rate"]
        divisor = gcd(rate, 16000)
        audio = resample_poly(decoded["source"], rate // divisor, 16000 // divisor).astype(np.float32)
        assert row["source_sha256"] == protocol["source"]["sha256"]
        assert row["source_native_samples"] == len(audio) and row["source_native_pcm_sha256"] == pcm(audio)
        split = rate * protocol["first_packet_seconds"]
        assert row["packet_samples"] == [split, len(audio) - split]
        replacement = resample_poly(decoded["replacement_source"], rate // divisor, 16000 // divisor).astype(np.float32)
        assert row["replacement_native_samples"] == len(replacement) and row["replacement_pcm_sha256"] == pcm(replacement)
        assert row["replacement_packet_samples"] == [min(4096, len(replacement) - i) for i in range(0, len(replacement), 4096)]
        assert row["changed_rate"] in protocol["native_rates"] and row["changed_rate"] != rate
    archive = args.result.with_name(receipt["traces_file"])
    assert sha(archive) == receipt["traces_sha256"]
    trace = json.loads(gzip.decompress(archive.read_bytes()))
    records = trace["records"]
    assert len(records) == receipt["records"] == 10
    timed = 0
    for rate in protocol["native_rates"]:
        rows = [r for r in records if r["rate"] == rate]
        assert len(rows) == 5 and {r["policy"] for r in rows} == set(protocol["policies"])
        normal = next(r for r in rows if r["policy"] == "normal")
        for row in rows:
            item = protocol["replacement_source" if row["policy"] == "replacement-and-stale-cancel" else "source"]
            assert row["id"] == protocol["source"]["id"] and row["reference"] == item["reference"]
            words = normalize(item["reference"]).split()
            distance = edit_distance(words, normalize(row["final"]["text"]).split())
            assert distance == row["substitutions"] + row["deletions"] + row["insertions"]
            assert distance / len(words) == row["wer"]
            assert row["text_matches_control"] is True and row["final"]["text"].strip()
            policy = row["policy"]
            if policy in {"normal", "already-cancelled", "cancel-while-awaiting"}:
                assert row["worker_pid_before"] == row["worker_pid_after"]
                assert row["final"]["done"] is True
                assert row["final"]["text"] == normal["final"]["text"]
                start, end = row["first_request_start_uptime"], row["first_request_return_uptime"]
                assert 0 < start < end
                assert row["first_response"]["done"] is False and row["tail_response"]["done"] is False
                if policy == "already-cancelled":
                    assert row["cancellation"]["cancelled_before_request"] is True
                if policy == "cancel-while-awaiting":
                    at = row["cancellation"]["cancel_at_uptime"]
                    exercised = start < at < end
                    assert exercised == row["cancellation"]["cancel_between_request_and_return"]
                    timed += exercised
            else:
                assert row["final"]["text"] == row["fresh_control"]["text"]
                if policy == "replacement-and-stale-cancel":
                    assert row["stale_cancel"]["cancelled"] is False
                else:
                    assert "sample rate changed" in row["rejection"]
                    assert row["worker_pid_before"] != row["worker_pid_after"]
    assert receipt["already_cancelled_requests_preserved"] == receipt["stale_cancel_rejections"] == receipt["restarted_worker_fallbacks"] == 2
    assert receipt["timed_cancellations_between_request_and_return"] == timed
    assert receipt["all_text_controls_match"] is True
    result = dict(status="passed-source-caller-order-and-control-checks", source_result_sha256=sha(args.result),
        verifier_sha256=sha(Path(__file__)), records=len(records), timed_cancellations_between_request_and_return=timed,
        already_cancelled_requests_preserved=2, stale_cancel_rejections=2, restarted_worker_fallbacks=2,
        boundary="Verified frozen sources, unchanged compiled WorkerClient input, native PCM recipes/counts, trace hashes, caller cancellation ordering, PID relationships, text controls and independent edit distances. Does not repeat inference, reconstruct ephemeral WAV file bytes or prove active GPU-kernel cancellation, physical capture, AppModel, UI or insertion.")
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
