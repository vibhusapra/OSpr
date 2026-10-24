"""Download a small public human-speech regression set and build deterministic stress cases.

The upstream dummy set is a SMALL subset of LibriSpeech, not the full test-clean
benchmark. Never describe its WER as leaderboard or production-dictation WER.
"""

import hashlib
import io
import json
from pathlib import Path

from huggingface_hub import HfApi, hf_hub_download
import numpy as np
import pyarrow.parquet as pq
import soundfile as sf

ROOT = Path(__file__).resolve().parent


def main():
    repo = "hf-internal-testing/librispeech_asr_dummy"
    revision = HfApi().dataset_info(repo).sha
    source = hf_hub_download(
        repo, "clean/validation-00000-of-00001.parquet", repo_type="dataset", revision=revision
    )
    rows = pq.read_table(source).to_pylist()
    directory = ROOT / "fixtures/audio"
    directory.mkdir(parents=True, exist_ok=True)
    manifest = []

    def save(name, audio, rate, text, suite, source_id):
        path = directory / f"{name}.wav"
        sf.write(path, audio, rate, subtype="PCM_16")
        manifest.append(
            dict(
                id=name,
                path=str(path.relative_to(ROOT)),
                reference=text,
                suite=suite,
                source_id=source_id,
                sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
                seconds=len(audio) / rate,
            )
        )

    for row in rows:
        audio, rate = sf.read(io.BytesIO(row["audio"]["bytes"]), dtype="float32")
        save(row["id"], audio, rate, row["text"], "human-clean", row["id"])
    # Same utterances with controlled degradation: not independent speakers or a
    # new corpus. Group them separately and report the random seed and SNR.
    rng = np.random.default_rng(20261022)
    for row in rows[:12]:
        audio, rate = sf.read(io.BytesIO(row["audio"]["bytes"]), dtype="float32")
        noise = rng.normal(0, np.sqrt(np.mean(audio**2)) / 10 ** (10 / 20), audio.shape)
        save(
            row["id"] + "-noise10",
            np.clip(audio + noise, -1, 1),
            rate,
            row["text"],
            "human-noise10db",
            row["id"],
        )
        save(row["id"] + "-quiet", audio * 0.1, rate, row["text"], "human-quiet", row["id"])
    save("silence-5", np.zeros(80000), 16000, "", "silence", "generated")
    save("low-noise-5", rng.normal(0, 0.0001, 80000), 16000, "", "silence", "generated")
    # Long concatenation catches chunk-boundary loss; reference joins exact text.
    pieces = [sf.read(io.BytesIO(row["audio"]["bytes"]), dtype="float32")[0] for row in rows[:10]]
    save(
        "long-concat",
        np.concatenate([np.concatenate([piece, np.zeros(3200)]) for piece in pieces]),
        16000,
        " ".join(row["text"] for row in rows[:10]),
        "human-long",
        "first-10-concatenated",
    )
    (ROOT / "fixtures/manifest.json").write_text(
        json.dumps(
            dict(
                dataset=repo,
                revision=revision,
                source_sha256=hashlib.sha256(Path(source).read_bytes()).hexdigest(),
                license="LibriSpeech CC BY 4.0; retain attribution to Vassil Panayotov et al. and LibriVox readers.",
                caveats="Small single-speaker read-English subset; no accents, spontaneous dictation or multilingual coverage.",
                noise_seed=20261022,
                items=manifest,
            ),
            indent=2,
        )
        + "\n"
    )
    print(f"Prepared {len(manifest)} cases from {len(rows)} public human recordings.")


if __name__ == "__main__":
    main()
