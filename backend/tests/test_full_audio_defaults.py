"""Full-audio defaults must reach ASR without an implicit level gate."""
import sys
from types import SimpleNamespace

import mlx
import numpy as np
import pytest
import soundfile as sf

from ospr_backend.audio import read_audio
from ospr_backend.engine import Engine
from ospr_backend.worker import dispatch


@pytest.mark.parametrize("gain", [1e-3, 1e-6, 1e-12])
@pytest.mark.parametrize("through_worker", [False, True])
def test_nonzero_quiet_audio_reaches_asr_unchanged(tmp_path, monkeypatch, gain, through_worker):
    audio = np.zeros(16000, dtype=np.float32)
    audio[4000:12000] = gain * np.sin(np.arange(8000) * 0.1)
    path = tmp_path / "quiet.wav"
    sf.write(path, audio, 16000, subtype="FLOAT")
    expected = read_audio(str(path))
    examined = []
    model = SimpleNamespace(preprocessor_config=None, generate=lambda _: [SimpleNamespace(
        text="quiet words", sentences=[SimpleNamespace(start=0.25, end=0.75, text="quiet words")])])
    engine = Engine()
    monkeypatch.setattr(engine, "_load", lambda _: (model, True))
    monkeypatch.setitem(sys.modules, "parakeet_mlx.audio", SimpleNamespace(
        get_logmel=lambda samples, _: examined.append(samples.copy()) or samples))
    core = SimpleNamespace(array=np.asarray, float32=np.float32, reset_peak_memory=lambda: None,
                           synchronize=lambda: None, get_peak_memory=lambda: 0, get_active_memory=lambda: 0)
    monkeypatch.setitem(sys.modules, "mlx.core", core)
    monkeypatch.setattr(mlx, "core", core, raising=False)
    result = (dispatch(engine, dict(action="transcribe", path=str(path))) if through_worker
              else engine.transcribe(str(path)))
    assert result["text"] == "quiet words"
    assert result["speech_seconds"] == result["audio_seconds"] == 1
    np.testing.assert_array_equal(examined[0], expected)
    assert result["segments"] == [dict(start=0.25, end=0.75, text="quiet words")]


@pytest.mark.parametrize("action", ["meeting", "transcribe"])
@pytest.mark.parametrize("trim", [False, True])
def test_exact_zero_input_skips_models_and_explains_empty_result(tmp_path, monkeypatch, action, trim):
    path = tmp_path / "zero.wav"
    sf.write(path, np.zeros(16000, dtype=np.float32), 16000, subtype="FLOAT")
    engine = Engine()
    monkeypatch.setattr(engine, "_load", lambda _: pytest.fail("Zero samples reached ASR"))
    result = dispatch(engine, dict(action=action, path=str(path), trim=trim))
    assert result["silence"] and result["text"] == ""
    assert result["empty_reason"] == ("volume_filter_abstained" if trim else "normalized_zero")
    assert not engine.models and engine.diarizer is None


@pytest.mark.parametrize("action", ["meeting", "transcribe"])
def test_explicit_volume_filter_reports_abstention(tmp_path, action):
    path = tmp_path / "quiet.wav"
    sf.write(path, np.full(16000, 1e-6, dtype=np.float32), 16000, subtype="FLOAT")
    result = dispatch(Engine(), dict(action=action, path=str(path), trim=True))
    assert result["text"] == "" and result["empty_reason"] == "volume_filter_abstained"
