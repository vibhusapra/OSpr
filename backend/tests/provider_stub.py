"""Loopback-only API contract fixture. Contains no real provider credentials."""

from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import time
from urllib.parse import parse_qs, urlsplit


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        data = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        route = urlsplit(self.path)
        if self.path.startswith("/slow/"):
            time.sleep(5)
        status, result = 200, {}
        if self.path.startswith("/redirect/"):
            self.send_response(307)
            self.send_header("Location", f"http://127.0.0.1:{self.server.server_port}/stolen")
            self.end_headers()
            return
        if route.path.endswith("/listen"):
            query = parse_qs(route.query)
            assert self.headers["Authorization"] == "Token test-key"
            assert self.headers["Content-Type"] == "audio/wav"
            assert query["model"] == ["nova-3"] and query["smart_format"] == ["false"]
            assert query["numerals"] == ["false"] and query["punctuate"] == ["true"]
            assert query["filler_words"] == ["true"] and query["utterances"] == ["true"]
            assert query["multichannel"] == ["false"]
            assert "diarize" not in query and "callback" not in query and "summarize" not in query
            if route.path.startswith("/deepgram-auto/"):
                assert query["detect_language"] == ["true"] and "language" not in query
            else:
                assert query["language"] == ["en"] and "detect_language" not in query
            if route.path.startswith("/deepgram-hints/"):
                assert query["keyterm"] == ["OSpr", "C++", "R&D", "naïve café"]
            index = 1 if data == b"PART-1" else 0
            assert data in (b"RIFF-public-fixture", b"PART-0", b"PART-1")
            if route.path.startswith("/deepgram-slow/") and index == 1:
                time.sleep(5)
            duration = .5 if index == 1 else 1
            word = {"word": "keep", "punctuated_word": "Keep", "start": .1, "end": .4}
            utterance = {"transcript": "Keep repeated phrase.", "start": .1, "end": .4}
            result = {"metadata": {"duration": duration}, "results": {
                "channels": [{"detected_language": "en", "alternatives": [{"transcript": "Keep repeated phrase.", "words": [word]}]}],
                "utterances": [utterance]}}
            if route.path.startswith("/deepgram-coarse/"):
                word["end"] = 99
                utterance["end"] = 99
            if route.path.startswith("/deepgram-fail/") and index == 1:
                status, result = 503, {"error": "PRIVATE INPUT MUST NEVER LEAK"}
        elif self.path.startswith("/error/"):
            status, result = 401, {"error": "PRIVATE INPUT MUST NEVER LEAK"}
        elif route.path.endswith("/models/test-model:generateContent"):
            body = json.loads(data)
            assert self.headers["x-goog-api-key"] == "test-key"
            assert self.headers.get("Authorization") is None
            assert not route.query
            assert body["contents"] == [{"role": "user", "parts": [{"text": "test passage"}]}]
            assert "Preserve meaning" in body["systemInstruction"]["parts"][0]["text"]
            assert body["systemInstruction"]["parts"][0]["text"].endswith("Clean up.")
            assert body["generationConfig"] == {"candidateCount": 1, "maxOutputTokens": 4096}
            assert "tools" not in body and "safetySettings" not in body
            candidate = {"finishReason": "STOP", "content": {"role": "model", "parts": [
                {"text": "PRIVATE THOUGHT", "thought": True},
                {"text": "Edited "}, {"text": "passage.", "thoughtSignature": "test-signature"}]}}
            if route.path.startswith("/gemini-truncated/"):
                candidate["finishReason"] = "MAX_TOKENS"
            if route.path.startswith("/gemini-blocked/"):
                candidate["finishReason"] = "SAFETY"
            if route.path.startswith("/gemini-negation/"):
                candidate["content"]["parts"] = [{"text": "Do not ship."}]
            result = {"candidates": [candidate]}
        elif route.path.endswith("/openai/v1/chat/completions"):
            body = json.loads(data)
            assert self.headers["api-key"] == "test-key"
            assert self.headers.get("Authorization") is None
            assert self.headers.get("x-goog-api-key") is None
            assert not route.query
            assert body["model"] == "test-deployment"
            assert body["messages"][0]["role"] == "system"
            assert body["messages"][0]["content"].endswith("Clean up.")
            assert body["messages"][1] == {"role": "user", "content": "test passage"}
            assert body["max_completion_tokens"] == 4096 and body["n"] == 1
            assert body["stream"] is False and body["store"] is False
            assert "temperature" not in body and "tools" not in body
            message = {"role": "assistant", "content": "Edited passage.", "refusal": None}
            choice = {"index": 0, "finish_reason": "stop", "message": message}
            if route.path.startswith("/azure-truncated/"):
                choice["finish_reason"] = "length"
            if route.path.startswith("/azure-filtered/"):
                choice["content_filter_results"] = {"hate": {"filtered": True}}
            if route.path.startswith("/azure-refused/"):
                message["refusal"] = "PRIVATE REFUSAL"
            if route.path.startswith("/azure-negation/"):
                message["content"] = "Do not ship."
            result = {"choices": [choice]}
        elif self.path.endswith("/chat/completions"):
            body = json.loads(data)
            assert body["messages"][0]["role"] == "system"
            assert body["messages"][1]["content"] == "test passage"
            if route.path.startswith("/anonymous-rewrite/"):
                assert self.headers.get("Authorization") is None
            else:
                assert self.headers["Authorization"] == "Bearer test-key"
            message = {"role": "assistant", "content": "Edited passage.", "refusal": None}
            choice = {"index": 0, "finish_reason": "stop", "message": message}
            if route.path.startswith("/rewrite-truncated/"):
                choice["finish_reason"] = "length"
            if route.path.startswith("/rewrite-refused/"):
                message["refusal"] = "PRIVATE REFUSAL"
            if route.path.startswith("/rewrite-tool/"):
                choice["finish_reason"] = "tool_calls"
                message["tool_calls"] = [{"id": "fake", "type": "function", "function": {"name": "fake", "arguments": "{}"}}]
            if route.path.startswith("/rewrite-missing/"):
                choice.pop("finish_reason")
            if route.path.startswith("/rewrite-empty/"):
                message["content"] = " \n"
            if route.path.startswith("/rewrite-negation/"):
                message["content"] = "Do not ship."
            result = {"choices": [choice]}
        elif self.path.endswith("/messages"):
            body = json.loads(data)
            assert body["system"] and body["max_tokens"] == 4096
            assert self.headers["x-api-key"] == "test-key"
            assert self.headers["anthropic-version"] == "2023-06-01"
            result = {"type": "message", "role": "assistant", "stop_reason": "end_turn", "stop_sequence": None,
                      "content": [{"type": "text", "text": "Edited passage."}]}
            if route.path.startswith("/rewrite-truncated/"):
                result["stop_reason"] = "max_tokens"
            if route.path.startswith("/rewrite-refused/"):
                result["stop_reason"] = "refusal"
                result["stop_details"] = {"explanation": "PRIVATE REFUSAL"}
            if route.path.startswith("/rewrite-tool/"):
                result["stop_reason"] = "tool_use"
                result["content"].append({"type": "tool_use", "id": "fake", "name": "fake", "input": {}})
            if route.path.startswith("/rewrite-missing/"):
                result.pop("stop_reason")
            if route.path.startswith("/rewrite-empty/"):
                result["content"] = [{"type": "text", "text": " \n"}]
            if route.path.startswith("/rewrite-negation/"):
                result["content"] = [{"type": "text", "text": "Do not ship."}]
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
