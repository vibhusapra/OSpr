import asyncio
import json
import os
from pathlib import Path
import sys

import pytest


def test_mcp_stdio_tools_list_and_silence_transcription(tmp_path):
    pytest.importorskip("mcp")
    import numpy as np
    import soundfile as sf
    from mcp import Client, StdioServerParameters

    path = tmp_path / "silence.wav"
    sf.write(path, np.zeros(16000), 16000)

    async def run():
        parameters = StdioServerParameters(
            command=sys.executable,
            args=["-m", "ospr_backend.mcp_server"],
            env=dict(os.environ, PYTHONPATH=str(Path(__file__).resolve().parents[1])),
        )
        async with Client(parameters) as client:
            listing = await client.list_tools()
            assert {tool.name for tool in listing.tools} == {"list_models", "transcribe_file", "rewrite_text"}
            models = await client.call_tool("list_models", {})
            assert "parakeet-v3" in json.loads(models.content[0].text)
            transcript = await client.call_tool("transcribe_file", {"path": str(path)})
            assert not transcript.is_error
            assert json.loads(transcript.content[0].text)["silence"]

    asyncio.run(run())
