import hashlib
import shutil
import subprocess

import numpy as np
import pytest
import soundfile as sf

from ospr_backend.audio import read_audio
from ospr_backend.review_audio import prepare_review
from ospr_backend.worker import dispatch


def test_review_preserves_every_normalized_float_sample_and_full_timeline(tmp_path):
    source, output = tmp_path / "source.wav", tmp_path / "review.wav"
    time = np.arange(48000 * 2) / 48000
    stereo = np.stack([0.001 * np.sin(time * 2 * np.pi * 440), 0.1 * np.sin(time * 2 * np.pi * 660)], axis=1).astype(np.float32)
    stereo[:4800] = 0  # Leading silence must not be trimmed out of the review timeline.
    sf.write(source, stereo, 48000, subtype="FLOAT")
    before = hashlib.sha256(source.read_bytes()).hexdigest()
    expected = read_audio(str(source))
    result = dispatch(None, dict(action="prepare_review", path=str(source), output=str(output), limit_bytes=1024**2))
    actual = read_audio(str(output))
    assert np.array_equal(expected.view(np.uint32), actual.view(np.uint32))
    assert result["audio_seconds"] == 2 and result["source_unchanged"]
    assert result["normalized_samples"] == len(expected)
    assert result["pcm_sha256"] == hashlib.sha256(expected.astype("<f4").tobytes()).hexdigest()
    assert sf.info(output).subtype == "FLOAT" and sf.info(output).samplerate == 16000
    assert output.stat().st_mode & 0o777 == 0o600
    assert hashlib.sha256(source.read_bytes()).hexdigest() == before
    with pytest.raises(ValueError, match="fresh"):
        prepare_review(source, output, 1024**2)


def test_movie_retention_contains_audio_only_and_no_original_tags(tmp_path):
    if shutil.which("ffmpeg") is None:
        pytest.skip("FFmpeg required for actual movie normalization")
    source, output = tmp_path / "source.mp4", tmp_path / "review.wav"
    subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "color=c=black:s=32x32:d=1", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=1", "-shortest", "-c:v", "mpeg4", "-c:a", "aac", "-metadata", "title=PRIVATE_TEST_TITLE", str(source)], check=True, timeout=30)
    before = hashlib.sha256(source.read_bytes()).hexdigest()
    expected = read_audio(str(source))
    prepare_review(source, output, 1024**2)
    assert np.array_equal(read_audio(str(output)).view(np.uint32), expected.view(np.uint32))
    assert b"PRIVATE_TEST_TITLE" not in output.read_bytes()
    assert output.read_bytes()[:4] == b"RIFF" and sf.info(output).channels == 1
    assert hashlib.sha256(source.read_bytes()).hexdigest() == before


def test_budget_rejection_and_failed_encoder_do_not_touch_source_or_existing_output(tmp_path, monkeypatch):
    source, output = tmp_path / "source.wav", tmp_path / "review.wav"
    sf.write(source, np.zeros(16000, dtype=np.float32), 16000, subtype="FLOAT")
    original = source.read_bytes()
    with pytest.raises(ValueError, match="budget"):
        prepare_review(source, output, 1024)
    assert not output.exists()

    def fail(*args, **kwargs):
        raise RuntimeError("codec failure")

    monkeypatch.setattr("ospr_backend.review_audio.sf.write", fail)
    with pytest.raises(RuntimeError, match="codec failure"):
        prepare_review(source, output, 1024**2)
    assert not output.exists() and source.read_bytes() == original
    output.write_bytes(b"existing output")
    with pytest.raises(ValueError, match="fresh"):
        prepare_review(source, output, 1024**2)
    assert output.read_bytes() == b"existing output"


@pytest.mark.parametrize("budget", [-1, True, 1023, 9 * 1024**3])
def test_invalid_budget_fails_before_reading_any_source(tmp_path, budget):
    with pytest.raises(ValueError, match="budget"):
        prepare_review(tmp_path / "missing.wav", tmp_path / "unused.wav", budget)
