"""Build reproducible long-file completeness fixtures from public read speech.

Concatenation tests duration/chunk/token limits, not spontaneous-meeting quality.
Run this preparatory script before the existing per-model benchmark harness.
"""

import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
import soundfile as sf

ROOT = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--minutes", nargs="+", type=int, default=[10, 60])
    args = parser.parse_args()
    if any(minutes < 1 or minutes > 120 for minutes in args.minutes):
        parser.error("Select 1–120 minutes")
    source_path = ROOT / "fixtures/test-clean.json"
    source = json.loads(source_path.read_text())
    items = source["items"]
    for item in items:
        path = ROOT / item["path"]
        if hashlib.sha256(path.read_bytes()).hexdigest() != item["sha256"]:
            raise ValueError("Source fixture checksum mismatch")
    directory = ROOT / "fixtures/audio/long-session"
    directory.mkdir(parents=True, exist_ok=True)
    output = []
    for minutes in args.minutes:
        path = directory / f"public-concat-{minutes}m.wav"
        pieces, reference, frames = [], [], 0
        with sf.SoundFile(path, mode="w", samplerate=16000, channels=1,
                          format="WAV", subtype="FLOAT") as writer:
            index = 0
            while frames < minutes * 60 * 16000:
                item = items[index % len(items)]
                audio, rate = sf.read(ROOT / item["path"], dtype="float32")
                if rate != 16000 or audio.ndim != 1:
                    raise ValueError("Expected verified mono 16kHz source")
                pieces.append(dict(source_id=item["id"], source_sha256=item["sha256"],
                                   start_seconds=frames / 16000,
                                   end_seconds=(frames + len(audio)) / 16000,
                                   reference=item["reference"]))
                writer.write(audio)
                writer.write(np.zeros(4000, dtype=np.float32))
                frames += len(audio) + 4000
                reference.append(item["reference"])
                index += 1
        info = sf.info(path)
        assert info.frames == frames and info.samplerate == 16000 and info.channels == 1
        output.append(dict(id=f"public-concat-{minutes}m", path=str(path.relative_to(ROOT)),
                           reference=" ".join(reference), suite="long-session", language="en",
                           sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
                           seconds=frames / 16000, pieces=pieces))
    manifest = dict(dataset="LibriSpeech test-clean deterministic concatenation",
                    source_manifest_sha256=hashlib.sha256(source_path.read_bytes()).hexdigest(),
                    source=source["source"], license=source["license"],
                    selection="Repeat the preselected 200-clip/40-speaker order, inserting 250ms digital silence after each whole clip, until target duration is reached; no partial final utterance.",
                    caveats="Synthetic speaker/utterance joins and repeated speech test completeness and resource limits. Not natural long conversation, the full corpus, independent new speakers or a production accuracy estimate.",
                    items=output)
    target = ROOT / "fixtures/long-session.json"
    target.write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps({"manifest": str(target), "files": [dict(id=r["id"], seconds=r["seconds"],
                                                             utterances=len(r["pieces"])) for r in output]}, indent=2))


if __name__ == "__main__":
    main()
