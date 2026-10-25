"""Owned owner-SIGKILL controls, GIL-held production main, and warm IPC overhead.

The optional real control enters cached Parakeet generation on repeated public
speech, interrupts its native owner, and checks fresh-process speech equality.
All output lives in a new private directory. No microphone, UI or provider API.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import platform
import shlex
import shutil
import signal
import subprocess
import time
import wave

from durable_import_common import application_fingerprint, digest

ROOT = Path(__file__).resolve().parents[1]


def snapshot(pid):
    result = subprocess.run(
        ["ps", "-p", str(pid), "-o", "ppid=,pgid=,stat=,lstart=,command="], capture_output=True, text=True
    )
    row = result.stdout.strip().split(None, 8)
    if result.returncode or len(row) != 9 or row[2].startswith("Z"):
        return None
    return dict(parent=int(row[0]), group=int(row[1]), state=row[2], start=" ".join(row[3:8]), command=row[8])


def signal_owned(pid, identity, value):
    current = snapshot(pid)
    if current and (current["group"], current["start"], current["command"]) == (
        identity["group"],
        identity["start"],
        identity["command"],
    ):
        try:
            os.kill(pid, value)
        except ProcessLookupError:
            pass


def fixture(directory, python, actual_worker, real_audio=None):
    engine = directory / "engine"
    package = engine / "backend/ospr_backend"
    package.mkdir(parents=True)
    (engine / ".venv/bin").mkdir(parents=True)
    launcher = engine / ".venv/bin/python"
    launcher.write_text("#!/bin/sh\nexec " + shlex.quote(str(python)) + ' "$@"\n')
    launcher.chmod(0o700)
    (package / "__init__.py").write_text(
        '__version__="lifetime-control"\n__path__.append(' + repr(str(actual_worker.parent)) + ")\n"
    )
    (package / "_actual_worker.py").write_bytes(actual_worker.read_bytes())
    control = """from . import _actual_worker as real
import ctypes,json,os,pathlib,subprocess,sys,time
original=real.dispatch
def dispatch(engine,request):
    if request.get('action') != 'owned_lifetime_control': return original(engine,request)
    decoder=subprocess.Popen([sys.executable,'-c',"import signal,pathlib,time;signal.signal(signal.SIGTERM,signal.SIG_IGN);pathlib.Path('decoder-ready').touch();time.sleep(120)"],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    until=time.monotonic()+5
    while not pathlib.Path('decoder-ready').exists():
        if time.monotonic()>until: raise RuntimeError('decoder did not start')
        time.sleep(.01)
    pathlib.Path('admitted.tmp').write_text(json.dumps(dict(worker=os.getpid(),decoder=decoder.pid,owner=os.getppid(),group=os.getpgrp())))
    pathlib.Path('admitted.tmp').replace('admitted.json')
    ctypes.PyDLL(None).sleep(120)
    return {'done':True}
real.dispatch=dispatch
"""
    if real_audio:
        control = """from . import _actual_worker as real
import json,os,pathlib
Original=real.Engine
class Observed(Original):
    def _load(self,model_id):
        model,warm=super()._load(model_id)
        cls=type(model)
        if not getattr(cls,'_lifetime_observed',False):
            original=cls.generate
            def generate(instance,*args,**kwargs):
                if not pathlib.Path('admitted.json').exists():
                    pathlib.Path('admitted.tmp').write_text(json.dumps(dict(worker=os.getpid(),owner=os.getppid(),group=os.getpgrp(),boundary='before real Parakeet generate')))
                    pathlib.Path('admitted.tmp').replace('admitted.json')
                return original(instance,*args,**kwargs)
            cls.generate=generate
            cls._lifetime_observed=True
        return model,warm
real.Engine=Observed
"""
    (package / "worker.py").write_text(control + "real.main()\n")
    return engine, digest(package / "worker.py")


def run_kill(owner, directory, python, real_audio=None):
    directory.mkdir()
    engine, dispatch_sha = fixture(directory, python, ROOT / "backend/ospr_backend/worker.py", real_audio)
    result_path = directory / "unexpected-completed.json"
    command = [str(owner), str(engine), "real" if real_audio else "control", str(result_path)]
    if real_audio:
        command.append(str(real_audio))
    identities = {}
    environment = dict(os.environ, HF_HUB_OFFLINE="1", OSPR_DEBUG_LOG="0")
    with (directory / "owner.log").open("w") as log:
        process = subprocess.Popen(
            command, cwd=engine, stdout=log, stderr=subprocess.STDOUT, start_new_session=True, env=environment
        )
        try:
            until = time.monotonic() + 60
            while not (engine / "admitted.json").exists():
                if process.poll() is not None:
                    raise RuntimeError("Owner stopped before admission; inspect retained owner.log")
                if time.monotonic() > until:
                    raise TimeoutError("Admission deadline; logs retained")
                time.sleep(0.01)
            ids = json.loads((engine / "admitted.json").read_text())
            assert ids["owner"] == process.pid and ids["group"] == ids["worker"]
            for key in ["worker", "decoder"]:
                if key in ids:
                    identity = snapshot(ids[key])
                    assert identity and identity["group"] == ids["group"]
                    assert identity["parent"] == (process.pid if key == "worker" else ids["worker"])
                    identities[key] = identity
            if real_audio:
                time.sleep(0.2)
                assert snapshot(ids["worker"]) and process.poll() is None and not result_path.exists()
            assert process.poll() is None
            # One diagnostic RSS/CPU-time snapshot, not peak memory or energy.
            helpers = []
            listing = subprocess.check_output(["ps", "-axo", "pid=,ppid=,rss=,time=,command="], text=True)
            expected = str(owner.parent / "ospr-worker-guardian") + f" {process.pid} {ids['worker']}"
            for line in listing.splitlines():
                fields = line.strip().split(None, 4)
                if len(fields) == 5 and int(fields[1]) == process.pid and fields[4] == expected:
                    helpers.append(dict(pid=int(fields[0]), rss_kib=int(fields[2]), cpu_time=fields[3]))
            assert len(helpers) == (0 if owner.name.startswith("baseline") else 1)
            started = time.monotonic()
            process.kill()
            assert process.wait(5) == -signal.SIGKILL
            time.sleep(2.5)
            surviving = {key: snapshot(ids[key]) is not None for key in identities}
            return dict(
                owner_exit=-signal.SIGKILL,
                ids=ids,
                dispatch_sha256=dispatch_sha,
                observation_seconds=time.monotonic() - started,
                survived=surviving,
                unexpected_result=result_path.exists(),
                helper_snapshot=helpers,
            )
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(5)
            # Failure cleanup is separate from the predeclared observations.
            for key, identity in identities.items():
                signal_owned(ids[key], identity, signal.SIGKILL)
            time.sleep(0.1)
            for key in identities:
                assert snapshot(ids[key]) is None, "Owned fixture did not stop after cleanup"


def command(owner, engine, mode, directory, audio=None):
    destination = directory / (mode + ".json")
    args = [str(owner), str(engine), mode, str(destination)] + ([str(audio)] if audio else [])
    with (directory / (mode + ".log")).open("w") as log:
        subprocess.run(
            args,
            check=True,
            stdout=log,
            stderr=subprocess.STDOUT,
            env=dict(os.environ, HF_HUB_OFFLINE="1", OSPR_DEBUG_LOG="0"),
            timeout=180,
        )
    return json.loads(destination.read_text())


def run(args):
    before = application_fingerprint(ROOT)
    source = ROOT / "Sources/OSprCore"
    with (args.output / "build.log").open("w") as log:
        subprocess.run(
            ["swift", "build", "-c", "release", "--product", "ospr-worker-guardian"],
            cwd=ROOT,
            check=True,
            stdout=log,
            stderr=subprocess.STDOUT,
            timeout=180,
        )
    shutil.copy2(ROOT / ".build/release/ospr-worker-guardian", args.output / "ospr-worker-guardian")
    owners = {}
    for kind in ["baseline", "candidate"] if args.baseline_ref else ["candidate"]:
        worker_source = source / "WorkerClient.swift"
        sources = [str(worker_source), str(source / "WorkerLifetime.swift")]
        if kind == "baseline":
            worker_source = args.output / "baseline-WorkerClient.swift"
            worker_source.write_bytes(
                subprocess.check_output(
                    ["git", "show", args.baseline_ref + ":Sources/OSprCore/WorkerClient.swift"], cwd=ROOT
                )
            )
            sources = [str(worker_source)]
        owners[kind] = args.output / (kind + "-owner")
        with (args.output / (kind + "-build.log")).open("w") as log:
            subprocess.run(
                [
                    "swiftc",
                    "-O",
                    "-parse-as-library",
                    *sources,
                    str(ROOT / "benchmarks/worker_lifetime.swift"),
                    "-o",
                    str(owners[kind]),
                ],
                check=True,
                stdout=log,
                stderr=subprocess.STDOUT,
                timeout=120,
            )
    protocol = dict(
        application_source_sha256=before,
        source_manifest_version=2,
        source_commit=subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        tracked_changes=bool(subprocess.check_output(["git", "diff", "--name-only", "HEAD"], cwd=ROOT)),
        baseline_ref=args.baseline_ref,
        owner_sha256={key: digest(path) for key, path in owners.items()},
        guardian_sha256=digest(args.output / "ospr-worker-guardian"),
        worker_sha256=digest(ROOT / "backend/ospr_backend/worker.py"),
        dependency_lock_sha256=digest(ROOT / "uv.lock"),
        model_lock_sha256=digest(ROOT / "backend/ospr_backend/models.lock.json"),
        python_version=subprocess.check_output([str(args.python), "--version"], text=True).strip(),
        runner_sha256=digest(Path(__file__)),
        probe_sha256=digest(ROOT / "benchmarks/worker_lifetime.swift"),
        observation_seconds=2.5,
        real_generate_delay_seconds=0.2,
        order=["baseline", "candidate", "candidate", "baseline"]
        if args.baseline_ref
        else ["candidate", "candidate"],
        machine=dict(
            os=platform.mac_ver()[0],
            arch=platform.machine(),
            cpu=subprocess.check_output(["sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip(),
        ),
        boundary="Injected GIL-held dispatch in production Python main; native owner SIGKILL; owned SIGTERM-ignoring decoder. No microphone/UI/provider. Shared-machine overhead observations, no comparative product or energy ranking.",
    )
    (args.output / "protocol.json").write_text(json.dumps(protocol, indent=2) + "\n")
    records = []
    for index, kind in enumerate(protocol["order"]):
        result = run_kill(owners[kind], args.output / f"kill-{index:02}-{kind}", args.python)
        row = dict(kind=kind, control="GIL-held-real-main", **result)
        records.append(row)
        (args.output / "records.json").write_text(json.dumps(records, indent=2) + "\n")
        assert (
            all(result["survived"].values()) if kind == "baseline" else not any(result["survived"].values())
        )
        directory = args.output / f"measure-{index:02}-{kind}"
        directory.mkdir()
        engine, _ = fixture(directory, args.python, ROOT / "backend/ospr_backend/worker.py")
        measured = command(owners[kind], engine, "measure", directory)["records"]
        assert len({row["pid"] for row in measured}) == 1
        records.append(dict(kind=kind, control="cold-and-five-warm-pings", records=measured))
    if args.real_audio:
        # Repetition changes no original bytes. About one hour guarantees that
        # the declared 200ms post-entry observation is inside a live request.
        long_audio = args.output / "public-repeat-hour.wav"
        with wave.open(str(args.real_audio), "rb") as reader:
            params = reader.getparams()
            frames = reader.readframes(reader.getnframes())
        with wave.open(str(long_audio), "wb") as writer:
            writer.setparams(params)
            for _ in range(max(1, round(3600 / (params.nframes / params.framerate)))):
                writer.writeframesraw(frames)
        records.append(
            dict(
                kind="candidate",
                control="real-Parakeet-owner-kill",
                **run_kill(owners["candidate"], args.output / "real-kill", args.python, long_audio),
            )
        )
        assert not any(records[-1]["survived"].values())
        speech = []
        for kind in ["baseline", "candidate"] if args.baseline_ref else ["candidate", "candidate"]:
            directory = args.output / ("real-control-" + str(len(speech)) + "-" + kind)
            directory.mkdir()
            engine, _ = fixture(directory, args.python, ROOT / "backend/ospr_backend/worker.py")
            reply = command(owners[kind], engine, "real", directory, args.real_audio)["records"][0]
            semantic = {
                key: reply.get(key) for key in ["text", "segments", "language", "model", "audio_seconds"]
            }
            speech.append(semantic)
            records.append(dict(kind=kind, control="fresh-process-public-speech", semantic=semantic))
        assert speech[0] == speech[1]
        protocol["real_audio_sha256"] = digest(args.real_audio)
    assert before == application_fingerprint(ROOT), "Application source changed during controls"
    return dict(status="passed-owned-worker-lifetime-controls", protocol=protocol, records=records)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--python", type=Path, default=ROOT / ".venv/bin/python")
    parser.add_argument(
        "--baseline-ref", help="Explicit historical source ref for the known pre-guardian negative control"
    )
    parser.add_argument(
        "--real-audio", type=Path, help="Optional cached-Parakeet control using a public mono PCM WAV"
    )
    args = parser.parse_args()
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=False)
    # Keep a venv path: resolving the interpreter symlink would drop its packages.
    args.python = args.python.absolute()
    try:
        if args.real_audio:
            args.real_audio = args.real_audio.resolve(strict=True)
        receipt = run(args)
    except Exception as error:
        (args.output / "failure.json").write_text(
            json.dumps(dict(status="failed", error=str(error)), indent=2) + "\n"
        )
        raise
    (args.output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(dict(status=receipt["status"], records=len(receipt["records"]))))


if __name__ == "__main__":
    main()
