"""Exercise the real Swift file CLI, fake-child rejection and optional local MLX."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def run(cli, contracts_only):
    cli = cli.resolve(strict=True)
    cases = []
    protocol = json.loads((ROOT / "benchmarks/fixtures/meeting-summary-protocol.json").read_text())
    with tempfile.TemporaryDirectory(prefix="ospr-summary-cli-") as temporary:
        directory = Path(temporary)
        source = directory / "public transcript.txt"
        source.write_text("Do not ship Friday. Price is $12.50.")
        original = source.read_bytes()
        root = directory / "owned fixture"
        backend = root / "backend/ospr_backend"
        backend.mkdir(parents=True)
        (backend / "__init__.py").write_text("")
        launcher = root / ".venv/bin/python"
        launcher.parent.mkdir(parents=True)
        launcher.write_text("#!/bin/sh\nexec " + shlex.quote(sys.executable) + ' "$@"\n')
        launcher.chmod(0o700)
        worker = backend / "worker.py"
        base = dict(
            items=[dict(section="decisions", text="Hold the Friday release.", source_ids=[0])],
            excerpts=[dict(id=0, text="Do not ship Friday.")],
            model="public-fixture",
            chunks=1,
        )
        variants = [("valid", base)]
        for name in [
            "bad-quote",
            "bad-quantity",
            "bad-reference",
            "bad-section",
            "missing-chunks",
            "stale-progress",
        ]:
            payload = json.loads(json.dumps(base))
            if name == "bad-quote":
                payload["excerpts"][0]["text"] = "PRIVATE quote absent from source"
            if name == "bad-quantity":
                payload["items"][0]["text"] = "Price is $15.50."
            if name == "bad-reference":
                payload["items"][0]["source_ids"] = [99]
            if name == "bad-section":
                payload["items"][0]["section"] = "execute"
            if name == "missing-chunks":
                payload.pop("chunks")
            variants.append((name, payload))
        for name, payload in variants:
            worker.write_text(
                "import json,sys\nfor line in sys.stdin:\n r=json.loads(line)\n"
                + (
                    ' print(json.dumps(dict(id="stale",event="progress",progress={})),flush=True)\n'
                    if name == "stale-progress"
                    else ""
                )
                + ' print(json.dumps(dict(id=r["id"],ok=True,result='
                + repr(payload)
                + ")),flush=True)\n"
            )
            environment = dict(os.environ, OSPR_ROOT=str(root), HF_HUB_OFFLINE="1")
            result = subprocess.run(
                [str(cli), "summarize-file", str(source)],
                cwd=directory,
                env=environment,
                capture_output=True,
                text=True,
                timeout=30,
            )
            assert source.read_bytes() == original
            if name == "valid":
                reply = json.loads(result.stdout)
                assert (
                    result.returncode == 0
                    and reply["source_quotes_verified"]
                    and reply["items"] == payload["items"]
                ), result.stderr
            else:
                assert result.returncode != 0 and not result.stdout.strip(), result
            assert "PRIVATE" not in result.stdout + result.stderr
            cases.append(
                dict(
                    case=name,
                    exit_code=result.returncode,
                    input_unchanged=True,
                    private_fixture_not_exposed=True,
                )
            )
        source.write_bytes(b"\xff\xfe\xff")
        result = subprocess.run(
            [str(cli), "summarize-file", str(source)],
            cwd=directory,
            env=environment,
            capture_output=True,
            text=True,
            timeout=30,
        )
        assert result.returncode != 0 and not result.stdout.strip() and source.read_bytes() == b"\xff\xfe\xff"
        cases.append(dict(case="non-UTF8-input", exit_code=result.returncode, input_unchanged=True))
        if not contracts_only:
            environment = dict(os.environ, HF_HUB_OFFLINE="1")
            engine = cli.parent.parent / "Resources/Engine"
            if engine.is_dir():
                environment.pop("OSPR_ROOT", None)
            else:
                environment["OSPR_ROOT"] = str(ROOT)
            for name in ["explicit-correction", "hindi-conditions", "multi-chunk-late-correction"]:
                case = next(row for row in protocol["cases"] if row["id"] == name)
                source.write_text(case["text"])
                original = source.read_bytes()
                result = subprocess.run(
                    [str(cli), "summarize-file", str(source)],
                    cwd=directory,
                    env=environment,
                    capture_output=True,
                    text=True,
                    timeout=300,
                )
                assert result.returncode == 0, result.stderr
                reply = json.loads(result.stdout)
                assert (
                    reply["source_quotes_verified"]
                    and reply["items"]
                    and all(r["text"] in case["text"] for r in reply["excerpts"])
                )
                assert source.read_bytes() == original
                cases.append(dict(case="local-9b-" + name, exit_code=0, input_unchanged=True, result=reply))
    build_path = cli.parent.parent / "Resources/build-info.json"
    return dict(
        status="passed-summary-file-cli-contracts"
        if contracts_only
        else "passed-summary-file-cli-contracts-and-local-inference",
        cli_sha256=hashlib.sha256(cli.read_bytes()).hexdigest(),
        build=json.loads(build_path.read_text()) if build_path.is_file() else None,
        cases=cases,
        boundary="Actual Swift CLI with owned synthetic worker and public UTF8 files: complete typed notes, bad quote/quantity/reference/category/metadata and stale progress rejection, no partial stdout or private-fixture echo, invalid UTF8 rejection and unchanged input. Optional three actual offline 9B file-to-worker-to-native-validation replays. Citation validation is not entailment or summary quality proof. No app UI, microphone/history/provider account, isolated timing, consumer ranking or distribution acceptance.",
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cli", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--contracts-only", action="store_true")
    args = parser.parse_args()
    result = run(args.cli, args.contracts_only)
    args.output.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps(dict(status=result["status"], cases=len(result["cases"]))))


if __name__ == "__main__":
    main()
