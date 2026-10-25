"""Recheck retained native exports; no app, microphone, provider or ASR calls."""

import argparse
import hashlib
import json
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def subtitle_body(text):
    lines = [line.strip() for line in text.splitlines()]
    return " ".join(line for line in lines if line and line != "WEBVTT" and not line.isdigit() and " --> " not in line)


def verify(receipt):
    assert receipt["status"] == "passed-scoped-native-file-import-and-export"
    assert digest(receipt["mixed_batch"]["invalid_fixture_utf8"].encode()) == receipt["mixed_batch"]["initial_inputs_sha256"]["02-invalid.wav"]
    exports = {item["phase"]: item for item in [*receipt["exports"], *receipt["filtered_exports"], receipt["final_gui"]["export"]]}
    assert set(exports) == {"before_retry", "after_retry", "edited_txt", "edited_json", "edited_srt", "edited_vtt", "filtered", "empty", "final_gui_json"}
    decoded = {}
    for phase, observed in exports.items():
        assert digest(observed["manifest_utf8"].encode()) == observed["manifest_sha256"]
        manifest = json.loads(observed["manifest_utf8"])
        assert manifest["count"] == len(manifest["records"]) == len(observed["files"])
        expected_query = {"filtered": "Quilter", "empty": "unmatched-native-control-2026"}.get(phase, "")
        assert manifest["query"] == expected_query and manifest["audio_included"] is False
        assert observed["directory_mode"] == 0o700 and observed["index_mode"] == 0o600
        files = {entry["name"]: entry for entry in observed["files"]}
        assert len(files) == len(observed["files"])
        assert {row["file"] for row in manifest["records"]} == set(files)
        records = {}
        for entry in manifest["records"]:
            name = entry["file"]
            assert Path(name).name == name and "/" not in name and "\\" not in name
            assert name.endswith("." + manifest["format"])
            file = files[name]
            assert file["mode"] == 0o600 and digest(file["utf8"].encode()) == file["sha256"]
            assert entry["id"] not in records
            if manifest["format"] == "json":
                record = json.loads(file["utf8"])
                assert record["id"] == entry["id"] and record["source"] == entry["source"]
                assert record["model"] == "whisper-small" and record["mode"] == "verbatim"
                records[entry["id"]] = record
            else:
                records[entry["id"]] = file["utf8"]
        decoded[phase] = records
    before, after = decoded["before_retry"], decoded["after_retry"]
    assert len(before) == 2 and len(after) == 3 and set(before) < set(after)
    assert all(after[key] == value for key, value in before.items())
    added = (set(after) - set(before)).pop()
    assert after[added]["source"] == "02-invalid.wav"
    edited = decoded["edited_json"]
    assert set(edited) == set(after)
    assert edited[added]["text"] == after[added]["text"] + receipt["edit_suffix"]
    assert edited[added]["rawText"] == after[added]["rawText"]
    for key, record in edited.items():
        assert set(decoded["edited_txt"]) == set(after)
        assert decoded["edited_txt"][key] == record["text"]
        for phase in ["edited_srt", "edited_vtt"]:
            assert set(decoded[phase]) == set(after)
            assert " ".join(subtitle_body(decoded[phase][key]).split()) == " ".join(record["rawText"].split())
    individual = receipt["individual_txt"]
    assert individual["name"] == "02-invalid-" + added.lower() + ".txt"
    assert digest(individual["utf8"].encode()) == individual["sha256"]
    assert individual["utf8"] == edited[added]["text"]
    expected_filtered = {key: row for key, row in edited.items() if row["source"] != "03-three.wav"}
    assert len(expected_filtered) == 2 and decoded["filtered"] == expected_filtered
    assert decoded["empty"] == {}
    assert len(decoded["final_gui_json"]) == 2
    assert {row["source"] for row in decoded["final_gui_json"].values()} == {"01-stew.wav", "02-invalid.wav"}
    assert receipt["final_gui"]["application_source_sha256"] == receipt["final_source_sha256"]
    for asset in [receipt["native_screenshot"], receipt["final_gui"]["screenshot"], *receipt["final_layouts"]]:
        path = (ROOT / asset["path"]).resolve()
        assert path.is_relative_to(ROOT) and digest(path.read_bytes()) == asset["sha256"]
    assert receipt["normal_app"]["baseline_hashes_unchanged"] == 5
    return {"status": "passed-retained-native-export-checks", "complete_directories": 9,
            "before_retry": 2, "after_retry": 3, "native_formats": ["txt", "json", "srt", "vtt"],
            "native_filtered_records": 2, "native_empty_records": 0, "final_gui_records": 2,
            "boundary": "Stored output/layout integrity; native source and pending acceptance remain separately scoped."}


def verify_native_source(receipt):
    ref = receipt["native_source_equivalent_commit"]
    assert re.fullmatch(r"[0-9a-f]{40}", ref)
    paths = subprocess.check_output(["git", "ls-tree", "-r", "--name-only", ref, "Sources", "backend/ospr_backend"], cwd=ROOT, text=True).splitlines()
    paths = sorted(p for p in paths if p.startswith("Sources/") and p.endswith(".swift")) + sorted(
        p for p in paths if p.startswith("backend/") and Path(p).suffix in {".py", ".json", ".npy"})
    fingerprint = hashlib.sha256()
    for path in paths:
        raw = subprocess.check_output(["git", "show", ref + ":" + path], cwd=ROOT)
        fingerprint.update(path.encode())
        fingerprint.update(raw)
        if path in receipt["implementation_file_sha256"]:
            assert digest(raw) == receipt["implementation_file_sha256"][path]
    assert fingerprint.hexdigest() == receipt["native_application_source_sha256"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--native-source", action="store_true", help="Also verify the historical Git source object; requires that commit locally")
    args = parser.parse_args()
    receipt = json.loads((ROOT / "benchmarks/results/file-import-native.json").read_text())
    result = verify(receipt)
    if args.native_source:
        verify_native_source(receipt)
        result["historical_native_source_verified"] = True
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
