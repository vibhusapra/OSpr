"""Verify native edge ranges against the exact normalized recognition array.

The native detector operates on a private float WAV produced by prepare_review.
The entire little-endian float32 waveform is bound to the range, not only its
selected slice. No implicit resampling or second RMS trim can change that range.
"""
import hashlib
import re

from .audio import SAMPLE_RATE


def pcm_sha256(audio):
    return hashlib.sha256(memoryview(audio.astype("<f4", copy=False))).hexdigest()


def checked_bounds(audio, selection, trim):
    keys = {"method", "sample_rate", "audio_samples", "pcm_sha256", "start_sample", "end_sample"}
    if not isinstance(selection, dict) or set(selection) != keys or trim is not False:
        raise ValueError("Neural speech edges require an exact manifest and RMS trimming disabled.")
    for key in ["sample_rate", "audio_samples", "start_sample", "end_sample"]:
        if type(selection[key]) is not int:
            raise ValueError("Neural speech edge positions must be integer samples.")
    start, end = selection["start_sample"], selection["end_sample"]
    if (selection["method"] != "silero-causal8-v1" or selection["sample_rate"] != SAMPLE_RATE
            or selection["audio_samples"] != len(audio) or not 0 <= start <= end <= len(audio)
            or start == end != 0):
        raise ValueError("Neural speech edges do not match the normalized timeline.")
    digest = selection["pcm_sha256"]
    if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest) or digest != pcm_sha256(audio):
        raise ValueError("Normalized audio changed after neural edge analysis; retry from the source.")
    return start, end
