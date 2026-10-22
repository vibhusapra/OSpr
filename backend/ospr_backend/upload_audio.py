"""Prepare oversized provider uploads locally; preserve the complete time axis.

No model load or network request. The original source/recovery take is untouched.
This does not split very long media into provider jobs.
"""

from pathlib import Path
import soundfile as sf
from .audio import SAMPLE_RATE, read_audio

MAX_UPLOAD_BYTES = 25 * 1024 * 1024


def prepare_upload(path, output):
    source = Path(path).expanduser().resolve(strict=True)
    destination = Path(output).expanduser().resolve()
    if source == destination or destination.exists():
        raise ValueError("Choose a fresh upload WAV path; source audio is never replaced.")
    audio = read_audio(str(source))
    if len(audio) * 2 + 1024 >= MAX_UPLOAD_BYTES:
        raise ValueError(
            "Even a smaller mono upload exceeds 25 MB. Split the file or use local transcription."
        )
    with destination.open("xb"):
        pass
    destination.chmod(0o600)
    try:
        sf.write(destination, audio, SAMPLE_RATE, format="WAV", subtype="PCM_16")
        size = destination.stat().st_size
        if size >= MAX_UPLOAD_BYTES:
            raise ValueError("Prepared audio exceeds the provider upload limit.")
        return dict(
            path=str(destination),
            audio_seconds=len(audio) / SAMPLE_RATE,
            bytes=size,
            format="16 kHz mono PCM16 WAV",
            source_unchanged=True,
        )
    except BaseException:
        destination.unlink(missing_ok=True)
        raise
