"""Real bundled MCP default transcription against two known full-audio controls."""
import argparse
import asyncio
import datetime
import gzip
import hashlib
import json
from pathlib import Path
import tempfile

from mcp import Client, StdioServerParameters

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


async def check(args):
    source_path = ROOT / "benchmarks/results/neural-edges-multilingual-v1.json"
    source = json.loads(source_path.read_text())
    archive = source_path.with_name(source["traces_file"])
    assert sha(archive) == source["traces_sha256"]
    raw = json.loads(gzip.decompress(archive.read_bytes()))
    identifiers = ["fleurs-de_de-000-original", "fleurs-de_de-000-quiet40db"]
    app = args.app.resolve(strict=True)
    python = app / "Contents/Resources/Engine/.venv/bin/python"
    build = json.loads((app / "Contents/Resources/build-info.json").read_text())
    assert not build["tracked_changes"] and not args.output.exists()
    records = []
    with tempfile.TemporaryDirectory(prefix="OSpr MCP default ") as directory:
        parameters = StdioServerParameters(command=str(python), args=["-m", "ospr_backend.mcp_server"],
            cwd=directory, env=dict(HOME=str(Path.home()), PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
                                   HF_HUB_OFFLINE="1", HF_HUB_DISABLE_TELEMETRY="1"))
        async with Client(parameters) as client:
            for identifier in identifiers:
                item = next(row for row in raw["items"] if row["id"] == identifier)
                expected = next(row["full"] for row in raw["records"] if row["id"] == identifier and row["model"] == "parakeet-v3")
                path = (ROOT / "benchmarks" / item["original_path"] if item["variant"] == "original"
                        else args.source_work.resolve() / f"{identifier}.wav")
                assert sha(path) == item["sha256"]
                response = await client.call_tool("transcribe_file", dict(path=str(path), language="de"))
                assert not response.is_error
                result = json.loads(response.content[0].text)
                assert result["text"] == expected["text"]
                assert result["speech_seconds"] == result["audio_seconds"] == item["samples"] / 16000
                records.append(dict(id=identifier, file_sha256=item["sha256"], expected_text=expected["text"], result=result))
    receipt = dict(status="passed", timestamp=datetime.datetime.now(datetime.UTC).isoformat(), build=build,
        python_launcher_sha256=sha(python), harness_sha256=sha(Path(__file__)), source_receipt_sha256=sha(source_path),
        actual_asr=2, records=records, boundary=__doc__.strip() + " Offline, foreign cwd; no microphone, history or UI access. Not a new held-out accuracy or latency benchmark.")
    args.output.write_text(json.dumps(receipt, indent=2, ensure_ascii=False) + "\n")
    print("Passed: two real bundled MCP full-audio default recognitions, original and quiet German")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--source-work", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    asyncio.run(asyncio.wait_for(check(args), timeout=180))


if __name__ == "__main__":
    main()
