from types import SimpleNamespace

import numpy as np
import pytest

from ospr_backend.audio import SAMPLE_RATE
from ospr_backend.qwen import TOKENS_PER_CHUNK, chunks, language_tag, transcribe_long


@pytest.mark.parametrize("seconds", [30, 30 + 1 / SAMPLE_RATE, 31, 60.5, 97])
def test_chunks_preserve_every_sample_and_bound_context_and_tail(seconds):
    original = np.arange(round(seconds * SAMPLE_RATE), dtype=np.float32)
    pieces = list(chunks(original))
    np.testing.assert_array_equal(np.concatenate([audio for audio, _ in pieces]), original)
    cursor = 0
    for audio, offset in pieces:
        assert round(offset * SAMPLE_RATE) == cursor
        assert 0 < len(audio) <= 30 * SAMPLE_RATE
        cursor += len(audio)
    assert len(pieces[-1][0]) >= SAMPLE_RATE


def test_boundary_prefers_quiet_region_without_removing_it():
    audio = np.ones(61 * SAMPLE_RATE, dtype=np.float32)
    audio[27 * SAMPLE_RATE:28 * SAMPLE_RATE] = 0
    first, _ = next(chunks(audio))
    assert 27 * SAMPLE_RATE <= len(first) <= 28 * SAMPLE_RATE


class Recognizer:
    def __init__(self, exhausted=False):
        self.calls = []
        self.exhausted = exhausted

    def generate(self, audio, **kwargs):
        self.calls.append((len(audio), kwargs))
        return SimpleNamespace(text="repeat", language=["en"],
                               generation_tokens=TOKENS_PER_CHUNK if self.exhausted else 5)


def test_each_chunk_has_a_fresh_budget_and_repeated_words_survive():
    model = Recognizer()
    audio = np.zeros(61 * SAMPLE_RATE, dtype=np.float32)
    result = transcribe_long(model, audio, language="en", offset=1.25)
    assert result["text"] == "repeat repeat repeat"
    assert result["decoder_chunks"] == 3 and result["language"] == "en"
    assert result["segments"][0]["start"] == 1.25
    assert result["segments"][-1]["end"] == pytest.approx(62.25)
    for _, options in model.calls:
        assert options == dict(max_tokens=TOKENS_PER_CHUNK, batch_size=1, language="en")
    assert sum(size for size, _ in model.calls) == len(audio)


def test_exhaustion_fails_instead_of_returning_partial_text():
    model = Recognizer(exhausted=True)
    with pytest.raises(RuntimeError, match="no partial transcript"):
        transcribe_long(model, np.zeros(61 * SAMPLE_RATE, dtype=np.float32))
    assert len(model.calls) == 1


def test_empty_chunks_are_counted_without_emitting_blank_subtitle_segments():
    model = SimpleNamespace(generate=lambda audio, **options: SimpleNamespace(
        text="", language=["en"], generation_tokens=1))
    result = transcribe_long(model, np.zeros(61 * SAMPLE_RATE, dtype=np.float32))
    assert result["decoder_chunks"] == 3
    assert result["segments"] == [] and result["text"] == ""


def test_multiple_detected_languages_do_not_become_an_invalid_wire_list():
    assert language_tag(["en", "en"]) == "en"
    assert language_tag(["en", "hi"]) is None
    assert language_tag([], "en") == "en"
    assert language_tag(None) is None


def test_multichannel_chunk_input_is_rejected():
    with pytest.raises(ValueError, match="mono"):
        list(chunks(np.zeros((32, 2), dtype=np.float32)))
