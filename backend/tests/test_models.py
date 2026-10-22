"""An interrupted cache download must not become permanently stuck cache-first."""

import pytest
import huggingface_hub
from huggingface_hub.errors import LocalEntryNotFoundError
from ospr_backend import engine


def test_pinned_artifact_manifest_has_weights_for_every_route():
    for spec in engine.MODEL_LOCK.values():
        assert len(spec["revision"]) == 40
        assert any(name.endswith((".safetensors", ".npz")) for name in spec["required_files"])
        assert spec["artifact_bytes"] == sum(spec["required_files"].values())
    assert "cohere-transcribe" not in engine.PUBLIC_MODELS


def test_partial_cache_repairs_online_but_never_contacts_hub_offline(tmp_path, monkeypatch):
    monkeypatch.setitem(
        engine.MODEL_LOCK,
        "fixture",
        {"repo": "fixture/repo", "revision": "a" * 40, "required_files": {"weights.npz": 3}},
    )
    calls = []

    def download(**kwargs):
        calls.append(kwargs["local_files_only"] if "local_files_only" in kwargs else False)
        if not kwargs.get("local_files_only"):
            (tmp_path / "weights.npz").write_bytes(b"abc")
        return str(tmp_path)

    monkeypatch.setattr(huggingface_hub, "snapshot_download", download)
    monkeypatch.setenv("HF_HUB_OFFLINE", "1")
    with pytest.raises(LocalEntryNotFoundError, match="incomplete"):
        engine.resolve_model("fixture")
    assert calls == [True]
    monkeypatch.delenv("HF_HUB_OFFLINE")
    assert engine.resolve_model("fixture") == str(tmp_path)
    assert calls == [True, True, False]
    monkeypatch.setenv("HF_HUB_OFFLINE", "1")
    assert engine.resolve_model("fixture") == str(tmp_path)
    assert calls[-1] is True
