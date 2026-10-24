import hashlib
import numpy as np
import pytest
import soundfile as sf
from ospr_backend.upload_audio import MAX_UPLOAD_BYTES, prepare_upload
from ospr_backend.worker import dispatch
from ospr_backend.upload_audio import prepare_upload_parts
from ospr_backend.temporary import private_root
import os


@pytest.fixture
def workspace(tmp_path, monkeypatch):
    monkeypatch.setattr("ospr_backend.temporary.tempfile.gettempdir", lambda: str(tmp_path))
    directory = private_root() / f"{os.getpid()}-upload-test"
    directory.mkdir(mode=0o700)
    return directory


def test_split_upload_preserves_every_sample_and_all_silence(tmp_path, workspace):
    # More than one part at the production 600s setting; 50ms silence windows
    # and repeated content must remain present, without overlapping or dropping.
    original = np.tile(np.array([0, .125, -.375, 1, -1, 0, 0, 0], dtype=np.float32), 16000 * 605 // 8)
    source = tmp_path / "long.wav"
    sf.write(source, original, 16000, subtype="FLOAT")
    before = hashlib.sha256(source.read_bytes()).digest()
    result = dispatch(None, dict(action="prepare_upload_parts", path=str(source), output_dir=str(workspace)))
    assert len(result["parts"]) == 2 and result["frames"] == len(original)
    offset, decoded = 0, []
    for part in result["parts"]:
        assert part["start_frame"] == offset and part["frames"] <= 600 * 16000
        path = workspace / os.path.basename(part["path"])
        assert path.stat().st_mode & 0o777 == 0o600 and path.stat().st_size < MAX_UPLOAD_BYTES
        audio, rate = sf.read(path, dtype="float32")
        assert rate == 16000 and len(audio) == part["frames"]
        offset += len(audio)
        decoded.append(audio)
    assert offset == len(original)
    assert np.max(np.abs(np.concatenate(decoded) - original)) <= 1 / 32768
    assert hashlib.sha256(source.read_bytes()).digest() == before


def test_split_encoding_failure_removes_only_new_parts(tmp_path, workspace, monkeypatch):
    source = tmp_path / "original.wav"
    source.write_bytes(b"preserve")
    monkeypatch.setattr("ospr_backend.upload_audio.read_audio", lambda _: np.zeros(9 * 16000, dtype=np.float32))
    monkeypatch.setattr("ospr_backend.upload_audio.MAX_UPLOAD_PART_SECONDS", 6)
    write, calls = sf.write, []
    def fail_second(*args, **kwargs):
        calls.append(args[0])
        if len(calls) == 2:
            raise OSError("Disk full")
        return write(*args, **kwargs)
    monkeypatch.setattr("ospr_backend.upload_audio.sf.write", fail_second)
    with pytest.raises(OSError, match="Disk full"):
        prepare_upload_parts(source, workspace)
    assert len(calls) == 2 and list(workspace.iterdir()) == [] and source.read_bytes() == b"preserve"


def test_split_workspace_rejects_existing_contents_without_touching_them(tmp_path, workspace):
    sentinel = workspace / "keep.txt"
    sentinel.write_bytes(b"keep")
    with pytest.raises(ValueError, match="empty"):
        prepare_upload_parts(tmp_path / "missing.wav", workspace)
    assert sentinel.read_bytes() == b"keep"


def test_split_workspace_rejects_links_and_nonprivate_permissions(tmp_path, workspace):
    link = workspace.parent / f"{os.getpid()}-upload-link"
    link.symlink_to(workspace, target_is_directory=True)
    with pytest.raises(ValueError, match="private"):
        prepare_upload_parts(tmp_path / "missing.wav", link)
    workspace.chmod(0o755)
    with pytest.raises(ValueError, match="private"):
        prepare_upload_parts(tmp_path / "missing.wav", workspace)
    assert link.is_symlink() and list(workspace.iterdir()) == []


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
