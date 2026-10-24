"""Exact-bundle MCP defaults on original/quiet public speech and exact zero.

Known regression controls, not held-out accuracy or native microphone evidence.
"""

import argparse
import asyncio
import datetime
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

from mcp import Client, StdioServerParameters
import numpy as np
import soundfile as sf

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


async def check(app, staging):
    baseline_path = ROOT / "benchmarks/results/full-audio-defaults-real.json"
    baseline = json.loads(baseline_path.read_text())
    manifest = json.loads((ROOT / "benchmarks/fixtures/fleurs.json").read_text())
    item = next(row for row in manifest["items"] if row["id"] == "fleurs-de_de-000")
    original = ROOT / "benchmarks" / item["path"]
    assert sha(original) == item["sha256"]
    audio, rate = sf.read(original, dtype="float32")
    assert rate == 16000 and audio.ndim == 1
    quiet = staging / "public-quiet.wav"
    sf.write(quiet, audio * np.float32(0.01), rate, subtype="FLOAT")
    zero = staging / "public-zero.wav"
    sf.write(zero, np.zeros(16000, dtype=np.float32), rate, subtype="FLOAT")
    launcher = app / "Contents/Resources/Engine/.venv/bin/python"
    environment = dict(HOME=str(Path.home()), PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
                       HF_HUB_OFFLINE="1", OSPR_DEBUG_LOG="0")
    parameters = StdioServerParameters(command=str(launcher), args=["-m", "ospr_backend.mcp_server"],
                                      env=environment, cwd=str(staging))
    records = []
    async with Client(parameters) as client:
        for suffix, path in [("original", original), ("quiet40db", quiet)]:
            identifier = item["id"] + "-" + suffix
            expected = next(row for row in baseline["records"] if row["id"] == identifier and row["model"] == "parakeet-v3")
            decoded, actual_rate = sf.read(path, dtype="float32")
            assert actual_rate == rate
            pcm_sha = hashlib.sha256(decoded.astype("<f4", copy=False).tobytes()).hexdigest()
            assert pcm_sha == expected["pcm_sha256"]
            result = await client.call_tool("transcribe_file", dict(path=str(path), model="parakeet-v3", language="de"))
            assert not result.is_error
            value = json.loads(result.content[0].text)
            assert value["text"] == expected["expected_text"]
            assert value["audio_seconds"] == value["speech_seconds"] == len(audio) / rate
            records.append(dict(id=identifier, pcm_sha256=pcm_sha, samples=len(decoded),
                                expected_text=expected["expected_text"], result=value))
        result = await client.call_tool("transcribe_file", dict(path=str(zero), model="parakeet-v3"))
        assert not result.is_error
        value = json.loads(result.content[0].text)
        assert value["text"] == "" and value["empty_reason"] == "normalized_zero"
        records.append(dict(id="synthetic-exact-zero", samples=16000, result=value))
    return dict(records=records, source_sha256=item["sha256"], source_receipt_sha256=sha(baseline_path),
                python_launcher_sha256=sha(launcher))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    assert not args.output.exists()
    app = args.app.resolve(strict=True)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    with tempfile.TemporaryDirectory(prefix="ospr-bundled-defaults-") as folder:
        result = asyncio.run(check(app, Path(folder)))
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    receipt = dict(result, status="passed", timestamp=datetime.datetime.now(datetime.UTC).isoformat(),
        build=json.loads((app / "Contents/Resources/build-info.json").read_text()),
        harness_sha256=sha(Path(__file__)), actual_asr=2, requests=3, signature_valid_after_inference=True,
        boundary="Real bundled MCP default transcription against two known full-audio controls and exact-zero abstention. Offline, foreign cwd, no supplied trim flag; quiet PCM hash checked before inference. No microphone, native UI, insertion, new accuracy or latency comparison.")
    args.output.write_text(json.dumps(receipt, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps(dict(status="passed", actual_asr=2, requests=3)))


if __name__ == "__main__":
    main()
