"""Small natural-meeting evaluation slices. AMI headset mix, not distant-mic SDM."""

import argparse
import hashlib
import json
from pathlib import Path
import xml.etree.ElementTree as ET
from zipfile import ZipFile
from urllib.request import urlopen
import numpy as np
import soundfile as sf
from huggingface_hub import hf_hub_download

ROOT = Path(__file__).resolve().parent
REPO = "FluidInference/ami-corpus-mirror"
REVISION = "722d8891643e1e4dc62cfd0d198fa05a1646c3cc"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--meetings", nargs="+", default=["ES2004a", "EN2002a", "IS1009a", "TS3003a"])
    parser.add_argument("--seconds", type=int, default=180)
    args = parser.parse_args()
    if not 30 <= args.seconds <= 600:
        raise ValueError("Select a bounded 30–600 second slice")
    annotations = Path(
        hf_hub_download(
            REPO, "annotations/ami_public_manual_1.6.2.zip", repo_type="dataset", revision=REVISION
        )
    )
    items = []
    with ZipFile(annotations) as archive:
        for meeting in args.meetings:
            if not meeting.isalnum():
                raise ValueError("Invalid meeting ID")
            source = Path(
                hf_hub_download(
                    REPO, f"sdm/{meeting}.Mix-Headset.wav", repo_type="dataset", revision=REVISION
                )
            )
            info = sf.info(source)
            audio, rate = sf.read(
                source, frames=args.seconds * info.samplerate, dtype="float32", always_2d=True
            )
            destination = ROOT / "fixtures/audio" / f"ami-{meeting}-{args.seconds}s.wav"
            destination.parent.mkdir(exist_ok=True, parents=True)
            sf.write(destination, np.mean(audio, axis=1), rate, subtype="PCM_16")
            duration = min(args.seconds, len(audio) / rate)
            turns = []
            words = []
            for speaker in "ABCD":
                segments = ET.fromstring(archive.read(f"segments/{meeting}.{speaker}.segments.xml"))
                for segment in segments.findall("segment"):
                    start = float(segment.attrib["transcriber_start"])
                    end = float(segment.attrib["transcriber_end"])
                    if start < duration and end > 0:
                        turns.append(
                            {
                                "start": max(0, start),
                                "end": min(duration, end),
                                "speaker": ord(speaker) - ord("A"),
                            }
                        )
                transcript = ET.fromstring(archive.read(f"words/{meeting}.{speaker}.words.xml"))
                for word in transcript.findall("w"):
                    if word.attrib.get("punc") == "true" or not word.text or "starttime" not in word.attrib:
                        continue
                    start = float(word.attrib["starttime"])
                    end = float(word.attrib["endtime"])
                    if 0 <= start < duration:
                        words.append(
                            {
                                "start": start,
                                "end": min(duration, end),
                                "speaker": ord(speaker) - ord("A"),
                                "text": word.text,
                            }
                        )
            metadata = ET.fromstring(archive.read("corpusResources/meetings.xml"))
            session = next(m for m in metadata.iter("meeting") if m.attrib["observation"] == meeting)
            speaker_ids = {
                s.attrib["global_name"]: ord(s.attrib["nxt_agent"]) - ord("A")
                for s in session.findall("speaker")
            }
            manual_segments = turns
            reference_url = f"https://raw.githubusercontent.com/pyannote/AMI-diarization-setup/67c2d539286e89f68952d5dcf83912bd9f01dfae/only_words/rttms/test/{meeting}.rttm"
            with urlopen(reference_url, timeout=30) as response:
                rttm = response.read()
            turns = []
            for line in rttm.decode().splitlines():
                fields = line.split()
                if not fields or fields[0] != "SPEAKER":
                    continue
                start, length = float(fields[3]), float(fields[4])
                label = fields[7].rsplit(".", 1)[-1]
                if start < duration and start + length > 0:
                    turns.append(
                        dict(
                            start=max(0, start),
                            end=min(duration, start + length),
                            speaker=speaker_ids[label],
                        )
                    )
            words.sort(key=lambda w: (w["start"], w["end"], w["speaker"]))
            turns.sort(key=lambda t: (t["start"], t["end"], t["speaker"]))
            items.append(
                {
                    "id": f"ami-{meeting}-{args.seconds}s",
                    "meeting": meeting,
                    "path": str(destination.relative_to(ROOT)),
                    "seconds": duration,
                    "reference": " ".join(w["text"] for w in words),
                    "words": words,
                    "turns": turns,
                    "manual_segments": manual_segments,
                    "rttm_url": reference_url,
                    "rttm_sha256": hashlib.sha256(rttm).hexdigest(),
                    "sha256": hashlib.sha256(destination.read_bytes()).hexdigest(),
                    "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
                }
            )
            print(meeting, duration, len(words), len(turns), flush=True)
    manifest = {
        "source": "AMI Meeting Corpus, manual annotations v1.6.2 and Mix-Headset audio, CC BY 4.0.",
        "upstream": "https://groups.inf.ed.ac.uk/ami/corpus/",
        "mirror": REPO,
        "revision": REVISION,
        "reference_protocol": "AMI-only_words-rttm-v1",
        "diarization_reference": "pyannote/AMI-diarization-setup @ 67c2d539286e89f68952d5dcf83912bd9f01dfae, only_words/test; cite Landini et al., VBx.",
        "annotation_sha256": hashlib.sha256(annotations.read_bytes()).hexdigest(),
        "selection": f"First {args.seconds} seconds of named meetings, preselected before inference; headset mix, not SDM.",
        "limitations": [
            "Four short meeting slices, not the full AMI benchmark.",
            "Diarization reference: pinned pyannote/BUT AMI only_words RTTM, clipped to the same prefix.",
            "Reference words are sorted by start time; overlapping-word order can penalize single-stream WER.",
        ],
        "items": items,
    }
    (ROOT / "fixtures/ami.json").write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    main()
