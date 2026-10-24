"""Exact-result reuse, mutation safety and generation lifetime contracts."""

from types import MethodType, SimpleNamespace
import weakref

import numpy as np
import pytest

from ospr_backend.qwen_features import generate, reuse_features


class Model:
    def __init__(self, dither=0):
        self._feature_extractor = SimpleNamespace(dither=dither)
        self.calls = 0

    def _preprocess_audio(self, audio):
        self.calls += 1
        if np.any(audio < 0):
            raise ValueError("invalid fixture")
        return np.array([np.sum(audio)], dtype=np.float32), np.ones(1), len(audio)

    def generate(self, audio, **kwargs):
        first = self._preprocess_audio(audio)
        second = self._preprocess_audio(audio)
        return SimpleNamespace(text=str(float(first[0][0])), audio_tokens=second[2], options=kwargs)


def test_identical_pcm_copy_reuses_exact_tuple_and_restores_method():
    model = Model()
    audio = np.arange(32, dtype=np.float32)
    original = model._preprocess_audio.__func__
    with reuse_features(model) as work:
        first = model._preprocess_audio(audio)
        assert model._preprocess_audio(audio.copy()) is first
        assert work.evaluations == 1 and work.hits == 1 and model.calls == 1
    assert "_preprocess_audio" not in vars(model) and "_ospr_reusing_features" not in vars(model)
    assert model._preprocess_audio.__func__ is original
    model._preprocess_audio(audio)
    assert model.calls == 2


def test_in_place_mutation_invalidates_same_array_identity():
    model, audio = Model(), np.ones(16, dtype=np.float32)
    with reuse_features(model) as work:
        first = model._preprocess_audio(audio)
        audio[0] = 9
        second = model._preprocess_audio(audio)
        assert first[0][0] == 16 and second[0][0] == 24
        assert first is not second and work.evaluations == 2 and work.hits == 0
        assert model._preprocess_audio(audio) is second


def test_only_latest_result_is_retained_and_exit_releases_it():
    model = Model()
    with reuse_features(model):
        features = model._preprocess_audio(np.ones(32, dtype=np.float32))[0]
        first_ref = weakref.ref(features)
        del features
        assert first_ref() is not None
        model._preprocess_audio(np.ones(64, dtype=np.float32))
        assert first_ref() is None
        last = model._preprocess_audio(np.ones(64, dtype=np.float32))[0]
        last_ref = weakref.ref(last)
        del last
    assert last_ref() is None


def test_error_restores_method_and_next_generation_has_no_stale_entry():
    model = Model()
    with pytest.raises(ValueError, match="invalid fixture"), reuse_features(model):
        model._preprocess_audio(np.ones(16, dtype=np.float32))
        model._preprocess_audio(-np.ones(16, dtype=np.float32))
    assert "_preprocess_audio" not in vars(model)
    with reuse_features(model) as work:
        model._preprocess_audio(np.ones(16, dtype=np.float32))
        assert work.evaluations == 1 and work.hits == 0


@pytest.mark.parametrize("audio", [np.ones(16, dtype=np.float64), np.ones((2, 8), dtype=np.float32),
                                  np.ones(32, dtype=np.float32)[::2], np.ones(480001, dtype=np.float32)])
def test_nonstandard_or_oversized_inputs_run_original_without_retention(audio):
    model = Model()
    with reuse_features(model) as work:
        model._preprocess_audio(audio)
        model._preprocess_audio(audio)
        assert work.evaluations == 2 and work.hits == 0


def test_dither_and_mid_generation_dither_changes_never_reuse_random_frontend():
    model, audio = Model(0.1), np.ones(16, dtype=np.float32)
    with reuse_features(model) as work:
        model._preprocess_audio(audio)
        model._preprocess_audio(audio)
        assert not work.enabled and work.evaluations == 2 and work.hits == 0
    model._feature_extractor.dither = 0
    with reuse_features(model) as work:
        model._preprocess_audio(audio)
        model._feature_extractor.dither = 0.1
        model._preprocess_audio(audio)
        model._feature_extractor.dither = 0
        model._preprocess_audio(audio)
        assert work.evaluations == 3 and work.hits == 0


def test_preexisting_instance_method_is_restored_exactly():
    model = Model()
    custom = MethodType(lambda self, audio: (audio.copy(), None, 1), model)
    model._preprocess_audio = custom
    with reuse_features(model):
        model._preprocess_audio(np.ones(16, dtype=np.float32))
    assert vars(model)["_preprocess_audio"] is custom


def test_nested_scope_does_not_replace_or_remove_outer_scope():
    model, audio = Model(), np.ones(16, dtype=np.float32)
    with reuse_features(model) as outer:
        first = model._preprocess_audio(audio)
        with reuse_features(model) as inner:
            assert not inner.enabled and model._preprocess_audio(audio) is first
        assert model._preprocess_audio(audio) is first
        assert outer.hits == 2 and outer.evaluations == 1
    assert "_preprocess_audio" not in vars(model)


def test_generation_diagnostic_disable_preserves_original_work(monkeypatch):
    audio = np.ones(16, dtype=np.float32)
    model = Model()
    result, enabled = generate(model, audio, language="en")
    assert result.text == "16.0" and result.audio_tokens == 16 and result.options == {"language": "en"}
    assert enabled.evaluations == enabled.hits == 1
    monkeypatch.setenv("OSPR_QWEN_FEATURE_REUSE", "0")
    result, disabled = generate(model, audio, language="en")
    assert result.text == "16.0" and disabled.evaluations == 2 and disabled.hits == 0


def test_missing_private_frontend_keeps_existing_generate_contract():
    model = SimpleNamespace(generate=lambda audio, **kwargs: "original")
    result, work = generate(model, np.ones(16, dtype=np.float32))
    assert result == "original" and work.evaluations == work.hits == 0
