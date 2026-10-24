"""Run existing functional gates against one immutable standalone development app.

The default runs every gate serially, including real offline inference and long
files. --only resumes named remaining gates after a diagnosed failure; existing
receipts are never overwritten. This does not launch GUI or authenticate to APIs.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
JOBS = {
    "portable": ("portable_app.py", "app", ()),
    "preparation": ("text_preparation_contracts.py", "cli", ()),
    "paired-preparation": ("text_preparation.py", "cli", ("--repeats", "1")),
    "cache": ("text_preparation_cache.py", "cli", ()),
    "choice-cli": ("local_model_cli.py", "cli", ()),
    "choice-mcp": ("local_model_mcp.py", "mcp", ()),
    "summary-cli": ("meeting_summary_cli.py", "cli", ()),
    "summary-mcp": ("meeting_summary_mcp.py", "mcp", ()),
    "profiles": ("context_profiles.py", "cli", ()),
    "rewrite": ("rewrite_completion_contracts.py", "cli", ()),
    "azure": ("azure_contracts.py", "cli", ()),
    "gemini": ("gemini_contracts.py", "cli", ()),
    "limit": (None, "limit", ()),
    "native-long": ("native_long.py", "app", ()),
    "neural-long": ("native_long.py", "app", ("--neural-edges",)),
    **{f"upload-{p}": ("upload_parts.py", "cli", ("--provider", p)) for p in ("compatible", "deepgram", "soniox")},
}


def sha(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--prefix", required=True)
    parser.add_argument("--only", nargs="+", choices=JOBS)
    args = parser.parse_args()
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,47}", args.prefix):
        parser.error("Use a lowercase filename prefix of at most 48 characters.")
    app = args.app.resolve(strict=True)
    engine = app / "Contents/Resources/Engine"
    python = engine / ".venv/bin/python"
    cli = app / "Contents/MacOS/ospr-cli"
    executable = app / "Contents/MacOS/OSpr"
    build = json.loads((app / "Contents/Resources/build-info.json").read_text())
    binding = dict(build=build, executable_sha256=sha(executable), cli_sha256=sha(cli))
    results = ROOT / "benchmarks/results"
    logs = ROOT / ".local"
    logs.mkdir(exist_ok=True)
    environment = dict(os.environ, HF_HUB_OFFLINE="1", HF_HUB_DISABLE_TELEMETRY="1")
    environment.pop("OSPR_ROOT", None)
    names = args.only or list(JOBS)
    for name in names:
        receipt = results / f"{args.prefix}-{name}.json"
        sidecar = results / f"{args.prefix}-{name}-binding.json"
        if receipt.exists() or sidecar.exists():
            parser.error(f"Receipt exists for {name}; select only remaining gates or a fresh prefix.")
        script, kind, extra = JOBS[name]
        print("START " + name, flush=True)
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
        with tempfile.TemporaryDirectory(prefix="ospr-standalone-gate-") as temporary:
            staging = Path(temporary)
            if kind == "limit":
                command = [str(cli), "_verify-local-completion", str(ROOT / "benchmarks/fixtures/audio/1272-128104-0000.wav")]
                result = subprocess.run(command, env=environment, cwd=staging, capture_output=True, text=True, check=True, timeout=600)
                (logs / f"{args.prefix}-{name}.log").write_text(result.stdout + result.stderr)
                data = json.loads(result.stdout)
                assert data["status"] == "passed" and data["expected_failure"] == "text-output-limit"
                assert data["same_worker_pid"] and data["warm_asr_text_unchanged"]
                data.update(build=build, cli_sha256=binding["cli_sha256"])
                receipt.write_text(json.dumps(data, indent=2) + "\n")
            else:
                target = ROOT / "benchmarks" / script
                runner = ROOT / ".venv/bin/python"
                if kind == "mcp":
                    # Execute the copied harness with only the bundled backend.
                    # Its parent-directory import must not reach checkout code.
                    (staging / "benchmarks").mkdir()
                    shutil.copy2(target, staging / "benchmarks" / script)
                    target = staging / "benchmarks" / script
                    (staging / "backend").symlink_to(engine / "backend", target_is_directory=True)
                    (staging / "benchmarks/fixtures").symlink_to(ROOT / "benchmarks/fixtures", target_is_directory=True)
                    runner = python
                command = [str(runner), str(target)]
                command += ["--python", str(python)] if kind == "mcp" else ["--app", str(app)] if kind == "app" else ["--cli", str(cli)]
                command += ["--output", str(receipt), *extra]
                with (logs / f"{args.prefix}-{name}.log").open("w") as log:
                    subprocess.run(command, env=environment, cwd=staging, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=1800)
                data = json.loads(receipt.read_text())
                assert data["status"].startswith("passed"), name
            if "build" in data:
                assert data["build"] == build, name
            for key in ("cli_sha256", "cli_executable_sha256"):
                if key in data:
                    assert data[key] == binding["cli_sha256"], name
            assert sha(executable) == binding["executable_sha256"] and sha(cli) == binding["cli_sha256"]
            subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
            sidecar.write_text(json.dumps(dict(**binding, gate=name,
                harness_sha256=sha(ROOT / "benchmarks" / script) if script else None,
                receipt_sha256=sha(receipt), signature_valid_after_gate=True), indent=2) + "\n")
        print("DONE " + name, flush=True)


if __name__ == "__main__":
    main()
