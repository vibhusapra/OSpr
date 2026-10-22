"""Loopback-only API contract fixture. Contains no real provider credentials."""

from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import time


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        data = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if self.path.startswith("/slow/"):
            time.sleep(5)
        status, result = 200, {}
        if self.path.startswith("/redirect/"):
            self.send_response(307)
            self.send_header("Location", f"http://127.0.0.1:{self.server.server_port}/stolen")
            self.end_headers()
            return
        if self.path.startswith("/error/"):
            status, result = 401, {"error": "PRIVATE INPUT MUST NEVER LEAK"}
        elif self.path.endswith("/chat/completions"):
            body = json.loads(data)
            assert body["messages"][0]["role"] == "system"
            assert body["messages"][1]["content"] == "test passage"
            assert self.headers["Authorization"] == "Bearer test-key"
            result = {"choices": [{"message": {"content": "Edited passage."}}]}
        elif self.path.endswith("/messages"):
            body = json.loads(data)
            assert body["system"] and body["max_tokens"] == 4096
            assert self.headers["x-api-key"] == "test-key"
            assert self.headers["anthropic-version"] == "2023-06-01"
            result = {"content": [{"type": "text", "text": "Edited passage."}]}
        elif self.path.endswith("/audio/transcriptions"):
            if self.path.startswith("/anonymous/"):
                assert self.headers.get("Authorization") is None
            else:
                assert self.headers["Authorization"] == "Bearer test-key"
            assert b'filename="recording.wav"' in data
            if b"gpt-transcribe" in data:
                assert b'name="languages[]"' in data and b'name="language"' not in data
            else:
                assert b'name="language"' in data
            if self.path.startswith("/parts"):
                index = 1 if b"PART-1" in data else 0
                if self.path.startswith("/parts-slow") and index == 1:
                    time.sleep(5)
                if self.path.startswith("/parts-fail") and index == 1:
                    status, result = 503, {"error": "PRIVATE INPUT MUST NEVER LEAK"}
                else:
                    end = 99 if self.path.startswith("/parts-badtiming") else .4
                    result = {"text": "Keep repeated phrase.", "language": "en",
                              "segments": [{"start": .1, "end": end, "text": "Keep repeated phrase."}],
                              "words": [{"start": .1, "end": end, "word": "Keep"}]}
            else:
                result = {"text": "A test recording."}
        else:
            status, result = 404, {}
        encoded = json.dumps(result).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)


if __name__ == "__main__":
    server = HTTPServer(("127.0.0.1", 0), Handler)
    print(server.server_port, flush=True)
    server.serve_forever()
