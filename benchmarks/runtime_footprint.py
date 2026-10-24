"""Isolated Torch-absence compatibility study; never edits the checked app.

A symlink package tree omits only top-level entries owned by Torch's RECORD.
All remaining modules and the actual bundled Python/backend are identical.
This is not a reduced distributable or a package-size/latency win by itself.
"""

import argparse
from contextlib import redirect_stdout
import datetime
import gzip
import hashlib
import importlib.metadata
import importlib.util
import json
import os
from pathlib import Path
import resource
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def worker(manifest):
    import mlx.core as mx
    from ospr_backend.engine import Engine

    torch_spec = importlib.util.find_spec("torch") is not None
    try:
        torch_version = importlib.metadata.version("torch")
    except importlib.metadata.PackageNotFoundError:
        torch_version = None
    assert torch_spec == manifest["expect_torch"]
    assert bool(torch_version) == manifest["expect_torch"]
    assert mx.metal.is_available() and str(mx.default_device()) == "Device(gpu, 0)"
    engine, rows = Engine(), []
    for index, request in enumerate(manifest["requests"], 1):
        started = time.perf_counter()
        result, error = None, None
        try:
            action = request["action"]
            if action == "warm":
                result = engine.warm(request["model"])
            elif action == "transcribe":
                result = engine.transcribe(request["path"], request["model"], language=request.get("language"))
            elif action == "notes":
                result = engine.notes(request["text"])
            elif action == "meeting":
                result = engine.meeting(request["path"], "parakeet-v3", language="en")
            elif action == "stream":
                state = engine.stream_begin("en")
                partial = engine.stream_feed(request["path"], session_id=state["session_id"])
                final = engine.stream_feed(final=True, session_id=state["session_id"])
                result = dict(partial=partial, final=final, text=final["text"])
            else:
                raise ValueError("Unknown frozen runtime request")
            if action in {"transcribe", "meeting", "stream"} and request.get("require_nonempty", True) and not result.get("text", "").strip():
                raise ValueError("Speech fixture returned empty text")
            if action == "warm" and result.get("primed_sample_rate") != 48000:
                raise ValueError("Model warm-up did not prime native-rate kernels")
            if action == "notes" and (not result.get("excerpts") or any(
                row["text"] not in request["text"] for row in result["excerpts"]
            )):
                raise ValueError("Source-excerpt notes failed integrity check")
            if action == "meeting" and not result.get("words"):
                raise ValueError("Speaker route returned no aligned words")
        except Exception as exc:
            error = dict(type=type(exc).__name__, message=str(exc))
        rows.append(dict(id=request["id"], action=request["action"], result=result, error=error,
            wall_ms=(time.perf_counter() - started) * 1000,
            torch_imported=any(name == "torch" or name.startswith("torch.") for name in sys.modules)))
        if index % 10 == 0 or index == len(manifest["requests"]):
            print("runtime_probe_progress " + json.dumps(dict(completed=index, total=len(manifest["requests"]), id=request["id"])), file=sys.stderr, flush=True)
    return dict(torch_spec_present=torch_spec, torch_metadata_version=torch_version,
                default_device=str(mx.default_device()), process_peak_rss_bytes=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
                peak_mlx_bytes=mx.get_peak_memory(), records=rows)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--worker", type=Path)
    parser.add_argument("--protocol", type=Path)
    args = parser.parse_args()
    if args.worker:
        with redirect_stdout(sys.stderr):
            result = worker(json.loads(args.worker.read_text()))
        print(json.dumps(result, ensure_ascii=False))
        return
    assert args.app and args.output and not args.output.exists()
    assert not subprocess.check_output(["git", "diff", "--name-only", "HEAD"], cwd=ROOT)
    app = args.app.resolve(strict=True)
    resources = app / "Contents/Resources"
    packages = resources / "Engine/.venv/lib/python3.12/site-packages"
    python_home = resources / "Python"
    backend = resources / "Engine/backend"
    protocol_path = args.protocol or ROOT / "benchmarks/fixtures/runtime-footprint-protocol.json"
    protocol = json.loads(protocol_path.read_text())
    item = protocol["source"]
    source = ROOT / "benchmarks" / item["path"]
    assert sha(source) == item["sha256"]
    assert sha(resources / "Engine/uv.lock") == protocol["dependency_lock_sha256"]
    assert sha(backend / "ospr_backend/models.lock.json") == protocol["model_lock_sha256"]
    torch = next(d for d in importlib.metadata.distributions(path=[str(packages)])
                 if d.metadata["Name"].lower() == "torch")
    excluded = {file.parts[0] for file in torch.files if file.parts and file.parts[0] != ".."}
    assert "torch" in excluded and all((packages / name).exists() for name in excluded)
    requests = []
    for model in protocol["models"]:
        requests += [dict(id="warm-" + model, action="warm", model=model),
                     dict(id="asr-" + model, action="transcribe", path=str(source), model=model, language="en")]
    requests += [dict(id="notes", action="notes", text=protocol["notes_text"]),
                 dict(id="meeting", action="meeting", path=str(source)),
                 dict(id="stream", action="stream", path=str(source))]
    records = []
    inputs = []
    with tempfile.TemporaryDirectory(prefix="runtime-footprint-", dir=ROOT / ".local") as directory:
        staging = Path(directory)
        candidate = staging / "site-packages"
        candidate.mkdir()
        for path in packages.iterdir():
            if path.name not in excluded:
                (candidate / path.name).symlink_to(path, target_is_directory=path.is_dir())
        if protocol.get("cases"):
            import numpy as np
            import soundfile as sf

            requests = []
            for model in protocol["models"]:
                requests.append(dict(id="warm-" + model, action="warm", model=model))
                for index, case in enumerate(protocol["cases"]):
                    if case["model"] != model:
                        continue
                    source_path = ROOT / "benchmarks" / case["path"]
                    assert sha(source_path) == case["sha256"]
                    audio, rate = sf.read(source_path, dtype="float32")
                    assert rate == 16000 and audio.ndim == 1
                    audio *= np.float32(case.get("amplitude", 1))
                    pcm = np.clip(audio, -1, 1)
                    digest = hashlib.sha256(pcm.astype("<f4", copy=False).tobytes()).hexdigest()
                    if case.get("pcm_sha256"):
                        assert digest == case["pcm_sha256"]
                    path = source_path
                    if case.get("amplitude", 1) != 1:
                        path = staging / f"quiet-{index}.wav"
                        sf.write(path, audio, rate, subtype="FLOAT")
                        decoded, decoded_rate = sf.read(path, dtype="float32")
                        assert decoded_rate == rate and decoded.tobytes() == audio.tobytes()
                    requests.append(dict(id=case["id"], action="transcribe", path=str(path), model=model,
                        language=case["language"], require_nonempty=case["expected_speech"]))
                    inputs.append(dict(id=case["id"], file_sha256=sha(path), normalized_samples=len(pcm), pcm_sha256=digest))
            requests += [dict(id="notes", action="notes", text=protocol["notes_text"]),
                         dict(id="meeting", action="meeting", path=str(source)),
                         dict(id="stream", action="stream", path=str(source))]
        for variant in protocol["variant_order"]:
            manifest = staging / (variant + ".json")
            manifest.write_text(json.dumps(dict(expect_torch=variant == "baseline", requests=requests)))
            environment = dict(os.environ, PYTHONHOME=str(python_home),
                PYTHONPATH=str(packages if variant == "baseline" else candidate) + os.pathsep + str(backend),
                PYTHONNOUSERSITE="1", PYTHONSAFEPATH="1", PYTHONDONTWRITEBYTECODE="1", HF_HUB_OFFLINE="1",
                HF_HUB_DISABLE_TELEMETRY="1", OSPR_DEBUG_LOG="0")
            log_path = args.output.with_name(args.output.stem + "." + variant + ".log")
            with log_path.open("w") as log:
                result = subprocess.run([str(python_home / "bin/python3.12"), str(Path(__file__).resolve()), "--worker", str(manifest)],
                    cwd=staging, env=environment, stdout=subprocess.PIPE, stderr=log, text=True,
                    timeout=protocol.get("worker_timeout_seconds", 300))
            row = dict(variant=variant, returncode=result.returncode)
            if result.returncode == 0:
                row.update(json.loads(result.stdout))
            else:
                row["failure_stderr"] = log_path.read_text()[-8000:]
            records.append(row)
            print(json.dumps(dict(variant=variant, returncode=result.returncode,
                request_errors=sum(bool(r["error"]) for r in row.get("records", [])))), flush=True)
    archive = args.output.with_suffix(".traces.json.gz")
    archive.write_bytes(gzip.compress(json.dumps(records, ensure_ascii=False).encode(), mtime=0))
    baseline = next(r for r in records if r["variant"] == "baseline")
    candidate = next(r for r in records if r["variant"] == "without-torch")
    pairs = []
    if baseline["returncode"] == candidate["returncode"] == 0:
        for before, after in zip(baseline["records"], candidate["records"], strict=True):
            assert before["id"] == after["id"]
            pairs.append(dict(id=before["id"], baseline_error=before["error"], candidate_error=after["error"],
                text_identical=((before["result"] or {}).get("text") == (after["result"] or {}).get("text"))
                    if before["action"] in {"transcribe", "meeting", "stream"} else None,
                excerpts_identical=((before["result"] or {}).get("excerpts") == (after["result"] or {}).get("excerpts"))
                    if before["action"] == "notes" else None,
                candidate_torch_imported=after["torch_imported"]))
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    receipt = dict(status="completed-isolated-compatibility-smoke-not-package-promotion",
        timestamp=datetime.datetime.now(datetime.UTC).isoformat(),
        git_commit=subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        build=json.loads((resources / "build-info.json").read_text()), harness_sha256=sha(Path(__file__)),
        protocol_sha256=sha(protocol_path), excluded_top_level_entries=sorted(excluded), torch_version=torch.version,
        requests_each=len(requests), source_inputs=inputs, summary=pairs, traces_file=archive.name, traces_sha256=sha(archive),
        checked_app_signature_unchanged=True, boundary=protocol["boundary"])
    assert not subprocess.check_output(["git", "diff", "--name-only", "HEAD"], cwd=ROOT)
    args.output.write_text(json.dumps(receipt, indent=2) + "\n")


if __name__ == "__main__":
    main()
