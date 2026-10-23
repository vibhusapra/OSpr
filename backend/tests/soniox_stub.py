"""Owned loopback Files/Transcriptions contract fixture; never contacts Soniox."""
from email import policy
from email.parser import BytesParser
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import threading
import time
import uuid

LOCK = threading.Lock()
FILES, JOBS, REQUESTS = {}, {}, []


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def respond(self, code, value=None):
        raw = b"" if value is None else json.dumps(value).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        try:
            self.wfile.write(raw)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def parse(self):
        parts = self.path.strip("/").split("/")
        mode = parts[0]
        route = "/".join(parts[2:])
        with LOCK:
            REQUESTS.append(dict(method=self.command, path=self.path,
                                 authorization=self.headers.get("Authorization")))
        return mode, route

    def do_POST(self):
        mode, route = self.parse()
        data = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        if mode == "redirect":
            self.send_response(302)
            self.send_header("Location", "/trap/v1/credentials")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if self.headers.get("Authorization") != "Bearer test-key":
            return self.respond(401, dict(message="PRIVATE INPUT"))
        if route == "files":
            message = BytesParser(policy=policy.default).parsebytes(
                ("Content-Type: " + self.headers["Content-Type"] + "\r\n\r\n").encode() + data)
            fields = {part.get_param("name", header="Content-Disposition"): part
                      for part in message.iter_parts()}
            audio = fields["file"].get_payload(decode=True)
            reference = fields["client_reference_id"].get_content().strip()
            assert reference.startswith("OSpr-")
            assert fields["file"].get_filename() == "recording.wav"
            item = str(uuid.uuid4())
            with LOCK:
                FILES[item] = dict(bytes=len(audio), sha256=hashlib.sha256(audio).hexdigest())
            return self.respond(201, dict(id=item))
        if route == "transcriptions":
            if mode == "create-error":
                return self.respond(422, dict(message="PRIVATE INPUT"))
            if mode == "create-server-error":
                return self.respond(503, dict(message="PRIVATE INPUT"))
            config = json.loads(data)
            assert config["file_id"] in FILES
            assert config["model"] == "stt-async-v5"
            assert config["enable_speaker_diarization"] is False
            assert config["enable_language_identification"] is True
            assert "translation" not in config and "audio_url" not in config and "webhook_url" not in config
            if mode == "hints":
                assert config["language_hints"] == ["en", "hi"]
                assert config["context"] == dict(terms=["OSpr", "C++", "naïve café"])
            if mode == "auto":
                assert "language_hints" not in config and "context" not in config
            item = str(uuid.uuid4())
            with LOCK:
                JOBS[item] = dict(config=config, polls=0)
            if mode == "bad-id":
                return self.respond(201, dict(id="../../another-job", status="queued"))
            return self.respond(201, dict(id=item, status="queued"))
        self.respond(404)

    def do_GET(self):
        mode, route = self.parse()
        if route == "stats":
            with LOCK:
                return self.respond(200, dict(files=FILES, jobs=JOBS, requests=REQUESTS))
        if self.headers.get("Authorization") != "Bearer test-key":
            return self.respond(401, dict(message="PRIVATE INPUT"))
        parts = route.split("/")
        item = parts[1] if len(parts) > 1 else ""
        if item not in JOBS:
            return self.respond(404)
        if route.endswith("/transcript"):
            tokens = [dict(text=text, start_ms=start, end_ms=end, confidence=.99, language="en")
                      for text, start, end in [("Hel", 10, 100), ("lo", 100, 200),
                                               (" ", 200, 210), ("world", 250, 700), (".", 700, 750)]]
            if mode == "bad-timing":
                tokens[0]["start_ms"] = True
            return self.respond(200, dict(id=item, text="Hello world.", tokens=tokens))
        with LOCK:
            JOBS[item]["polls"] += 1
            polls = JOBS[item]["polls"]
        if mode == "slow":
            time.sleep(5)
        status = "processing" if mode in ("pending", "slow") or polls == 1 else "completed"
        if mode == "job-error":
            status = "error"
        self.respond(200, dict(id=item, status=status, audio_duration_ms=1000, error_message="PRIVATE INPUT"))

    def do_DELETE(self):
        mode, route = self.parse()
        if self.headers.get("Authorization") != "Bearer test-key":
            return self.respond(401, dict(message="PRIVATE INPUT"))
        if mode == "cleanup-error":
            return self.respond(503, dict(message="PRIVATE INPUT"))
        kind, item = route.split("/", 1)
        with LOCK:
            if kind == "transcriptions":
                if mode in ("pending", "slow"):
                    return self.respond(409, dict(message="PRIVATE INPUT"))
                JOBS.pop(item, None)
            elif kind == "files":
                FILES.pop(item, None)
        self.respond(204)


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    print(server.server_address[1], flush=True)
    server.serve_forever()
