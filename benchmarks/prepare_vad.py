"""Preselect public VAD stress cases before candidate inference.

Derived WAVs are ignored data; the complete selection, transforms and hashes are
committed. This is a development protocol, not a sealed acceptance benchmark.
"""

import hashlib
import json
from pathlib import Path

import numpy as np
import soundfile as sf
from scipy.io import wavfile

ROOT = Path(__file__).resolve().parent
RATE = 16000


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    output = ROOT / "fixtures/vad-protocol.json"
    directory = ROOT / "fixtures/audio/vad-candidate"
    directory.mkdir(parents=True, exist_ok=True)
    rng = np.random.default_rng(20261023)
    records, inputs = [], {}

    def save(identifier, audio, **fields):
        path = directory / (identifier + ".wav")
        # scipy emits a deterministic IEEE Float WAV. libsndfile's default FLOAT
        # writer adds a PEAK timestamp, changing fixture hashes on every rebuild.
        wavfile.write(path, RATE, np.ascontiguousarray(audio, dtype=np.float32))
        records.append(
            dict(
                id=identifier,
                path=str(path.relative_to(ROOT)),
                sha256=sha(path),
                samples=len(audio),
                **fields,
            )
        )

    for split in ["test-clean", "test-other"]:
        manifest = ROOT / "fixtures" / (split + ".json")
        inputs[str(manifest.relative_to(ROOT))] = sha(manifest)
        items = json.loads(manifest.read_text())["items"]
        selected, seen = [], set()
        for row in items:
            if row["speaker_id"] not in seen:
                selected.append(row)
                seen.add(row["speaker_id"])
            if len(selected) == 20:
                break
        assert len(selected) == 20
        for row in selected:
            source = ROOT / row["path"]
            assert sha(source) == row["sha256"]
            samples, rate = sf.read(source, dtype="float32")
            assert rate == RATE and samples.ndim == 1
            original = np.pad(samples, (RATE, 3 * RATE))
            noise_rms = np.sqrt(np.mean(samples**2)) / 10 ** (10 / 20)
            noise = rng.normal(0, noise_rms, len(original)).astype(np.float32)
            for variant, audio in [
                ("original", original),
                ("quiet40db", original * 0.01),
                ("noise10db", np.clip(original + noise, -1, 1)),
            ]:
                save(
                    f"{split}-{row['id']}-{variant}",
                    audio,
                    suite=variant,
                    source_id=row["id"],
                    source_sha256=row["sha256"],
                    speaker_id=row["speaker_id"],
                    source_start_sample=RATE,
                    source_end_sample=RATE + len(samples),
                    reference=row["reference"],
                    language="en",
                    expected_speech=True,
                )
    count = 5 * RATE
    t = np.arange(count, dtype=np.float32) / RATE
    clicks = np.zeros(count, dtype=np.float32)
    for offset in range(0, count, 5600):
        clicks[offset : offset + 32] = np.hanning(32).astype(np.float32) * 0.1
    negatives = [
        ("silence", np.zeros(count, dtype=np.float32)),
        ("gaussian", rng.normal(0, 0.01, count).astype(np.float32)),
        ("hum60hz", 0.01 * np.sin(2 * np.pi * 60 * t)),
        ("tone440hz", 0.03 * np.sin(2 * np.pi * 440 * t)),
        ("clicks", clicks),
    ]
    for name, audio in negatives:
        save("synthetic-" + name, audio, suite="synthetic-negative", reference="", expected_speech=False)
    for name in ["ami", "fleurs"]:
        manifest = ROOT / "fixtures" / (name + ".json")
        inputs[str(manifest.relative_to(ROOT))] = sha(manifest)
        for row in json.loads(manifest.read_text())["items"]:
            path = ROOT / row["path"]
            assert sha(path) == row["sha256"]
            info = sf.info(path)
            record = dict(
                id=row["id"],
                path=row["path"],
                sha256=row["sha256"],
                samples=info.frames,
                suite=name,
                language=row.get("language", "en"),
                expected_speech=True,
            )
            if name == "ami":
                record.update(only_words=row["turns"], manual_segments=row["manual_segments"])
            records.append(record)
    protocol = dict(
        version=1,
        selection="First utterance of each of the first twenty unique speakers in the existing test-clean and test-other manifests. Each gains one-second leading and three-second trailing padding; original, -40 dB gain and continuous seeded Gaussian 10 dB SNR variants. All four existing AMI prefixes and all fifty FLEURS clips are included without selection by VAD outcome.",
        seed=20261023,
        sample_rate=RATE,
        input_manifests=inputs,
        endpoint=dict(
            start_threshold=0.5, continue_threshold=0.35, minimum_speech_seconds=0.096, silence_seconds=1.2
        ),
        primary_candidate="coreml-32-v6.0/cpu, preselected for 32ms granularity and independence from the ASR GPU; no product default changes before quality/integration gates",
        limitations=[
            "Public development fixtures reused from OSpr research, not a sealed holdout or a standard VAD benchmark.",
            "Gain/noise/padding variants share the same forty read-English utterances; they are not independent samples.",
            "Source clip end is a conservative content boundary, not an acoustic last-word annotation.",
            "AMI only_words/manual-segment masks are timing proxies, not hand-labeled speech/non-speech frames; no collar is applied.",
            "Synthetic negative controls do not represent real keyboards, music, echo or physical microphone routes.",
            "The Core ML 32ms model is v6.0; Core ML 256ms and MLX 32ms use v6.2.1. Runtime and model-version effects are confounded.",
        ],
        items=records,
    )
    output.write_text(json.dumps(protocol, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps(dict(cases=len(records), sha256=sha(output), output=str(output))))


if __name__ == "__main__":
    main()
