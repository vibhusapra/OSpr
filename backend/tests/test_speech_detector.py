import hashlib
import json
from pathlib import Path
import re
from types import SimpleNamespace

import pytest

from ospr_backend import speech_detector as detector
from ospr_backend.worker import dispatch


@pytest.fixture
def cache(tmp_path, monkeypatch):
    import huggingface_hub.constants as constants

    monkeypatch.setattr(constants, "HF_HUB_CACHE", str(tmp_path))
    spec = dict(repo="fixture/speech", revision="a" * 40, subfolder="speech.mlmodelc",
                files=[dict(path="speech.mlmodelc/model.mil", size=3, sha256=hashlib.sha256(b"abc").hexdigest())])
    monkeypatch.setattr(detector, "SPEC", spec)
    root = tmp_path / "models--fixture--speech" / "snapshots" / spec["revision"]
    file = root / spec["files"][0]["path"]
    return root, file


def test_inventory_checks_same_size_corruption_and_never_calls_sdk(cache, monkeypatch):
    import huggingface_hub

    monkeypatch.setattr(huggingface_hub, "hf_hub_download", lambda **_: pytest.fail("Inventory must be offline/read-only"))
    root, file = cache
    assert not detector.inventory()["complete"]
    file.parent.mkdir(parents=True)
    file.write_bytes(b"abc")
    good = detector.inventory()
    assert good["complete"] and good["verified_bytes"] == good["required_bytes"] == 3
    file.write_bytes(b"abd")
    assert not detector.inventory()["complete"] and detector.inventory()["verified_bytes"] == 0
    assert file.read_bytes() == b"abd"
    assert root.exists()


def test_cached_prepare_uses_no_sdk_or_gpu_and_accepts_shared_blob_symlink(cache, monkeypatch):
    import huggingface_hub

    monkeypatch.setattr(huggingface_hub, "hf_hub_download", lambda **_: pytest.fail("Cached preparation must not access SDK/network"))
    root, file = cache
    file.parent.mkdir(parents=True)
    blob = root.parent / "blob"
    blob.write_bytes(b"abc")
    file.symlink_to(blob)
    result = detector.prepare()
    assert result["complete"] and result["model_path"] == str(file.parent)
    assert file.is_symlink() and blob.read_bytes() == b"abc"


def test_capture_preparation_never_repairs_missing_or_corrupt_cache(cache, monkeypatch):
    import huggingface_hub

    monkeypatch.setattr(huggingface_hub, "hf_hub_download", lambda **_: pytest.fail("Microphone start must not download"))
    _, file = cache
    with pytest.raises(ValueError, match="Prepare the local"):
        detector.prepare(download=False)
    file.parent.mkdir(parents=True)
    file.write_bytes(b"bad")
    with pytest.raises(ValueError, match="Prepare the local"):
        detector.prepare()
    assert file.read_bytes() == b"bad"
    for invalid in ["true", 1, None]:
        with pytest.raises(ValueError, match="explicit boolean"):
            detector.prepare(download=invalid)


def test_explicit_download_repairs_exact_pinned_data_without_auth(cache, monkeypatch):
    import huggingface_hub
    import huggingface_hub.constants as constants

    monkeypatch.setattr(constants, "HF_HUB_OFFLINE", False)
    _, file = cache
    file.parent.mkdir(parents=True)
    file.write_bytes(b"bad")
    calls, events = [], []

    def fetch(**kwargs):
        calls.append(kwargs)
        output = Path(kwargs["local_dir"]) / kwargs["filename"]
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_bytes(b"abc")
        return str(output)

    monkeypatch.setattr(huggingface_hub, "hf_hub_download", fetch)
    result = detector.prepare(download=True, progress=events.append)
    assert result["complete"]
    assert len(calls) == 1 and "local_dir" in calls[0]
    assert {k: v for k, v in calls[0].items() if k != "local_dir"} == dict(
        repo_id="fixture/speech", filename="speech.mlmodelc/model.mil", revision="a" * 40,
        token=False, force_download=True)
    assert result["cache_kind"] == "ospr-verified"
    assert file.read_bytes() == b"bad", "Shared snapshots and immutable blobs must not be edited"
    assert events[-1] == dict(phase="download", model="speech-detector", completed_bytes=3, total_bytes=3)


def test_bad_download_fails_integrity_gate_and_is_not_marked_complete(cache, monkeypatch):
    import huggingface_hub

    _, file = cache

    def fetch(**kwargs):
        output = Path(kwargs["local_dir"]) / kwargs["filename"]
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_bytes(b"abd")
        return str(output)

    monkeypatch.setattr(huggingface_hub, "hf_hub_download", fetch)
    with pytest.raises(ValueError, match="SHA-256"):
        detector.prepare(download=True)
    assert not detector.inventory()["complete"]


def test_owned_cache_repair_publishes_a_new_version_without_removing_the_old_one(cache, monkeypatch):
    import huggingface_hub

    def fetch(**kwargs):
        output = Path(kwargs["local_dir"]) / kwargs["filename"]
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_bytes(b"abc")
        return str(output)

    monkeypatch.setattr(huggingface_hub, "hf_hub_download", fetch)
    first = detector.prepare(download=True)
    old = Path(first["model_path"]) / "model.mil"
    old.write_bytes(b"abd")
    with pytest.raises(ValueError, match="failed verification"):
        detector.prepare(download=False)
    repaired = detector.prepare(download=True)
    assert repaired["complete"] and repaired["model_path"] != first["model_path"]
    assert old.read_bytes() == b"abd"
    assert (Path(repaired["model_path"]) / "model.mil").read_bytes() == b"abc"
    assert detector.prepare(download=False)["model_path"] == repaired["model_path"]


def test_invalid_owned_locator_never_traverses_outside_its_cache(cache):
    _, owned = detector.cache_paths()
    owned.mkdir(parents=True)
    (owned / "current").write_text("../../outside")
    state = detector.inventory()
    assert not state["complete"] and state["path"] is None
    assert state["cache_kind"] == "invalid-owned-cache"


@pytest.mark.parametrize("linked_component", ["parent", "revision"])
def test_installer_refuses_symlinked_managed_directories(cache, monkeypatch, tmp_path, linked_component):
    import huggingface_hub

    monkeypatch.setattr(huggingface_hub, "hf_hub_download", lambda **_: pytest.fail("Unsafe cache must fail before download"))
    _, owned = detector.cache_paths()
    outside = tmp_path / "outside"
    outside.mkdir()
    if linked_component == "parent":
        owned.parent.symlink_to(outside, target_is_directory=True)
    else:
        owned.parent.mkdir()
        owned.symlink_to(outside, target_is_directory=True)
    with pytest.raises(ValueError, match="real private directory"):
        detector.prepare(download=True)
    assert list(outside.iterdir()) == []


def test_worker_separates_explicit_download_from_cache_only_recording_preflight(monkeypatch):
    calls = []
    def callback(event):
        pass

    def prepare(**kwargs):
        calls.append(kwargs)
        return {"complete": True}

    monkeypatch.setattr(detector, "prepare", prepare)
    fake = SimpleNamespace(progress=callback)
    dispatch(fake, dict(action="download_model", model="speech-detector"))
    dispatch(fake, dict(action="prepare_speech_detector", download=True))
    assert calls == [dict(download=True, progress=callback), dict(download=False)]


def test_native_worker_and_research_model_pins_are_identical():
    root = Path(__file__).resolve().parents[2]
    research = json.loads((root / "benchmarks/fixtures/vad-models.json").read_text())["models"]["coreml-32-v6.0"]
    native = (root / "Sources/OSprCore/NativeSpeechAsset.swift").read_text()
    literal = re.search(r'#"""\n(.*?)\n"""#', native, re.S).group(1)
    assert json.loads(literal) == detector.SPEC == research
