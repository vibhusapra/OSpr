"""Real Swift/worker/local-provider check; no paid API or ASR quality claim.

An 80-minute FLOAT WAV crosses the former normalized-audio recursion threshold.
The loopback fixture validates every uploaded PCM16 sample against that source.
Provider responses are deterministic sentinels, explicitly not recognition.
"""
import argparse
import datetime
from email.parser import BytesParser
from email.policy import default
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time
import uuid
from urllib.parse import parse_qs, urlsplit

import numpy as np
import soundfile as sf

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    with path.open("rb") as file:
        return hashlib.file_digest(file, "sha256").hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", type=Path, default=ROOT / ".build/debug/ospr-cli")
    parser.add_argument("--provider", choices=("compatible", "deepgram", "soniox"), default="compatible")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.output is None:
        args.output = ROOT / "benchmarks/results" / ({"deepgram": "deepgram-upload-parts.json", "soniox": "soniox-upload-parts.json"}.get(args.provider, "upload-parts.json"))
    manifest_path = ROOT / "benchmarks/fixtures/long-session.json"
    manifest = json.loads(manifest_path.read_text())
    source_item = next(x for x in manifest["items"] if x["id"] == "public-concat-60m")
    source = ROOT / "benchmarks" / source_item["path"]
    assert sha(source) == source_item["sha256"]
    cli = args.cli.resolve(strict=True)
    total = 80 * 60 * 16000
    records, errors = [], []
    with tempfile.TemporaryDirectory(prefix="ospr-upload-check-") as directory:
        recording = Path(directory) / "public-80m.wav"
        with sf.SoundFile(source) as original, sf.SoundFile(recording, "w", samplerate=16000, channels=1, subtype="FLOAT") as output:
            remaining = total
            while remaining:
                block = original.read(min(remaining, 16000 * 30), dtype="float32")
                if not len(block):
                    original.seek(0)
                    continue
                output.write(block)
                remaining -= len(block)
        assert recording.stat().st_size > 256 * 1024 * 1024
        recording_sha = sha(recording)
        cursor = 0
        lock = threading.Lock()
        remote_files, remote_jobs, resource_events = {}, {}, []

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def reply(self, code, value=None):
                data = b"" if value is None else json.dumps(value).encode()
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def do_GET(self):
                try:
                    assert args.provider == "soniox"
                    assert self.headers["Authorization"] == "Bearer ospr-public-fixture-key"
                    parts = self.path.strip("/").split("/")
                    assert parts[:2] == ["v1", "transcriptions"]
                    job = remote_jobs[parts[2]]
                    record = records[job["index"]]
                    if len(parts) == 4:
                        assert parts[3] == "transcript"
                        text = f"Part {record['index'] + 1}. Keep this repeated phrase."
                        tokens = [dict(text=(" " if n else "") + word, start_ms=100 + n * 50,
                                       end_ms=150 + n * 50, confidence=.99, language="en")
                                  for n, word in enumerate(text.split())]
                        self.reply(200, dict(id=parts[2], text=text, tokens=tokens))
                    else:
                        self.reply(200, dict(id=parts[2], status="completed", audio_duration_ms=record["frames"] / 16))
                except Exception as error:
                    errors.append(type(error).__name__)
                    self.reply(400, dict(error="public-fixture contract failed"))

            def do_DELETE(self):
                try:
                    assert args.provider == "soniox"
                    assert self.headers["Authorization"] == "Bearer ospr-public-fixture-key"
                    prefix, kind, identifier = self.path.strip("/").split("/")
                    assert prefix == "v1"
                    with lock:
                        if kind == "transcriptions":
                            del remote_jobs[identifier]
                        else:
                            assert kind == "files"
                            assert not any(job["file_id"] == identifier for job in remote_jobs.values())
                            del remote_files[identifier]
                        resource_events.append(dict(method="DELETE", kind=kind, id=identifier))
                    self.reply(204)
                except Exception as error:
                    errors.append(type(error).__name__)
                    self.reply(400, dict(error="public-fixture contract failed"))

            def do_POST(self):
                nonlocal cursor
                try:
                    length = int(self.headers["Content-Length"])
                    assert length < 25_000_000
                    body = self.rfile.read(length)
                    if args.provider == "soniox" and self.path == "/v1/transcriptions":
                        assert self.headers["Authorization"] == "Bearer ospr-public-fixture-key"
                        config = json.loads(body)
                        assert config["model"] == "stt-async-v5" and config["language_hints"] == ["en"]
                        assert config["enable_speaker_diarization"] is False and config["enable_language_identification"] is True
                        assert config["client_reference_id"].startswith("OSpr-")
                        assert "audio_url" not in config and "translation" not in config and "webhook_url" not in config
                        item = str(uuid.uuid4())
                        with lock:
                            record = records[remote_files[config["file_id"]]]
                            record["job_id"] = item
                            remote_jobs[item] = dict(index=record["index"], file_id=config["file_id"])
                            resource_events.append(dict(method="POST", kind="transcriptions", id=item))
                        self.reply(201, dict(id=item, status="completed", audio_duration_ms=record["frames"] / 16))
                        return
                    if args.provider == "deepgram":
                        route = urlsplit(self.path)
                        query = parse_qs(route.query)
                        assert route.path == "/v1/listen" and query["model"] == ["nova-3"] and query["language"] == ["en"]
                        assert query["filler_words"] == ["true"] and query["smart_format"] == ["false"]
                        assert self.headers["Authorization"] == "Token ospr-public-fixture-key"
                        assert self.headers["Content-Type"] == "audio/wav"
                        fields = {"file": body}
                    else:
                        assert self.path == ("/v1/files" if args.provider == "soniox" else "/v1/audio/transcriptions")
                        assert self.headers["Authorization"] == "Bearer ospr-public-fixture-key"
                        message = BytesParser(policy=default).parsebytes(
                            ("Content-Type: " + self.headers["Content-Type"] + "\r\nMIME-Version: 1.0\r\n\r\n").encode() + body
                        )
                        fields = {p.get_param("name", header="Content-Disposition"): p.get_payload(decode=True) for p in message.iter_parts()}
                        if args.provider == "soniox":
                            assert fields["client_reference_id"].startswith(b"OSpr-")
                        else:
                            assert fields["model"] == b"fixture-parts" and fields["language"] == b"en"
                    with sf.SoundFile(io.BytesIO(fields["file"])) as audio:
                        assert audio.samplerate == 16000 and audio.channels == 1 and audio.subtype == "PCM_16"
                        decoded = audio.read(dtype="float32")
                    assert 0 < len(decoded) <= 600 * 16000
                    with lock, sf.SoundFile(recording) as original:
                        original.seek(cursor)
                        expected = original.read(len(decoded), dtype="float32")
                        assert len(expected) == len(decoded)
                        maximum_error = float(np.max(np.abs(expected - decoded)))
                        assert maximum_error <= 1 / 32768
                        index = len(records)
                        records.append(dict(index=index, start_frame=cursor, frames=len(decoded), request_bytes=length, max_pcm16_error=maximum_error))
                        cursor += len(decoded)
                    if args.provider == "soniox":
                        item = str(uuid.uuid4())
                        with lock:
                            remote_files[item] = index
                            records[index]["file_id"] = item
                            resource_events.append(dict(method="POST", kind="files", id=item))
                        self.reply(201, dict(id=item))
                        return
                    text = f"Part {index + 1}. Keep this repeated phrase."
                    result = {"text": text, "language": "en", "segments": [{"start": .1, "end": .4, "text": text}]}
                    if args.provider == "deepgram":
                        result = {"metadata": {"duration": len(decoded) / 16000}, "results": {
                            "channels": [{"detected_language": "en", "alternatives": [{"transcript": text,
                                "words": [{"word": "keep", "punctuated_word": "Keep", "start": .1, "end": .4}]}]}],
                            "utterances": [{"transcript": text, "start": .1, "end": .4}]}}
                    data = json.dumps(result).encode()
                    self.send_response(200)
                except Exception as error:
                    errors.append(type(error).__name__)
                    data = b'{"error":"public-fixture contract failed"}'
                    self.send_response(400)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        began = time.perf_counter()
        bundled = cli.parent.name == "MacOS" and cli.parent.parent.name == "Contents"
        environment = dict(os.environ, OSPR_TRANSCRIPTION_KEY="ospr-public-fixture-key", HF_HUB_OFFLINE="1")
        environment.pop("OSPR_ROOT", None)
        if not bundled:
            environment["OSPR_ROOT"] = str(ROOT)
        command = {"deepgram": "transcribe-deepgram", "soniox": "transcribe-soniox"}.get(args.provider, "transcribe-cloud")
        model = {"deepgram": "nova-3", "soniox": "stt-async-v5"}.get(args.provider, "fixture-parts")
        process = subprocess.Popen([str(cli), command, str(recording), f"http://127.0.0.1:{server.server_port}/v1", model, "en"],
            cwd=directory, env=environment,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            stdout, stderr = process.communicate(timeout=180)
            assert process.returncode == 0, stderr
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()
            server.shutdown()
            server.server_close()
        elapsed = (time.perf_counter() - began) * 1000
        result = json.loads(stdout)
        assert not errors and cursor == total and result["audio_seconds"] == 4800
        assert result["upload_parts"] == len(records) > 1
        assert result["text"].count("Keep this repeated phrase.") == len(records)
        for record, segment in zip(records, result["segments"], strict=True):
            assert abs(segment["start"] - (record["start_frame"] / 16000 + .1)) < 1e-8
            assert abs(segment["end"] - (record["start_frame"] / 16000 + .4)) < 1e-8
        if args.provider == "deepgram":
            for record, word in zip(records, result["words"], strict=True):
                assert word["text"] == "Keep"
                assert abs(word["start"] - (record["start_frame"] / 16000 + .1)) < 1e-8
        if args.provider == "soniox":
            assert not remote_jobs and not remote_files and "warning" not in result
            assert len(resource_events) == 4 * len(records)
            words = result["words"]
            assert len(words) == 6 * len(records)
            for index, record in enumerate(records):
                assert abs(words[index * 6]["start"] - (record["start_frame"] / 16000 + .1)) < 1e-8
        assert sha(recording) == recording_sha
        workspace_root = Path(tempfile.gettempdir()) / "OSpr-Engine"
        assert not list(workspace_root.glob(f"{process.pid}-upload-*"))
        build = None
        if bundled:
            app = cli.parents[2]
            build = json.loads((app / "Contents/Resources/build-info.json").read_text())
            subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
        evidence = dict(status="passed", provider=args.provider, verified_at=datetime.datetime.now(datetime.UTC).isoformat(),
            git_commit=subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
            source_manifest_sha256=sha(manifest_path), source_sha256=source_item["sha256"],
            generated_fixture_sha256=recording_sha, generated_bytes=recording.stat().st_size,
            cli_sha256=sha(cli), normalized_frames=cursor, seconds=4800, requests=records,
            engine_binding="bundled" if bundled else "checkout", harness_sha256=sha(Path(__file__)),
            build=build, signature_valid_after_upload=True if bundled else None,
            source_preserved=True, workspace_removed=True, native_wall_ms=elapsed,
            boundary="Real Swift CLI → owned Python preparation → serial loopback provider → assembled timestamps. Every sample checked within PCM16 quantization. Fake provider text is a sentinel, not ASR, paid-provider validation, native UI, or a timing benchmark.")
        if args.provider == "soniox":
            evidence["remote_resource_events"] = resource_events
            evidence["all_owned_files_and_jobs_removed"] = not remote_jobs and not remote_files
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(evidence, indent=2) + "\n")
        print(json.dumps({"status": "passed", "seconds": 4800, "parts": len(records), "native_wall_ms": elapsed}))


if __name__ == "__main__":
    main()
