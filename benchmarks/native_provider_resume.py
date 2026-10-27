"""Local synthetic provider for native saved-route confirmation acceptance.

Serve uses a manifest-bound public clip or explicit generated CI silence. It
records hashes/fields, never credentials or request bodies. Prepare/verify use
an owned headless profile and cannot claim native interaction. All outputs are
private pending review.
"""
from __future__ import annotations

import argparse
from email.parser import BytesParser
from email.policy import default
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import threading
import time
import wave

from durable_import_common import application_fingerprint, digest, prepare_probe


def serve(package, root, synthetic=False):
    root.mkdir(parents=True, mode=0o700, exist_ok=False)
    if synthetic:
        audio = root / "Provider Resume.wav"
        with wave.open(str(audio), "wb") as output:
            output.setnchannels(1)
            output.setsampwidth(2)
            output.setframerate(16000)
            output.writeframes(bytes(32000))
        item = dict(id="synthetic-ci-silence", sha256=digest(audio), seconds=1)
    else:
        item = json.loads((package / "benchmarks/fixtures/manifest.json").read_text())["items"][0]
        audio = package / "benchmarks" / item["path"]
        if digest(audio) != item["sha256"]:
            raise ValueError("Public input differs from manifest")
        shutil.copy2(audio, root / "Provider Resume.wav")
    lock = threading.Lock()
    records = []

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            length = int(self.headers.get("Content-Length", "0"))
            observed = dict(path=self.path, bytes=length, credential_present=bool(self.headers.get("Authorization")), cookie_present=bool(self.headers.get("Cookie")))
            try:
                assert self.path == "/saved/v1/audio/transcriptions" and 0 < length < 1_000_000
                assert not observed["credential_present"] and not observed["cookie_present"]
                body = self.rfile.read(length)
                message = BytesParser(policy=default).parsebytes(("Content-Type: " + self.headers["Content-Type"] + "\r\nMIME-Version: 1.0\r\n\r\n").encode() + body)
                fields = {p.get_param("name", header="Content-Disposition"): p.get_payload(decode=True) for p in message.iter_parts()}
                assert set(fields) == {"model", "response_format", "language", "prompt", "file"}
                assert fields["model"] == b"fixture-resume-original" and fields["language"] == b"en"
                assert fields["prompt"] == b"original public vocabulary" and fields["response_format"] == b"json"
                import hashlib
                observed.update(model=fields["model"].decode(), language=fields["language"].decode(), vocabulary=fields["prompt"].decode(), audio_sha256=hashlib.sha256(fields["file"]).hexdigest())
                assert observed["audio_sha256"] == item["sha256"]
                observed["status"] = "accepted-original-saved-route-and-public-bytes"
                response = dict(text="Public provider resume fixture result.", audio_seconds=item["seconds"], segments=[])
                status = 200
            except Exception as error:
                observed.update(status="rejected", error_type=type(error).__name__)
                response, status = {"error": "owned fixture contract failed"}, 400
            with lock:
                records.append(observed)
                (root / "requests.json").write_text(json.dumps(records, indent=2) + "\n")
            data = json.dumps(response).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    plan = dict(host="127.0.0.1", port=server.server_port, saved_base=f"http://127.0.0.1:{server.server_port}/saved/v1",
                current_base=f"http://127.0.0.1:{server.server_port}/current/v1", saved_model="fixture-resume-original",
                response_text="Public provider resume fixture result.", fixture_id=item["id"], fixture_sha256=item["sha256"], server_pid=os.getpid())
    (root / "requests.json").write_text("[]\n")
    def terminate(_signal, _frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, terminate)
    ready = root / "server.staged.json"
    ready.write_text(json.dumps(plan, indent=2) + "\n")
    ready.replace(root / "server.json")
    print(json.dumps(dict(status="serving-owned-loopback", port=server.server_port)), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


def probe(package, root, app, stage):
    build = json.loads((app / "Contents/Resources/build-info.json").read_text())
    if build["application_source_sha256"] != application_fingerprint(package):
        raise ValueError("Selected app source differs from current checkout")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    source = package / "benchmarks/native_provider_resume.swift"
    if stage == "prepare":
        temporary = package / "Tests/OSprPlatformTests/NativeProviderResumeTemporary.swift"
        if temporary.exists() or (root / "protocol-private.json").exists():
            raise ValueError("Existing provider probe; select a fresh run")
        try:
            shutil.copy2(source, temporary)
            binding = prepare_probe(package, root, "native_provider_resume.swift", "NativeProviderResumeTemporary")
        finally:
            temporary.unlink(missing_ok=True)
        protocol = dict(build=build, app_sha256=digest(app / "Contents/MacOS/OSpr"), runner_sha256=digest(Path(__file__)), binding=binding)
        (root / "protocol-private.json").write_text(json.dumps(protocol, indent=2) + "\n")
    else:
        protocol = json.loads((root / "protocol-private.json").read_text())
        if protocol["build"] != build or protocol["runner_sha256"] != digest(Path(__file__)) or protocol["app_sha256"] != digest(app / "Contents/MacOS/OSpr") or protocol["binding"]["probe_sha256"] != digest(source):
            raise ValueError("App/runner/probe changed after preparation")
    executable = package / ".build/debug/OSprPackageTests.xctest/Contents/MacOS/OSprPackageTests"
    if digest(executable) != protocol["binding"]["test_executable_sha256"]:
        raise ValueError("Compiled provider probe changed")
    command = [subprocess.check_output(["xcrun", "--find", "xctest"], text=True).strip(), "-XCTest", "OSprPlatformTests.NativeProviderResumeTemporary/testStage", str(executable.parents[2])]
    environment = os.environ | {"HF_HUB_OFFLINE": "1", "OSPR_PROVIDER_RESUME_STAGE": stage, "OSPR_PROVIDER_RESUME_ROOT": str(root)}
    with (root / (stage + ".log")).open("x") as log:
        result = subprocess.run(command, cwd=package, env=environment, stdout=log, stderr=subprocess.STDOUT, timeout=120)
    if result.returncode:
        raise RuntimeError("Provider fixture stage failed; original log/profile retained")
    requests = json.loads((root / "requests.json").read_text())
    expected = 1 if stage in {"verify-completed", "exercise-headless"} else 0
    if len(requests) != expected or any(row["status"] != "accepted-original-saved-route-and-public-bytes" for row in requests):
        raise ValueError("Unexpected provider request count or route")
    print(json.dumps(dict(status="passed-" + stage, requests=len(requests), native_interaction_proven=False)))


def ci_control(package, root, app):
    if root.exists():
        raise ValueError("Refusing to replace an existing CI fixture")
    root.parent.mkdir(parents=True, exist_ok=True)
    with (root.parent / (root.name + "-server.log")).open("x") as log:
        server = subprocess.Popen([str(package / ".venv/bin/python"), str(Path(__file__).resolve()),
                                   "--stage", "serve", "--synthetic-ci-fixture", "--output", str(root)],
                                  cwd=package, stdout=log, stderr=subprocess.STDOUT)
        try:
            limit = time.monotonic() + 10
            while not (root / "server.json").is_file():
                if server.poll() is not None or time.monotonic() > limit:
                    raise RuntimeError("Owned synthetic provider did not become ready; log retained")
                time.sleep(.02)
            if server.poll() is not None:
                raise RuntimeError("Owned synthetic provider exited after readiness; log retained")
            probe(package, root, app, "prepare")
            probe(package, root, app, "exercise-headless")
        finally:
            if server.poll() is None:
                server.terminate()
                try:
                    server.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.wait(timeout=5)
    if server.returncode != 0:
        raise RuntimeError("Owned synthetic provider did not stop cleanly")
    plan = json.loads((root / "server.json").read_text())
    assert plan["fixture_id"] == "synthetic-ci-silence"
    (root / "ci-result.json").write_text(json.dumps(dict(status="passed-synthetic-provider-controller-ci", requests=1,
        owned_server_stopped=True, model_downloads=False, provider_credentials=False, native_interaction_proven=False), indent=2) + "\n")
    print("Passed synthetic provider/controller CI; owned server stopped; no models, credentials or native UI.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stage", required=True, choices=("serve", "prepare", "verify-declined", "verify-completed", "exercise-headless", "ci"))
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--app", type=Path)
    parser.add_argument("--synthetic-ci-fixture", action="store_true", help="Serve generated silence for credential-free HTTP/controller CI; not ASR or native UI acceptance")
    args = parser.parse_args()
    package, root = Path(__file__).resolve().parents[1], args.output.resolve()
    if args.stage == "serve":
        serve(package, root, args.synthetic_ci_fixture)
    else:
        if args.app is None:
            parser.error("--app is required for probe stages")
        if args.stage == "ci":
            ci_control(package, root, args.app.resolve(strict=True))
        else:
            probe(package, root, args.app.resolve(strict=True), args.stage)


if __name__ == "__main__":
    main()
