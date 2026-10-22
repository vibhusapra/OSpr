"""Reproduce the secure-delete integrity bug and check the legacy merge fix.

Runs only owned in-memory synthetic SQL through explicitly supplied SQLite
shells. This is a version compatibility control, not a storage/app benchmark.
The schema and FTS triggers are extracted from the actual Swift source.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def fixture():
    source = (ROOT / "Sources/OSprCore/HistoryDatabase.swift").read_text()
    schema = re.search(r"CREATE TABLE history \(.*?PRAGMA user_version=1;", source, re.S).group()

    def put(identifier, text, raw, words, audio):
        names = "position,id,created,text,raw,preview,mode,model,app,duration,latency,audio,word_count,payload"
        values = ["NULL", repr(identifier), "1", repr(text), repr(raw), repr(text), "'clean'", "'fixture'",
                  "''", "1", "1", repr(audio) if audio else "NULL", str(words), "x'7b7d'"]
        updates = ",".join(f"{key}=excluded.{key}" for key in names.split(",") if key not in ("position", "id"))
        return f"INSERT INTO history({names}) VALUES({','.join(values)}) ON CONFLICT(id) DO UPDATE SET {updates};"

    commands = [".bail on", "PRAGMA trusted_schema=ON;", "PRAGMA secure_delete=ON;", schema,
                "BEGIN IMMEDIATE;", put("expired", "expired sentinel", "expired sentinel", 2, "old.wav"),
                put("boundary", "boundary keep", "boundary keep", 2, "boundary.wav"),
                put("recent", "new version", "new version", 2, "recent.wav"), "COMMIT;",
                "BEGIN IMMEDIATE; DELETE FROM history WHERE id='expired'; COMMIT;", "BEGIN IMMEDIATE;",
                put("recent", "edited five words right here", "new version", 5, "recent.wav"), "COMMIT;",
                "BEGIN IMMEDIATE;", put("recent", "edited five words right here", "new version", 5, None),
                "COMMIT;", "BEGIN IMMEDIATE; DELETE FROM history WHERE id='boundary'; COMMIT;"]
    return "\n".join(commands) + "\n"


def run(shell):
    version = subprocess.check_output([str(shell), "--version"], text=True, timeout=10).strip()
    parts = version.split()[0].split(".")
    number = int(parts[0]) * 1_000_000 + int(parts[1]) * 1_000 + int(parts[2])
    assert number >= 3_042_000, version
    cases = []
    for name in ("unmerged_baseline", "legacy_merge_fix", "divergent_index"):
        sql = fixture()
        if name == "divergent_index":
            sql += "INSERT INTO history_search(history_search,rowid,text,raw) SELECT 'delete',position,text,raw FROM history;\n"
        if name != "unmerged_baseline" and number < 3_046_001:
            sql += "INSERT INTO history_search(history_search) VALUES('optimize');\n"
        sql += "PRAGMA quick_check;\nINSERT INTO history_search(history_search,rank) VALUES('integrity-check',1);\n"
        result = subprocess.run([str(shell), "-batch", ":memory:"], input=sql, capture_output=True, text=True, timeout=30)
        success = result.returncode == 0 and result.stdout.splitlines()[-1] == "ok"
        if name == "unmerged_baseline":
            assert success == (number >= 3_046_001), (version, name, result.stdout, result.stderr)
        elif name == "legacy_merge_fix":
            assert success, (version, name, result.stdout, result.stderr)
        else:
            assert not success and "malformed" in result.stderr, (version, name, result.stdout, result.stderr)
        cases.append(dict(case=name, sql_sha256=hashlib.sha256(sql.encode()).hexdigest(),
                          exit_code=result.returncode, stdout=result.stdout.strip(), stderr=result.stderr.strip(),
                          integrity_passed=success))
    return dict(version=version, shell_sha256=digest(shell), cases=cases)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--shell", action="append", required=True, type=Path)
    args = parser.parse_args()
    cases = [run(path.resolve()) for path in args.shell]
    print(json.dumps(dict(status="passed", boundary="Synthetic in-memory C API/shell compatibility; not native Swift integration or performance.",
                          source_files_sha256={path: digest(ROOT / path) for path in (
                              "Sources/OSprCore/HistoryDatabase.swift", "benchmarks/history_sqlite_compatibility.py")},
                          fix_reference="https://www.sqlite.org/releaselog/3_46_1.html",
                          schema_and_fixture_sha256=hashlib.sha256(fixture().encode()).hexdigest(), runtimes=cases), indent=2))


if __name__ == "__main__":
    main()
