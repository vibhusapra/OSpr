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
def transcribe_file(
    path: str,
    model: str = "parakeet-v3",
    language: str = "",
    vocabulary: str = "",
    speaker_labels: bool = False,
) -> str:
    """Transcribe a user-specified LOCAL audio file; no upload or microphone capture.

    path must be an absolute local file path. Available models are returned by
    list_models. Local model weights download from Hugging Face on first use.
    speaker_labels enables experimental local anonymous diarization and word
    timing with Parakeet or Whisper; it does not identify people or separate overlap.
    The full normalized waveform is recognized without volume or neural edge filtering.
    """
    from pathlib import Path

    if not Path(path).is_absolute() or model not in PUBLIC_MODELS:
        raise ValueError("Provide an absolute audio path and a supported model ID.")
    with gpu_lock, redirect_stdout(sys.stderr):
        result = (
            engine.meeting(path, model, language or None, vocabulary[:16000])
            if speaker_labels
            else engine.transcribe(path, model, language or None, vocabulary[:16000])
        )
        return json.dumps(result)


@server.tool()
def rewrite_text(text: str, instruction: str, model: str = "rewrite-quality") -> str:
    """Rewrite supplied text using the local quantized model. Original is returned
    alongside output for review: LLM edits may omit or change meaning. model is
    rewrite-quality (4B, default) or meeting-quality (9B, experimental). Prepare
    the 6 GB 9B weights first with CLI download meeting-quality or native Models.
    """
    if len(text) > 100000 or len(instruction) > 16000:
        raise ValueError("Rewrite input too long.")
    from .refinement import prepared_local_model

    with gpu_lock, redirect_stdout(sys.stderr):
        selected_model = prepared_local_model(model, engine)
        return json.dumps(dict(original=text, **engine.rewrite(text, instruction, model_id=selected_model)))


@server.tool()
def summarize_text(text: str) -> str:
    """Draft local meeting notes with exact source quotes for review. First use
    downloads a 6 GB 9B model. Maximum input: 100,000 characters. AI paraphrases can be wrong or incomplete;
    citations are not entailment proof. No microphone, history, upload or task execution.
    """
    with gpu_lock, redirect_stdout(sys.stderr):
        return json.dumps(engine.summary(text), ensure_ascii=False)


if __name__ == "__main__":
    server.run(transport="stdio")
