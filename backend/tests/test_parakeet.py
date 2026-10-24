from types import SimpleNamespace

import numpy as np
import pytest

from ospr_backend.audio import SAMPLE_RATE
from ospr_backend import parakeet


def test_long_decode_preserves_repeats_and_independent_word_boundaries(monkeypatch):
    monkeypatch.setattr(parakeet, "_logmel", lambda audio, config: audio)
    token = SimpleNamespace(text="repeat", start=0.1, end=0.6)
    calls = []

    def generate(audio):
        calls.append(len(audio))
        return [SimpleNamespace(text="repeat", tokens=[token], sentences=[SimpleNamespace(
            text="repeat", start=-0.02, end=len(audio) / SAMPLE_RATE + 0.02)])]

    model = SimpleNamespace(preprocessor_config=None, generate=generate)
    result = parakeet.transcribe_long(model, np.zeros(61 * SAMPLE_RATE, dtype=np.float32),
                                      offset=2, word_timestamps=True)
    assert result["text"] == "repeat repeat repeat"
    assert [w["text"] for w in result["words"]] == ["repeat"] * 3
    assert [w["start"] for w in result["words"]] == pytest.approx([2.1, 27.1, 52.1])
    assert result["segments"][0]["start"] == 2
    assert result["segments"][-1]["end"] == 63
    assert all(b["start"] >= a["end"] for a, b in zip(result["segments"], result["segments"][1:], strict=False))
    assert result["decoded_samples"] == sum(calls) == 61 * SAMPLE_RATE
    assert max(calls) <= 30 * SAMPLE_RATE
    # Some runtimes reuse objects. Offsetting must not mutate their next output.
    assert token.start == 0.1 and token.end == 0.6


def test_plain_transcription_does_not_derive_word_timing(monkeypatch):
    monkeypatch.setattr(parakeet, "_logmel", lambda audio, config: audio)
    model = SimpleNamespace(preprocessor_config=None, generate=lambda audio: [SimpleNamespace(
        text="hello", sentences=[SimpleNamespace(text="hello", start=0, end=1)])])
    result = parakeet.transcribe_long(model, np.zeros(31 * SAMPLE_RATE, dtype=np.float32))
    assert result["text"] == "hello hello" and result["words"] == []


@pytest.mark.parametrize("start,end", [(float("nan"), 1), (0, float("inf")), (2, 1)])
def test_invalid_recognizer_timing_fails_before_saving_partial_text(monkeypatch, start, end):
    monkeypatch.setattr(parakeet, "_logmel", lambda audio, config: audio)
    model = SimpleNamespace(preprocessor_config=None, generate=lambda audio: [SimpleNamespace(
        text="hello", sentences=[SimpleNamespace(text="hello", start=start, end=end)])])
    with pytest.raises(ValueError, match="invalid recognizer timing"):
        parakeet.transcribe_long(model, np.zeros(31 * SAMPLE_RATE, dtype=np.float32))


def test_blank_chunks_do_not_create_empty_subtitle_segments(monkeypatch):
    monkeypatch.setattr(parakeet, "_logmel", lambda audio, config: audio)
    model = SimpleNamespace(preprocessor_config=None, generate=lambda audio: [SimpleNamespace(
        text="", sentences=[SimpleNamespace(text="", start=0, end=1)])])
    result = parakeet.transcribe_long(model, np.zeros(31 * SAMPLE_RATE, dtype=np.float32))
    assert result["text"] == "" and result["segments"] == []
    assert result["decoder_chunks"] == 2
