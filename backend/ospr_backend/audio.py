"""One bounded, deterministic decode/resample path for all speech engines."""

from pathlib import Path
from math import gcd
import json
import shutil
import subprocess
from .temporary import private_audio_file

import numpy as np
import soundfile as sf
from scipy.signal import resample_poly

SAMPLE_RATE = 16000
MAX_SECONDS = 4 * 60 * 60


def read_audio(path: str) -> np.ndarray:
    source = Path(path).expanduser().resolve(strict=True)
    try:
        info = sf.info(source)
    except sf.LibsndfileError:
        return _decode_with_ffmpeg(source)
    if info.duration > MAX_SECONDS or info.frames < 1:
        raise ValueError("Audio must contain between one sample and four hours of sound.")
    if info.channels > 32 or info.samplerate < 1000 or info.samplerate > 384000:
        raise ValueError("Unsupported audio format.")
    # Bound native-rate multichannel material before allocating its float array.
    # FFmpeg streams the conversion to bounded 16 kHz mono first.
    if info.frames * info.channels * 4 > 256 * 1024 * 1024:
        return _decode_with_ffmpeg(source)
    audio, rate = sf.read(source, dtype="float32", always_2d=True)
    mono = np.mean(audio, axis=1)
    if not np.isfinite(mono).all():
        raise ValueError("Audio contains non-finite samples.")
    if rate != SAMPLE_RATE:
        divisor = gcd(rate, SAMPLE_RATE)
        mono = resample_poly(mono, SAMPLE_RATE // divisor, rate // divisor).astype(np.float32)
    return np.ascontiguousarray(np.clip(mono, -1, 1))


def _decode_with_ffmpeg(source):
    # Video/AAC support is opt-in through a locally installed FFmpeg. Never
    # accept URLs and never allow network protocols in container demuxers.
    ffmpeg, ffprobe = shutil.which("ffmpeg"), shutil.which("ffprobe")
    if not ffmpeg or not ffprobe:
        raise ValueError("This format or large native-rate file needs FFmpeg. Install with: brew install ffmpeg") from None
    probe = subprocess.run(
        [
            ffprobe,
            "-v",
            "error",
            "-protocol_whitelist",
            "file,pipe",
            "-show_format",
            "-of",
            "json",
            str(source),
        ],
        capture_output=True,
        timeout=30,
        check=True,
    )
    duration = float(json.loads(probe.stdout).get("format", {}).get("duration", 0))
    if not 0 < duration <= MAX_SECONDS:
        raise ValueError("Media must contain between one sample and four hours of audio.") from None
    with private_audio_file() as decoded:
        subprocess.run(
            [
                ffmpeg,
                "-nostdin",
                "-v",
                "error",
                "-protocol_whitelist",
                "file,pipe",
                "-i",
                str(source),
                "-vn",
                "-ac",
                "1",
                "-ar",
                str(SAMPLE_RATE),
                "-t",
                str(MAX_SECONDS + 0.01),
                "-c:a",
                "pcm_f32le",
                "-y",
                decoded.name,
            ],
            capture_output=True,
            timeout=600,
            check=True,
        )
        return read_audio(decoded.name)


def speech_bounds(audio: np.ndarray, threshold: float = 0.003, padding: float = 0.16):
    """Conservative RMS edge trimming; never advertised as a neural VAD.

    Interior silence stays intact, preserving timestamps. Very quiet speech can be
    missed: callers can disable trimming and the threshold is an exposed setting.
    """
    if not len(audio):
        return 0, 0
    window = 320
    padded = np.pad(audio, (0, (-len(audio)) % window))
    rms = np.sqrt(np.mean(padded.reshape(-1, window) ** 2, axis=1))
    active = np.flatnonzero(rms > threshold)
    if not len(active):
        return 0, 0
    margin = int(padding * SAMPLE_RATE)
    return max(0, int(active[0]) * window - margin), min(len(audio), (int(active[-1]) + 1) * window + margin)
