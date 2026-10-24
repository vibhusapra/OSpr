"""Reuse Qwen's prompt length without retaining PCM or frontend tensors.

Chunk loop adapted from MLX Audio, Copyright 2025 Prince Canuma and contributors.
MIT license: licenses/mlx-audio-MIT.txt.
"""

import ast
from contextlib import contextmanager
from dataclasses import dataclass
from functools import lru_cache
import hashlib
import inspect
import os
import textwrap
from types import MethodType

# MLX Audio 0.6.1's single-chunk loop. Fail closed on private-API changes.
_CHUNK_AST_SHA256 = "32a087e9e44bbb788c9260e13e2c7fccf482ad06acab3e70c2a3975a4adf041b"


@dataclass
class FeatureWork:
    enabled: bool = False
    evaluations: int = 0
    hits: int = 0


@lru_cache(maxsize=4)
def _supported_chunk(function):
    try:
        tree = ast.parse(textwrap.dedent(inspect.getsource(function)))
        digest = hashlib.sha256(ast.dump(tree.body[0], include_attributes=False).encode()).hexdigest()
        return digest == _CHUNK_AST_SHA256
    except (OSError, TypeError, SyntaxError):
        return False


@contextmanager
def reuse_features(model, enabled=True):
    """Remove only redundant prompt accounting from a known serial chunk loop.

    Encoding and sampling use the untouched stream_generate and Torch frontend.
    The original loop re-extracts audio after its first token only to count the
    prompt. Capture that count during the real prompt build instead. Each chunk
    keeps one integer; neither PCM nor features survive the encoding operation.
    Unsupported implementations and stochastic frontends run the original loop.
    """
    work = FeatureWork()
    original = getattr(model, "_preprocess_audio", None)
    chunk = getattr(model, "_generate_single_chunk", None)
    build = getattr(model, "_build_prompt", None)
    extractor = getattr(model, "_feature_extractor", None)
    if not callable(original) or getattr(model, "_ospr_reusing_features", False):
        yield work
        return
    chunk_function = getattr(chunk, "__func__", chunk)
    work.enabled = bool(enabled and callable(build) and inspect.isfunction(chunk_function)
                        and _supported_chunk(chunk_function)
                        and getattr(extractor, "dither", None) == 0)
    missing = object()
    names = ["_preprocess_audio", "_ospr_reusing_features"]
    if work.enabled:
        names += ["_build_prompt", "_generate_single_chunk"]
    previous = {name: vars(model).get(name, missing) for name in names}
    prompt_length = None

    def preprocess(_owner, audio):
        work.evaluations += 1
        return original(audio)

    def build_prompt(_owner, *args, **kwargs):
        nonlocal prompt_length
        ids = build(*args, **kwargs)
        prompt_length = int(ids.shape[1])
        return ids

    def single_chunk(_owner, audio_chunk, *, max_tokens=8192, sampler=None,
                     logits_processors=None, language=None, prefill_step_size=2048,
                     verbose=False, system_prompt=None):
        # Same token loop as MLX Audio; only its redundant accounting is replaced.
        nonlocal prompt_length
        prompt_length = None
        generated_tokens, prompt_tokens = [], 0
        try:
            for token, _ in model.stream_generate(
                audio_chunk, max_tokens=max_tokens, sampler=sampler,
                logits_processors=logits_processors, language=language,
                prefill_step_size=prefill_step_size, verbose=verbose,
                system_prompt=system_prompt,
            ):
                if prompt_tokens == 0:
                    if (prompt_length is not None and prompt_length > 0
                            and getattr(model, "_feature_extractor", None) is extractor
                            and getattr(extractor, "dither", None) == 0):
                        prompt_tokens = prompt_length
                        work.hits += 1
                    else:
                        # Custom streams or changed randomness retain original accounting.
                        _, _, audio_tokens = model._preprocess_audio(audio_chunk)
                        prompt_tokens = model._build_prompt(audio_tokens, language, system_prompt).shape[1]
                generated_tokens.append(int(token))
            return (model._tokenizer.decode(generated_tokens, skip_special_tokens=True),
                    prompt_tokens, len(generated_tokens))
        finally:
            prompt_length = None

    object.__setattr__(model, "_preprocess_audio", MethodType(preprocess, model))
    object.__setattr__(model, "_ospr_reusing_features", True)
    if work.enabled:
        object.__setattr__(model, "_build_prompt", MethodType(build_prompt, model))
        object.__setattr__(model, "_generate_single_chunk", MethodType(single_chunk, model))
    try:
        yield work
    finally:
        prompt_length = None
        for name, value in previous.items():
            if value is missing:
                object.__delattr__(model, name)
            else:
                object.__setattr__(model, name, value)


def generate(model, audio, **kwargs):
    # Research only: the frozen latency gate failed. Default keeps upstream work.
    mode = os.environ.get("OSPR_QWEN_FEATURE_REUSE")
    method = model.generate
    if mode not in {"0", "1"}:
        return method(audio, **kwargs), FeatureWork()
    enabled = mode == "1"
    # Load-time model views can retain a method bound to another owner.
    owner = getattr(method, "__self__", None)
    with reuse_features(owner if owner is not None else model, enabled=enabled) as work:
        result = method(audio, **kwargs)
    return result, work
