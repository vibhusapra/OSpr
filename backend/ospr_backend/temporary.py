"""Private transient audio with next-launch cleanup after an interrupted worker."""
from contextlib import contextmanager
import os
from pathlib import Path
import re
import shutil
import stat
import tempfile

_cleaned = set()


def private_root():
    root = Path(tempfile.gettempdir()) / 'OSpr-Engine'
    root.mkdir(mode=0o700, exist_ok=True)
    attributes = root.lstat()
    if stat.S_ISLNK(attributes.st_mode) or not stat.S_ISDIR(attributes.st_mode) or attributes.st_uid != os.getuid():
        raise ValueError('Private temporary audio directory has an unexpected owner or type.')
    root.chmod(0o700)
    if root not in _cleaned:
        cleanup_stale(root)
        _cleaned.add(root)
    return root


def cleanup_stale(root):
    for directory in root.iterdir():
        if not re.fullmatch(r'[1-9][0-9]*-[a-zA-Z0-9_-]+', directory.name):
            continue
        try:
            attributes = directory.lstat()
        except FileNotFoundError:
            continue  # Another local worker may be cleaning the same orphan.
        if stat.S_ISLNK(attributes.st_mode) or not stat.S_ISDIR(attributes.st_mode) or attributes.st_uid != os.getuid():
            continue
        pid = int(directory.name.split('-', 1)[0])
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            shutil.rmtree(directory, ignore_errors=True)
        except (PermissionError, OverflowError):
            continue


@contextmanager
def private_audio_file():
    with tempfile.TemporaryDirectory(prefix=f'{os.getpid()}-', dir=private_root()) as directory:
        with tempfile.NamedTemporaryFile(suffix='.wav', dir=directory) as audio:
            yield audio
