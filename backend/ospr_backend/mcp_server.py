"""Optional stdio MCP adapter. No listener, microphone, history, or UI access.

Clients explicitly provide a local audio file or text. Model downloads can occur
on first inference. Install with `uv sync --extra mcp --extra research`.
"""

import json
import sys
from contextlib import redirect_stdout
from threading import Lock

from mcp.server import MCPServer

from .engine import Engine, PUBLIC_MODELS

server = MCPServer(
    "OSpr",
    instructions="Local Apple Silicon transcription. First model use downloads public weights. Audio stays local. No microphone or history access.",
)
engine = Engine()
gpu_lock = Lock()


@server.tool()
def list_models() -> str:
    """List the pinned local speech engines and their language/license coverage."""
    return json.dumps(PUBLIC_MODELS)


@server.tool()
def transcribe_file(path: str, model: str = "parakeet-v3", language: str = "", vocabulary: str = "") -> str:
    """Transcribe a user-specified LOCAL audio file; no upload or microphone capture.

    path must be an absolute local file path. Available models are returned by
    list_models. Local model weights download from Hugging Face on first use.
    """
    from pathlib import Path

    if not Path(path).is_absolute() or model not in PUBLIC_MODELS:
        raise ValueError("Provide an absolute audio path and a supported model ID.")
    with gpu_lock, redirect_stdout(sys.stderr):
        return json.dumps(engine.transcribe(path, model, language or None, vocabulary[:16000]))


@server.tool()
def rewrite_text(text: str, instruction: str) -> str:
    """Rewrite supplied text using the local quantized model. Original is returned
    alongside output for review: LLM edits may omit or change meaning.
    """
    if len(text) > 100000 or len(instruction) > 16000:
        raise ValueError("Rewrite input too long.")
    with gpu_lock, redirect_stdout(sys.stderr):
        return json.dumps(dict(original=text, **engine.rewrite(text, instruction)))


if __name__ == "__main__":
    server.run(transport="stdio")
