import copy

import pytest

from ospr_backend.timing import bound_timings


def run(segments, words=None, start=0, end=5, text="All recognized words remain."):
    return bound_timings(segments, words or [], start=start, end=end, text=text, granularity="segment")


def test_observed_whisper_30_second_segment_is_bounded_to_its_real_08_second_input():
    # Frozen multilingual fixture fleurs-de_de-000-quiet40db: the recognizer
    # extrapolated a Whisper window past a 0.8 s neural selection and 17.94 s source.
    source = [dict(start=4.608, end=34.588, text="Das ist die beste Ausdruck.")]
    before = copy.deepcopy(source)
    result = run(source, start=4.608, end=5.408, text=source[0]["text"])
    assert result["segments"] == [dict(start=4.608, end=5.408, text=source[0]["text"])]
    assert source == before  # Preserve raw evidence owned by the caller.
    assert result["timing_corrections"] == dict(clipped_intervals=1, fallback_to_utterance=False)
    assert "bounded" in result["timing_warning"]


def test_valid_offsets_intermediate_pauses_and_word_payloads_are_preserved():
    segments = [dict(start=12, end=13, text="First."), dict(start=18, end=19, text="Second.")]
    words = [dict(start=12.2, end=12.8, text="First.", probability=0.9), dict(start=18.2, end=18.8, text="Second.")]
    result = run(segments, words, start=10, end=20)
    assert result == dict(segments=segments, words=words, timestamp_granularity="segment")
    assert result["segments"][0] is not segments[0]


def test_both_outer_sides_are_bounded_on_original_source_coordinates():
    segments = [dict(start=9.98, end=20.02, text="Keep it all.")]
    words = [dict(start=9.99, end=11, text="Keep"), dict(start=19, end=20.02, text="all.")]
    result = run(segments, words, start=10, end=20)
    assert result["segments"] == [dict(start=10, end=20, text="Keep it all.")]
    assert result["words"][0]["start"] == 10 and result["words"][1]["end"] == 20
    assert result["timing_corrections"]["clipped_intervals"] == 3


@pytest.mark.parametrize("bad", [
    dict(start=float("nan"), end=2, text="bad"), dict(start=1, end=float("inf"), text="bad"),
    dict(start=3, end=2, text="bad"), dict(start=6, end=7, text="bad"),
    dict(start=-2, end=-1, text="bad"), dict(start=8, end=8, text="bad"),
    dict(start=True, end=2, text="bad"), dict(start="1", end=2, text="bad"),
    dict(start=1, text="bad"), None,
])
def test_unusable_segment_keeps_complete_text_with_explicit_approximate_timing(bad):
    text = "Keep every word, including the last one."
    result = run([bad], [dict(start=1, end=2, text="Keep")], text=text)
    assert result["segments"] == [dict(start=0, end=5, text=text)]
    assert result["words"] == [] and result["timestamp_granularity"] == "utterance"
    assert result["timing_corrections"]["fallback_to_utterance"] and "approximate" in result["timing_warning"]


def test_one_word_beyond_audio_does_not_get_a_manufactured_eof_alignment():
    result = run([dict(start=0, end=4, text="One two.")],
                 [dict(start=1, end=2, text="One"), dict(start=8, end=9, text="two.")], text="One two.")
    assert result["segments"] == [dict(start=0, end=5, text="One two.")]
    assert result["words"] == [] and result["timestamp_granularity"] == "utterance"


def test_unordered_alignment_falls_back_without_reordering_or_dropping_text():
    result = run([dict(start=3, end=4, text="First."), dict(start=1, end=2, text="Second.")], text="First. Second.")
    assert result["segments"] == [dict(start=0, end=5, text="First. Second.")]
    assert result["timestamp_granularity"] == "utterance"


def test_no_segments_with_text_has_a_visible_fallback_and_empty_text_stays_empty():
    assert run([], text="Still here.")["segments"] == [dict(start=0, end=5, text="Still here.")]
    assert run([], text="")["segments"] == []


def test_zero_length_word_within_audio_and_float_roundoff_do_not_invent_warning():
    result = run([dict(start=0, end=5 + 1e-12, text="Word.")], [dict(start=5, end=5, text=".")])
    assert result["segments"][0]["end"] == 5
    assert result["words"] == [dict(start=5, end=5, text=".")]
    assert "timing_warning" not in result


@pytest.mark.parametrize("start,end", [(0, 0), (-1, 2), (4, 2), (float("nan"), 1), (0, float("inf"))])
def test_invalid_source_interval_is_an_internal_error(start, end):
    with pytest.raises(ValueError, match="analyzed audio"):
        run([], start=start, end=end)
