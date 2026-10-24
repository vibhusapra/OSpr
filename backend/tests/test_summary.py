import json
import pytest
from ospr_backend.summary import summarize, parse


def item(text="Do not ship Friday.", ids=None, section="decisions"):
    return dict(section=section, text=text, source_ids=[0] if ids is None else ids)


def test_paraphrases_keep_explicit_source_quotes_and_unicode():
    text = "Do not ship on Friday. 次は東京です。"
    result = summarize(
        text,
        lambda *_: json.dumps(
            dict(items=[item("Hold the Friday release.", [0]), item("Next: 東京。", [1], "overview")])
        ),
    )
    assert len(result["items"]) == 2 and result["items"][0]["text"] not in text
    assert result["excerpts"] == [
        dict(id=0, text="Do not ship on Friday."),
        dict(id=1, text="次は東京です。"),
    ]
    assert result["chunks"] == 1 and not result["reconciled"]


@pytest.mark.parametrize(
    "payload",
    [
        None,
        [],
        {},
        {"items": None},
        {"items": [], "unexpected": 1},
        {"items": [item(ids=[True])]},
        {"items": [item(ids=[99])]},
        {"items": [item(ids=[])]},
        {"items": [item(ids=[0, 0])]},
        {"items": [item(section="execute")]},
        {"items": [item(text="")]},
        {"items": [item(text="x" * 1001)]},
        {"items": [item(text="bad\x00content")]},
        {"items": [dict(item(), owner="invented")]},
        {"items": [item()] * 33},
    ],
)
def test_invalid_output_fails_without_a_partial_summary(payload):
    with pytest.raises(ValueError, match="Previous notes and transcript are unchanged"):
        summarize("Do not ship on Friday.", lambda *_: json.dumps(payload))


def test_all_chunks_read_then_reconciled_and_final_refs_bounded_to_candidates():
    text = " ".join(f"Commitment {i} will be reviewed on Monday." for i in range(650))
    seen, candidates = [], []

    def complete(prompt, _):
        value = json.loads(prompt)
        if "transcript" in value:
            rows = value["transcript"]
            seen.extend(r["id"] for r in rows)
            row = item(rows[-1]["text"], [rows[-1]["id"]], "actions")
            candidates.append(row)
            return json.dumps(dict(items=[row]))
        assert [{k: v for k, v in row.items() if k != "chunk"} for row in value["candidates"]] == candidates
        assert value["evidence"] == [
            dict(id=row["source_ids"][0], text=row["text"]) for row in candidates
        ]
        return json.dumps(dict(items=[candidates[-1]]))

    result = summarize(text, complete)
    assert len(seen) == 650 and seen == list(range(650))
    assert result["chunks"] > 1 and result["reconciled"]
    assert result["items"][0]["text"].startswith("Commitment 649")
    assert result["excerpts"][0]["id"] == 649


def test_reconciliation_cannot_invent_a_source_id_or_silently_drop_all_candidates():
    text = "Do not ship. " * 1100
    for final in [dict(items=[item(ids=[1])]), dict(items=[])]:

        def complete(prompt, _, final=final):
            value = json.loads(prompt)
            if "transcript" in value:
                return json.dumps(dict(items=[item(ids=[value["transcript"][0]["id"]])]))
            return json.dumps(final)

        with pytest.raises(ValueError):
            summarize(text, complete)


def test_blank_oversize_and_wrong_type_fail_before_model_work():
    def never(*_):
        raise AssertionError("unexpected generation")

    assert summarize(" \n", never)["items"] == []
    for source in ["x" * 100001, 42]:
        with pytest.raises(ValueError):
            summarize(source, never)


def test_optional_json_fence_and_punctuation_are_preserved():
    result = parse(
        "```json\n" + json.dumps(dict(items=[item("Price stays $12.50; not $15.50.")])) + "\n```", {0}, 4, 3
    )
    assert result[0]["text"] == "Price stays $12.50; not $15.50."


def test_duplicate_json_keys_and_uncited_quantities_fail_closed():
    with pytest.raises(ValueError):
        summarize("Price is $12.50.", lambda *_: '{"items":[],"items":[]}')
    for text in ["Price is $12.55.", "The deadline is June 12."]:
        with pytest.raises(ValueError, match="quantity absent"):
            summarize("Price is $12.50.", lambda *_, text=text: json.dumps(dict(items=[item(text)])))


def test_progress_covers_each_chunk_and_reconciliation_without_echoing_text():
    text = "No decision was made. " * 900
    events = []

    def complete(prompt, _):
        value = json.loads(prompt)
        if "transcript" in value:
            row = value["transcript"][0]
            return json.dumps(dict(items=[item(row["text"], [row["id"]], "overview")]))
        return json.dumps(dict(items=[{k: v for k, v in value["candidates"][0].items() if k != "chunk"}]))

    result = summarize(text, complete, progress=events.append)
    assert [e["part"] for e in events if e["phase"] == "summarizing"] == list(range(1, result["chunks"] + 1))
    assert events[-1]["phase"] == "reconciling"
    assert text not in json.dumps(events)


def test_many_supporting_quotes_are_allowed_but_unknown_refs_still_fail():
    text = " ".join(f"Observation {i} has no decision." for i in range(12))
    result = summarize(
        text,
        lambda *_: json.dumps(
            dict(items=[item("General observations with no decision.", list(range(12)), "overview")])
        ),
    )
    assert len(result["excerpts"]) == 12
    with pytest.raises(ValueError):
        summarize(
            text,
            lambda *_: json.dumps(dict(items=[item("General observations.", list(range(13)), "overview")])),
        )


def test_weekday_qualifiers_cannot_be_strengthened_or_reversed():
    for changed in ["Priya will send review by Monday.", "Priya sends review before Monday."]:
        with pytest.raises(ValueError, match="date/time qualifier"):
            summarize(
                "Priya will send the review on Monday.",
                lambda *_, changed=changed: json.dumps(dict(items=[item(changed, section="actions")])),
            )
    result = summarize(
        "Priya will send the review on Monday.",
        lambda *_: json.dumps(dict(items=[item("Review on Monday.", section="actions")])),
    )
    assert result["items"]


def test_script_hint_preserves_writing_system_without_guessing_language():
    from ospr_backend.summary import script_instruction

    assert "Devanagari" in script_instruction(
        "शुक्रवार को बीटा जारी नहीं करना है।"
    ) or "DEVANAGARI" in script_instruction("शुक्रवार को बीटा जारी नहीं करना है।")
    assert "Hindi" not in script_instruction("शुक्रवार को बीटा जारी नहीं करना है।")
    assert not script_instruction("Keep the original French or Spanish language.")
    seen = []
    summarize(
        "शुक्रवार को बीटा जारी नहीं करना है।",
        lambda prompt, instruction: seen.append(instruction) or '{"items":[]}',
    )
    assert "DEVANAGARI" in seen[0]


def test_bare_deadline_is_not_mistaken_for_an_explicit_weekday_swap():
    result = summarize(
        "The audit deadline is Tuesday.",
        lambda *_: json.dumps(dict(items=[item("Audit is due by Tuesday.", section="actions")])),
    )
    assert result["items"]


def test_one_bounded_format_source_repair_then_atomic_rejection():
    calls, events = [], []

    def complete(prompt, instruction):
        calls.append(instruction)
        value = json.loads(prompt)
        if len(calls) == 2:
            assert value["previous_attempt"]["draft"] == json.dumps(
                dict(items=[item("Price is $12.55.")])
            )
            assert "quantity absent" in value["previous_attempt"]["validation_error"]
            assert value["previous_attempt"]["truncated"] is False
            assert value["transcript"] == [dict(id=0, text="Price is $12.50.")]
        return json.dumps(dict(items=[item("Price is $12.55." if len(calls) == 1 else "Price is $12.50.")]))

    result = summarize("Price is $12.50.", complete, progress=events.append)
    assert result["validation_retries"] == 1 and len(calls) == 2
    assert result["items"][0]["text"] == "Price is $12.50."
    assert any(e["phase"] == "retrying" for e in events)
    failed = []

    def invalid(*_):
        failed.append(True)
        return '{"items":[{"section":"overview","text":"No evidence","source_ids":[999]}]}'

    with pytest.raises(ValueError):
        summarize("Price is $12.50.", invalid)
    assert len(failed) == 2


def test_repair_draft_is_bounded_quoted_data_and_does_not_grow_on_retry():
    prompts = []

    def complete(prompt, instruction):
        value = json.loads(prompt)
        prompts.append(value)
        if len(prompts) == 1:
            return "malformed " + "x" * 100000
        assert "quoted data" in instruction
        previous = value["previous_attempt"]
        assert len(previous["draft"]) == 12000 and previous["truncated"]
        assert "previous_attempt" not in prompts[0]
        return '{"items":[]}'

    assert summarize("Public source.", complete)["validation_retries"] == 1
    assert len(prompts) == 2


def test_repair_receives_all_item_specific_preservation_failures_without_public_echo():
    calls = []

    def complete(prompt, _):
        value = json.loads(prompt)
        calls.append(value)
        if len(calls) == 1:
            return json.dumps(dict(items=[item("Price is $98.10."), item(
                "Review before Monday.", [1], "actions"
            )]))
        assert value["previous_attempt"]["validation_checks"] == [
            dict(item_index=0, issue="uncited-quantity", spellings=["98.10"]),
            dict(item_index=1, issue="changed-date-qualifier", date="monday",
                 used="before", supported=["on"]),
        ]
        assert "98.10" not in value["previous_attempt"]["validation_error"]
        return json.dumps(dict(items=[item("Price remains $12.50."), item(
            "Review on Monday.", [1], "actions"
        )]))

    result = summarize("Price is $12.50. Review on Monday.", complete)
    assert result["validation_retries"] == 1


def test_repair_identifies_an_unsupported_section_without_echoing_generated_text():
    calls = []

    def complete(prompt, _):
        calls.append(json.loads(prompt))
        if len(calls) == 1:
            return json.dumps(dict(items=[item("Publish only if approved.", section="conditions")]))
        previous = calls[-1]["previous_attempt"]
        assert previous["validation_checks"] == [dict(
            item_index=0, issue="invalid-section",
            allowed_sections=["actions", "decisions", "overview", "questions"],
        )]
        assert "conditions" not in previous["validation_error"]
        return json.dumps(dict(items=[item("Publish only if approved.", section="actions")]))

    assert summarize("Publish only if approved.", complete)["validation_retries"] == 1


def test_repair_metadata_is_bounded_even_with_many_source_failures():
    calls = []
    bad_text = " ".join(str(i) for i in range(100000, 100120))

    def complete(prompt, _):
        calls.append(json.loads(prompt))
        if len(calls) == 1:
            return json.dumps(dict(items=[item(bad_text)] * 32))
        previous = calls[-1]["previous_attempt"]
        assert previous["checks_truncated"] is True
        assert len(json.dumps(previous["validation_checks"], ensure_ascii=False)) <= 4000
        assert len(previous["draft"]) <= 12000
        assert calls[-1]["transcript"] == [dict(id=0, text="Price stays 0.")]
        return '{"items":[]}'

    assert summarize("Price stays 0.", complete)["validation_retries"] == 1


def test_reconciliation_evidence_is_exact_unique_ordered_and_never_uncited():
    text = "A proposal remains unapproved. " + "No substantive update. " * 400
    citations = []

    def complete(prompt, _):
        value = json.loads(prompt)
        if "candidates" not in value:
            row = value["transcript"][0]
            citations.append(row)
            return json.dumps(dict(items=[item(row["text"], [row["id"]], "overview")]))
        assert value["evidence"] == citations
        assert {r["id"] for r in value["evidence"]} == {
            i for row in value["candidates"] for i in row["source_ids"]
        }
        return json.dumps(dict(items=value["candidates"][:1]))

    assert summarize(text, complete)["reconciled"]


def test_generation_failure_is_not_retried_as_a_format_repair():
    calls = []

    def complete(*_):
        calls.append(True)
        raise RuntimeError("Local completion not acknowledged")

    with pytest.raises(RuntimeError, match="not acknowledged"):
        summarize("Public source.", complete)
    assert len(calls) == 1


def test_month_day_and_clock_qualifiers_are_preserved_but_bare_deadlines_are_allowed():
    for source, changed in [
        ("Omar will send results on June 5.", "Omar sends results by June 5."),
        ("Review starts at 14:00.", "Review starts before 14:00."),
    ]:
        with pytest.raises(ValueError, match="date/time qualifier"):
            summarize(
                source, lambda *_, changed=changed: json.dumps(dict(items=[item(changed, section="actions")]))
            )
    assert summarize(
        "The deadline is June 5.",
        lambda *_: json.dumps(dict(items=[item("Review due by June 5.", section="actions")])),
    )["items"]
