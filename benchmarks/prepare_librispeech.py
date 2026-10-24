"""Stratified subset of official LibriSpeech test archives, preserving attribution.

Download from https://www.openslr.org/12/ and pass a local .tar.gz. Select up to
five utterances per speaker by ID (deterministic, not chosen by model accuracy).
No archive paths are extracted to disk. Publish manifest/checksum, not raw audio.
"""

import argparse
from collections import defaultdict
import hashlib
import io
import json
from pathlib import Path
import tarfile

import soundfile as sf

ROOT = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("archive")
    parser.add_argument("--per-speaker", type=int, default=5)
    parser.add_argument("--split", default="test-clean", choices=["test-clean", "test-other"])
    args = parser.parse_args()
    archive = Path(args.archive)
    directory = ROOT / "fixtures/audio" / args.split
    directory.mkdir(parents=True, exist_ok=True)
    by_speaker = defaultdict(list)
    references = {}
    with tarfile.open(archive) as tar:
        members = tar.getmembers()
        for member in members:
            if member.name.endswith(".trans.txt"):
                for line in tar.extractfile(member).read().decode().splitlines():
                    identifier, text = line.split(" ", 1)
                    references[identifier] = text
            elif member.name.endswith(".flac"):
                identifier = Path(member.name).stem
                by_speaker[identifier.split("-")[0]].append(member)
        items = []
        for speaker in sorted(by_speaker):
            for member in sorted(by_speaker[speaker], key=lambda m: m.name)[: args.per_speaker]:
                identifier = Path(member.name).stem
                audio, rate = sf.read(io.BytesIO(tar.extractfile(member).read()), dtype="float32")
                target = directory / f"{identifier}.wav"
                sf.write(target, audio, rate, subtype="PCM_16")
                items.append(
                    dict(
                        id=identifier,
                        path=str(target.relative_to(ROOT)),
                        reference=references[identifier],
                        language="en",
                        suite=f"librispeech-{args.split}",
                        speaker_id=speaker,
                        sha256=hashlib.sha256(target.read_bytes()).hexdigest(),
                        seconds=len(audio) / rate,
                    )
                )
    result = dict(
        dataset="LibriSpeech",
        source=f"https://www.openslr.org/resources/12/{args.split}.tar.gz",
        source_sha256=hashlib.file_digest(archive.open("rb"), "sha256").hexdigest(),
        license="CC BY 4.0 · Vassil Panayotov, Guoguo Chen, Daniel Povey, Sanjeev Khudanpur; LibriVox speakers",
        selection=f"First {args.per_speaker} utterances per speaker sorted by archive path, selected before inference.",
        speakers=len(by_speaker),
        caveats="A subset of read English speech. Not the full official test set and not spontaneous dictation.",
        items=items,
    )
    path = ROOT / "fixtures" / f"{args.split}.json"
    path.write_text(json.dumps(result, indent=2) + "\n")
    print(
        f"Prepared {len(items)} recordings from {len(by_speaker)} speakers; {sum(i['seconds'] for i in items) / 60:.1f} minutes."
    )


if __name__ == "__main__":
    main()
