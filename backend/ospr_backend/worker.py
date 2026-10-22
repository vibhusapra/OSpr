"""Private stdio IPC. One JSON request/response per line, no listening socket.

stdout is protocol only; third-party logs go to stderr. The native app owns
the child process and its lifetime. Audio is never uploaded by this worker.
"""

import json
import os
import sys
import traceback

from . import __version__
from .engine import Engine, PUBLIC_MODELS

MAX_REQUEST = 2 * 1024 * 1024


def dispatch(engine, request):
    action = request.get("action")
    if action == "ping":
        return {"version": __version__, "pid": os.getpid(), "models": PUBLIC_MODELS}
    if action == "warm":
        if request.get("model", "parakeet-v3") not in PUBLIC_MODELS:
            raise ValueError("Model has not passed the shipping quality gate. Use the research harness.")
        return engine.warm(request.get("model", "parakeet-v3"))
    if action == "stream_begin":
        return engine.stream_begin(request.get("language"))
    if action == "stream_feed":
        return engine.stream_feed(request["path"], session_id=request["session_id"])
    if action == "stream_end":
        return engine.stream_feed(final=True, session_id=request["session_id"])
    if action == "stream_cancel":
        return engine.stream_cancel(session_id=request["session_id"])
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
        return engine.rewrite(text, instruction)
    raise ValueError("Unknown action.")


def main():
    engine = Engine()
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
            response = {"id": request.get("id"), "ok": True, "result": dispatch(engine, request)}
        except Exception as error:
            traceback.print_exc(file=sys.stderr)
            response = {
                "id": request.get("id") if isinstance(request, dict) else None,
                "ok": False,
                "error": f"{type(error).__name__}: {error}",
            }
        print(json.dumps(response, ensure_ascii=False, allow_nan=False), flush=True)


if __name__ == "__main__":
    main()
