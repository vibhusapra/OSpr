"""Fixed native-rate PCM continuity and real streaming recognizer regression.

Unpaced replay. Reports processing work, not microphone/UI latency or energy.
Run with PYTHONPATH=backend and HF_HUB_OFFLINE=1 on the pinned cached model.
"""

import argparse
import datetime
import gzip
import hashlib
import json
from math import gcd
from pathlib import Path
import subprocess
import time

import jiwer
import numpy as np
import soundfile as sf
from scipy.signal import resample_poly

from ospr_backend.audio import read_audio
from ospr_backend.engine import Engine
from ospr_backend.streaming_audio import StreamNormalizer
from ospr_backend.temporary import private_audio_file
from run import normalize

ROOT = Path(__file__).resolve().parents[1]
PROTOCOL = ROOT / "benchmarks/fixtures/stream-normalization-protocol.json"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def pcm_sha(audio):
    return hashlib.sha256(audio.astype("<f4", copy=False).tobytes()).hexdigest()


def resample(audio, rate, target=16000):
    divisor = gcd(rate, target)
    return resample_poly(audio, target // divisor, rate // divisor).astype(np.float32)


def endpoints(length, pattern):
    position, index = 0, 0
    while position < length:
        position = min(length, position + pattern[index % len(pattern)])
        yield position
        index += 1


def synthetic(protocol):
    rows = []
    rng = np.random.default_rng(20261023)
    for rate in protocol["synthetic_rates"]:
        audio = (0.2 * np.sin(2 * np.pi * 440 * np.arange(rate) / rate)
                 + rng.normal(0, 0.01, rate)).astype(np.float32)
        expected = np.clip(resample(audio, rate), -1, 1)
        for packet in protocol["synthetic_packets"]:
            normalizer, position, live, legacy, retained = StreamNormalizer(rate), 0, [], [], 0
            started = time.perf_counter()
            for end in endpoints(len(audio), [packet]):
                chunk = audio[position:end]
                live.append(normalizer.feed(chunk))
                retained = max(retained, len(normalizer.buffer))
                legacy.append(np.clip(resample(chunk, rate), -1, 1))
                position = end
            live.append(normalizer.feed([], final=True))
            actual, old = np.concatenate(live), np.concatenate(legacy)
            assert actual.tobytes() == expected.tobytes()
            rows.append(dict(rate=rate, packet=packet, input_samples=len(audio), expected_samples=len(expected),
                actual_samples=len(actual), legacy_samples=len(old), actual_pcm_sha256=pcm_sha(actual),
                expected_pcm_sha256=pcm_sha(expected), legacy_pcm_sha256=pcm_sha(old),
                retained_max_samples=retained, state_bound_samples=2 * normalizer.halo + 2 * normalizer.down,
                wall_ms=(time.perf_counter() - started) * 1000))
    stress = []
    for rate in [44100, 48000]:
        audio = rng.uniform(-0.4, 0.4, rate * protocol["stress_seconds"] + 7).astype(np.float32)
        normalizer, pieces, position, retained = StreamNormalizer(rate), [], 0, 0
        started = time.perf_counter()
        for end in endpoints(len(audio), [1024]):
            pieces.append(normalizer.feed(audio[position:end]))
            retained = max(retained, len(normalizer.buffer))
            assert retained <= 2 * normalizer.halo + 2 * normalizer.down
            position = end
        pieces.append(normalizer.feed([], final=True))
        actual, expected = np.concatenate(pieces), np.clip(resample(audio, rate), -1, 1)
        assert actual.tobytes() == expected.tobytes()
        stress.append(dict(rate=rate, input_samples=len(audio), expected_samples=len(expected),
            actual_samples=len(actual), expected_pcm_sha256=pcm_sha(expected), actual_pcm_sha256=pcm_sha(actual),
            retained_max_samples=retained, state_bound_samples=2 * normalizer.halo + 2 * normalizer.down,
            wall_ms=(time.perf_counter() - started) * 1000))
    return rows, stress


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    assert not args.output.exists()
    assert not subprocess.check_output(["git", "diff", "--name-only", "HEAD"], cwd=ROOT)
    protocol = json.loads(PROTOCOL.read_text())
    assert sha(ROOT / "benchmarks/fixtures/manifest.json") == protocol["source_manifest_sha256"]
    assert sha(ROOT / "uv.lock") == protocol["dependency_lock_sha256"]
    assert sha(ROOT / "backend/ospr_backend/models.lock.json") == protocol["model_lock_sha256"]
    synthetic_rows, stress = synthetic(protocol)
    engine, records = Engine(), []
    model, _ = engine._load(protocol["model"])
    archive = args.output.with_suffix(".traces.json.gz")
    for item_index, item in enumerate(protocol["sources"]):
        source = ROOT / "benchmarks" / item["path"]
        assert sha(source) == item["sha256"]
        original = read_audio(source)
        for rate in protocol["native_rates"]:
            native = resample(original, 16000, rate)
            with private_audio_file() as file:
                sf.write(file.name, native, rate, subtype="FLOAT")
                expected = read_audio(file.name)
                for pattern in protocol["partitions"]:
                    ends = list(endpoints(len(native), pattern))
                    for policy in protocol["policy_orders"][item_index]:
                        state = engine.stream_begin(protocol["language_hint"])
                        session, digest, sent, events = engine.stream, hashlib.sha256(), [0], []
                        original_feed = session.feed

                        def observe(audio, original_feed=original_feed, digest=digest, sent=sent):
                            digest.update(audio.astype("<f4", copy=False).tobytes())
                            sent[0] += len(audio)
                            return original_feed(audio)

                        session.feed = observe
                        position, canonical_position, retained = 0, 0, 0
                        began = time.perf_counter()
                        for end in ends:
                            if policy == "continuous":
                                chunk, packet_rate = native[position:end], rate
                            elif policy == "legacy":
                                # Exactly the old native packet read_audio normalization,
                                # then the no-op 16 kHz Engine input path.
                                sf.write(file.name, native[position:end], rate, subtype="FLOAT")
                                chunk, packet_rate = read_audio(file.name), 16000
                            else:
                                canonical_end = end * 16000 // rate
                                chunk, packet_rate = expected[canonical_position:canonical_end], 16000
                                canonical_position = canonical_end
                            sf.write(file.name, chunk, packet_rate, subtype="FLOAT")
                            event = engine.stream_feed(file.name, session_id=state["session_id"])
                            retained = max(retained, len(engine.stream_normalizer.buffer))
                            events.append(dict(native_end=end, supplied_samples=sent[0], text=event["text"],
                                               processing_ms=event["processing_ms"]))
                            position = end
                        if policy == "canonical" and canonical_position < len(expected):
                            sf.write(file.name, expected[canonical_position:], 16000, subtype="FLOAT")
                            engine.stream_feed(file.name, session_id=state["session_id"])
                        final = engine.stream_feed(final=True, session_id=state["session_id"])
                        assert final["done"] and session.done
                        if policy != "legacy":
                            assert sent[0] == len(expected) and digest.hexdigest() == pcm_sha(expected)
                        scored = jiwer.process_words(normalize(item["reference"]), normalize(final["text"]))
                        first = next((event for event in events if event["text"]), None)
                        row = dict(id=item["id"], source_sha256=item["sha256"], rate=rate, pattern=pattern,
                            policy=policy, native_samples=len(native), native_pcm_sha256=pcm_sha(native),
                            expected_samples=len(expected), expected_pcm_sha256=pcm_sha(expected),
                            supplied_samples=sent[0], supplied_pcm_sha256=digest.hexdigest(),
                            retained_max_samples=retained, text=final["text"], reference=item["reference"],
                            wer=scored.wer, substitutions=scored.substitutions, deletions=scored.deletions,
                            insertions=scored.insertions, reference_words=len(normalize(item["reference"]).split()),
                            first_partial_native_sample=first["native_end"] if first else None,
                            final_flush_ms=final["processing_ms"], wall_ms=(time.perf_counter() - began) * 1000,
                            events=events)
                        records.append(row)
                        archive.write_bytes(gzip.compress(json.dumps(records, ensure_ascii=False).encode(), mtime=0))
                        print(json.dumps({key: row[key] for key in ["id", "rate", "pattern", "policy", "wer", "supplied_samples"]}), flush=True)
    summary = []
    for policy in ["canonical", "legacy", "continuous"]:
        rows = [row for row in records if row["policy"] == policy]
        errors = sum(row["substitutions"] + row["deletions"] + row["insertions"] for row in rows)
        words = sum(row["reference_words"] for row in rows)
        summary.append(dict(policy=policy, sessions=len(rows), errors=errors, words=words, wer=errors / words,
            pcm_matches=sum(row["supplied_pcm_sha256"] == row["expected_pcm_sha256"] for row in rows),
            samples_match=sum(row["supplied_samples"] == row["expected_samples"] for row in rows)))
    receipt = dict(status="completed-native-pcm-and-real-stream-replay-not-device-acceptance",
        timestamp=datetime.datetime.now(datetime.UTC).isoformat(),
        git_commit=subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        tracked_changes=False, harness_sha256=sha(Path(__file__)), protocol_sha256=sha(PROTOCOL),
        source_sha256={name: sha(ROOT / name) for name in ["backend/ospr_backend/streaming_audio.py",
            "backend/ospr_backend/engine.py", "backend/ospr_backend/audio.py", "uv.lock"]},
        model=protocol["model"], att_context_size=model.default_att_context_size,
        actual_asr_sessions=len(records), summary=summary, synthetic=synthetic_rows, stress=stress,
        traces_file=archive.name, traces_sha256=sha(archive), boundary=protocol["boundary"])
    assert not subprocess.check_output(["git", "diff", "--name-only", "HEAD"], cwd=ROOT)
    args.output.write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
