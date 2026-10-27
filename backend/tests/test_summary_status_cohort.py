"""No silent word loss, duplicate segments or reference-summary leakage."""
import importlib.util
import io
from pathlib import Path
from zipfile import ZipFile

import pytest

SPEC = importlib.util.spec_from_file_location("summary_status_cohort", Path(__file__).resolve().parents[2] / "benchmarks/prepare_summary_status.py")
cohort = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(cohort)


def annotated_archive(range_a="id(M.A.words0)..id(M.A.words2)", duplicate=False):
    buffer = io.BytesIO()
    prefix = '<nite:root xmlns:nite="http://nite.sourceforge.net/">'
    segment = '<segment transcriber_start="2" transcriber_end="3"><nite:child href="M.A.words.xml#' + range_a + '"/></segment>'
    with ZipFile(buffer, "w") as z:
        z.writestr("corpusResources/meetings.xml", '<root><meeting observation="M" type="scenario" duration="3"><speaker nxt_agent="A" role="PM"/><speaker nxt_agent="B" role="ME"/></meeting></root>')
        z.writestr("words/M.A.words.xml", prefix + ''.join(f'<w nite:id="M.A.words{i}">{word}</w>' for i, word in enumerate(["Do", "not", "ship"])) + '</nite:root>')
        z.writestr("segments/M.A.segments.xml", prefix + segment * (2 if duplicate else 1) + '</nite:root>')
        z.writestr("words/M.B.words.xml", prefix + '<w nite:id="M.B.words0">Chloé</w></nite:root>')
        z.writestr("segments/M.B.segments.xml", prefix + '<segment transcriber_start="1" transcriber_end="2"><nite:child href="M.B.words.xml#id(M.B.words0)"/></segment></nite:root>')
        z.writestr("abstractive/M.abssumm.xml", '<root><decisions><sentence>REFERENCE ONLY SENTINEL</sentence></decisions></root>')
    buffer.seek(0)
    return ZipFile(buffer)


def test_exact_once_words_source_order_roles_unicode_and_separate_reference():
    with annotated_archive() as archive:
        result = cohort.meeting_case(archive, "M")
    assert result["text"] == "[Marketing Expert] Chloé\n[Project Manager] Do not ship"
    assert result["provenance"]["annotated_word_tokens"] == 4
    assert result["provenance"]["exact_once_word_coverage"]
    assert "REFERENCE ONLY SENTINEL" not in result["text"]
    assert result["reference_summary"] == {"decisions": ["REFERENCE ONLY SENTINEL"]}


@pytest.mark.parametrize("word_range,duplicate", [
    ("id(M.A.words0)..id(M.A.words1)", False),
    ("id(M.A.words0)..id(M.A.words2)", True),
    ("id(M.A.words2)..id(M.A.words0)", False),
    ("not-an-annotation-range", False),
])
def test_incomplete_duplicate_reversed_or_unknown_ranges_refused(word_range, duplicate):
    with annotated_archive(word_range, duplicate) as archive, pytest.raises(ValueError):
        cohort.meeting_case(archive, "M")
