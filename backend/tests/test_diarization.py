import pytest
import numpy as np
import soundfile as sf
import sys
from types import SimpleNamespace
from ospr_backend.diarization import attribute, formatted, tokens_to_words
from ospr_backend.engine import Engine


def test_subword_pieces_keep_their_original_timing():
    tokens = [
        {"start": 0.0, "end": 0.2, "text": " Hello"},
        {"start": 0.2, "end": 0.4, "text": "world"},
        {"start": 0.5, "end": 0.8, "text": " again"},
        {"start": 0.8, "end": 0.9, "text": "."},
    ]
    words = tokens_to_words(tokens)
    assert words == [
        {"start": 0.0, "end": 0.4, "text": "Helloworld"},
        {"start": 0.5, "end": 0.9, "text": "again."},
    ]


def test_speaker_overlap_and_unassigned_words_are_explicit():
    words = [
        {"start": 0.0, "end": 1.0, "text": "Hello"},
        {"start": 1.0, "end": 2.0, "text": "there"},
        {"start": 2.0, "end": 3.0, "text": "Both"},
        {"start": 4.0, "end": 5.0, "text": "Unknown"},
    ]
    turns = [{"start": 0.0, "end": 3.0, "speaker": 0}, {"start": 2.0, "end": 3.0, "speaker": 1}]
    labeled, segments = attribute(words, turns)
    assert [w["speaker"] for w in labeled] == [0, 0, None, None]
    assert labeled[2]["overlapSpeakers"] == [0, 1]
    assert segments[0]["text"] == "Hello there"
    assert "Speaker 1: Hello there" in formatted(segments)
    assert "Overlapping speakers: Both" in formatted(segments)
    assert "Unassigned: Unknown" in formatted(segments)


def test_invalid_alignment_and_unsupported_meeting_model_fail():
    with pytest.raises(ValueError, match="timing"):
        attribute([{"start": float("nan"), "end": 1.0, "text": "bad"}], [])
    with pytest.raises(ValueError, match="word timing"):
        Engine().meeting("unused", "qwen3-asr")


def test_meeting_silence_gate_honors_quiet_audio_opt_out(tmp_path, monkeypatch):
    path = tmp_path / "quiet.wav"
    sf.write(path, np.full(16000, 0.001, dtype=np.float32), 16000, subtype="FLOAT")
    engine = Engine()
    assert engine.meeting(str(path))["silence"]

    def reached_loader(*args, **kwargs):
        raise RuntimeError("diarizer reached")

    monkeypatch.setitem(sys.modules, "mlx_audio.vad", SimpleNamespace(load=reached_loader))
    monkeypatch.setattr("ospr_backend.engine.resolve_model", lambda _: "fixture")
    for options in [{"trim": False}, {"threshold": 0.0001}]:
        with pytest.raises(RuntimeError, match="diarizer reached"):
            engine.meeting(str(path), **options)
    with pytest.raises(ValueError, match="Threshold"):
        engine.meeting(str(path), threshold=float("nan"))
