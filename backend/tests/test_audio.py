import numpy as np
import pytest
import soundfile as sf

from ospr_backend.audio import read_audio, speech_bounds


@pytest.mark.parametrize("rate", [8000, 16000, 44100, 48000])
@pytest.mark.parametrize("channels", [1, 2])
def test_normalizes_audio_once(tmp_path, rate, channels):
    t = np.arange(rate) / rate
    mono = np.sin(t * 2 * np.pi * 440).astype(np.float32) * 0.1
    audio = mono if channels == 1 else np.stack([mono, mono], axis=1)
    path = tmp_path / "audio.wav"
    sf.write(path, audio, rate)
    result = read_audio(str(path))
    assert result.shape == (16000,)
    assert result.dtype == np.float32
    assert result.flags.c_contiguous
    assert np.isfinite(result).all()
    assert np.max(np.abs(result)) < 0.11


def test_bounds_preserve_interior_silence():
    audio = np.concatenate(
        [np.zeros(16000), np.ones(16000) * 0.1, np.zeros(16000), np.ones(16000) * 0.1, np.zeros(16000)]
    ).astype(np.float32)
    start, end = speech_bounds(audio)
    assert start == 13440
    assert end == 66560
    assert end - start > 48000


def test_silence_and_low_noise_are_empty():
    assert speech_bounds(np.zeros(16000)) == (0, 0)
    assert speech_bounds(np.ones(16000) * 0.0001) == (0, 0)
    assert speech_bounds(np.array([])) == (0, 0)


def test_empty_file_is_rejected(tmp_path):
    path = tmp_path / "empty.wav"
    sf.write(path, np.array([], dtype=np.float32), 16000)
    with pytest.raises(ValueError, match="one sample"):
        read_audio(str(path))


def test_nonfinite_audio_is_rejected(tmp_path):
    path = tmp_path / "nan.wav"
    sf.write(path, np.array([0, np.nan, np.inf]), 16000, subtype="FLOAT")
    with pytest.raises(ValueError, match="non-finite"):
        read_audio(str(path))


def test_arbitrary_urls_never_open():
    with pytest.raises(FileNotFoundError):
        read_audio("https://example.com/audio.wav")


def test_compressed_local_media_decodes_without_network(tmp_path):
    import shutil
    import subprocess

    if not shutil.which("ffmpeg") or not shutil.which("ffprobe"):
        pytest.skip("optional FFmpeg is not installed")
    original = tmp_path / "input.wav"
    sf.write(original, (np.sin(np.arange(48000) * 2 * np.pi * 440 / 48000) * 0.1).astype(np.float32), 48000)
    compressed = tmp_path / "local.m4a"
    subprocess.run(
        ["ffmpeg", "-nostdin", "-v", "error", "-i", str(original), "-c:a", "aac", str(compressed)], check=True
    )
    audio = read_audio(str(compressed))
    assert 15500 < len(audio) < 17000
    assert audio.dtype == np.float32
    assert np.isfinite(audio).all()
    # AAC is lossy; compare its interior against the expected waveform.
    expected = np.sin(np.arange(len(audio)) * 2 * np.pi * 440 / 16000) * 0.1
    assert np.corrcoef(audio[200:15000], expected[200:15000])[0, 1] > 0.98


def test_large_native_rate_audio_is_normalized_before_full_allocation(tmp_path, monkeypatch):
    from types import SimpleNamespace
    path = tmp_path / 'large.wav'
    path.write_bytes(b'fixture')
    monkeypatch.setattr('ospr_backend.audio.sf.info', lambda _: SimpleNamespace(duration=3600, frames=3600*96000, channels=8, samplerate=96000))
    calls = []
    def bounded(source):
        calls.append(source)
        return np.zeros(16000, dtype=np.float32)
    monkeypatch.setattr('ospr_backend.audio._decode_with_ffmpeg', bounded)
    assert len(read_audio(str(path))) == 16000
    assert calls == [path.resolve()]


def test_large_already_normalized_audio_does_not_reenter_ffmpeg(tmp_path, monkeypatch):
    from types import SimpleNamespace
    path = tmp_path / "already-normalized.wav"
    path.write_bytes(b"fixture")
    frames = 256 * 1024 * 1024 // 4 + 1
    monkeypatch.setattr("ospr_backend.audio.sf.info", lambda _: SimpleNamespace(duration=frames / 16000, frames=frames, channels=1, samplerate=16000))
    samples = np.array([-.125, 0, .25], dtype=np.float32)
    monkeypatch.setattr("ospr_backend.audio.sf.read", lambda *args, **kwargs: (samples, 16000))
    def fail(_): raise AssertionError("Already-normalized input would recursively decode")
    monkeypatch.setattr("ospr_backend.audio._decode_with_ffmpeg", fail)
    assert read_audio(str(path)) is samples
