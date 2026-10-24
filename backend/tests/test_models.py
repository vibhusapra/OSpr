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
    assert engine.PUBLIC_MODELS["cohere-native8"]["repo"] == "littoralai/cohere-transcribe-mlx-8bit"
    assert engine.MODEL_LOCK["cohere-native8"]["safetensor_sha256"] == "aadaf8d3388975853385400c9bd8dee92a71e12a83860f35bebaac345aa8af93"


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


def test_explicit_warmup_primes_once_and_discards_synthetic_output(monkeypatch):
    from ospr_backend.engine import Engine
    from ospr_backend.audio import read_audio
    engine = Engine()
    calls = []
    monkeypatch.setattr(engine, '_load', lambda model: (None, False))
    def transcribe(path, model, language, trim):
        audio = read_audio(path)
        assert len(audio) == 16000 and language == 'en' and not trim
        calls.append(model)
        return {'text': 'discard this synthetic result'}
    monkeypatch.setattr(engine, 'transcribe', transcribe)
    first = engine.warm('parakeet-v3')
    second = engine.warm('parakeet-v3')
    assert calls == ['parakeet-v3'] and second['prime_ms'] == 0
    assert first['prime_ms'] > 0 and 'text' not in first
