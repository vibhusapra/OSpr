"""The consumer pilot must fail closed rather than silently score a subset."""

import copy
import hashlib
import importlib.util
import json
import sys
from pathlib import Path

import pytest

pytest.importorskip("jiwer")
ROOT = Path(__file__).resolve().parents[2] / "benchmarks"
sys.path.insert(0, str(ROOT))
SPEC = importlib.util.spec_from_file_location("native_file_comparison", ROOT / "native_file_comparison.py")
pilot = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(pilot)
PROTOCOL = json.loads(pilot.PROTOCOL.read_text())
OBSERVATIONS = json.loads(pilot.OBSERVATIONS.read_text())
DIGEST = hashlib.sha256(pilot.PROTOCOL.read_bytes()).hexdigest()


def test_complete_retained_score_and_order_independence():
    expected = json.loads((ROOT / "results/native-file-comparison.json").read_text())
    expected.pop("observations_sha256")
    shuffled = copy.deepcopy(OBSERVATIONS)
    for route in shuffled["completed_routes"].values():
        route["records"].reverse()
    assert pilot.score(PROTOCOL, shuffled, DIGEST) == expected


@pytest.mark.parametrize("fault", ["missing", "duplicate", "foreign", "text", "digest", "model", "protocol"])
def test_incomplete_or_changed_evidence_rejected(fault):
    data = copy.deepcopy(OBSERVATIONS)
    rows = data["completed_routes"]["ospr-small-repeat"]["records"]
    if fault == "missing":
        rows.pop()
    elif fault == "duplicate":
        rows[-1] = copy.deepcopy(rows[0])
    elif fault == "foreign":
        rows[-1]["source"] = "outside-cohort.wav"
    elif fault == "text":
        rows[0]["text"] = "a better invented answer"
    elif fault == "digest":
        rows[0]["raw_export_utf8"] += " "
    elif fault == "model":
        record = json.loads(rows[0]["raw_export_utf8"])
        record["model"] = "parakeet-v3"
        rows[0]["raw_export_utf8"] = json.dumps(record)
        rows[0]["raw_export_sha256"] = hashlib.sha256(rows[0]["raw_export_utf8"].encode()).hexdigest()
    else:
        data["protocol_sha256"] = "0" * 64
    with pytest.raises(ValueError):
        pilot.score(PROTOCOL, data, DIGEST)


def test_empty_recognition_is_scored_as_deletions():
    data = copy.deepcopy(OBSERVATIONS)
    row = data["completed_routes"]["macwhisper-small"]["records"][0]
    row.update(text="", raw_export_utf8="", raw_export_sha256=hashlib.sha256(b"").hexdigest())
    result = pilot.score(PROTOCOL, data, DIGEST)
    record = result["completed_routes"]["macwhisper-small"]["records"][0]
    assert record["wer"] == 1
    assert record["deletions"] == record["reference_words"]
