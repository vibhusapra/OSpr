"""Real native WorkerClient stop/replacement/error replay on frozen public PCM."""

import argparse
import datetime
import gzip
import hashlib
import json
from math import gcd
import os
from pathlib import Path
import subprocess
import tempfile

import jiwer
import numpy as np
import soundfile as sf
from scipy.signal import resample_poly
from run import normalize

ROOT = Path(__file__).resolve().parents[1]
PROTOCOL = ROOT / "benchmarks/fixtures/native-stream-stop-protocol.json"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def native(audio, rate):
    divisor = gcd(rate, 16000)
    return resample_poly(audio, rate // divisor, 16000 // divisor).astype(np.float32)


def checked_wave(path, audio, rate):
    sf.write(path, audio, rate, subtype="FLOAT")
    decoded, actual_rate = sf.read(path, dtype="float32")
    assert actual_rate == rate and decoded.tobytes() == audio.tobytes()
    return str(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--app", type=Path, help="Use this app's bundled Python engine with the unchanged native client source.")
    args = parser.parse_args()
    assert not args.output.exists()
    assert not subprocess.check_output(["git", "diff", "--name-only", "HEAD"], cwd=ROOT)
    protocol = json.loads(PROTOCOL.read_text())
    app = args.app.resolve(strict=True) if args.app else None
    engine_root = app / "Contents/Resources/Engine" if app else ROOT
    build_info = json.loads((app / "Contents/Resources/build-info.json").read_text()) if app else None
    if app:
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
        for name in ["streaming_audio.py", "engine.py", "worker.py", "models.lock.json"]:
            assert sha(engine_root / "backend/ospr_backend" / name) == sha(ROOT / "backend/ospr_backend" / name)
    assert sha(ROOT / "benchmarks/fixtures/manifest.json") == protocol["source_manifest_sha256"]
    assert sha(ROOT / "uv.lock") == protocol["dependency_lock_sha256"]
    assert sha(ROOT / "backend/ospr_backend/models.lock.json") == protocol["model_lock_sha256"]
    inputs = {}
    for key in ["source", "replacement_source"]:
        item = protocol[key]
        path = ROOT / "benchmarks" / item["path"]
        assert sha(path) == item["sha256"]
        audio, rate = sf.read(path, dtype="float32")
        assert rate == 16000 and audio.ndim == 1 and np.isfinite(audio).all()
        inputs[key] = audio
    with tempfile.TemporaryDirectory(prefix="native-stream-stop-", dir=ROOT / ".local") as directory:
        staging = Path(directory)
        probe = staging / "probe"
        compile_args = ["swiftc", "-O", "-swift-version", "5", "-parse-as-library",
                        "Sources/OSprCore/WorkerClient.swift", "benchmarks/native_stream_stop.swift", "-o", str(probe)]
        build = subprocess.run(compile_args, cwd=ROOT, capture_output=True, text=True, timeout=60)
        assert build.returncode == 0, build.stderr
        probe_sha = sha(probe)
        cases, source_rows = [], []
        for rate in protocol["native_rates"]:
            audio = native(inputs["source"], rate)
            split = rate * protocol["first_packet_seconds"]
            assert 0 < split < len(audio)
            folder = staging / str(rate)
            folder.mkdir()
            first = checked_wave(folder / "first.wav", audio[:split], rate)
            tail = checked_wave(folder / "tail.wav", audio[split:], rate)
            changed_rate = next(value for value in protocol["native_rates"] if value != rate)
            changed = native(inputs["source"][12 * 16000:], changed_rate)
            changed_path = checked_wave(folder / "changed.wav", changed, changed_rate)
            replacement = native(inputs["replacement_source"], rate)
            packets = [checked_wave(folder / f"replacement-{i}.wav", replacement[i:i + 4096], rate)
                       for i in range(0, len(replacement), 4096)]
            cases.append(dict(id=protocol["source"]["id"], rate=rate, packets=[first, tail],
                changedRateTail=changed_path, fullSource=str(ROOT / "benchmarks" / protocol["source"]["path"]),
                replacementPackets=packets))
            source_rows.append(dict(rate=rate, source_sha256=protocol["source"]["sha256"],
                source_native_samples=len(audio), source_native_pcm_sha256=hashlib.sha256(audio.astype("<f4").tobytes()).hexdigest(),
                packet_samples=[split, len(audio) - split], packet_sha256=[sha(Path(first)), sha(Path(tail))],
                changed_rate=changed_rate, changed_tail_samples=len(changed), changed_tail_sha256=sha(Path(changed_path)),
                replacement_native_samples=len(replacement), replacement_pcm_sha256=hashlib.sha256(replacement.astype("<f4").tobytes()).hexdigest(),
                replacement_packet_samples=[min(4096, len(replacement) - i) for i in range(0, len(replacement), 4096)],
                replacement_packet_sha256=[sha(Path(path)) for path in packets]))
        manifest = staging / "manifest.json"
        manifest.write_text(json.dumps(dict(root=str(engine_root), cases=cases, cancelAfterMS=protocol["cancel_after_ms"])))
        environment = dict(os.environ, HF_HUB_OFFLINE="1", OSPR_DEBUG_LOG="0")
        result = subprocess.run([str(probe), str(manifest)], cwd=ROOT, env=environment,
                                capture_output=True, text=True, timeout=240)
        assert result.returncode == 0, result.stderr
        traces = json.loads(result.stdout)
        assert sha(probe) == probe_sha
    if app:
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    assert len(traces["records"]) == len(protocol["native_rates"]) * len(protocol["policies"])
    for row in traces["records"]:
        reference = protocol["replacement_source" if row["policy"] == "replacement-and-stale-cancel" else "source"]["reference"]
        scored = jiwer.process_words(normalize(reference), normalize(row["final"]["text"]))
        row.update(reference=reference, wer=scored.wer, substitutions=scored.substitutions,
                   deletions=scored.deletions, insertions=scored.insertions)
    archive = args.output.with_suffix(".traces.json.gz")
    archive.write_bytes(gzip.compress(json.dumps(traces, ensure_ascii=False).encode(), mtime=0))
    rows = traces["records"]
    already = [r for r in rows if r["policy"] == "already-cancelled"]
    awaiting = [r for r in rows if r["policy"] == "cancel-while-awaiting"]
    receipt = dict(status="completed-real-native-worker-stop-replay-not-ui-acceptance",
        timestamp=datetime.datetime.now(datetime.UTC).isoformat(),
        git_commit=subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        tracked_changes=False, protocol_sha256=sha(PROTOCOL), harness_sha256=sha(Path(__file__)),
        swift_harness_sha256=sha(ROOT / "benchmarks/native_stream_stop.swift"),
        worker_client_sha256=sha(ROOT / "Sources/OSprCore/WorkerClient.swift"), probe_sha256=probe_sha,
        compiler=subprocess.check_output(["swiftc", "--version"], text=True).strip(),
        compile_arguments=compile_args[:-1] + ["<temporary-owned-probe>"],
        source_sha256={name: sha(ROOT / name) for name in ["backend/ospr_backend/streaming_audio.py",
            "backend/ospr_backend/engine.py", "backend/ospr_backend/worker.py", "uv.lock"]},
        model=protocol["model"], engine_binding="bundled" if app else "checkout", build=build_info,
        signature_valid_after_inference=bool(app), source_packets=source_rows, records=len(rows),
        already_cancelled_requests_preserved=sum(r["cancellation"]["cancelled_before_request"] for r in already),
        timed_cancellations_between_request_and_return=sum(r["cancellation"]["cancel_between_request_and_return"] for r in awaiting),
        all_text_controls_match=all(r["text_matches_control"] for r in rows),
        stale_cancel_rejections=sum(r["stale_cancel"]["cancelled"] is False for r in rows if "stale_cancel" in r),
        restarted_worker_fallbacks=sum(r["worker_pid_before"] != r["worker_pid_after"] for r in rows if r["policy"] == "rate-error-full-file-fallback"),
        traces_file=archive.name, traces_sha256=sha(archive), boundary=protocol["boundary"])
    assert not subprocess.check_output(["git", "diff", "--name-only", "HEAD"], cwd=ROOT)
    args.output.write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps({key: receipt[key] for key in ["records", "already_cancelled_requests_preserved",
        "timed_cancellations_between_request_and_return", "all_text_controls_match", "stale_cancel_rejections", "restarted_worker_fallbacks"]}, indent=2))


if __name__ == "__main__":
    main()
