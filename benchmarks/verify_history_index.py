"""Independently verify synthetic history results, provenance and percentiles.

Checks the known fixture's actual expected IDs/counts, not just agreement between
two implementations. NumPy supplies an independent percentile implementation.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import subprocess
import uuid

import numpy as np

ROOT = Path(__file__).resolve().parents[1]


def same(actual, expected):
    assert math.isfinite(actual) and math.isclose(actual, expected, rel_tol=1e-10, abs_tol=1e-8), (actual, expected)


def verify(path, binary=None):
    result = json.loads(path.read_text())
    count, repeats = result["rows"], result["repeats"]
    assert result["status"] == "passed" and 1 <= count <= 100_000 and 1 <= repeats <= 10
    assert result["debug_build"] is False and result["source_changes_at_run"] is False
    commit = result["git_base_commit"]
    assert re.fullmatch(r"[0-9a-f]{40}", commit)
    for name, expected in result["source_files_sha256"].items():
        assert (name.startswith("Sources/") or name == "Package.swift") and ".." not in Path(name).parts
        source = subprocess.check_output(["git", "show", f"{commit}:{name}"], cwd=ROOT)
        assert hashlib.sha256(source).hexdigest() == expected, name
    if binary:
        assert hashlib.sha256(binary.read_bytes()).hexdigest() == result["cli_sha256"]
    fixture = result["fixture"]
    assert fixture["rows"] == count and fixture["bytes"] > 0
    assert re.fullmatch(r"[0-9a-f]{64}", fixture["sha256"])
    common = [str(uuid.UUID(int=index + 1)).upper() for index in range(count - 1, max(-1, count - 101), -1)]
    expected_matches = {query: common for query in ("API", "C++", "do not", "example/notes", "日本語", "Ω")}
    expected_matches[f"needle-{count // 2:07d}"] = [str(uuid.UUID(int=count // 2 + 1)).upper()]
    expected_matches["not-present-anywhere-49018"] = []
    migration = result["migration"]
    assert migration["mode"] == "migration" and migration["records"] == count
    assert migration["words"] == count * fixture["text_words_per_record"]
    assert migration["database_bytes"] > 0 and migration["peak_rss_bytes"] > 0
    assert math.isfinite(migration["initial_data_ms"]) and migration["initial_data_ms"] > 0
    assert re.fullmatch(r"[0-9a-f]{64}", migration["first_record_sha256"])
    records = result["records"]
    assert len(records) == 2 * repeats
    for mode in ("legacy", "indexed"):
        rows = [row for row in records if row["mode"] == mode]
        assert {row["repeat"] for row in rows} == set(range(repeats)) and len(rows) == repeats
        for row in rows:
            assert row["matches"] == expected_matches and row["records"] == count
            assert row["words"] == migration["words"]
            assert row["first_record_sha256"] == migration["first_record_sha256"]
            assert row["peak_rss_bytes"] > 0 and row["initial_data_ms"] > 0
            assert row["database_bytes"] == (migration["database_bytes"] if mode == "indexed" else 0)
            assert set(row["query_ms"]) == set(expected_matches)
            assert all(math.isfinite(time) and time >= 0 for time in row["query_ms"].values())
        summary = result["summary"][mode]
        assert summary["trials"] == repeats and set(summary["queries"]) == set(expected_matches)
        for name, percentile in (("p50", 50), ("p95", 95)):
            same(summary[f"initial_data_{name}_ms"], np.percentile([row["initial_data_ms"] for row in rows], percentile))
            for query in expected_matches:
                same(summary["queries"][query][f"{name}_ms"], np.percentile([row["query_ms"][query] for row in rows], percentile))
        same(summary["peak_rss_p50_bytes"], np.median([row["peak_rss_bytes"] for row in rows]))
    assert result["all_query_ids_and_first_detail_equal"] is True
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("receipt", type=Path)
    parser.add_argument("--cli", type=Path)
    parser.add_argument("--baseline", type=Path)
    args = parser.parse_args()
    result = verify(args.receipt, args.cli)
    if args.baseline:
        baseline = verify(args.baseline)
        assert result["fixture"] == baseline["fixture"]
    print(json.dumps(dict(status="passed", rows=result["rows"], trials=len(result["records"]),
                         verified="Expected fixture IDs/counts, detail agreement, Git source hashes, optional CLI hash and all independent NumPy percentiles.")))


if __name__ == "__main__":
    main()
