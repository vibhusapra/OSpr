"""Prepare oversized provider uploads locally; preserve the complete time axis.

No model load or network request. The original source/recovery take is untouched.
Long uploads use independent, contiguous parts without dropping silence or text.
"""

from pathlib import Path
import os
import stat
import soundfile as sf
from .audio import SAMPLE_RATE, read_audio
from .audio_chunks import chunks
from .temporary import private_root

MAX_UPLOAD_BYTES = 25_000_000
MAX_UPLOAD_PART_SECONDS = 600


def prepare_upload_parts(path, output_dir):
    """Write PCM16 parts in a fresh, private caller-owned workspace.

    No model or network access. All files are ready before any upload begins.
    The caller removes the directory on completion/cancel; the worker's existing
    PID-directory cleanup handles an app crash. Failure removes only our files.
    """
    destination = Path(output_dir).expanduser()
    attributes = destination.lstat()
    if (not stat.S_ISDIR(attributes.st_mode) or attributes.st_uid != os.getuid()
            or stat.S_IMODE(attributes.st_mode) != 0o700
            or destination.resolve().parent != private_root().resolve()
            or not destination.name.startswith(f"{os.getppid()}-upload-")
            and not destination.name.startswith(f"{os.getpid()}-upload-")):
        raise ValueError("Upload parts require a private caller-owned workspace.")
    if any(destination.iterdir()):
        raise ValueError("Upload workspace must be empty; existing files are preserved.")
    source = Path(path).expanduser().resolve(strict=True)
    audio = read_audio(str(source))
    created, parts, offset = [], [], 0
    try:
        for index, (samples, _) in enumerate(chunks(audio, max_seconds=MAX_UPLOAD_PART_SECONDS)):
            output = destination / f"part-{index:04d}.wav"
            # Exclusive creation avoids overwriting even a raced-in file.
            with output.open("xb"):
                pass
            created.append(output)
            output.chmod(0o600)
            sf.write(output, samples, SAMPLE_RATE, format="WAV", subtype="PCM_16")
            size = output.stat().st_size
            if size >= MAX_UPLOAD_BYTES or sf.info(output).frames != len(samples):
                raise ValueError("Prepared upload part is oversized or incomplete.")
            parts.append(dict(path=str(output.resolve()), start_frame=offset, frames=len(samples), bytes=size))
            offset += len(samples)
        if not parts or offset != len(audio):
            raise ValueError("Prepared upload parts did not preserve the full recording.")
        return dict(parts=parts, frames=offset, sample_rate=SAMPLE_RATE,
                    audio_seconds=offset / SAMPLE_RATE, source_unchanged=True,
                    max_part_seconds=MAX_UPLOAD_PART_SECONDS, format="16 kHz mono PCM16 WAV")
    except BaseException:
        for output in created:
            output.unlink(missing_ok=True)
        raise


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
