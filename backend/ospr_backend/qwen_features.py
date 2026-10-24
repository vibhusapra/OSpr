"""Bounded, generation-scoped reuse of Qwen's identical frontend result."""

from contextlib import contextmanager
from dataclasses import dataclass
import hashlib
import os
from types import MethodType

import numpy as np


@dataclass
class FeatureWork:
    enabled: bool = False
    evaluations: int = 0
    hits: int = 0


@contextmanager
def reuse_features(model, enabled=True):
    """Preserve the frontend; reuse at most one deterministic PCM result.

    The serial worker owns the model. No cache survives this generation. Inputs
    outside the normal bounded float32 mono path always run the original method.
    """
    work = FeatureWork()
    original = getattr(model, "_preprocess_audio", None)
    extractor = getattr(model, "_feature_extractor", None)
    if not callable(original) or extractor is None or getattr(model, "_ospr_reusing_features", False):
        yield work
        return
    work.enabled = bool(enabled and getattr(extractor, "dither", None) == 0)
    missing = object()
    previous = vars(model).get("_preprocess_audio", missing)
    previous_marker = vars(model).get("_ospr_reusing_features", missing)
    key, cached = None, None

    def preprocess(_owner, audio):
        nonlocal key, cached
        eligible = (work.enabled and getattr(model, "_feature_extractor", None) is extractor
                    and getattr(extractor, "dither", None) == 0
                    and isinstance(audio, np.ndarray) and audio.dtype == np.float32
                    and audio.ndim == 1 and audio.flags.c_contiguous and 0 < len(audio) <= 30 * 16000)
        fingerprint = (audio.shape, hashlib.sha256(memoryview(audio).cast("B")).digest()) if eligible else None
        if fingerprint is not None and fingerprint == key:
            work.hits += 1
            return cached
        key, cached = None, None
        work.evaluations += 1
        result = original(audio)
        if fingerprint is not None:
            key, cached = fingerprint, result
        return result

    object.__setattr__(model, "_preprocess_audio", MethodType(preprocess, model))
    object.__setattr__(model, "_ospr_reusing_features", True)
    try:
        yield work
    finally:
        key, cached = None, None
        for name, value in [("_preprocess_audio", previous), ("_ospr_reusing_features", previous_marker)]:
            if value is missing:
                object.__delattr__(model, name)
            else:
                object.__setattr__(model, name, value)


def generate(model, audio, **kwargs):
    # A diagnostic escape hatch permits paired real-model baseline comparisons.
    enabled = os.environ.get("OSPR_QWEN_FEATURE_REUSE", "1") != "0"
    method = model.generate
    # Model fusion can retain a bound method owned by the pre-fusion object.
    # Patch the object that actually executes generate, not a neighboring view.
    owner = getattr(method, "__self__", None)
    with reuse_features(owner if owner is not None else model, enabled=enabled) as work:
        result = method(audio, **kwargs)
    return result, work
