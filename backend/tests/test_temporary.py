import os
from pathlib import Path
import pytest
from ospr_backend.temporary import cleanup_stale, private_audio_file


def test_private_audio_removed_even_on_exception(tmp_path, monkeypatch):
    monkeypatch.setattr('ospr_backend.temporary.tempfile.gettempdir', lambda: str(tmp_path))
    with pytest.raises(RuntimeError):
        with private_audio_file() as audio:
            path = Path(audio.name)
            audio.write(b'speech')
            assert path.stat().st_mode & 0o777 == 0o600
            assert path.parent.stat().st_mode & 0o777 == 0o700
            assert path.parent.parent.stat().st_mode & 0o777 == 0o700
            raise RuntimeError('cancelled')
    assert not path.exists() and not path.parent.exists()


def test_orphan_cleanup_keeps_live_workers_and_symlinks(tmp_path):
    dead = tmp_path / '2147483647-dead'
    dead.mkdir()
    (dead / 'audio.wav').write_bytes(b'speech')
    live = tmp_path / f'{os.getpid()}-live'
    live.mkdir()
    outside = tmp_path / 'unrelated'
    outside.mkdir()
    sentinel = outside / 'keep.wav'
    sentinel.write_bytes(b'keep')
    link = tmp_path / '2147483646-link'
    link.symlink_to(outside, target_is_directory=True)
    cleanup_stale(tmp_path)
    assert not dead.exists()
    assert live.exists() and sentinel.read_bytes() == b'keep' and link.is_symlink()
