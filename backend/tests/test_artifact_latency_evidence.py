"""Retained experiment integrity: no dropped cases, relabeling or hidden failures."""
import copy
import importlib.util
import json
from pathlib import Path
import statistics
import sys

import pytest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "benchmarks"))
try:
    SPEC = importlib.util.spec_from_file_location("ospr_latency_verifier", ROOT / "benchmarks/verify_artifact_latency.py")
    checks = importlib.util.module_from_spec(SPEC)
    SPEC.loader.exec_module(checks)
finally:
    sys.path.pop(0)

PROTOCOL_PATH = ROOT / "benchmarks/fixtures/artifact-latency-protocol.json"
RECEIPT_PATH = ROOT / "benchmarks/results/artifact-latency-control.json"


@pytest.fixture
def evidence():
    return json.loads(PROTOCOL_PATH.read_text()), json.loads(RECEIPT_PATH.read_text())


def reported_timeout(result):
    """Synthetic ingestion control, never a claim about a measured failure."""
    row = result["records"][0]
    row.update(status="timeout", return_code=-15)
    for key in ("response", "wer", "word_errors"):
        row.pop(key, None)
    group = result["groups"][row["group"] + "/" + row["artifact"]]
    group["successful"] -= 1
    group["failures"] += 1
    group["wall_ms"].remove(row["wall_ms"])
    group["successful_wall_ms_median"] = statistics.median(group["wall_ms"]) if group["wall_ms"] else None
    return result


def test_actual_individual_cases_scores_order_and_aggregate_agree():
    value = checks.verify(PROTOCOL_PATH, RECEIPT_PATH)
    assert value["attempts"] == 16 and value["chronological_frozen_order"]


def test_reported_failure_is_retained_in_attempt_and_failure_denominators(evidence):
    protocol, result = evidence
    value = checks.verify_records(protocol, reported_timeout(result))
    assert value["attempts"] == 16 and value["failures"] >= 1
    group = result["groups"]["short-parakeet/A"]
    assert group["attempts"] == 2 and group["failures"] == 1 and group["successful"] == 1


@pytest.mark.parametrize("fault", ["missing", "artifact", "text", "negative-time", "chronology", "denominator"])
def test_incomplete_or_changed_experiment_evidence_is_refused(evidence, fault):
    protocol, original = evidence
    result = copy.deepcopy(original)
    if fault == "missing":
        result["records"].pop()
    elif fault == "artifact":
        result["records"][0]["cli_sha256"] = "0" * 64
    elif fault == "text":
        result["records"][0]["response"]["text"] += " extra invented token"
    elif fault == "negative-time":
        result["records"][0]["wall_ms"] = -1
    elif fault == "chronology":
        result["records"][0]["timestamp"] = result["records"][-1]["timestamp"]
    else:
        result = reported_timeout(result)
        result["groups"]["short-parakeet/A"]["failures"] = 0
        result["groups"]["short-parakeet/A"]["attempts"] = 1
    with pytest.raises(AssertionError):
        checks.verify_records(protocol, result)
