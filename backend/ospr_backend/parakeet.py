"""Direct long-file Parakeet decoding without overlap token merging."""

import math

from .audio import SAMPLE_RATE
from .audio_chunks import chunks


def _logmel(audio, config):
    import mlx.core as mx
    from parakeet_mlx.audio import get_logmel

    return get_logmel(mx.array(audio, dtype=mx.float32), config)


def _interval(start, end, duration):
    start, end = float(start), float(end)
    if not math.isfinite(start) or not math.isfinite(end) or end < start:
        raise ValueError("Parakeet returned invalid recognizer timing")
    # Frame padding can extend outside a chunk; do not seek into its neighbor.
    start = min(duration, max(0, start))
    return start, min(duration, max(start, end))


def transcribe_long(model, audio, offset=0, word_timestamps=False):
    texts, segments, words = [], [], []
    count, decoded_samples = 0, 0
    for part, position in chunks(audio):
        result = model.generate(_logmel(part, model.preprocessor_config))[0]
        if not isinstance(result.text, str):
            raise ValueError("Parakeet returned an invalid transcript")
        texts.append(result.text.strip())
        origin = offset + position
        duration = len(part) / SAMPLE_RATE
        for sentence in result.sentences:
            start, end = _interval(sentence.start, sentence.end, duration)
            if sentence.text.strip():
                segments.append(dict(start=origin + start, end=origin + end, text=sentence.text))
        if word_timestamps:
            from .diarization import tokens_to_words

            timed = []
            for token in result.tokens:
                start, end = _interval(token.start, token.end, duration)
                timed.append(dict(start=origin + start, end=origin + end, text=token.text))
            # A chunk's first subword need not have a leading space. Group each
            # independent decode before concatenating, preserving repeated words.
            words.extend(tokens_to_words(timed))
        count += 1
        decoded_samples += len(part)
    if decoded_samples != len(audio):
        raise RuntimeError("Parakeet did not receive the complete input; no partial transcript was saved")
    return dict(text=" ".join(text for text in texts if text), segments=segments,
                words=words, decoder_chunks=count, decoded_samples=decoded_samples)
