"""Mix private PCM tracks using their shared ScreenCaptureKit presentation clock."""

import math
from pathlib import Path
import shutil
import subprocess
import soundfile as sf


def mix_tracks(tracks, output):
    if not 1 <= len(tracks) <= 2:
        raise ValueError("Provide one or two meeting audio tracks")
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        raise ValueError("Desktop + microphone mixing needs FFmpeg. Install with: brew install ffmpeg")
    paths = []
    starts = []
    for track in tracks:
        path = Path(track["path"]).resolve(strict=True)
        start = float(track["start"])
        if not math.isfinite(start):
            raise ValueError("Invalid audio track clock")
        info = sf.info(path)
        if path.suffix.lower() != ".wav" or not 0 < info.duration <= 4 * 3600 or not 1 <= info.channels <= 32:
            raise ValueError("Meeting tracks must be bounded local WAV files")
        paths.append(path)
        starts.append(start)
    origin = min(starts)
    if max(starts) - origin > 3600:
        raise ValueError("Meeting track clocks are too far apart")
    destination = Path(output).resolve()
    if destination in paths or destination.exists():
        raise ValueError("Choose a fresh output WAV path")
    arguments = [ffmpeg, "-nostdin", "-v", "error"]
    for path in paths:
        arguments += ["-protocol_whitelist", "file,pipe", "-i", str(path)]
    filters = []
    for index, start in enumerate(starts):
        delay = round((start - origin) * 16000)
        filters.append(
            f"[{index}:a]aresample=16000,aformat=sample_fmts=flt:channel_layouts=mono,adelay={delay}S:all=1[t{index}]"
        )
    labels = "".join(f"[t{i}]" for i in range(len(paths)))
    weights = " ".join(str(1 / len(paths)) for _ in paths)
    filters.append(
        f"{labels}amix=inputs={len(paths)}:duration=longest:dropout_transition=0:normalize=0:weights='{weights}'[out]"
    )
    # Exclusive creation prevents overwriting a different recording or export.
    descriptor = destination.open("xb")
    descriptor.close()
    destination.chmod(0o600)
    try:
        subprocess.run(
            arguments
            + [
                "-filter_complex",
                ";".join(filters),
                "-map",
                "[out]",
                "-ar",
                "16000",
                "-ac",
                "1",
                "-c:a",
                "pcm_f32le",
                "-y",
                str(destination),
            ],
            check=True,
            capture_output=True,
            timeout=600,
        )
    except BaseException:
        destination.unlink(missing_ok=True)
        raise
    return {
        "path": str(destination),
        "audio_seconds": sf.info(destination).duration,
        "tracks": len(paths),
        "description": "Presentation-clock aligned local tracks; equal-weight mix, no echo cancellation.",
    }
