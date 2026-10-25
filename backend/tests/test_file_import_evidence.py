"""Retained native evidence must not silently lose an output or original source."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("verify_file_import", ROOT / "benchmarks/verify_file_import.py")
checks = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(checks)
RECEIPT = json.loads((ROOT / "benchmarks/results/file-import-native.json").read_text())


@pytest.mark.parametrize("fault", ["digest", "format", "partial", "raw_source", "path"])
def test_changed_native_evidence_is_rejected(fault):
    receipt = copy.deepcopy(RECEIPT)
    exports = {item["phase"]: item for item in receipt["exports"]}
    if fault == "digest":
        exports["edited_txt"]["files"][0]["utf8"] += "extra text"
    elif fault == "format":
        receipt["exports"].pop()
    elif fault == "raw_source":
        file = exports["edited_json"]["files"][0]
        record = json.loads(file["utf8"])
        record["rawText"] = "Changed original source"
        file["utf8"] = json.dumps(record)
        file["sha256"] = hashlib.sha256(file["utf8"].encode()).hexdigest()
    else:
        observed = exports["before_retry"]
        manifest = json.loads(observed["manifest_utf8"])
        if fault == "partial":
            manifest["records"].pop()
            manifest["count"] -= 1
            observed["files"].pop()
        else:
            manifest["records"][0]["file"] = "../escaped.json"
            observed["files"][0]["name"] = "../escaped.json"
        observed["manifest_utf8"] = json.dumps(manifest)
        observed["manifest_sha256"] = hashlib.sha256(observed["manifest_utf8"].encode()).hexdigest()
    with pytest.raises(AssertionError):
        checks.verify(receipt)
