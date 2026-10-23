"""Private stdio IPC. One JSON object per line, no listening socket.

Each request has one final response. Explicit warm/download requests may also
receive request-ID-scoped progress events before that response.

stdout is protocol only; third-party logs go to stderr. The native app owns
the child process and its lifetime. Audio is never uploaded by this worker.
"""

import json
import os
import sys
import traceback
import threading

from . import __version__
from .engine import Engine, PUBLIC_MODELS, MODEL_LOCK, resolve_model

MAX_REQUEST = 2 * 1024 * 1024


def dispatch(engine, request):
    action = request.get("action")
    if action == "ping":
        return {"version": __version__, "pid": os.getpid(), "models": PUBLIC_MODELS}
    if action == "warm":
        if request.get("model", "parakeet-v3") not in PUBLIC_MODELS:
            raise ValueError("Model has not passed the shipping quality gate. Use the research harness.")
        return engine.warm(request.get("model", "parakeet-v3"))
    if action == "model_status":
        from .model_cache import inventory

        return {"models": inventory(MODEL_LOCK, [*PUBLIC_MODELS, "rewrite-quality", "diarization"]),
                "resident": list(engine.models), "rewrite_resident": engine.rewriter_id,
                "diarizer_resident": engine.diarizer is not None}
    if action == "download_model":
        model = request.get("model")
        if model not in {*PUBLIC_MODELS, "rewrite-quality", "diarization"}:
            raise ValueError("Unknown shipping model.")
        resolve_model(model, engine.progress)
        return {"model": model, "complete": True}
    if action == "stream_begin":
        return engine.stream_begin(request.get("language"))
    if action == "stream_feed":
        return engine.stream_feed(request["path"], session_id=request["session_id"])
    if action == "stream_end":
        return engine.stream_feed(final=True, session_id=request["session_id"])
    if action == "stream_cancel":
        return engine.stream_cancel(session_id=request["session_id"])
    if action == "mix_meeting":
        from .meeting_audio import mix_tracks

        return mix_tracks(request["tracks"], request["output"])
    if action == "prepare_upload":
        from .upload_audio import prepare_upload

        return prepare_upload(request["path"], request["output"])
    if action == "prepare_upload_parts":
        from .upload_audio import prepare_upload_parts

        return prepare_upload_parts(request["path"], request["output_dir"])
    if action == "prepare_review":
        from .review_audio import prepare_review

        return prepare_review(request["path"], request["output"], request["limit_bytes"])
    if action == "meeting":
        return engine.meeting(
            request["path"],
            request.get("model", "parakeet-v3"),
            request.get("language"),
            request.get("vocabulary", "")[:16000],
            bool(request.get("trim", True)),
            float(request.get("threshold", 0.003)),
        )
    if action == "transcribe":
        model = request.get("model", "parakeet-v3")
        if model not in PUBLIC_MODELS:
            raise ValueError("Unknown model.")
        threshold = float(request.get("threshold", 0.003))
        if not 0 <= threshold <= 0.1:
            raise ValueError("Threshold must be between 0 and 0.1.")
        return engine.transcribe(
            request["path"],
            model,
            request.get("language"),
            request.get("vocabulary", "")[:16000],
            bool(request.get("trim", True)),
            threshold,
        )
    if action == "rewrite":
        text, instruction = request.get("text", ""), request.get("instruction", "")
        if len(text) > 100000 or len(instruction) > 16000:
            raise ValueError("Rewrite input too long.")
        return engine.rewrite(text, instruction, task=request.get("task", "transcript"))
    if action == "notes":
        return engine.notes(request.get("text", ""))
    raise ValueError("Unknown action.")


def main():
    # A private process group lets the native owner cancel FFmpeg descendants too.
    if hasattr(os, "setsid"):
        try:
            os.setsid()
        except PermissionError:
            pass  # Already a session/group leader in an embedding process.
    engine = Engine()
    output_lock = threading.Lock()
    protocol_stdout = sys.stdout  # Engine redirects third-party stdout while loading.

    def emit(value):
        with output_lock:
            print(json.dumps(value, ensure_ascii=False, allow_nan=False), file=protocol_stdout, flush=True)

    while True:
        raw = sys.stdin.buffer.readline(MAX_REQUEST + 1)
        if not raw:
            return
        if len(raw) > MAX_REQUEST:
            # Do not attempt to resynchronize a truncated request.
            return
        request = {}
        try:
            request = json.loads(raw)
            if not isinstance(request, dict):
                raise ValueError("Expected a JSON object.")
            request_id = request.get("id")
            if request.get("action") in {"warm", "download_model"}:
                engine.progress = lambda event, request_id=request_id: emit({"id": request_id, "event": "progress", "progress": event})
            response = {"id": request.get("id"), "ok": True, "result": dispatch(engine, request)}
        except Exception as error:
            if os.environ.get("OSPR_DEBUG_LOG") == "1":
                traceback.print_exc(file=sys.stderr)
            response = {
                "id": request.get("id") if isinstance(request, dict) else None,
                "ok": False,
                "error": f"{type(error).__name__}: {error}",
            }
        finally:
            engine.progress = None
        emit(response)


if __name__ == "__main__":
    main()
