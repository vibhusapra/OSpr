"""Research-only direct, disjoint low-energy chunks versus Parakeet overlap merge."""

import datetime
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import platform
import resource
import subprocess
import time

import mlx.core as mx

from ospr_backend.audio import read_audio
from ospr_backend.engine import Engine, MODEL_LOCK, MODELS
from ospr_backend.qwen import chunks
from parakeet_mlx.audio import get_logmel
from run import ROOT, summarize


def decode(model, item):
    path = ROOT / item["path"]
    if hashlib.sha256(path.read_bytes()).hexdigest() != item["sha256"]:
        raise ValueError("Fixture checksum mismatch")
    started = time.perf_counter()
    audio = read_audio(str(path))
    mx.reset_peak_memory()
    texts, segments, count, decoded_samples = [], [], 0, 0
    for part, offset in chunks(audio):
        mel = get_logmel(mx.array(part, dtype=mx.float32), model.preprocessor_config)
        result = model.generate(mel)[0]
        texts.append(result.text.strip())
        segments.extend(dict(start=float(s.start) + offset, end=float(s.end) + offset,
                             text=s.text) for s in result.sentences)
        count += 1
        decoded_samples += len(part)
    assert decoded_samples == len(audio)
    mx.synchronize()
    return dict(item, text=" ".join(t for t in texts if t), segments=segments,
                wall_ms=(time.perf_counter() - started) * 1000,
                peak_gpu_bytes=mx.get_peak_memory(), decoder_chunks=count,
                input_samples=len(audio), decoded_samples=decoded_samples, word_timestamps=False)


def main():
    manifest_path = ROOT / "fixtures/long-session.json"
    manifest = json.loads(manifest_path.read_text())
    engine = Engine()
    started = time.perf_counter()
    model, _ = engine._load("parakeet-v3")
    load_ms = (time.perf_counter() - started) * 1000
    cold = decode(model, manifest["items"][0])
    records = []
    for item in manifest["items"]:
        record = decode(model, item)
        records.append(record)
        print(json.dumps(dict(id=item["id"], wall_ms=record["wall_ms"],
                              chunks=record["decoder_chunks"])), flush=True)
    paths = [Path(__file__), ROOT / "run.py", ROOT.parent / "uv.lock", *sorted(
        (ROOT.parent / "backend/ospr_backend").glob("*.py"))]
    result = dict(timestamp=datetime.datetime.now(datetime.UTC).isoformat(),
                  model="parakeet-v3", model_spec=MODELS["parakeet-v3"], research_candidate=True,
                  candidate="Direct 30s maximum disjoint low-energy chunks; no overlap token merger",
                  model_lock=MODEL_LOCK["parakeet-v3"], offline=os.environ.get("HF_HUB_OFFLINE") == "1",
                  git_commit=subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
                  working_tree_dirty=bool(subprocess.check_output(["git", "status", "--porcelain"], text=True).strip()),
                  source_sha256=hashlib.sha256(b"".join(
                      p.relative_to(ROOT.parent).as_posix().encode() + b"\0" + p.read_bytes()
                      for p in paths)).hexdigest(),
                  versions={name: importlib.metadata.version(name) for name in ("mlx", "parakeet-mlx", "numpy")},
                  hardware=subprocess.check_output(["/usr/sbin/sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip(),
                  platform=platform.platform(), model_load_ms=load_ms, cold=cold, records=records,
                  process_peak_rss_bytes=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
                  corpus_manifest_sha256=hashlib.sha256(manifest_path.read_bytes()).hexdigest(),
                  summary=summarize(records),
                  boundary="Research Engine-pinned model, direct float32 Mel and disjoint sample-preserving chunks. No overlap merge, text deduplication, word-timing derivation, microphone, UI or insertion.",
                  limitations=["Two deterministic concatenations, repeated read speech, one warm trial each; not natural long conversation or a full corpus.",
                               "Fixed order, no thermal isolation; exploratory timings. Chunk boundaries can cut words and lose acoustic context.",
                               "Not enabled in the shipping engine; word-timing/diarization and broader regression acceptance are still required."])
    target = ROOT / "results/parakeet-long-candidate.json"
    target.write_text(json.dumps(result, indent=2) + "\n")
    print(str(target), flush=True)


if __name__ == "__main__":
    main()
