"""Sample-preserving, bounded low-energy boundaries for independent decodes."""

import numpy as np

from .audio import SAMPLE_RATE

MAX_CHUNK_SECONDS = 30


def chunks(audio, *, max_seconds=MAX_CHUNK_SECONDS):
    """Contiguous views, default 30s, cutting at low energy within the last 5s.

    A 100ms box-energy sum uses a bounded cumulative sum, avoiding quadratic
    convolution and full-recording temporary arrays. Keep at least a one-second
    tail. Upload preparation can explicitly select 600s. No resampling, dropping,
    overlapping or deduplicating recognized text; default ASR cuts are unchanged.
    """
    if audio.ndim != 1:
        raise ValueError("Chunking requires mono audio")
    if not isinstance(max_seconds, (int, float)) or not np.isfinite(max_seconds) or not 6 <= max_seconds <= 600:
        raise ValueError("Chunk duration must be between 6 and 600 seconds")
    maximum = int(max_seconds * SAMPLE_RATE)
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
