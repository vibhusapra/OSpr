import shutil
import numpy as np
import pytest
import soundfile as sf
from ospr_backend.meeting_audio import mix_tracks


@pytest.mark.skipif(not shutil.which("ffmpeg"), reason="optional FFmpeg not installed")
def test_two_tracks_are_aligned_by_presentation_time_without_clipping(tmp_path):
    rate = 16000
    t = np.arange(rate) / rate
    first = (np.sin(2 * np.pi * 440 * t) * 0.2).astype(np.float32)
    second = (np.sin(2 * np.pi * 660 * t) * 0.2).astype(np.float32)
    a, b, out = [tmp_path / name for name in ["system.wav", "microphone.wav", "mix.wav"]]
    sf.write(a, first, rate, subtype="FLOAT")
    sf.write(b, second, rate, subtype="FLOAT")
    result = mix_tracks([{"path": str(a), "start": 1000.0}, {"path": str(b), "start": 1000.25}], str(out))
    actual, sampling_rate = sf.read(out, dtype="float32")
    expected = np.zeros(20000, dtype=np.float32)
    expected[:16000] += first * 0.5
    expected[4000:] += second * 0.5
    assert sampling_rate == rate and len(actual) == len(expected)
    np.testing.assert_allclose(actual, expected, atol=1e-5)
    assert result["tracks"] == 2 and result["audio_seconds"] == 1.25
    assert out.stat().st_mode & 0o777 == 0o600
    with pytest.raises(ValueError, match="fresh"):
        mix_tracks([{"path": str(a), "start": 0}], str(out))


def test_invalid_track_count_and_clock_fail_before_ffmpeg_launch(tmp_path, monkeypatch):
    # Validate bad tracks independently of whether this host installed the
    # optional mixer. No process should launch for either invalid request.
    monkeypatch.setattr("ospr_backend.meeting_audio.shutil.which", lambda _: "/unused/ffmpeg")
    with pytest.raises(ValueError):
        mix_tracks([], str(tmp_path / "mix.wav"))
    source = tmp_path / "input.wav"
    sf.write(source, np.zeros(16000), 16000)
    with pytest.raises(ValueError, match="clock"):
        mix_tracks([{"path": str(source), "start": float("nan")}], str(tmp_path / "mix.wav"))
