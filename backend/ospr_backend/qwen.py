"""Bound Qwen long-file context and reset its token budget for every chunk."""

import numpy as np

from .audio import SAMPLE_RATE

MAX_CHUNK_SECONDS = 30
TOKENS_PER_CHUNK = 2048


def chunks(audio):
    """Contiguous views, at most 30s, cutting at low energy within the last 5s.

    A 100ms box-energy sum uses a bounded cumulative sum, avoiding quadratic
    convolution and full-recording temporary arrays. Keep at least a one-second
    tail. No resampling, dropping, overlapping or deduplicating recognized text.
    """
    if audio.ndim != 1:
        raise ValueError("Qwen chunking requires mono audio")
    maximum = MAX_CHUNK_SECONDS * SAMPLE_RATE
    lookback = 5 * SAMPLE_RATE
    window = SAMPLE_RATE // 10
    start = 0
    while len(audio) - start > maximum:
        lower = start + maximum - lookback
        upper = min(start + maximum, len(audio) - SAMPLE_RATE)
        left = lower - window // 2
        right = upper + window - window // 2
        region = audio[left:right].astype(np.float64)
        sums = np.concatenate(([0.0], np.cumsum(region * region)))
        energy = sums[window:] - sums[:-window]
        cut = lower + int(np.argmin(energy))
        yield audio[start:cut], start / SAMPLE_RATE
        start = cut
    if start < len(audio):
        yield audio[start:], start / SAMPLE_RATE


def language_tag(value, fallback=None):
    """The runtime returns a list per chunk; the wire schema uses one tag or nil."""
    if isinstance(value, str):
        return value or fallback
    if isinstance(value, list):
        tags = {tag for tag in value if isinstance(tag, str) and tag}
        return next(iter(tags)) if len(tags) == 1 else None if tags else fallback
    return fallback


def transcribe_long(model, audio, language=None, offset=0):
    texts, segments, languages = [], [], []
    count = 0
    for chunk, position in chunks(audio):
        count += 1
        result = model.generate(chunk, max_tokens=TOKENS_PER_CHUNK, batch_size=1,
                                **({"language": language} if language else {}))
        if getattr(result, "generation_tokens", 0) >= TOKENS_PER_CHUNK:
            raise RuntimeError("Qwen reached a chunk token limit; no partial transcript was saved. Try another speech model.")
        if not isinstance(result.text, str):
            raise ValueError("Qwen returned an invalid transcript")
        text = result.text.strip()
        texts.append(text)
        if text:
            segments.append(dict(start=offset + position,
                                 end=offset + position + len(chunk) / SAMPLE_RATE, text=text))
        tag = language_tag(getattr(result, "language", None), language)
        if tag:
            languages.append(tag)
    return dict(text=" ".join(text for text in texts if text), segments=segments,
                language=language_tag(languages, language), decoder_chunks=count,
                max_tokens_per_chunk=TOKENS_PER_CHUNK)
