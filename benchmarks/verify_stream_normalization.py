"""Independently check source-bound PCM receipts and edit distances.

Uses whole-array SciPy normalization and legacy packet reconstruction, never the
candidate StreamNormalizer. Does not repeat GPU inference or certify devices.
"""

import argparse
import gzip
import hashlib
import json
from math import ceil, gcd
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


def converted(audio, source, target=16000):
    divisor = gcd(source, target)
    return resample_poly(audio, target // divisor, source // divisor).astype(np.float32)


def ends(length, pattern):
    position, index, result = 0, 0, []
    while position < length:
        position = min(length, position + pattern[index % len(pattern)])
        result.append(position)
        index += 1
    return result


def edit_distance(a, b):
    previous = list(range(len(b) + 1))
    for index, word in enumerate(a, 1):
        current = [index]
        for other, target in enumerate(b, 1):
            current.append(min(previous[other] + 1, current[-1] + 1,
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
    path = ROOT / "benchmarks/fixtures/stream-normalization-protocol.json"
    protocol = json.loads(path.read_text())
    assert sha(path) == receipt["protocol_sha256"]
    for name, digest in dict(receipt["source_sha256"], **{
        "benchmarks/stream_normalization.py": receipt["harness_sha256"]
    }).items():
        frozen = subprocess.check_output(["git", "show", receipt["git_commit"] + ":" + name], cwd=ROOT)
        assert hashlib.sha256(frozen).hexdigest() == digest == sha(ROOT / name)
    archive = args.result.with_name(receipt["traces_file"])
    assert sha(archive) == receipt["traces_sha256"]
    records = json.loads(gzip.decompress(archive.read_bytes()))
    assert len(records) == receipt["actual_asr_sessions"] == 36
    for item in protocol["sources"]:
        path = ROOT / "benchmarks" / item["path"]
        assert sha(path) == item["sha256"]
        original, original_rate = sf.read(path, dtype="float32")
        assert original_rate == 16000 and original.ndim == 1
        for rate in protocol["native_rates"]:
            native = converted(original, 16000, rate)
            expected = np.clip(converted(native, rate), -1, 1)
            divisor = gcd(rate, 16000)
            up, down = 16000 // divisor, rate // divisor
            halo = ceil((10 * max(up, down) + down) / up) + 2
            for pattern in protocol["partitions"]:
                positions = ends(len(native), pattern)
                rows = [row for row in records if row["id"] == item["id"]
                        and row["rate"] == rate and row["pattern"] == pattern]
                assert len(rows) == 3 and {r["policy"] for r in rows} == {"legacy", "continuous", "canonical"}
                old, start = [], 0
                for end in positions:
                    old.append(np.clip(converted(native[start:end], rate), -1, 1))
                    start = end
                legacy = np.concatenate(old)
                for row in rows:
                    assert row["reference"] == item["reference"] and row["source_sha256"] == item["sha256"]
                    assert row["native_samples"] == len(native) and row["native_pcm_sha256"] == pcm(native)
                    assert row["expected_samples"] == len(expected) and row["expected_pcm_sha256"] == pcm(expected)
                    actual = legacy if row["policy"] == "legacy" else expected
                    assert row["supplied_samples"] == len(actual) and row["supplied_pcm_sha256"] == pcm(actual)
                    assert [e["native_end"] for e in row["events"]] == positions
                    if row["policy"] == "continuous":
                        counts = [max(0, (end - halo) * up // down) for end in positions]
                        assert row["retained_max_samples"] <= 2 * halo + 2 * down
                    elif row["policy"] == "canonical":
                        counts = [end * 16000 // rate for end in positions]
                    else:
                        counts = np.cumsum([len(piece) for piece in old]).tolist()
                    assert [e["supplied_samples"] for e in row["events"]] == counts
                    first = next((e for e in row["events"] if e["text"]), None)
                    assert row["first_partial_native_sample"] == (first["native_end"] if first else None)
                    words = normalize(item["reference"]).split()
                    distance = edit_distance(words, normalize(row["text"]).split())
                    assert len(words) == row["reference_words"]
                    assert distance == row["substitutions"] + row["deletions"] + row["insertions"]
                    assert distance / len(words) == row["wer"]
    rng = np.random.default_rng(20261023)
    for rate in protocol["synthetic_rates"]:
        audio = (0.2 * np.sin(2 * np.pi * 440 * np.arange(rate) / rate)
                 + rng.normal(0, 0.01, rate)).astype(np.float32)
        expected = np.clip(converted(audio, rate), -1, 1)
        for packet in protocol["synthetic_packets"]:
            row = next(r for r in receipt["synthetic"] if r["rate"] == rate and r["packet"] == packet)
            old = np.concatenate([np.clip(converted(audio[i:i + packet], rate), -1, 1)
                                  for i in range(0, len(audio), packet)])
            assert row["expected_pcm_sha256"] == row["actual_pcm_sha256"] == pcm(expected)
            assert row["expected_samples"] == row["actual_samples"] == len(expected)
            assert row["legacy_samples"] == len(old) and row["legacy_pcm_sha256"] == pcm(old)
            assert row["retained_max_samples"] <= row["state_bound_samples"]
    for rate in [44100, 48000]:
        audio = rng.uniform(-0.4, 0.4, rate * protocol["stress_seconds"] + 7).astype(np.float32)
        expected = np.clip(converted(audio, rate), -1, 1)
        row = next(r for r in receipt["stress"] if r["rate"] == rate)
        assert row["input_samples"] == len(audio)
        assert row["expected_pcm_sha256"] == row["actual_pcm_sha256"] == pcm(expected)
        assert row["expected_samples"] == row["actual_samples"] == len(expected)
        assert row["retained_max_samples"] <= row["state_bound_samples"]
    summary = []
    for policy in ["canonical", "legacy", "continuous"]:
        rows = [r for r in records if r["policy"] == policy]
        errors = sum(edit_distance(normalize(r["reference"]).split(), normalize(r["text"]).split()) for r in rows)
        words = sum(r["reference_words"] for r in rows)
        summary.append(dict(policy=policy, sessions=len(rows), errors=errors, words=words, wer=errors / words,
            pcm_matches=sum(r["supplied_pcm_sha256"] == r["expected_pcm_sha256"] for r in rows),
            samples_match=sum(r["supplied_samples"] == r["expected_samples"] for r in rows)))
    assert summary == receipt["summary"]
    pairs = sum(r["text"] == next(c["text"] for c in records if c["id"] == r["id"]
        and c["rate"] == r["rate"] and c["pattern"] == r["pattern"] and c["policy"] == "canonical")
        for r in records if r["policy"] == "continuous")
    result = dict(status="passed-independent-pcm-source-and-distance-checks", source_result_sha256=sha(args.result),
        verifier_sha256=sha(Path(__file__)), actual_sessions=len(records), synthetic_cases=len(receipt["synthetic"]),
        stress_cases=len(receipt["stress"]), continuous_text_matches=pairs, summary=summary,
        boundary="Whole-array and independently reconstructed legacy PCM hashes, packet sample positions and edit distances agree with raw receipts. Does not repeat recognizer inference or establish native latency, device behavior or general accuracy.")
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
