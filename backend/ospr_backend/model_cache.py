"""Read-only pinned-cache inventory and protocol-safe weight preparation progress."""

from pathlib import Path
import io
import threading
import time


def inventory(lock, model_ids, cache_root=None):
    # Reading known pinned paths avoids a hub request and scanning unrelated caches.
    if cache_root is None:
        from huggingface_hub.constants import HF_HUB_CACHE

        cache_root = HF_HUB_CACHE
    rows = []
    for model_id in model_ids:
        entry = lock[model_id]
        snapshot = Path(cache_root) / ("models--" + entry["repo"].replace("/", "--")) / "snapshots" / entry["revision"]
        directory = snapshot / entry.get("subfolder", "")
        verified = 0
        present = 0
        for name, size in entry["required_files"].items():
            try:
                file = directory / name
                if file.is_file() and file.stat().st_size == size:
                    verified += size
                    present += 1
            except OSError:
                pass  # Concurrent cache repair/removal is a missing artifact.
        rows.append({
            "id": model_id, "repo": entry["repo"], "revision": entry["revision"],
            "required_bytes": entry["artifact_bytes"], "verified_bytes": verified,
            "complete": present == len(entry["required_files"]),
            "path": str(snapshot) if snapshot.is_dir() else None,
        })
    return rows


def progress_bar(callback):
    """HF's aggregate reconstruction bytes include cached bytes, not network traffic.

    Suppress terminal drawing; events remain bounded even with parallel downloads.
    A changing total is expected while the hub enumerates individual files.
    """
    from tqdm.auto import tqdm

    lock = threading.Lock()
    last = [0.0]

    class Progress(tqdm):
        def __init__(self, *args, **kwargs):
            kwargs["disable"] = False  # Still count updates when terminal bars are disabled.
            kwargs["file"] = io.StringIO()
            super().__init__(*args, **kwargs)

        def display(self, *args, **kwargs):
            if self.unit != "B" or "reconstr" not in self.desc.lower():
                return
            with lock:
                now = time.monotonic()
                if now - last[0] < 0.15 and (not self.total or self.n < self.total):
                    return
                last[0] = now
                callback({"phase": "download", "completed_bytes": int(self.n), "total_bytes": int(self.total or 0)})

    return Progress
