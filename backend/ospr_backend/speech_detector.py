"""Pinned Core ML data for the native optional auto-finish path; no inference."""

import hashlib
import json
from pathlib import Path

SPEC = json.loads(Path(__file__).with_name("speech-detector.lock.json").read_text())
IDENTIFIER = "speech-detector"


def valid(path, item):
    try:
        return path.is_file() and path.stat().st_size == item["size"] and hashlib.sha256(path.read_bytes()).hexdigest() == item["sha256"]
    except OSError:
        return False


def inventory(cache_root=None):
    if cache_root is None:
        from huggingface_hub.constants import HF_HUB_CACHE

        cache_root = HF_HUB_CACHE
    root = Path(cache_root) / ("models--" + SPEC["repo"].replace("/", "--")) / "snapshots" / SPEC["revision"]
    present = [item for item in SPEC["files"] if valid(root / item["path"], item)]
    return dict(id=IDENTIFIER, repo=SPEC["repo"], revision=SPEC["revision"],
                required_bytes=sum(item["size"] for item in SPEC["files"]),
                verified_bytes=sum(item["size"] for item in present), complete=len(present) == len(SPEC["files"]),
                path=str(root) if root.is_dir() else None)


def prepare(download=False, progress=None):
    if not isinstance(download, bool):
        raise ValueError("Speech detector download must be an explicit boolean.")
    state = inventory()
    if progress:
        progress(dict(phase="checking", model=IDENTIFIER))
    if not state["complete"] and not download:
        raise ValueError("Prepare the local speech detector in Models before enabling neural auto finish. Cached files are missing or failed verification.")
    if not state["complete"]:
        from huggingface_hub import hf_hub_download
        from huggingface_hub.constants import HF_HUB_OFFLINE

        for item in SPEC["files"]:
            current = Path(state["path"]) / item["path"] if state["path"] else None
            if current is not None and valid(current, item):
                continue
            if progress:
                progress(dict(phase="download", model=IDENTIFIER,
                              completed_bytes=inventory()["verified_bytes"], total_bytes=state["required_bytes"]))
            # Repair corrupted pinned data only through the normal hub API;
            # never delete the shared cache or execute repository Python code.
            path = Path(hf_hub_download(repo_id=SPEC["repo"], filename=item["path"], revision=SPEC["revision"],
                                       token=False, force_download=not HF_HUB_OFFLINE))
            if not valid(path, item):
                raise ValueError("The speech detector failed its pinned size/SHA-256 check. Reconnect to repair its download.")
            state = inventory()
        state = inventory()
    if not state["complete"]:
        raise ValueError("The speech detector is incomplete. Reconnect and prepare it again.")
    if progress:
        progress(dict(phase="download", model=IDENTIFIER, completed_bytes=state["required_bytes"], total_bytes=state["required_bytes"]))
    return dict(state, model_path=str(Path(state["path"]) / SPEC["subfolder"]))
