"""Compare normalized samples and default ASR cuts against a recorded baseline.

This is input equivalence, not a new model accuracy or performance measurement.
"""
import argparse
import datetime
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile

import numpy as np
import soundfile as sf

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "backend"))


def sha(data):
    return hashlib.sha256(data).hexdigest()


def main():
    from ospr_backend.audio import read_audio
    from ospr_backend.audio_chunks import chunks

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", default="9864c79dd5d0193d958fada45fdac78f272f83d7")
    parser.add_argument("--output", type=Path, default=ROOT / "benchmarks/results/audio-input-equivalence.json")
    args = parser.parse_args()
    baseline = subprocess.check_output(["git", "rev-parse", args.baseline], cwd=ROOT, text=True).strip()
    sources, modules = {}, {}
    with tempfile.TemporaryDirectory(prefix="ospr-audio-equivalence-") as directory:
        for name in ("audio", "audio_chunks"):
            source = subprocess.check_output(["git", "show", f"{baseline}:backend/ospr_backend/{name}.py"], cwd=ROOT)
            sources[name] = sha(source)
            path = Path(directory) / f"{name}.py"
            path.write_bytes(source)
            spec = importlib.util.spec_from_file_location(f"ospr_backend._baseline_{name}", path)
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            modules[name] = module
        records, manifests = [], {}
        rate_controls = []
        # Exercise the branch absent from the existing 16 kHz speech fixtures.
        # Deliberately unequal stereo channels also verify downmix order.
        for rate in (8000, 16000, 44100, 48000):
            t = np.arange(rate * 2 + 17) / rate
            mono = (np.sin(t * 2 * np.pi * 437) * .12).astype(np.float32)
            for channels in (1, 2):
                samples = mono if channels == 1 else np.stack([mono, mono * -.3], axis=1)
                path = Path(directory) / f"control-{rate}-{channels}.wav"
                sf.write(path, samples, rate, subtype="FLOAT")
                old = modules["audio"].read_audio(str(path))
                new = read_audio(str(path))
                assert old.dtype == new.dtype and old.shape == new.shape and np.array_equal(old, new)
                assert [(len(part), start) for part, start in modules["audio_chunks"].chunks(old)] == [(len(part), start) for part, start in chunks(new)]
                rate_controls.append(dict(rate=rate, channels=channels, frames=len(new), normalized_sha256=sha(new.tobytes())))
        for name in ("manifest", "test-clean", "test-other", "fleurs"):
            path = ROOT / f"benchmarks/fixtures/{name}.json"
            manifests[name] = sha(path.read_bytes())
            for item in json.loads(path.read_text())["items"]:
                audio_path = ROOT / "benchmarks" / item["path"]
                assert sha(audio_path.read_bytes()) == item["sha256"]
                old = modules["audio"].read_audio(str(audio_path))
                new = read_audio(str(audio_path))
                assert old.dtype == new.dtype and old.shape == new.shape and np.array_equal(old, new), item["id"]
                old_cuts = [(len(part), start) for part, start in modules["audio_chunks"].chunks(old)]
                new_cuts = [(len(part), start) for part, start in chunks(new)]
                assert old_cuts == new_cuts, item["id"]
                records.append(dict(suite=name, id=item["id"], frames=len(new), normalized_sha256=sha(new.tobytes()), chunks=len(new_cuts)))
    assert len(records) == 515
    result = dict(status="passed", verified_at=datetime.datetime.now(datetime.UTC).isoformat(), baseline=baseline,
                  baseline_source_sha256=sources, current_source_sha256={name: sha((ROOT / f"backend/ospr_backend/{name}.py").read_bytes()) for name in sources},
                  manifests_sha256=manifests, cases=len(records), records=records, rate_controls=rate_controls,
                  boundary="All 515 existing short-suite inputs, eight synthetic mono/stereo rate controls (8/16/44.1/48 kHz), and default ASR cut offsets are bit-identical to the baseline. No model inference rerun, speed, long-file equivalence, or new accuracy claim.")
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({"status": "passed", "cases": len(records)}))


if __name__ == "__main__":
    main()
