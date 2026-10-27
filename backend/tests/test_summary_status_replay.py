"""The published study cannot drop failed cases or alter recorded notes silently."""
import copy
import importlib.util
import json
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("summary_status_replay", ROOT / "benchmarks/verify_summary_status.py")
verifier = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(verifier)
PROTOCOL = json.loads((ROOT / "benchmarks/fixtures/summary-status-protocol.json").read_text())
DATA = json.loads((ROOT / "benchmarks/results/summary-status-baseline-9b.json").read_text())


def summarize():
    return verifier.archive_module(ROOT / "benchmarks/fixtures/meeting_summary_pre_status.py",
                                   ROOT / "benchmarks/fixtures/summary_status_notes.py").summarize


def test_complete_twenty_case_replay_preserves_three_refusals():
    result = verifier.replay(DATA, PROTOCOL, summarize())
    assert result["cases"] == 20 and result["admitted_for_review"] == 17 and result["rejected"] == 3
    assert result["rendered_prompts_verified"] is False


@pytest.mark.parametrize("fault", ["missing", "duplicate", "order", "source", "raw-output", "saved-result"])
def test_missing_changed_or_relabelled_evidence_refused(fault):
    data = copy.deepcopy(DATA)
    if fault == "missing":
        data["records"].pop()
    elif fault == "duplicate":
        data["records"][-1] = copy.deepcopy(data["records"][0])
    elif fault == "order":
        data["records"][0], data["records"][1] = data["records"][1], data["records"][0]
    elif fault == "source":
        data["records"][0]["source_sha256"] = "0" * 64
    elif fault == "raw-output":
        data["records"][0]["calls"][0]["output"] = "an invented replacement"
    elif fault == "saved-result":
        data["records"][0]["result"]["items"][0]["text"] = "The plan is approved."
    with pytest.raises(AssertionError):
        verifier.replay(data, PROTOCOL, summarize())
