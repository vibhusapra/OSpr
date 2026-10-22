"""Paired fresh-process file-command pilot using a real official Vibe release.

Each command loads a new model context. OS file/shader caches are already warm.
This measures CLI products, not GUI capture, hotkeys, endpointing or insertion.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import random
import signal
import subprocess
import time

import jiwer
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
NORMALIZE = jiwer.Compose([jiwer.ToLowerCase(), jiwer.RemovePunctuation(), jiwer.RemoveMultipleSpaces(), jiwer.Strip()])


def sha(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vibe-app", required=True, type=Path)
    parser.add_argument("--ospr-app", required=True, type=Path)
    parser.add_argument("--vibe-release", required=True, type=Path)
    parser.add_argument("--ggml-model", type=Path, default=ROOT / ".local/models/ggml-large-v3-turbo.bin")
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--output", type=Path, default=ROOT / "benchmarks/results/product-cli.json")
    args = parser.parse_args()
    assert 1 <= args.repeats <= 10
    vibe, ospr, weights = args.vibe_app.resolve(strict=True), args.ospr_app.resolve(strict=True), args.ggml_model.resolve(strict=True)
    vibe_cli = vibe / "Contents/MacOS/vibe"
    ospr_cli = ospr / "Contents/MacOS/ospr-cli"
    profile = Path.home() / "Library/Application Support/github.com.thewh1teagle.vibe/app_config.json"
    assert json.loads(profile.read_text()).get("analytics_enabled") is False, "Disable Vibe analytics before the pilot"
    for app in (vibe, ospr):
        subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    assessment = subprocess.run(["/usr/sbin/spctl", "--assess", "--type", "execute", "--verbose=2", str(vibe)], capture_output=True, text=True, check=True)
    assert "Notarized Developer ID" in assessment.stderr
    selected, manifests = [], {}
    for suite in ("test-clean", "test-other"):
        path = ROOT / f"benchmarks/fixtures/{suite}.json"
        manifests[suite] = sha(path)
        seen = set()
        for item in json.loads(path.read_text())["items"]:
            speaker = str(item.get("speaker", item["id"].split("-")[0]))
            if speaker in seen:
                continue
            seen.add(speaker)
            source = ROOT / "benchmarks" / item["path"]
            assert sha(source) == item["sha256"]
            selected.append(dict(item, speaker=speaker, cohort=suite))
            if len(seen) == 10:
                break
    assert len(selected) == 20
    configurations = {
        "ospr-parakeet": dict(product="OSpr", model="parakeet-v3", format="json"),
        "ospr-whisper-turbo": dict(product="OSpr", model="whisper-turbo", format="json"),
        "vibe-whisper-turbo": dict(product="Vibe 3.2.2", model="Whisper Large v3 Turbo GGML FP16", format="text"),
    }
    jobs = [(item, configuration, repeat) for item in selected for configuration in configurations for repeat in range(args.repeats)]
    random.Random(20261022).shuffle(jobs)
    environment = dict(os.environ, HF_HUB_OFFLINE="1", HF_HUB_DISABLE_TELEMETRY="1")
    environment.pop("OSPR_ROOT", None)
    environment.pop("OSPR_TRANSCRIPTION_KEY", None)
    records = []
    for ordinal, (item, name, repeat) in enumerate(jobs):
        config = configurations[name]
        audio = ROOT / "benchmarks" / item["path"]
        command = [str(ospr_cli), "transcribe", str(audio), config["model"]] if config["product"] == "OSpr" else [str(vibe_cli), "transcribe", str(weights), str(audio)]
        if config["product"].startswith("Vibe"):
            assert json.loads(profile.read_text()).get("analytics_enabled") is False
        began = time.perf_counter()
        process = subprocess.Popen(command, cwd=ROOT, env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
        error = None
        try:
            stdout, stderr = process.communicate(timeout=120)
            elapsed = (time.perf_counter() - began) * 1000
            if process.returncode:
                raise RuntimeError(f"exit-{process.returncode}")
            response = json.loads(stdout) if config["format"] == "json" else {}
            text = response["text"] if config["format"] == "json" else stdout.strip()
            if not text.strip():
                raise RuntimeError("empty-transcript")
            if config["format"] == "json":
                assert response["warm"] is False, "Each command must load a fresh model context"
        except (subprocess.TimeoutExpired, RuntimeError, ValueError, KeyError, AssertionError) as failure:
            error = type(failure).__name__ + (":" + str(failure) if isinstance(failure, RuntimeError) else "")
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.communicate(timeout=2)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.communicate()
            elapsed = (time.perf_counter() - began) * 1000
            text, response = "", {}
        score = jiwer.process_words(NORMALIZE(item["reference"]), NORMALIZE(text))
        records.append(dict(configuration=name, id=item["id"], speaker=item["speaker"], suite=item["cohort"], repeat=repeat,
                            seconds=item["seconds"], wall_ms=elapsed, text=text, reference=item["reference"], error=error,
                            wer=score.wer, substitutions=score.substitutions, deletions=score.deletions, insertions=score.insertions,
                            observed_language=response.get("language")))
        print(json.dumps(dict(done=ordinal + 1, total=len(jobs), configuration=name, error=error)), flush=True)
    summaries = {}
    for name in configurations:
        runs = [record for record in records if record["configuration"] == name]
        scored = sorted((record for record in runs if record["repeat"] == 0), key=lambda record: record["id"])
        score = jiwer.process_words([NORMALIZE(record["reference"]) for record in scored], [NORMALIZE(record["text"]) for record in scored])
        times = [record["wall_ms"] for record in runs]
        stable = sum(len({record["text"] for record in runs if record["id"] == item["id"]}) == 1 for item in selected)
        summaries[name] = dict(cases=len(scored), trials=len(runs), errors=sum(record["error"] is not None for record in runs),
            wer=score.wer, substitutions=score.substitutions, deletions=score.deletions, insertions=score.insertions,
            process_wall_p50_ms=float(np.median(times)), process_wall_p95_ms=float(np.percentile(times, 95)),
            aggregate_process_rtf=sum(times) / 1000 / sum(record["seconds"] for record in runs), stable_case_texts=stable)
    release = json.loads(args.vibe_release.read_text())
    asset = next(asset for asset in release["assets"] if asset["name"] == "vibe_aarch64.app.tar.gz")
    receipt = dict(status="passed" if all(not record["error"] for record in records) else "completed-with-failures",
        verified_at=datetime.datetime.now(datetime.UTC).isoformat(), git_commit=subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        machine=dict(os=platform.mac_ver()[0], architecture=platform.machine(), chip="Apple M5 Max, 40 GPU cores, 128 GB"),
        selection="First utterance of the first ten speakers in each existing clean/other manifest, before pilot output; three fresh processes per product/case; seed 20261022 randomizes all jobs.",
        repeats=args.repeats, manifests_sha256=manifests, configurations=configurations, summary=summaries, records=records,
        ospr=dict(build=json.loads((ospr / "Contents/Resources/build-info.json").read_text()), cli_sha256=sha(ospr_cli), model_lock_sha256=sha(ROOT / "backend/ospr_backend/models.lock.json")),
        vibe=dict(version=release["tag_name"], release_url=release["html_url"], asset=asset["name"], asset_digest=asset["digest"],
            executable_sha256=sha(vibe_cli), server_sha256=sha(vibe / "Contents/MacOS/vibe-server"), ggml_model_sha256=sha(weights),
            notarized_assessment=True, analytics_disabled=True), harness_sha256=sha(Path(__file__)),
        limitations=["Fresh model contexts per command; OS file and shader caches primed by prior smoke runs. These are not warm resident decoding or fully uncached starts.",
            "Real official Vibe desktop CLI forwards to its bundled server. OSpr CLI owns its Python/Metal worker. Excludes GUI, microphone, hotkey, endpointing, rewriting and insertion.",
            "Default file-command behavior: no hints or custom vocabulary. OSpr uses its default edge trim and language selection; Vibe uses its CLI defaults. The two Turbo conversions/runtimes differ.",
            "Twenty public read-speech cases, not all 365 clips or spontaneous dictation. Quality scores use repeat zero only; timings use all trials. Small score gaps do not establish a winner.",
            "Seeded randomized serial order, shared active Mac and no thermal/energy isolation. No battery, calibrated memory or end-to-end product ranking claim."])
    for app in (vibe, ospr):
        subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    args.output.write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(dict(status=receipt["status"], summary=summaries)))


if __name__ == "__main__":
    main()
