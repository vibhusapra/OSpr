import hashlib
import numpy as np
import pytest
import soundfile as sf
from ospr_backend.upload_audio import MAX_UPLOAD_BYTES, prepare_upload
from ospr_backend.worker import dispatch


def test_oversized_stereo_take_becomes_small_upload_without_losing_time_or_source(tmp_path):
    source, output = tmp_path / "original.wav", tmp_path / "upload.wav"
    rate, seconds = 48000, 70
    time = np.arange(rate * seconds) / rate
    stereo = np.stack(
        [0.1 * np.sin(2 * np.pi * 440 * time), 0.1 * np.sin(2 * np.pi * 660 * time)], axis=1
    ).astype(np.float32)
    sf.write(source, stereo, rate, subtype="FLOAT")
    assert source.stat().st_size > MAX_UPLOAD_BYTES
    before = hashlib.sha256(source.read_bytes()).hexdigest()
    result = dispatch(None, dict(action="prepare_upload", path=str(source), output=str(output)))
    assert result["source_unchanged"] and result["bytes"] < MAX_UPLOAD_BYTES
    assert result["audio_seconds"] == seconds
    audio, decoded_rate = sf.read(output)
    assert decoded_rate == 16000 and audio.ndim == 1 and len(audio) == seconds * 16000
    expected = 0.05 * np.sin(2 * np.pi * 440 * np.arange(len(audio)) / 16000) + 0.05 * np.sin(
        2 * np.pi * 660 * np.arange(len(audio)) / 16000
    )
    assert np.corrcoef(audio[100:-100], expected[100:-100])[0, 1] > 0.9999
    assert output.stat().st_mode & 0o777 == 0o600
    assert hashlib.sha256(source.read_bytes()).hexdigest() == before
    with pytest.raises(ValueError, match="fresh"):
        prepare_upload(source, output)


def test_excessively_long_upload_fails_before_output_creation(tmp_path, monkeypatch):
    source = tmp_path / "input.wav"
    source.write_bytes(b"preserve")
    output = tmp_path / "upload.wav"

    class Oversized:
        def __len__(self):
            return MAX_UPLOAD_BYTES // 2 + 1

    monkeypatch.setattr("ospr_backend.upload_audio.read_audio", lambda _: Oversized())
    with pytest.raises(ValueError, match="25 MB"):
        prepare_upload(source, output)
    assert not output.exists() and source.read_bytes() == b"preserve"


def test_failed_encoding_removes_only_the_owned_output(tmp_path, monkeypatch):
    source = tmp_path / "input.wav"
    source.write_bytes(b"preserve")
    output = tmp_path / "upload.wav"
    monkeypatch.setattr("ospr_backend.upload_audio.read_audio", lambda _: np.zeros(16000, dtype=np.float32))

    def fail(*args, **kwargs):
        raise RuntimeError("encoder failed")

    monkeypatch.setattr("ospr_backend.upload_audio.sf.write", fail)
    with pytest.raises(RuntimeError, match="encoder failed"):
        prepare_upload(source, output)
    assert not output.exists() and source.read_bytes() == b"preserve"
