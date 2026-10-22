"""Retain audio only, with exact normalized samples and the full source timeline.

Float WAV avoids quantization changes to ASR. Video, tags and external container
references are not retained. This route uses no model or network connection.
"""
from pathlib import Path
import soundfile as sf
from .audio import SAMPLE_RATE, read_audio


def prepare_review(path, output, limit_bytes):
    if not isinstance(limit_bytes, int) or isinstance(limit_bytes, bool) or not 1024 <= limit_bytes <= 8 * 1024**3:
        raise ValueError("Invalid retained-audio budget.")
    source = Path(path).expanduser().resolve(strict=True)
    destination = Path(output).expanduser().resolve()
    if source == destination or destination.exists():
        raise ValueError("Choose a fresh review WAV path; the source is never replaced.")
    audio = read_audio(str(source))
    if len(audio) * 4 + 1024 > limit_bytes:
        raise ValueError("Normalized audio exceeds the retained-audio budget. Transcription can continue without retaining it.")
    with destination.open("xb"):
        pass
    destination.chmod(0o600)
    try:
        sf.write(destination, audio, SAMPLE_RATE, format="WAV", subtype="FLOAT")
        size = destination.stat().st_size
        if size > limit_bytes:
            raise ValueError("Retained audio exceeds the storage budget.")
        return dict(audio_seconds=len(audio) / SAMPLE_RATE, bytes=size, format="16 kHz mono float32 WAV", source_unchanged=True)
    except BaseException:
        destination.unlink(missing_ok=True)
        raise
