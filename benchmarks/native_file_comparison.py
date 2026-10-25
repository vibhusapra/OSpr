"""Score retained native exports; never launch apps or replace missing cases."""

import argparse
import hashlib
import json
from pathlib import Path

import jiwer

try:
    from benchmarks.run import normalize
except ModuleNotFoundError:
    from run import normalize

ROOT = Path(__file__).resolve().parent
PROTOCOL = ROOT / "fixtures/native-file-comparison.json"
OBSERVATIONS = ROOT / "fixtures/native-file-observations.json"


def validate_exports(rows, *, ospr):
    for row in rows:
        raw = row["raw_export_utf8"]
        if hashlib.sha256(raw.encode()).hexdigest() != row["raw_export_sha256"]:
            raise ValueError("Native export digest differs")
        if ospr:
            record = json.loads(raw)
            if (record["source"] != row["source"] or record["text"] != row["text"]
                    or record["rawText"] != row["text"] or record["model"] != "whisper-small"
                    or record["mode"] != "verbatim"):
                raise ValueError("OSpr export differs from the frozen verbatim configuration")
        elif raw != row["text"]:
            raise ValueError("Plain native export differs from hypothesis")


def score(protocol, observations, protocol_sha256):
    if observations["protocol_sha256"] != protocol_sha256:
        raise ValueError("Observation protocol hash differs")
    items = protocol["items"]
    expected = {item["staged_name"]: item for item in items}
    if len(items) != 20 or len(expected) != 20:
        raise ValueError("Expected twenty unique frozen cases")
    results = {}
    for route, observed in observations["completed_routes"].items():
        rows = observed["records"]
        sources = [row["source"] for row in rows]
        if len(rows) != 20 or len(set(sources)) != 20 or set(sources) != set(expected):
            raise ValueError(f"{route}: incomplete, duplicate or foreign cohort")
        if any(not isinstance(row["text"], str) for row in rows):
            raise ValueError(f"{route}: missing text; empty string is a retained hypothesis")
        validate_exports(rows, ospr=route == "ospr-small-repeat")
        indexed = {row["source"]: row for row in rows}
        scored = []
        for item in items:
            row = indexed[item["staged_name"]]
            words = jiwer.process_words(normalize(item["reference"]), normalize(row["text"]))
            scored.append({
                "id": item["id"], "suite": item["suite"], "source": item["staged_name"],
                "reference": item["reference"], "text": row["text"],
                "reference_words": words.hits + words.substitutions + words.deletions,
                "substitutions": words.substitutions, "deletions": words.deletions,
                "insertions": words.insertions, "wer": words.wer,
            })
        summary = {}
        for suite in ["all", "test-clean", "test-other"]:
            subset = [r for r in scored if suite == "all" or r["suite"] == suite]
            counts = {key: sum(r[key] for r in subset) for key in [
                "reference_words", "substitutions", "deletions", "insertions"
            ]}
            summary[suite] = {
                "cases": len(subset), **counts,
                "word_errors": sum(counts[k] for k in ["substitutions", "deletions", "insertions"]),
            }
            summary[suite]["wer"] = summary[suite]["word_errors"] / counts["reference_words"]
        results[route] = {"summary": summary, "records": scored}
    if set(results) != {"macwhisper-small", "ospr-small-repeat"}:
        raise ValueError("Both fixed completed routes required")
    interrupted = observations["interrupted_attempt"]
    interrupted_sources = [r["source"] for r in interrupted["records"]]
    if len(interrupted_sources) != len(set(interrupted_sources)) or not set(interrupted_sources) < set(expected):
        raise ValueError("Interrupted attempt must retain its unique strict subset")
    validate_exports(interrupted["records"], ospr=True)
    # Deliberately no WER for the interrupted subset, no inferred missing outputs,
    # and no aggregation of incompatible consumer-reported timing boundaries.
    return {
        "schema_version": 1, "status": "complete-twenty-case-native-file-pilot",
        "protocol_sha256": protocol_sha256,
        "normalization": "benchmarks.run.normalize; corpus micro WER; no numeral expansion",
        "completed_routes": results,
        "interrupted_exports": len(interrupted_sources),
        "interrupted_missing_sources": sorted(set(expected) - set(interrupted_sources)),
        "limitations": observations["limitations"],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--verify", type=Path, help="Require exact equality with a retained score")
    args = parser.parse_args()
    result = score(json.loads(PROTOCOL.read_text()), json.loads(OBSERVATIONS.read_text()),
                   hashlib.sha256(PROTOCOL.read_bytes()).hexdigest())
    result["observations_sha256"] = hashlib.sha256(OBSERVATIONS.read_bytes()).hexdigest()
    if args.verify and json.loads(args.verify.read_text()) != result:
        raise SystemExit("Retained native comparison score differs")
    if args.output:
        args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({key: value["summary"] for key, value in result["completed_routes"].items()}, indent=2))


if __name__ == "__main__":
    main()
