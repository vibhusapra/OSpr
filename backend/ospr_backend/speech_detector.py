"""Pinned Core ML data for the native optional auto-finish path; no inference."""

import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import tempfile
import uuid

SPEC = json.loads(Path(__file__).with_name("speech-detector.lock.json").read_text())
IDENTIFIER = "speech-detector"


def valid(path, item):
    try:
        return path.is_file() and path.stat().st_size == item["size"] and hashlib.sha256(path.read_bytes()).hexdigest() == item["sha256"]
    except OSError:
        return False


def cache_paths(cache_root=None):
    if cache_root is None:
        from huggingface_hub.constants import HF_HUB_CACHE

        cache_root = HF_HUB_CACHE
    # Paths cross the worker/native IPC boundary; do not return a path whose
    # meaning depends on the worker's different working directory.
    base = Path(cache_root).expanduser().resolve()
    shared = base / ("models--" + SPEC["repo"].replace("/", "--")) / "snapshots" / SPEC["revision"]
    owned = base / ".ospr-native-speech" / SPEC["revision"]
    return shared, owned


def selected_root(cache_root=None):
    shared, owned = cache_paths(cache_root)
    marker = owned / "current"
    if marker.exists() or marker.is_symlink():
        try:
            if marker.is_symlink() or owned.is_symlink() or owned.parent.is_symlink():
                return None, "invalid-owned-cache"
            with marker.open("rb") as file:
                token = file.read(65).decode("ascii").strip()
            if re.fullmatch(r"[0-9a-f]{32}", token):
                root = owned / token
                if root.is_dir() and not root.is_symlink():
                    return root, "ospr-verified"
        except (OSError, UnicodeError):
            pass
        return None, "invalid-owned-cache"
    return shared, "hub-read-only"


def inventory(cache_root=None):
    root, kind = selected_root(cache_root)
    present = [item for item in SPEC["files"] if root is not None and valid(root / item["path"], item)]
    return dict(id=IDENTIFIER, repo=SPEC["repo"], revision=SPEC["revision"],
                required_bytes=sum(item["size"] for item in SPEC["files"]),
                verified_bytes=sum(item["size"] for item in present), complete=len(present) == len(SPEC["files"]),
                path=str(root) if root is not None and root.is_dir() else None, cache_kind=kind)


def install_verified(state, progress):
    from huggingface_hub import hf_hub_download
    from huggingface_hub.constants import HF_HUB_OFFLINE

    _, owned = cache_paths()
    for directory in [owned.parent, owned]:
        if directory.is_symlink():
            raise ValueError("The OSpr speech cache must be a real private directory.")
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix=".stage-", dir=owned))
    current = Path(state["path"]) if state["path"] else None
    copied = 0
    try:
        with tempfile.TemporaryDirectory(prefix="ospr-speech-download-") as download:
            for item in SPEC["files"]:
                path = current / item["path"] if current else None
                if path is None or not valid(path, item):
                    if progress:
                        progress(dict(phase="download", model=IDENTIFIER, completed_bytes=copied,
                                      total_bytes=state["required_bytes"]))
                    # A forced hub-cache request can still return a corrupt
                    # snapshot. A fresh local_dir avoids that snapshot, and we
                    # install only verified known files into our own directory.
                    path = Path(hf_hub_download(repo_id=SPEC["repo"], filename=item["path"], revision=SPEC["revision"],
                                               token=False, force_download=not HF_HUB_OFFLINE, local_dir=download))
                if not valid(path, item):
                    raise ValueError("The speech detector failed its pinned size/SHA-256 check. Reconnect to repair its download.")
                destination = stage / item["path"]
                destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                shutil.copyfile(path, destination)
                destination.chmod(0o600)
                if not valid(destination, item):
                    raise ValueError("The staged speech detector failed its pinned integrity check.")
                copied += item["size"]
        token = uuid.uuid4().hex
        # Unique immutable versions avoid replacing directories a live native
        # model may still be reading. Only the small locator changes atomically.
        os.replace(stage, owned / token)
        marker = owned / (".current-" + token)
        with os.fdopen(os.open(marker, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "wb") as file:
            file.write((token + "\n").encode("ascii"))
        os.replace(marker, owned / "current")
    finally:
        shutil.rmtree(stage, ignore_errors=True)


def prepare(download=False, progress=None):
    if not isinstance(download, bool):
        raise ValueError("Speech detector download must be an explicit boolean.")
    state = inventory()
    if progress:
        progress(dict(phase="checking", model=IDENTIFIER))
    if not state["complete"] and not download:
        raise ValueError("Prepare the local speech detector in Models before enabling neural auto finish. Cached files are missing or failed verification.")
    if not state["complete"]:
        install_verified(state, progress)
        state = inventory()
    if not state["complete"]:
        raise ValueError("The speech detector is incomplete. Reconnect and prepare it again.")
    if progress:
        progress(dict(phase="download", model=IDENTIFIER, completed_bytes=state["required_bytes"], total_bytes=state["required_bytes"]))
    return dict(state, model_path=str(Path(state["path"]) / SPEC["subfolder"]))
