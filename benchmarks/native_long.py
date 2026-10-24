"""Verify both long-file fixes through an offline bundled Swift CLI/owned worker."""

import argparse
import datetime
import hashlib
import json
import math
from pathlib import Path
import subprocess
import tempfile
import time

import jiwer
import numpy as np
import soundfile as sf

from run import ROOT, normalize


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--output", type=Path, default=ROOT / "results/native-long-files.json")
    parser.add_argument("--neural-edges", action="store_true", help="Exercise exact-sample neural final edges instead of the default transcription route.")
    args = parser.parse_args()
    app = args.app.resolve(strict=True)
    cli = app / "Contents/MacOS/ospr-cli"
    manifest = json.loads((ROOT / "fixtures/long-session.json").read_text())
    fixture = next(row for row in manifest["items"] if row["id"] == "public-concat-60m")
    audio = ROOT / fixture["path"]
    assert hashlib.sha256(audio.read_bytes()).hexdigest() == fixture["sha256"]
    normalized_sha = None
    if args.neural_edges:
        digest = hashlib.sha256()
        with sf.SoundFile(audio) as file:
            assert file.samplerate == 16000 and file.channels == 1
            for block in file.blocks(blocksize=65536, dtype="float32"):
                np.clip(block, -1, 1, out=block)
                digest.update(memoryview(block.astype("<f4", copy=False)))
        normalized_sha = digest.hexdigest()
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    records = []
    environment = dict(HOME=str(Path.home()), PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
                       HF_HUB_OFFLINE="1", HF_HUB_DISABLE_TELEMETRY="1")
    with tempfile.TemporaryDirectory(prefix="OSpr native long ") as temporary:
        for model in ("parakeet-v3", "qwen3-asr"):
            started = time.perf_counter()
            command = "transcribe-neural-edges" if args.neural_edges else "transcribe"
            process = subprocess.run([str(cli), command, str(audio), model], cwd=temporary,
                                     env=environment, capture_output=True, text=True, timeout=650)
            elapsed = (time.perf_counter() - started) * 1000
            if process.returncode:
                raise RuntimeError(process.stderr)
            response = json.loads(process.stdout)
            assert response["model"] == model and response["decoder_chunks"] > 1
            assert abs(response["audio_seconds"] - fixture["seconds"]) <= 1 / 16000
            assert not response["warm"]  # Each command owns a new worker.
            if args.neural_edges:
                edges = response["speech_edges"]
                assert edges["pcm_sha256"] == normalized_sha and edges["audio_samples"] == round(fixture["seconds"] * 16000)
                assert response["speech_seconds"] == (edges["end_sample"] - edges["start_sample"]) / 16000
                assert all(segment["start"] >= edges["start_sample"] / 16000 for segment in response["segments"])
            if model == "parakeet-v3":
                assert response["decoded_samples"] == round(response["speech_seconds"] * 16000)
            else:
                assert response["max_tokens_per_chunk"] == 2048
                assert response["language"] is None or isinstance(response["language"], str)
            segments = response["segments"]
            assert all(math.isfinite(s["start"]) and math.isfinite(s["end"])
                       and 0 <= s["start"] <= s["end"] <= fixture["seconds"] + 1 / 16000
                       for s in segments)
            assert all(a["start"] <= b["start"] for a, b in zip(segments, segments[1:], strict=False))
            scored = jiwer.process_words(normalize(fixture["reference"]), normalize(response["text"]))
            # Fixture-specific regression gate chosen after the observed losses;
            # not a general production accuracy SLA. Both old buggy paths fail it.
            assert scored.wer < 0.05, f"Long-file regression: {model}, WER {scored.wer:.3%}"
            records.append(dict(model=model, native_wall_ms=elapsed, wer=scored.wer,
                                substitutions=scored.substitutions, deletions=scored.deletions,
                                insertions=scored.insertions, response=response))
            print(json.dumps(dict(model=model, status="passed", wer=scored.wer,
                                  native_wall_ms=elapsed)), flush=True)
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    receipt = dict(timestamp=datetime.datetime.now(datetime.UTC).isoformat(), status="passed",
                   build=json.loads((app / "Contents/Resources/build-info.json").read_text()),
                   cli_executable_sha256=hashlib.sha256(cli.read_bytes()).hexdigest(),
                   fixture_id=fixture["id"], fixture_sha256=fixture["sha256"],
                   source_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                   records=records, signature_valid_after_inference=True,
                   neural_edges=args.neural_edges, normalized_pcm_sha256=normalized_sha,
                   boundary="Two separate cold bundled Swift CLI → owned worker → Metal long-file requests, offline from a foreign cwd. " +
                            ("Exact-sample native neural edge analysis, full PCM hash checks and original timeline offsets; automatic language."
                             if args.neural_edges else "CLI default transcription with automatic language and no supplied trim flag; audio_seconds and speech_seconds record the actual analyzed duration."),
                   limitations=["Functional regression check, not a latency benchmark; includes cold loading and shared-system activity.",
                                "One repeated-speech synthetic hour input, not natural-meeting or production accuracy.",
                                "No microphone, app permissions, audible playback, native UI or insertion."])
    args.output.write_text(json.dumps(receipt, indent=2) + "\n")


if __name__ == "__main__":
    main()
