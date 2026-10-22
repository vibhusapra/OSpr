"""Persistent whisper.cpp Metal baseline; NOT a benchmark of a consumer app.

Use the same preprocessed input as OSpr. HTTP transport is included in wall time;
model download is excluded, server startup + first decode are reported separately.
"""

import argparse
import datetime
import hashlib
import io
import json
from pathlib import Path
import platform
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

import soundfile as sf

from ospr_backend.audio import read_audio, speech_bounds, SAMPLE_RATE
from run import summarize

ROOT = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--weights", required=True)
    parser.add_argument("--manifest", default="fixtures/test-clean.json")
    parser.add_argument("--limit", type=int, default=0)
    args = parser.parse_args()
    items = json.loads((ROOT / args.manifest).read_text())["items"]
    if args.limit:
        items = items[: args.limit]
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    records = []
    with tempfile.TemporaryDirectory(prefix="ospr-cpp-") as temporary:
        log = Path(temporary) / "server.log"
        with log.open("w") as handle:
            started = time.perf_counter()
            command = [
                "whisper-server",
                "-m",
                str(Path(args.weights).resolve()),
                "--host",
                "127.0.0.1",
                "--port",
                str(port),
                "-l",
                "en",
                "-bo",
                "1",
                "-bs",
                "1",
                "-nf",
                "-t",
                "4",
                "--tmp-dir",
                temporary,
            ]
            server = subprocess.Popen(command, stdout=handle, stderr=handle)
            try:
                for _ in range(600):
                    if server.poll() is not None:
                        raise RuntimeError(log.read_text()[-4000:])
                    try:
                        urllib.request.urlopen(f"http://127.0.0.1:{port}/", timeout=0.2).close()
                        break
                    except (urllib.error.URLError, TimeoutError):
                        time.sleep(0.1)
                else:
                    raise TimeoutError("whisper.cpp startup timed out")
                startup_ms = (time.perf_counter() - started) * 1000

                def transcribe(item):
                    begin = time.perf_counter()
                    audio = read_audio(str(ROOT / item["path"]))
                    left, right = speech_bounds(audio)
                    if left == right:
                        return dict(text="", wall_ms=(time.perf_counter() - begin) * 1000, silence=True)
                    stream = io.BytesIO()
                    sf.write(stream, audio[left:right], SAMPLE_RATE, format="WAV", subtype="PCM_16")
                    boundary = "OSprBenchmarkBoundary"
                    body = (
                        f'--{boundary}\r\nContent-Disposition: form-data; name="response_format"\r\n\r\njson\r\n'
                        f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="audio.wav"\r\nContent-Type: audio/wav\r\n\r\n'
                    ).encode()
                    body += stream.getvalue() + f"\r\n--{boundary}--\r\n".encode()
                    request = urllib.request.Request(
                        f"http://127.0.0.1:{port}/inference",
                        data=body,
                        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
                    )
                    with urllib.request.urlopen(request, timeout=180) as response:
                        result = json.load(response)
                    return dict(text=result["text"].strip(), wall_ms=(time.perf_counter() - begin) * 1000)

                cold = transcribe(items[0])
                for item in items:
                    try:
                        result = transcribe(item)
                    except Exception as error:
                        result = dict(error=str(error), wall_ms=0)
                    records.append(dict(item, **result))
                    print(
                        len(records),
                        item["id"],
                        round(result["wall_ms"]),
                        result.get("text", result.get("error"))[:90],
                        flush=True,
                    )
            finally:
                server.terminate()
                try:
                    server.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.wait()
        log_path = ROOT / "results" / f"whisper-cpp-{Path(args.manifest).stem}.log"
        log_path.write_text(log.read_text())
    output = ROOT / "results" / f"whisper-cpp-{Path(args.manifest).stem}.json"
    output.write_text(
        json.dumps(
            dict(
                timestamp=datetime.datetime.now(datetime.UTC).isoformat(),
                model="whisper.cpp Large v3 Turbo FP16",
                backend="Homebrew whisper.cpp 1.9.4 · Metal + flash attention · 4 threads",
                command=[
                    "<weights>" if arg == str(Path(args.weights).resolve()) or arg == args.weights else arg
                    for arg in command[:-1]
                ]
                + ["<temporary-directory>"],
                weights_sha256=hashlib.file_digest(Path(args.weights).open("rb"), "sha256").hexdigest(),
                platform=platform.platform(),
                startup_ms=startup_ms,
                first_decode=cold,
                summary=summarize(records),
                records=records,
                limitations=[
                    "Engine baseline, not a consumer-product benchmark.",
                    "HTTP, PCM encoding and transport are included; OSpr in-process timings omit IPC.",
                    "Identical RMS trimming; silence gate is harness behavior, not whisper.cpp behavior.",
                    "FP16 weights correspond to the same upstream model family but have a different conversion.",
                ],
            ),
            indent=2,
        )
        + "\n"
    )
    print(output)


if __name__ == "__main__":
    main()
