"""Real cached Parakeet/privacy/history control in an isolated AppModel profile.

No microphone, native UI, external API, network model download or audio playback.
An explicit gate before generation allows deterministic live preference changes.
"""
from __future__ import annotations

import argparse
import json
import os
import platform
from pathlib import Path
import shlex
import shutil
import subprocess
import time

from durable_import_common import application_fingerprint, digest, prepare_probe

ROOT = Path(__file__).resolve().parents[1]


def run(args):
    root = args.output
    package = root / "engine/backend/ospr_backend"
    shutil.copytree(ROOT / "backend/ospr_backend", package, ignore=shutil.ignore_patterns("__pycache__"))
    backend = {str(path.relative_to(package)): digest(path) for path in package.rglob("*") if path.is_file()}
    (package / "worker.py").rename(package / "_actual_worker.py")
    (package / "worker.py").write_text('''from . import _actual_worker as real
import json,os,pathlib,time
Original=real.Engine
class Observed(Original):
    def transcribe(self,path,*args,**kwargs):
        self._privacy_path=path
        return super().transcribe(path,*args,**kwargs)
    def _load(self,model_id):
        model,warm=super()._load(model_id)
        cls=type(model)
        if not getattr(cls,'_privacy_observed',False):
            original=cls.generate
            calls=0
            def generate(instance,*args,**kwargs):
                nonlocal calls
                calls+=1
                if calls==2:
                    import mlx.core as mx
                    temporary=pathlib.Path('admitted.tmp')
                    temporary.write_text(json.dumps(dict(worker_pid=os.getpid(),path=self._privacy_path,generation_call=calls,device=str(mx.default_device()))))
                    temporary.replace('admitted.json')
                    until=time.monotonic()+45
                    while not pathlib.Path('release-generation').exists():
                        if time.monotonic()>until:raise RuntimeError('Real fixture release deadline')
                        time.sleep(.01)
                return original(instance,*args,**kwargs)
            cls.generate=generate
            cls._privacy_observed=True
        return model,warm
real.Engine=Observed
real.main()
''')
    bin_path = root / "engine/.venv/bin"
    bin_path.mkdir(parents=True)
    launcher = bin_path / "python"
    launcher.write_text("#!/bin/sh\nexec " + shlex.quote(str(args.python)) + ' "$@"\n')
    launcher.chmod(0o700)
    original_sha = digest(args.audio)
    for name in ["prior.wav", "active.wav", "later.wav"]:
        shutil.copy2(args.audio, root / name)
    versions = json.loads(subprocess.check_output([str(args.python), "-c", "import importlib.metadata as m,json;print(json.dumps({name:m.version(name) for name in ['mlx','parakeet-mlx','mlx-whisper','soundfile','numpy']}))"], text=True))
    locked = json.loads(subprocess.check_output([str(args.python), "-c", "import json,tomllib,sys;print(json.dumps({p['name']:p['version'] for p in tomllib.load(open(sys.argv[1],'rb'))['package']}))", str(ROOT / "uv.lock")], text=True))
    assert all(version == locked[name] for name, version in versions.items()), "Selected installed speech libraries differ from the dependency lock"
    build = prepare_probe(ROOT, root, "live_audio_privacy.swift", "LiveAudioPrivacyTemporary")
    protocol = dict(build=build, source_commit=subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
                    tracked_changes=bool(subprocess.check_output(["git", "diff", "--name-only", "HEAD"], cwd=ROOT)),
                    runner_sha256=digest(Path(__file__)), probe_sha256=digest(ROOT / "benchmarks/live_audio_privacy.swift"),
                    source_sha256=original_sha, backend_sha256=backend, backend_files=len(backend),
                    wrapper_sha256=digest(package / "worker.py"),
                    model_lock_sha256=digest(ROOT / "backend/ospr_backend/models.lock.json"),
                    dependency_lock_sha256=digest(ROOT / "uv.lock"),
                    python_version=subprocess.check_output([str(args.python), "--version"], text=True).strip(),
                    python_executable_sha256=digest(args.python), library_versions=versions,
                    machine=dict(os=platform.mac_ver()[0], architecture=platform.machine(), cpu=subprocess.check_output(["sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip()),
                    boundary="Headless actual AppModel and cached Parakeet. Gate before second real generation after actual review preparation/adoption; live Keep audio revocation; later file; separate restart. No physical/UI/energy/ranking acceptance.")
    (root / "protocol.json").write_text(json.dumps(protocol, indent=2) + "\n")
    xctest = subprocess.check_output(["xcrun", "--find", "xctest"], text=True).strip()
    command = [xctest, "-XCTest", "OSprPlatformTests.LiveAudioPrivacyTemporary/testStage", str(ROOT / ".build/debug/OSprPackageTests.xctest")]
    records = []
    for stage in ["exercise", "restart"]:
        environment = dict(os.environ, HF_HUB_OFFLINE="1", OSPR_DEBUG_LOG="0", OSPR_AUDIO_PRIVACY_ROOT=str(root), OSPR_AUDIO_PRIVACY_STAGE=stage)
        with (root / (stage + ".log")).open("w") as log:
            subprocess.run(command, cwd=root / "engine", env=environment, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=180)
        record = json.loads((root / (stage + ".json")).read_text())
        records.append(record)
        assert record["status"] == "passed"
        if stage == "exercise":
            # Observe the production guardian; do not hide failure with a kill.
            until = time.monotonic() + 3
            pid = record["worker_pid"]
            while time.monotonic() < until:
                result = subprocess.run(["ps", "-p", str(pid), "-o", "stat="], capture_output=True, text=True)
                if not result.stdout.strip() or result.stdout.strip().startswith("Z"):
                    break
                time.sleep(.02)
            else:
                raise RuntimeError("Owned real worker outlived its finished owner")
    assert digest(args.audio) == original_sha
    assert application_fingerprint(ROOT) == build["application_source_sha256"]
    for name, expected in backend.items():
        actual = package / ("_actual_worker.py" if name == "worker.py" else name)
        assert digest(actual) == expected
    return dict(status="passed-real-local-audio-privacy-and-restart", protocol=protocol, records=records)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--audio", required=True, type=Path, help="Public mono PCM WAV")
    parser.add_argument("--python", type=Path, default=ROOT / ".venv/bin/python")
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=False)
    temporary = ROOT / "Tests/OSprPlatformTests/LiveAudioPrivacyTemporary.swift"
    if temporary.exists():
        raise RuntimeError("Temporary probe already exists; refusing to replace it")
    try:
        args.audio = args.audio.resolve(strict=True)
        args.python = args.python.absolute()  # Preserve the venv interpreter path.
        shutil.copy2(ROOT / "benchmarks/live_audio_privacy.swift", temporary)
        receipt = run(args)
        (args.output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
        print(json.dumps(dict(status=receipt["status"], backend_files=receipt["protocol"]["backend_files"])))
    except Exception as error:
        (args.output / "failure.json").write_text(json.dumps(dict(status="failed", error=str(error)), indent=2) + "\n")
        raise
    finally:
        if temporary.exists():
            if temporary.read_bytes() != (ROOT / "benchmarks/live_audio_privacy.swift").read_bytes():
                raise RuntimeError("Temporary probe changed; preserve it for inspection")
            temporary.unlink()


if __name__ == "__main__":
    main()
