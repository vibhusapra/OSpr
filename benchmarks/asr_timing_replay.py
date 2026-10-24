"""Replay frozen real recognizer timing failures through the source boundary fix.

No ASR is rerun here. Text/word payload preservation and every repaired interval
are checked against the original selected waveform bounds.
"""
import argparse
import copy
import datetime
import gzip
import hashlib
import json
from pathlib import Path
import subprocess

from ospr_backend.timing import bound_timings

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--result", type=Path, default=ROOT / "benchmarks/results/neural-edges-multilingual-v1.json")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    assert not args.output.exists()
    assert not subprocess.check_output(["git", "diff", "--name-only", "HEAD"], cwd=ROOT)
    source = json.loads(args.result.read_text())
    archive = args.result.with_name(source["traces_file"])
    archive_sha = sha(archive)
    assert archive_sha == source["traces_sha256"]
    records = json.loads(gzip.decompress(archive.read_bytes()))["records"]
    changes, examined, abstentions = [], 0, 0
    for row in records:
        for route in ["full", "neural_edges"]:
            original = row[route]
            before = copy.deepcopy(original)
            if original["silence"]:
                abstentions += 1
                continue
            if route == "neural_edges":
                edge = original["speech_edges"]
                start, end = edge["start_sample"] / 16000, edge["end_sample"] / 16000
            else:
                start, end = 0, original["audio_seconds"]
            fixed = bound_timings(original["segments"], original.get("words", []), start=start, end=end,
                                  text=original["text"], granularity=original["timestamp_granularity"])
            assert original == before  # Raw evidence remains unchanged.
            for key in ["segments", "words"]:
                for interval in fixed[key]:
                    assert start <= interval["start"] <= interval["end"] <= end
                if not fixed.get("timing_corrections", {}).get("fallback_to_utterance"):
                    assert [item["text"] for item in fixed[key]] == [item["text"] for item in original.get(key, [])]
                    for old, new in zip(original.get(key, []), fixed[key], strict=True):
                        assert {k:v for k,v in old.items() if k not in {"start", "end"}} == {k:v for k,v in new.items() if k not in {"start", "end"}}
            examined += 1
            if "timing_corrections" in fixed:
                changes.append(dict(model=row["model"], id=row["id"], route=route, analyzed_start=start, analyzed_end=end,
                                    original_segments=original["segments"], fixed=fixed, text=original["text"]))
    assert examined == source["actual_asr"] == 1010 and abstentions == source["abstentions"] == 30
    assert len(changes) == 12
    german = next(row for row in changes if row["model"] == "whisper-turbo" and row["id"] == "fleurs-de_de-000-quiet40db")
    assert german["original_segments"][0]["end"] == 34.588 and german["fixed"]["segments"][0]["end"] == 5.408
    assert sha(archive) == archive_sha
    receipt = dict(status="passed-stored-real-timing-replay", timestamp=datetime.datetime.now(datetime.UTC).isoformat(),
        git_commit=subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(), tracked_changes=False,
        source_result_sha256=sha(args.result), source_traces_sha256=archive_sha,
        timing_source_sha256=sha(ROOT / "backend/ospr_backend/timing.py"), harness_sha256=sha(Path(__file__)),
        actual_model_responses_checked=examined, abstentions_skipped=abstentions, corrected_responses=len(changes),
        all_returned_intervals_in_analyzed_range=True, unchanged_text_and_untimed_payload=True, changes=changes,
        boundary=__doc__.strip() + " This is a replay of frozen model outputs, not new inference, improved recognition quality, manual alignment validation or native UI acceptance. The original multilingual study remains unchanged.")
    args.output.write_text(json.dumps(receipt, indent=2, ensure_ascii=False) + "\n")
    print(f"Passed: {examined} real stored responses, {len(changes)} corrected, {abstentions} abstentions skipped")


if __name__ == "__main__":
    main()
