"""Offsets locate the exact occurrence in original UTF-8, independent of model text."""
import json

import pytest

from ospr_backend.notes import located_excerpts, select, units
from ospr_backend.summary import summarize


@pytest.mark.parametrize("middle", ["😀", "cafe\u0301", "東京", "مرحبا", "👩‍💻", "\r\n", "दुनिया"])
def test_repeated_quotes_and_unicode_use_byte_coordinates(middle):
    text = "Echo.\n" + middle + "\nEcho."
    source = units(text)
    result = located_excerpts(text, source, iter(range(len(source))))
    encoded = text.encode()
    for row, original in zip(result, source, strict=True):
        assert encoded[row["source_start_utf8"]:row["source_end_utf8"]].decode() == original["text"]
        assert row["source_start_utf8"] == len(text[:original["start"]].encode())
    assert result[0]["text"] == result[-1]["text"] == "Echo."
    assert result[0]["source_start_utf8"] != result[-1]["source_start_utf8"]


def test_summary_and_extractive_notes_keep_same_unit_occurrence_and_legacy_scalar_fields():
    text = "Echo. 😀. Echo."
    notes = select(text, lambda *_: '{"selected":[2]}')["excerpts"][0]
    summary = summarize(text, lambda *_: json.dumps({"items": [{"section": "overview", "text": "Echo.", "source_ids": [2]}]}))["excerpts"][0]
    assert {k: v for k, v in notes.items() if k not in {"start", "end"}} == summary
    assert text[notes["start"]:notes["end"]] == "Echo."
    assert notes["source_start_utf8"] == len("Echo. 😀. ".encode())


def test_long_unicode_source_produces_exact_bounded_slices_without_new_model_calls():
    text = ("😀 café 東京. " * 4000).strip()
    source = units(text)
    selected = [0, 100, len(source) - 1]
    result = located_excerpts(text, source, selected)
    assert [r["id"] for r in result] == selected
    for row in result:
        assert text.encode()[row["source_start_utf8"]:row["source_end_utf8"]].decode() == row["text"]
    assert located_excerpts(text, source, []) == []
