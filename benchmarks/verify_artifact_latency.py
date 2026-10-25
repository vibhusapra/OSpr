"""Independently recheck retained counterbalanced records without inference.

Checks actual case files against the aggregate, chronology, source/protocol/runner
hashes and raw-response scores. --frozen-commit additionally checks pre-inference
Git blobs when full history is available. No app launch, models or UI.
"""
import argparse
import datetime
import json
from pathlib import Path
import subprocess

from artifact_latency import ROOT, sha, verify_result


def verify_records(protocol, result):
    summary = verify_result(protocol, result)
    stamps = [datetime.datetime.fromisoformat(row["timestamp"]) for row in result["records"]]
    assert all(a < b for a, b in zip(stamps, stamps[1:], strict=False)), "Frozen case order differs from observed chronology"
    for row in result["records"]:
        assert row["observations"] and all("timestamp" in sample for sample in row["observations"])
        if row["status"] == "invalid-response":
            assert row["payload_error"] and len(row["stdout_sha256"]) == 64
    return summary


def verify(protocol_path, receipt_path, frozen_commit=None):
    protocol, result = json.loads(protocol_path.read_text()), json.loads(receipt_path.read_text())
    assert result["protocol_sha256"] == sha(protocol_path)
    assert result["harness_sha256"] == sha(ROOT / "benchmarks/artifact_latency.py")
    assert protocol["scorer_source_sha256"] == sha(ROOT / "benchmarks/run.py")
    assert protocol["lock_sha256"] == sha(ROOT / "uv.lock")
    directory = receipt_path.with_suffix("")
    expected_names = {row["id"] + ".json" for row in protocol["cases"]}
    assert {path.name for path in directory.glob("*.json")} == expected_names, "Missing or additional terminal case"
    assert [json.loads((directory / (row["id"] + ".json")).read_text()) for row in protocol["cases"]] == result["records"]
    summary = verify_records(protocol, result)
    if frozen_commit:
        for path in (protocol_path, ROOT / "benchmarks/artifact_latency.py"):
            original = subprocess.check_output(["git", "show", f"{frozen_commit}:{path.resolve().relative_to(ROOT)}"])
            assert original == path.read_bytes(), "Protocol or runner changed after the frozen commit"
    return dict(status="passed-retained-artifact-timing-integrity", **summary,
                chronological_frozen_order=True, individual_cases_match_aggregate=True,
                protocol_sha256=sha(protocol_path), receipt_sha256=sha(receipt_path),
                verifier_sha256=sha(Path(__file__)), frozen_git_commit=frozen_commit,
                boundary="Stored artifact/response/score/order/denominator integrity. Does not prove isolated speed, energy, causality, product ranking or native dictation acceptance.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--protocol", type=Path, default=ROOT / "benchmarks/fixtures/artifact-latency-protocol.json")
    parser.add_argument("--receipt", type=Path, default=ROOT / "benchmarks/results/artifact-latency-control.json")
    parser.add_argument("--frozen-commit", help="Optional pre-inference Git commit; requires local history")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    value = verify(args.protocol, args.receipt, args.frozen_commit)
    if args.output:
        with args.output.open("x") as output:
            json.dump(value, output, indent=2)
            output.write("\n")
    print(json.dumps(value))


if __name__ == "__main__":
    main()
