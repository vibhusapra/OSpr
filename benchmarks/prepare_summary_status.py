"""Freeze full public AMI scenario meetings plus existing status development cases.

Gold summaries are evaluation metadata only, never model input. Every annotated
word, including punctuation, must occur in exactly one serialized speaker turn.
No audio, speech recognition, private meeting or provider account is used.
"""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import xml.etree.ElementTree as ET
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parents[1]
ARCHIVE_SHA256 = "56e29112cd89cfba76fbf8f10215eb245cc89b0d3d27355ba14b406a7ea7776c"
REVISION = "722d8891643e1e4dc62cfd0d198fa05a1646c3cc"
MEETINGS = ("ES2004c", "ES2004d")
NITE = "{http://nite.sourceforge.net/}"
ROLES = {"PM": "Project Manager", "ME": "Marketing Expert", "ID": "Industrial Designer", "UI": "User Interface Designer"}


def meeting_case(archive, meeting):
    metadata = ET.fromstring(archive.read("corpusResources/meetings.xml"))
    session = next(m for m in metadata.iter("meeting") if m.attrib["observation"] == meeting)
    roles = {s.attrib["nxt_agent"]: s.attrib["role"] for s in session.findall("speaker")}
    turns, expected, observed, member_hashes = [], [], [], {}

    def member(name):
        data = archive.read(name)
        member_hashes[name] = hashlib.sha256(data).hexdigest()
        return ET.fromstring(data)

    for speaker in sorted(roles):
        entries = list(member(f"words/{meeting}.{speaker}.words.xml"))
        index = {r.attrib[NITE + "id"]: i for i, r in enumerate(entries)}
        assert len(index) == len(entries), "Duplicate word annotation ID"
        expected.extend(r.attrib[NITE + "id"] for r in entries if r.tag == "w" and r.text)
        for segment in member(f"segments/{meeting}.{speaker}.segments.xml").findall("segment"):
            words, ids = [], []
            for child in segment.findall(NITE + "child"):
                href = child.attrib["href"]
                match = re.fullmatch(re.escape(f"{meeting}.{speaker}.words.xml") + r"#id\(([^)]+)\)(?:\.\.id\(([^)]+)\))?", href)
                if not match:
                    raise ValueError("Unexpected annotation word range")
                begin, end = index[match[1]], index[match[2] or match[1]]
                if end < begin:
                    raise ValueError("Reversed annotation word range")
                for row in entries[begin:end + 1]:
                    if row.tag == "w" and row.text:
                        words.append(row.text)
                        ids.append(row.attrib[NITE + "id"])
            if words:
                observed.extend(ids)
                turns.append(dict(start=float(segment.attrib["transcriber_start"]), speaker=speaker,
                                  text="[" + ROLES.get(roles[speaker], roles[speaker]) + "] " + " ".join(words),
                                  word_ids=ids))
    if Counter(expected) != Counter(observed) or any(count != 1 for count in Counter(observed).values()):
        raise ValueError("Every annotated word must appear exactly once; no omitted or repeated turns")
    turns.sort(key=lambda row: (row["start"], row["speaker"]))
    text = "\n".join(row["text"] for row in turns)
    if not text or len(text) > 100000:
        raise ValueError("Full meeting exceeds the supported input budget")
    gold = member(f"abstractive/{meeting}.abssumm.xml")
    references = {section.tag: ["".join(s.itertext()).strip() for s in section.findall("sentence")] for section in gold}
    return dict(id="full-ami-" + meeting, kind="public-AMI-full-scenario-meeting", text=text,
                required_source_phrases=[], reference_summary=references,
                reference_expectations=["Review final choices, conditions, contradictions and ownership against the human reference and full transcript; gold may omit details."],
                provenance=dict(meeting=meeting, meeting_type=session.attrib["type"], duration_seconds=float(session.attrib["duration"]),
                                upstream="https://groups.inf.ed.ac.uk/ami/corpus/", license="CC BY 4.0",
                                archive_sha256=ARCHIVE_SHA256, mirror_revision=REVISION, member_sha256=member_hashes,
                                annotated_word_tokens=len(expected), serialized_turns=len(turns),
                                exact_once_word_coverage=True, text_sha256=hashlib.sha256(text.encode()).hexdigest(),
                                serialization="Manual segment order by start then speaker; exact word tokens joined with spaces, punctuation included; speaker roles from corpus metadata; no audio or ASR."))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--allow-download", action="store_true")
    args = parser.parse_args()
    if args.output.exists():
        parser.error("Choose a new protocol path; previous cohorts are immutable")
    from huggingface_hub import hf_hub_download
    source = Path(hf_hub_download("FluidInference/ami-corpus-mirror", "annotations/ami_public_manual_1.6.2.zip",
                                repo_type="dataset", revision=REVISION, local_files_only=not args.allow_download))
    if hashlib.sha256(source.read_bytes()).hexdigest() != ARCHIVE_SHA256:
        raise ValueError("Pinned annotation archive hash differs")
    previous = json.loads((ROOT / "benchmarks/fixtures/summary-fidelity-protocol.json").read_text())
    with ZipFile(source) as archive:
        cases = previous["cases"] + [meeting_case(archive, meeting) for meeting in MEETINGS]
    result = dict(version=1, status="development-cohort-not-sealed-or-independent-semantic-evaluation",
                  models=[row for row in previous["models"] if not row.get("research_only")], cases=cases,
                  boundary="Twenty preselected development cases: eighteen reused adversarial controls plus two complete public AMI scenario meetings. Human abstractive summaries are review metadata, never model input. Corpus words/roles are manually annotated; no ASR, microphone, native UI or consumer benchmark. Authored and human-reference review does not prove general entailment/completeness. Shared Mac timing is diagnostic; no latency/energy ranking.")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("x") as out:
        out.write(json.dumps(result, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps(dict(cases=len(cases), full_meetings=[dict(id=r["id"], characters=len(r["text"]), words=r["provenance"]["annotated_word_tokens"]) for r in cases[-2:]])))


if __name__ == "__main__":
    main()
