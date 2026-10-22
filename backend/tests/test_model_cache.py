import json

from ospr_backend.model_cache import inventory, progress_bar
from ospr_backend import engine
from ospr_backend.worker import dispatch


def test_inventory_is_offline_pinned_size_checked_and_read_only(tmp_path, monkeypatch):
    import huggingface_hub

    monkeypatch.setattr(huggingface_hub, "snapshot_download", lambda **_: (_ for _ in ()).throw(AssertionError("Network/SDK lookup forbidden")))
    lock = {"fixture": {"repo": "test/fixture", "revision": "a" * 40,
                        "required_files": {"weights.bin": 5, "config.json": 2}, "artifact_bytes": 7}}
    missing = inventory(lock, ["fixture"], tmp_path)[0]
    assert not missing["complete"] and missing["verified_bytes"] == 0 and missing["path"] is None
    root = tmp_path / "models--test--fixture" / "snapshots" / ("a" * 40)
    root.mkdir(parents=True)
    blob = tmp_path / "shared-blob"
    blob.write_bytes(b"12345")
    (root / "weights.bin").symlink_to(blob)
    (root / "config.json").write_bytes(b"bad")
    partial = inventory(lock, ["fixture"], tmp_path)[0]
    assert not partial["complete"] and partial["verified_bytes"] == 5
    (root / "config.json").write_bytes(b"{}")
    complete = inventory(lock, ["fixture"], tmp_path)[0]
    assert complete["complete"] and complete["verified_bytes"] == 7
    blob.unlink()
    assert not inventory(lock, ["fixture"], tmp_path)[0]["complete"]
    assert (root / "weights.bin").is_symlink()  # No cache cleanup side effects.


def test_progress_counts_prepared_bytes_without_terminal_output(capsys):
    events = []
    bar = progress_bar(events.append)(total=100, desc="Reconstructing files", unit="B", mininterval=0)
    bar.update(20)
    bar.update(80)
    bar.close()
    assert events[0]["completed_bytes"] == 0
    assert events[-1] == {"phase": "download", "completed_bytes": 100, "total_bytes": 100}
    assert len(events) <= 4
    assert capsys.readouterr() == ("", "")
    json.dumps(events, allow_nan=False)


def test_download_only_never_loads_gpu_and_forbids_research_model(monkeypatch):
    from ospr_backend import worker
    import pytest

    calls = []
    class Fake:
        progress = None

        def warm(self, *args):
            raise AssertionError("Download-only must not load weights or run inference")

    monkeypatch.setattr(worker, "resolve_model", lambda model, callback: calls.append(model))
    result = dispatch(Fake(), {"action": "download_model", "model": "parakeet-v3"})
    assert result["complete"] and calls == ["parakeet-v3"]
    with pytest.raises(ValueError, match="Unknown shipping"):
        dispatch(Fake(), {"action": "download_model", "model": "cohere-transcribe"})


def test_online_repair_emits_stages_and_passes_sdk_progress(tmp_path, monkeypatch):
    import huggingface_hub
    from huggingface_hub.errors import LocalEntryNotFoundError

    monkeypatch.delenv("HF_HUB_OFFLINE", raising=False)
    monkeypatch.setitem(engine.MODEL_LOCK, "fixture", {"repo": "fixture/repo", "revision": "a" * 40, "required_files": {"weights.npz": 3}})
    events = []

    def download(**options):
        if options.get("local_files_only"):
            raise LocalEntryNotFoundError("missing fixture")
        bar = options["tqdm_class"](desc="Reconstruction", total=3, unit="B", mininterval=0)
        bar.update(3)
        bar.close()
        (tmp_path / "weights.npz").write_bytes(b"abc")
        return str(tmp_path)

    monkeypatch.setattr(huggingface_hub, "snapshot_download", download)
    assert engine.resolve_model("fixture", events.append) == str(tmp_path)
    assert events[0]["phase"] == "checking"
    assert any(event.get("completed_bytes") == 3 for event in events)


def test_worker_progress_survives_third_party_stdout_redirect(monkeypatch):
    from contextlib import redirect_stdout
    import io
    import sys
    from ospr_backend import worker

    captured = io.StringIO()
    input_bytes = io.BytesIO(b'{"id":"first","action":"warm","model":"parakeet-v3"}\n{"id":"second","action":"ping"}\n')
    class Input:
        buffer = input_bytes

    class FakeEngine:
        progress = None

        def warm(self, model):
            with redirect_stdout(sys.stderr):
                print("Third-party diagnostic")
                self.progress({"phase": "loading", "model": model})
            return {"ready": True}

    monkeypatch.setattr(worker, "Engine", FakeEngine)
    monkeypatch.setattr(sys, "stdin", Input())
    monkeypatch.setattr(sys, "stdout", captured)
    monkeypatch.setattr(worker.os, "setsid", lambda: None)
    worker.main()
    frames = [json.loads(line) for line in captured.getvalue().splitlines()]
    assert len(frames) == 3
    assert frames[0]["id"] == "first" and frames[0]["event"] == "progress"
    assert frames[1]["ok"] and frames[1]["result"]["ready"]
    assert frames[2]["id"] == "second" and frames[2]["ok"]
