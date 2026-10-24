"""Lossless source-encoding invariants, independent of model/grammar packages."""
import importlib.util
import json
from pathlib import Path
import random

import pytest

spec = importlib.util.spec_from_file_location(
    "summary_experiments", Path(__file__).resolve().parents[2]/"benchmarks/summary_experiments.py"
)
experiments = importlib.util.module_from_spec(spec)
spec.loader.exec_module(experiments)


def test_aliases_preserve_every_id_text_order_and_unicode_spelling():
    composed = "Zoë's proposal is still not approved. " * 15
    decomposed = composed.replace("ë", "e\u0308")
    rows = [dict(id=3, text=composed), dict(id=7, text=decomposed),
            dict(id=11, text=composed), dict(id=20, text="Last correction: keep the original price.")]
    before = json.dumps(dict(transcript=rows), ensure_ascii=False)
    prompt, instruction, result = experiments.compact_source(before, "Summarize.")
    encoded = json.loads(prompt)["transcript"]
    assert encoded[1]["text"] == decomposed and encoded[2] == dict(id=11, same_as=3)
    assert experiments.expand_source(encoded) == rows
    assert result["source_units"] == 4 and result["aliases"] == 1 and result["exact_roundtrip"]
    assert result["encoded_prompt_bytes"] < result["original_prompt_bytes"]
    assert "chronological" in instruction


def test_short_unique_and_nontranscript_inputs_stay_byte_identical():
    for value in [dict(transcript=[dict(id=0, text="Yes."), dict(id=1, text="Yes.")]),
                  dict(transcript=[dict(id=0, text="A unique source.")]), dict(candidates=[])]:
        prompt = json.dumps(value)
        assert experiments.compact_source(prompt, "Keep.") == (prompt, "Keep.", None)


@pytest.mark.parametrize("rows", [
    [dict(id=0, same_as=1), dict(id=1, same_as=0)],
    [dict(id=0, same_as=0)],
    [dict(id=0, text="x"), dict(id=0, text="x")],
    [dict(id=True, text="x")],
    [dict(id=1, same_as=True)],
])
def test_unknown_forward_cyclic_and_ambiguous_references_refuse(rows):
    with pytest.raises(ValueError):
        experiments.expand_source(rows)


def test_two_hundred_deterministic_duplicate_layouts_roundtrip_without_cross_chunk_state():
    rng = random.Random(734)
    texts = ["Still awaiting approval. " * 5, "A different decision; keep the qualifier. " * 4,
             "金曜日に公開しないでください。" * 5, "Short."]
    for _ in range(200):
        rows = [dict(id=i*3+7, text=rng.choice(texts)) for i in range(rng.randint(1, 50))]
        prompt = json.dumps(dict(transcript=rows), ensure_ascii=False)
        encoded, _, _ = experiments.compact_source(prompt, "Summarize.")
        assert experiments.expand_source(json.loads(encoded)["transcript"]) == rows
    standalone = json.dumps(dict(transcript=[dict(id=99, text=texts[0])]))
    assert experiments.compact_source(standalone, "Keep.") == (standalone, "Keep.", None)
