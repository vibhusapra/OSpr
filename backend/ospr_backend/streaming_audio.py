"""Continuous 16 kHz normalization for native microphone packets.

Keep a phase-aligned FIR halo, not the recording. Output equals the existing
whole-file resample_poly path, including clipping and the final zero-padded tail.
"""

from math import ceil, gcd
from pathlib import Path

import numpy as np
import soundfile as sf
from scipy.signal import firwin, resample_poly

from .audio import SAMPLE_RATE

NATIVE_RATES = frozenset({8000, 11025, 16000, 22050, 24000, 32000, 44100, 48000,
                          88200, 96000, 176400, 192000, 352800, 384000})
MAX_PACKET_SECONDS = 12
MAX_PACKET_BYTES = 32 * 1024 * 1024


def read_stream_packet(path):
    """Read bounded native PCM before resampling; never run a media subprocess."""
    source = Path(path).expanduser().resolve(strict=True)
    with sf.SoundFile(source) as file:
        if file.samplerate not in NATIVE_RATES or not 1 <= file.channels <= 32:
            raise ValueError("Unsupported streaming sample rate or channel count.")
        if file.frames > file.samplerate * MAX_PACKET_SECONDS:
            raise ValueError("Streaming packets must be at most 12 seconds.")
        if file.frames < 1 or file.frames * file.channels * 4 > MAX_PACKET_BYTES:
            raise ValueError("Streaming packet is empty or exceeds the memory limit.")
        audio = file.read(dtype="float32", always_2d=file.channels != 1)
        rate = file.samplerate
    mono = audio if audio.ndim == 1 else np.mean(audio, axis=1)
    if not np.isfinite(mono).all():
        raise ValueError("Audio contains non-finite samples.")
    return np.ascontiguousarray(mono), rate


class StreamNormalizer:
    def __init__(self, sample_rate):
        if isinstance(sample_rate, bool) or sample_rate not in NATIVE_RATES:
            raise ValueError("Unsupported streaming sample rate.")
        self.sample_rate = int(sample_rate)
        divisor = gcd(self.sample_rate, SAMPLE_RATE)
        self.up, self.down = SAMPLE_RATE // divisor, self.sample_rate // divisor
        half_length = 10 * max(self.up, self.down)
        # Conservative input-domain support includes SciPy's centering padding.
        self.halo = ceil((half_length + self.down) / self.up) + 2
        self.filter = None if self.up == self.down else firwin(
            2 * half_length + 1, 1 / max(self.up, self.down), window=("kaiser", 5.0)
        ).astype(np.float32)
        self.buffer = np.empty(0, dtype=np.float32)
        self.start = self.received = self.emitted = 0
        self.closed = False

    def feed(self, audio, *, final=False):
        if self.closed:
            raise ValueError("Streaming normalizer is already closed.")
        audio = np.asarray(audio, dtype=np.float32)
        if audio.ndim != 1 or not np.isfinite(audio).all():
            raise ValueError("Streaming audio must be finite mono PCM.")
        if len(audio) > self.sample_rate * MAX_PACKET_SECONDS:
            raise ValueError("Streaming packets must be at most 12 seconds.")
        self.received += len(audio)
        if self.up == self.down:
            self.emitted += len(audio)
            self.closed = final
            return np.clip(audio, -1, 1).copy()
        self.buffer = np.concatenate((self.buffer, audio))
        if not self.received:
            self.closed = final
            return np.empty(0, dtype=np.float32)
        # A live packet must not emit samples whose FIR needs future input.
        end = (self.received * self.up + self.down - 1) // self.down if final else max(
            0, (self.received - self.halo) * self.up // self.down
        )
        base = self.start * self.up // self.down
        normalized = resample_poly(self.buffer, self.up, self.down, window=self.filter)
        ready = np.clip(normalized[self.emitted - base:end - base], -1, 1).copy()
        self.emitted = end
        if final:
            self.buffer = np.empty(0, dtype=np.float32)
            self.closed = True
        else:
            # Removing a multiple of down preserves the global polyphase phase.
            keep = max(self.start, ((self.emitted * self.down // self.up - self.halo) // self.down)
                       * self.down, 0)
            self.buffer = self.buffer[keep - self.start:].copy()
            self.start = keep
        return ready
