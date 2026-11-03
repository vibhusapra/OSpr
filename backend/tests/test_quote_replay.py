"""Metadata compatibility against all frozen production-study model replies.

No inference or semantic scoring: prompts, call ordering, rejection messages and
pre-existing output fields must remain identical to the archived implementation.
"""
import hashlib
import importlib.util
import json
from pathlib import Path

import pytest

from ospr_backend.summary import summarize

ROOT = Path(__file__).resolve().parents[2]


@pytest.mark.parametrize("model", ["9b", "4b"])
def test_locations_preserve_all_frozen_production_calls_and_results(model):
    spec = importlib.util.spec_from_file_location("quote_replay_archive", ROOT / "benchmarks/verify_summary_status.py")
    replay = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(replay)
    manifest = json.loads((ROOT / "benchmarks/fixtures/summary-status-study.json").read_text())
    run = next(row for row in manifest["runs"] if row["name"] == "diagnostics-" + model)
    data_path = ROOT / run["path"]
    assert hashlib.sha256(data_path.read_bytes()).hexdigest() == run["sha256"]
    frozen = replay.archive_module(ROOT / run["implementation"]["path"], ROOT / manifest["notes"]["path"])
    protocol = json.loads((ROOT / manifest["protocol"]["path"]).read_text())
    records = json.loads(data_path.read_text())["records"]
    assert len(protocol["cases"]) == len(records) == 20
    for case, record in zip(protocol["cases"], records, strict=True):
        observed = []
        results = []
        for implementation in [frozen.summarize, summarize]:
            prompts = []

            def complete(prompt, instruction, record=record, prompts=prompts):
                attempt = record["calls"][len(prompts)]
                prompts.append((prompt, instruction))
                if attempt["status"] == "failed":
                    kind, message = attempt["error"].split(": ", 1)
                    raise {"ValueError": ValueError, "RuntimeError": RuntimeError}[kind](message)
                return attempt["output"]

            try:
                result = implementation(case["text"], complete)
            except (ValueError, RuntimeError) as error:
                assert record["status"] == "rejected-no-summary"
                assert record["error"] == f"{type(error).__name__}: {error}"
                result = None
            assert len(prompts) == len(record["calls"])
            observed.append(prompts)
            results.append(result)
        assert observed[0] == observed[1], "Metadata changed a model prompt or call order"
        if results[0] is not None:
            assert results[0] == record["result"]
            source = case["text"].encode()
            for excerpt in results[1]["excerpts"]:
                start = excerpt.pop("source_start_utf8")
                end = excerpt.pop("source_end_utf8")
                assert 0 <= start < end <= len(source)
                assert source[start:end] == excerpt["text"].encode()
            assert results[1] == results[0], "Pre-existing result fields changed"
