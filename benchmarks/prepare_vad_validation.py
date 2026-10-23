"""Freeze the remaining 33 VAD speakers before testing the causal score.

These speakers were in older ASR studies; this is excluded-speaker VAD
validation, not a sealed ASR holdout. No candidate inference runs here.
"""

import hashlib
import json
from pathlib import Path

import numpy as np
from scipy.io import wavfile
import soundfile as sf

ROOT = Path(__file__).resolve().parent
RATE = 16000


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    development = ROOT / "fixtures/vad-protocol.json"
    prior = json.loads(development.read_text())
    excluded = {row["speaker_id"] for row in prior["items"] if "speaker_id" in row}
    assert len(excluded) == 40
    output = ROOT / "fixtures/vad-causal8-validation-protocol.json"
    directory = ROOT / "fixtures/audio/vad-validation"
    directory.mkdir(parents=True, exist_ok=True)
    rng = np.random.default_rng(20261024)
    items, speakers, inputs = [], set(), {}
    for split in ["test-clean", "test-other"]:
        manifest = ROOT / "fixtures" / (split + ".json")
        inputs[str(manifest.relative_to(ROOT))] = sha(manifest)
        for row in json.loads(manifest.read_text())["items"]:
            speaker = row["speaker_id"]
            if speaker in excluded or speaker in speakers:
                continue
            speakers.add(speaker)
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
                identifier = f"vad-validation-{split}-{row['id']}-{variant}"
                path = directory / (identifier + ".wav")
                wavfile.write(path, RATE, np.ascontiguousarray(audio, dtype=np.float32))
                items.append(
                    dict(
                        id=identifier,
                        path=str(path.relative_to(ROOT)),
                        sha256=sha(path),
                        samples=len(audio),
                        suite=variant,
                        source_id=row["id"],
                        source_sha256=row["sha256"],
                        speaker_id=speaker,
                        source_start_sample=RATE,
                        source_end_sample=RATE + len(samples),
                        reference=row["reference"],
                        language="en",
                        expected_speech=True,
                    )
                )
    assert len(speakers) == 33 and not (speakers & excluded) and len(items) == 99
    controls = [row for row in prior["items"] if row["suite"] == "synthetic-negative"]
    assert len(controls) == 5
    items.extend(controls)
    protocol = dict(
        version=2,
        seed=20261024,
        sample_rate=RATE,
        development_protocol_sha256=sha(development),
        input_manifests=inputs,
        excluded_development_speakers=sorted(excluded),
        validation_speakers=sorted(speakers),
        selection="First available utterance from every remaining speaker in the existing stratified English manifests. Twenty clean and thirteen other speakers are excluded from the VAD development slice; no selection by detector/ASR outcome. Three fixed transforms plus the same five development negative controls.",
        score=dict(
            window_frames=8,
            formula="1-product(1-p) over the current and seven preceding frames; no future frames; correlated activity score",
        ),
        policies=[
            dict(id="raw", window_frames=1, silence_seconds=1.2),
            dict(id="raw-history-control", window_frames=1, silence_seconds=1.424),
            dict(id="causal8", window_frames=8, silence_seconds=1.2),
        ],
        endpoint=dict(start_threshold=0.5, continue_threshold=0.35, minimum_speech_seconds=0.096),
        edge=dict(start_threshold=0.5, continue_threshold=0.35, padding_samples=2560),
        asr_models=["parakeet-v3", "whisper-turbo", "cohere-native8"],
        asr_input_policies=[
            "full-no-trim",
            "rms-default-edge",
            "rms-low-edge",
            "raw-edge",
            "causal8-edge",
            "rms-default-endpoint",
            "raw-endpoint",
            "raw-history-control-endpoint",
            "causal8-endpoint",
            "rms-default-chain",
            "causal8-chain",
        ],
        gate="No GUI/default promotion from aggregate WER alone. Check every new empty speech result, per-model original/quiet/noisy WER, negative hallucinations, finish coverage and actual endpoint delays. Live queue/resampling/device acceptance remains required.",
        limitations=[
            "These speakers appeared in earlier ASR evaluation; this is not a sealed model-ranking holdout.",
            "Three transforms share each source utterance. Gain is synthetic electrical attenuation; SNR is nominal before clipping.",
            "The five synthetic negative controls are reused, not independent environmental noise.",
            "The 224ms history retention is not a bound on added finish delay: continued weak posteriors may sustain the aggregated score. The 1.424s raw control only accounts for the fixed history span; compare observed delays too.",
            "Source clip end is a content-boundary proxy, not a last-phoneme annotation. No physical microphone or scheduling test.",
        ],
        items=items,
    )
    output.write_text(json.dumps(protocol, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(dict(cases=len(items), speakers=len(speakers), sha256=sha(output), output=str(output))))


if __name__ == "__main__":
    main()
