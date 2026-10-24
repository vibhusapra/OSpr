import hashlib
import sys
from types import SimpleNamespace

import numpy as np
import pytest
import soundfile as sf
import mlx

from ospr_backend.audio import read_audio
from ospr_backend.engine import Engine
from ospr_backend.speech_edges import checked_bounds, pcm_sha256
from ospr_backend.worker import dispatch


def manifest(audio, start=0, end=None):
    return dict(method="silero-causal8-v1", sample_rate=16000, audio_samples=len(audio),
                pcm_sha256=pcm_sha256(audio), start_sample=start, end_sample=len(audio) if end is None else end)


def test_hash_contract_preserves_float_bits_signed_zero_and_subnormal():
    audio = np.array([-0.0, 0.0, 1.0, -1.0, np.nextafter(np.float32(0), np.float32(1))], dtype=np.float32)
    assert pcm_sha256(audio) == hashlib.sha256(audio.astype("<f4").tobytes()).hexdigest()
    assert pcm_sha256(audio) != pcm_sha256(np.abs(audio))
    assert checked_bounds(audio, manifest(audio, 1, 4), False) == (1, 4)


@pytest.mark.parametrize("change", [
    {"method": "rms"}, {"sample_rate": 48000}, {"sample_rate": True}, {"audio_samples": 5},
    {"audio_samples": 4.0}, {"start_sample": -1}, {"end_sample": 5}, {"start_sample": 3, "end_sample": 2},
    {"start_sample": 2, "end_sample": 2}, {"start_sample": False}, {"end_sample": 3.0},
    {"pcm_sha256": "0" * 64}, {"pcm_sha256": "bad"}, {"pcm_sha256": None}, {"extra": True},
])
def test_invalid_manifest_is_rejected_before_model_loading(tmp_path, monkeypatch, change):
    audio = np.array([0, 0.001, 0, 0], dtype=np.float32)
    path = tmp_path / "source.wav"
    sf.write(path, audio, 16000, subtype="FLOAT")
    selection = manifest(audio) | change
    engine = Engine()
    monkeypatch.setattr(engine, "_load", lambda *_: pytest.fail("Invalid edges reached model load"))
    with pytest.raises(ValueError):
        dispatch(engine, dict(action="transcribe", path=str(path), trim=False, speech_edges=selection))


@pytest.mark.parametrize("selection", [[], "bad", {}, None])
def test_non_manifest_and_second_rms_trim_are_rejected(selection):
    audio = np.zeros(400, dtype=np.float32)
    with pytest.raises(ValueError):
        checked_bounds(audio, selection, False)
    with pytest.raises(ValueError, match="disabled"):
        checked_bounds(audio, manifest(audio), True)


def test_one_changed_sample_outside_the_selected_range_is_rejected():
    audio = np.zeros(16000, dtype=np.float32)
    selection = manifest(audio, 5000, 10000)
    audio[0] = 0.00001
    with pytest.raises(ValueError, match="changed"):
        checked_bounds(audio, selection, False)


def test_detector_abstention_skips_model_and_preserves_original_duration(tmp_path, monkeypatch):
    path = tmp_path / "quiet.wav"
    audio = np.full(16000, 0.001, dtype=np.float32)
    sf.write(path, audio, 16000, subtype="FLOAT")
    engine = Engine()
    monkeypatch.setattr(engine, "_load", lambda *_: pytest.fail("Abstention loaded ASR"))
    for action in ["transcribe", "meeting"]:
        result = dispatch(engine, dict(action=action, path=str(path), trim=False, speech_edges=manifest(audio, 0, 0)))
        assert result["text"] == "" and result["silence"] and result["detector_abstained"]
        assert result["audio_seconds"] == 1 and result["speech_seconds"] == 0
        assert result["speech_edges"]["audio_samples"] == 16000
    assert not engine.models


def test_selected_array_and_timestamps_keep_the_original_timeline_without_rms(tmp_path, monkeypatch):
    path = tmp_path / "quiet.wav"
    audio = np.arange(48000, dtype=np.float32) / 48_000_000  # Entire waveform below RMS default.
    sf.write(path, audio, 16000, subtype="FLOAT")
    audio = read_audio(str(path))
    selection = manifest(audio, 16000, 32000)
    examined = []

    def get_logmel(samples, _config):
        examined.append(samples.copy())
        return samples

    model = SimpleNamespace(preprocessor_config=None, generate=lambda _mel: [SimpleNamespace(
        text="quiet speech", sentences=[SimpleNamespace(start=0.25, end=0.5, text="quiet speech")],
        tokens=[SimpleNamespace(start=0.25, end=0.5, text=" quiet")])])
    engine = Engine()
    monkeypatch.setattr(engine, "_load", lambda *_: (model, True))
    monkeypatch.setitem(sys.modules, "parakeet_mlx.audio", SimpleNamespace(get_logmel=get_logmel))
    # No real GPU/model: this test observes the actual engine slicing/offsets.
    core = SimpleNamespace(array=np.asarray, float32=np.float32, reset_peak_memory=lambda: None,
                           synchronize=lambda: None, get_peak_memory=lambda: 0, get_active_memory=lambda: 0)
    monkeypatch.setitem(sys.modules, "mlx.core", core)
    monkeypatch.setattr(mlx, "core", core, raising=False)
    result = engine.transcribe(str(path), trim=False, speech_edges=selection, word_timestamps=True)
    np.testing.assert_array_equal(examined[0].view(np.uint32), audio[16000:32000].view(np.uint32))
    assert result["audio_seconds"] == 3 and result["speech_seconds"] == 1
    assert result["segments"] == [dict(start=1.25, end=1.5, text="quiet speech")]
    assert result["words"][0]["start"] == 1.25 and result["words"][0]["end"] == 1.5
    assert result["speech_edges"] == selection and result["text"] == "quiet speech"


def test_meeting_validates_edges_before_diarizer_and_forwards_them_to_timed_asr(tmp_path, monkeypatch):
    audio = np.full(48000, 0.001, dtype=np.float32)
    path = tmp_path / "quiet.wav"
    sf.write(path, audio, 16000, subtype="FLOAT")
    selection = manifest(audio, 16000, 32000)
    engine = Engine()
    # Diarization sees the whole timeline; only ASR receives the outer range.
    class Diarizer:
        def generate(self, samples, **_kwargs):
            np.testing.assert_array_equal(samples, audio)
            return SimpleNamespace(segments=[SimpleNamespace(start=0, end=3, speaker=0)], num_speakers=1)

    def transcribe(_path, _model, _language, _vocabulary, **options):
        assert options == dict(trim=False, word_timestamps=True, speech_edges=selection)
        return dict(text="quiet", audio_seconds=3, speech_edges=selection,
                    words=[dict(start=1.25, end=1.5, text="quiet")])

    engine.diarizer = Diarizer()
    monkeypatch.setattr(engine, "transcribe", transcribe)
    monkeypatch.setitem(sys.modules, "mlx_audio.vad", SimpleNamespace(load=lambda *_: pytest.fail("Already loaded")))
    result = dispatch(engine, dict(action="meeting", path=str(path), trim=False, speech_edges=selection))
    assert result["words"][0]["start"] == 1.25 and result["words"][0]["speaker"] == 0
    with pytest.raises(ValueError):
        dispatch(engine, dict(action="meeting", path=str(path), trim=True, speech_edges=selection))
