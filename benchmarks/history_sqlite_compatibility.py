"""Reproduce the secure-delete bug and validate normal-delete trigger maintenance.

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


def seed_sql():
    return "INSERT INTO history(id,created,text,raw,preview,mode,model,app,duration,latency,word_count,payload) VALUES('upgrade-probe',1,'OSpr history format migration probe','OSpr history format migration probe','','verbatim','','',0,0,5,x'7b7d'); DELETE FROM history WHERE id='upgrade-probe';\n"


def format_sql():
    return "SELECT CASE WHEN (SELECT v FROM history_search_config WHERE k='version')>=5 THEN 'seeded-format' ELSE 'wrong-format' END;\n"


LEGACY_COMMIT = "1dc00b49806bc112e4627ec2d6fb724119b6e54f"


def schema(legacy=False):
    if legacy:
        source = subprocess.check_output(["git", "show", f"{LEGACY_COMMIT}:Sources/OSprCore/HistoryDatabase.swift"], cwd=ROOT, text=True)
        return re.search(r"CREATE TABLE history \(.*?PRAGMA user_version=1;", source, re.S).group()
    source = (ROOT / "Sources/OSprCore/HistoryDatabase.swift").read_text()
    tables = re.search(r"CREATE TABLE history \(.*?PRAGMA user_version=2;", source, re.S).group()
    triggers = re.search(r'private static let triggerSQL = """(.*?)"""', source, re.S).group(1)
    return tables + "\n" + triggers + "\nBEGIN IMMEDIATE; " + seed_sql() + "COMMIT;\n" + format_sql()


def fixture(legacy=False):

    def put(identifier, text, raw, words, audio):
        names = "position,id,created,text,raw,preview,mode,model,app,duration,latency,audio,word_count,payload"
        values = ["NULL", repr(identifier), "1", repr(text), repr(raw), repr(text), "'clean'", "'fixture'",
                  "''", "1", "1", repr(audio) if audio else "NULL", str(words), "x'7b7d'"]
        updates = ",".join(f"{key}=excluded.{key}" for key in names.split(",") if key not in ("position", "id"))
        return f"INSERT INTO history({names}) VALUES({','.join(values)}) ON CONFLICT(id) DO UPDATE SET {updates};"

    commands = [".bail on", "PRAGMA trusted_schema=ON;", "PRAGMA secure_delete=ON;", schema(legacy),
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
    for name in ("legacy_special_delete", "current_maintenance", "current_empty_index", "current_full_clear", "legacy_nonempty_upgrade", "legacy_empty_upgrade", "legacy_corrupt_upgrade", "stable_format_after_rollback", "divergent_index"):
        sql = fixture(legacy=name.startswith("legacy"))
        if name in ("current_empty_index", "legacy_empty_upgrade"):
            sql += "DELETE FROM history;\n"
        if name == "current_full_clear":
            trigger = re.search(r"CREATE TRIGGER history_delete .*?END;", schema(), re.S).group()
            search = re.search(r"CREATE VIRTUAL TABLE history_search .*?;", schema(), re.S).group()
            sql += "BEGIN IMMEDIATE; DROP TRIGGER history_delete; DELETE FROM history; DROP TABLE history_search;\n"
            sql += search + "\nINSERT INTO history_search(history_search,rank) VALUES('secure-delete',1); UPDATE history_stats SET records=0,words=0;\n"
            sql += trigger + seed_sql() + "COMMIT;\n" + format_sql()
        if name == "legacy_corrupt_upgrade":
            sql += "DELETE FROM history_search;\n"
        if name in ("legacy_nonempty_upgrade", "legacy_empty_upgrade", "legacy_corrupt_upgrade"):
            triggers = re.search(r'private static let triggerSQL = """(.*?)"""', (ROOT / "Sources/OSprCore/HistoryDatabase.swift").read_text(), re.S).group(1)
            sql += "BEGIN IMMEDIATE; DROP TRIGGER history_insert; DROP TRIGGER history_delete; DROP TRIGGER history_update;\n" + triggers
            sql += seed_sql()
        if name == "stable_format_after_rollback":
            sql += "BEGIN IMMEDIATE; UPDATE history SET text='uncommitted text' WHERE id='recent'; ROLLBACK; UPDATE history SET text='committed text' WHERE id='recent'; SELECT CASE WHEN (SELECT v FROM history_search_config WHERE k='version')>=5 THEN 'stable-format' ELSE 'wrong-format' END;\n"
        if name == "divergent_index":
            sql += "DELETE FROM history_search;\n"
        sql += "PRAGMA quick_check;\nINSERT INTO history_search(history_search,rank) VALUES('integrity-check',1);\n"
        if name in ("legacy_nonempty_upgrade", "legacy_empty_upgrade", "legacy_corrupt_upgrade"):
            sql += "PRAGMA user_version=2; COMMIT;\n" + format_sql()
        result = subprocess.run([str(shell), "-batch", ":memory:"], input=sql, capture_output=True, text=True, timeout=30)
        success = result.returncode == 0 and "ok" in result.stdout.splitlines()
        if name not in ("legacy_special_delete", "legacy_corrupt_upgrade"):
            assert "seeded-format" in result.stdout and "wrong-format" not in result.stdout, (version, name, result.stdout, result.stderr)
        if name == "stable_format_after_rollback":
            assert "stable-format" in result.stdout and "wrong-format" not in result.stdout
        if name == "legacy_special_delete":
            assert success == (number >= 3_046_001), (version, name, result.stdout, result.stderr)
        elif name not in ("divergent_index", "legacy_corrupt_upgrade"):
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
                          legacy_schema_commit=LEGACY_COMMIT,
                          schema_and_fixture_sha256=hashlib.sha256(fixture().encode()).hexdigest(), runtimes=cases), indent=2))


if __name__ == "__main__":
    main()
