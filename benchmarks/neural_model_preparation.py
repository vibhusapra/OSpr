"""Real disposable-cache preparation/repair and native model controls.

Requires network access for explicit public model preparation. No private audio,
paid provider, microphone, user cache deletion or authentication is involved.
"""

import argparse
import datetime
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--audio", type=Path, default=ROOT / "benchmarks/fixtures/audio/vad-validation/vad-validation-test-clean-4970-29093-0000-original.wav")
    args = parser.parse_args()
    assert not args.output.exists()
    cli, audio = args.cli.resolve(strict=True), args.audio.resolve(strict=True)
    cli_sha, audio_sha = sha(cli), sha(audio)
    assert not subprocess.check_output(["git", "diff", "--name-only", "HEAD"], cwd=ROOT)
    spec_path = ROOT / "backend/ospr_backend/speech-detector.lock.json"
    spec = json.loads(spec_path.read_text())
    with tempfile.TemporaryDirectory(prefix="ospr-public-model-preparation-") as directory:
        cache = Path(directory).resolve()
        assert not list(cache.iterdir())
        env = dict(os.environ, HF_HUB_CACHE=str(cache), HF_HUB_DISABLE_TELEMETRY="1")

        def run(*arguments, offline=True):
            result = subprocess.run([str(cli), *map(str, arguments)], cwd=ROOT, text=True, capture_output=True,
                                    timeout=180, env=dict(env, HF_HUB_OFFLINE="1" if offline else "0"))
            return result, json.loads(result.stdout) if result.returncode == 0 else None

        result, first = run("download", "speech-detector", offline=False)
        assert result.returncode == 0, result.stderr[-2000:]
        assert first["cache_kind"] == "ospr-verified"
        assert first["repo"] == spec["repo"] and first["revision"] == spec["revision"]
        result, checked = run("verify-speech-detector")
        assert result.returncode == 0 and checked["native_integrity_verified"]
        original_path = Path(checked["model_path"])
        weight = original_path / "weights/weight.bin"
        assert weight.resolve().is_relative_to(cache)
        original = weight.read_bytes()
        pinned = next(f for f in spec["files"] if f["path"].endswith("weights/weight.bin"))
        assert len(original) == pinned["size"] and hashlib.sha256(original).hexdigest() == pinned["sha256"]
        bad = bytes([original[0] ^ 1]) + original[1:]
        # Only our installed disposable version is modified. Shared immutable
        # hub/CAS blobs are never chmodded, overwritten or removed.
        weight.write_bytes(bad)
        assert weight.stat().st_size == len(original)
        result, _ = run("verify-speech-detector")
        assert result.returncode != 0 and "failed verification" in result.stderr
        result, repaired = run("download", "speech-detector", offline=False)
        assert result.returncode == 0, result.stderr[-2000:]
        assert repaired["complete"] and repaired["model_path"] != str(original_path)
        assert weight.read_bytes() == bad, "Repair must not remove/edit a prior native reader's version"
        result, checked = run("verify-speech-detector")
        assert result.returncode == 0 and checked["native_integrity_verified"]
        model = Path(checked["model_path"])
        assert model.resolve().is_relative_to(cache)
        assert sha(model / "weights/weight.bin") == pinned["sha256"]
        result, probes = run("_benchmark-speech-probes", audio, model)
        assert result.returncode == 0 and probes["status"] == "passed", result.stderr[-2000:]
    assert sha(cli) == cli_sha and sha(audio) == audio_sha
    assert not subprocess.check_output(["git", "diff", "--name-only", "HEAD"], cwd=ROOT)
    receipt = dict(status="passed-real-model-preparation-and-repair", timestamp=datetime.datetime.now(datetime.UTC).isoformat(),
        git_commit=subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        tracked_changes=False, cli_sha256=cli_sha, harness_sha256=sha(Path(__file__)),
        model_lock_sha256=sha(spec_path), audio_sha256=audio_sha,
        repo=spec["repo"], revision=spec["revision"], artifact_bytes=first["required_bytes"],
        checks=dict(new_empty_isolated_cache=True, explicit_public_preparation=True, cache_only_native_verification=True,
                    same_size_owned_corruption_rejected=True, repair_publishes_new_version=True,
                    prior_corrupt_version_retained=True, native_verification_after_repair=True,
                    original_weight_hash_restored=True, relocated_native_cpu_model_runs=True),
        probes=probes, versions={"huggingface-hub": importlib.metadata.version("huggingface-hub")},
        prior_observation=dict(source="f293b28f33314713e74fd7381505d6a9f5ace395", status="failed-real-shared-snapshot-repair",
            detail="On this host, force-download through the hub snapshot returned the same corrupt snapshot. The revised path uses fresh SDK local_dir staging and a separate verified installation."),
        boundary="Real public asset preparation in a newly-created empty disposable cache, worker/native SHA gates, one-byte same-size installed-version corruption, explicit repair and actual Core ML CPU probes on one public speech fixture. Authentication disabled. SDK may reuse global transfer caches; network bytes are not measured. No shared/immutable blob mutation, ASR recognition, microphone, private audio, paid provider, UI or device acceptance. The script removes only its own disposable test cache.")
    args.output.write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt, indent=2))


if __name__ == "__main__":
    main()
