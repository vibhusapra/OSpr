"""Check a session transition receipt, provenance and the shared known fixture."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import subprocess

from verify_history_index import verify as verify_index

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("receipt", type=Path)
    parser.add_argument("--cli", type=Path)
    parser.add_argument("--baseline", type=Path)
    args = parser.parse_args()
    result = json.loads(args.receipt.read_text())
    count, fixture = result["rows"], result["fixture"]
    assert result["status"] == "passed" and 1 <= count <= 100_000
    assert result["debug_build"] is False and result["source_changes_at_run"] is False
    commit = result["git_base_commit"]
    assert re.fullmatch(r"[0-9a-f]{40}", commit)
    hashes = result["source_files_sha256"]
    assert {"Package.swift", "Sources/OSprCore/HistoryDatabase.swift", "Sources/OSprCore/HistoryRepository.swift",
            "Sources/OSprCLI/HistorySessionBenchmark.swift", "Sources/OSprCLI/HistoryIndexBenchmark.swift"} <= set(hashes)
    for name, expected in hashes.items():
        assert (name.startswith("Sources/") or name == "Package.swift") and ".." not in Path(name).parts
        source = subprocess.check_output(["git", "show", f"{commit}:{name}"], cwd=ROOT)
        assert hashlib.sha256(source).hexdigest() == expected, name
    if args.cli:
        assert hashlib.sha256(args.cli.read_bytes()).hexdigest() == result["cli_sha256"]
    transition, migration = result["transition"], result["migration"]
    assert fixture["rows"] == count and transition["records"] == count and migration["records"] == count
    assert transition["words"] == migration["words"] == count * fixture["text_words_per_record"]
    for key in ("initial_payloads_sha256", "session_payloads_sha256", "restored_payloads_sha256", "first_detail_sha256"):
        assert re.fullmatch(r"[0-9a-f]{64}", transition[key])
    assert transition["initial_payloads_sha256"] == transition["session_payloads_sha256"] == transition["restored_payloads_sha256"]
    assert transition["first_detail_sha256"] == migration["first_record_sha256"]
    assert transition["all_payloads_and_counts_equal"] is True and transition["disk_content_and_search_empty_while_off"] is True
    assert transition["original_database_bytes"] == migration["database_bytes"]
    assert 0 < transition["cleared_database_bytes"] <= transition["original_database_bytes"]
    assert transition["restored_database_bytes"] > transition["cleared_database_bytes"] or count < 10
    assert transition["peak_rss_bytes"] > 0
    for key in ("disable_flush_ms", "enable_flush_ms"):
        assert math.isfinite(transition[key]) and transition[key] > 0
    if args.baseline:
        baseline = verify_index(args.baseline)
        assert fixture == baseline["fixture"]
        assert transition["first_detail_sha256"] == baseline["migration"]["first_record_sha256"]
    print(json.dumps(dict(status="passed", rows=count, verified="Git/optional executable provenance, known fixture/counts, every-payload round-trip hashes, selected detail and disk-clear receipt; one exploratory round trip.")))


if __name__ == "__main__":
    main()
