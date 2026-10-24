"""Actual local stdio MCP summary and bounded-input rejection, no GUI/history."""

import argparse
import asyncio
import json
import os
from pathlib import Path
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent


async def run(python):
    from mcp import Client, StdioServerParameters

    protocol = json.loads((ROOT / "benchmarks/fixtures/meeting-summary-protocol.json").read_text())
    case = next(row for row in protocol["cases"] if row["id"] == "explicit-correction")
    with tempfile.TemporaryDirectory(prefix="ospr-summary-mcp-") as directory:
        environment = dict(os.environ, PYTHONPATH=str(ROOT / "backend"), HF_HUB_OFFLINE="1")
        parameters = StdioServerParameters(
            command=str(python), args=["-m", "ospr_backend.mcp_server"], env=environment, cwd=directory
        )
        async with Client(parameters, read_timeout_seconds=300) as client:
            names = sorted(row.name for row in (await client.list_tools()).tools)
            assert names == ["list_models", "rewrite_text", "summarize_text", "transcribe_file"]
            result = await client.call_tool("summarize_text", dict(text=case["text"]))
            assert not result.is_error, result
            summary = json.loads(result.content[0].text)
            assert summary["items"] and summary["model"] == "mlx-community/Qwen3.5-9B-4bit"
            assert all(row["text"] in case["text"] for row in summary["excerpts"])
            oversized = await client.call_tool("summarize_text", dict(text="x" * 100001))
            assert oversized.is_error
            assert "x" * 100 not in str(oversized.content)
    build_path = python.parents[3] / "build-info.json"
    return dict(
        status="passed-local-summary-mcp-inference-and-input-bound",
        tools=names,
        summary=summary,
        oversized_input_rejected=True,
        oversized_text_not_echoed=True,
        build=json.loads(build_path.read_text()) if build_path.is_file() else None,
        boundary="Actual owned local stdio MCP server from foreign cwd, offline cached 9B public synthetic input, source membership checks and 100001-character input rejection without echo. Not native app/history/microphone, source entailment/representative meeting quality, isolated latency/energy, provider account or consumer ranking acceptance.",
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--python", type=Path, default=Path(sys.executable))
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    result = asyncio.run(run(args.python.absolute()))
    args.output.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n")
    print(result["status"])


if __name__ == "__main__":
    main()
