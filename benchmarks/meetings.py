"""Explicit frame-based meeting diagnostics. Not an official diarization leaderboard."""

import argparse
import datetime
import hashlib
import importlib.metadata
import json
from pathlib import Path
import subprocess
import time
import jiwer
import numpy as np
from scipy.optimize import linear_sum_assignment
from ospr_backend.engine import Engine
from run import normalize

ROOT = Path(__file__).resolve().parent


def activity(turns, frames, step=0.01):
    result = np.zeros((frames, 8), dtype=bool)
    for turn in turns:
        start = max(0, int(round(turn["start"] / step)))
        end = min(frames, int(round(turn["end"] / step)))
        result[start:end, turn["speaker"]] = True
    return result


def diarization_score(reference, hypothesis, seconds, collar=0.25):
    # 10 ms discretization; union activity per anonymous speaker, overlaps included.
    step = 0.01
    frames = int(round(seconds / step))
    ref, hyp = activity(reference, frames), activity(hypothesis, frames)
    keep = np.ones(frames, dtype=bool)
    for turn in reference:
        for edge in [turn["start"], turn["end"]]:
            left = max(0, int(np.floor((edge - collar) / step)))
            right = min(frames, int(np.ceil((edge + collar) / step)))
            if collar:
                keep[left:right] = False
    ref, hyp = ref[keep], hyp[keep]
    mapping = linear_sum_assignment(ref.astype(np.int64).T @ hyp.astype(np.int64), maximize=True)
    correct = sum(np.logical_and(ref[:, r], hyp[:, h]).astype(int) for r, h in zip(*mapping, strict=True))
    nref, nhyp = ref.sum(axis=1), hyp.sum(axis=1)
    miss = np.maximum(nref - nhyp, 0).sum()
    false_alarm = np.maximum(nhyp - nref, 0).sum()
    confusion = (np.minimum(nref, nhyp) - correct).sum()
    denominator = nref.sum()
    return {
        "der": float((miss + false_alarm + confusion) / denominator) if denominator else None,
        "miss_seconds": float(miss * step),
        "false_alarm_seconds": float(false_alarm * step),
        "confusion_seconds": float(confusion * step),
        "reference_speaker_seconds": float(denominator * step),
        "scored_wall_seconds": float(len(ref) * step),
        "collar_seconds": collar,
        "frame_seconds": step,
        "include_overlap": True,
        "permutation": {str(h): int(r) for r, h in zip(*mapping, strict=True)},
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--model", default="parakeet-v3", choices=["parakeet-v3", "whisper-turbo", "whisper-small"]
    )
    args = parser.parse_args()
    manifest = json.loads((ROOT / "fixtures/ami.json").read_text())
    if manifest.get("reference_protocol") != "AMI-only_words-rttm-v1":
        raise ValueError("Re-run prepare_ami.py: published only_words reference is required.")
    engine = Engine()
    records = []
    for item in manifest["items"]:
        path = ROOT / item["path"]
        if hashlib.sha256(path.read_bytes()).hexdigest() != item["sha256"]:
            raise ValueError("AMI fixture checksum changed")
        start = time.perf_counter()
        result = engine.meeting(str(path), args.model, language="en")
        result["wall_ms"] = (time.perf_counter() - start) * 1000
        words = jiwer.process_words(normalize(item["reference"]), normalize(result["raw_text"]))
        scored = {
            "id": item["id"],
            "model": args.model,
            "asr_wer": words.wer,
            "der_250ms": diarization_score(item["turns"], result["speaker_turns"], item["seconds"]),
            "der_0ms": diarization_score(item["turns"], result["speaker_turns"], item["seconds"], collar=0),
            "reference": item["reference"],
            "result": result,
        }
        records.append(scored)
        print(
            item["id"],
            f"WER {words.wer:.3%}",
            f"DER {scored['der_250ms']['der']:.3%}",
            round(result["wall_ms"]),
            flush=True,
        )
    output = {
        "timestamp": datetime.datetime.now(datetime.UTC).isoformat(),
        "model": args.model,
        "git_commit": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
        "working_tree_dirty": bool(subprocess.check_output(["git", "status", "--porcelain"], text=True).strip()),
        "source_sha256": hashlib.sha256(b"".join(
            p.relative_to(ROOT.parent).as_posix().encode() + b"\0" + p.read_bytes()
            for p in [Path(__file__), ROOT.parent / "uv.lock", *sorted(
                (ROOT.parent / "backend/ospr_backend").glob("*.py")),
                ROOT.parent / "backend/ospr_backend/models.lock.json"])).hexdigest(),
        "versions": {name: importlib.metadata.version(name) for name in ("mlx", "mlx-audio", "parakeet-mlx", "numpy", "jiwer")},
        "method": "AMI headset-mix slices; 10 ms speaker activity with best per-recording Hungarian mapping; pinned AMI only_words RTTM reference; overlap included; collar 0/250 ms.",
        "corpus": {k: v for k, v in manifest.items() if k != "items"},
        "records": records,
        "limitations": manifest["limitations"]
        + [
            "Custom transparent diagnostic scorer, not pyannote/dscore official replication.",
            "First meeting includes model loading/JIT; per-file timings are not warm latency percentiles.",
            "Word speaker attribution cannot separate overlapping speech. No consumer-app or production meeting ranking.",
        ],
    }
    (ROOT / "results" / f"ami-{args.model}.json").write_text(json.dumps(output, indent=2) + "\n")


if __name__ == "__main__":
    main()
