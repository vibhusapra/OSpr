"""OSpr inference regression benchmark. Real raw outputs, no fabricated competitors."""

import argparse
import datetime
import hashlib
import importlib.metadata
import json
import platform
import resource
import subprocess
import time
from pathlib import Path

import jiwer
import numpy as np

from ospr_backend.engine import Engine, MODELS

ROOT = Path(__file__).resolve().parent


def normalize(text):
    # Conservative shared WER normalization. No model-specific number expansion.
    return jiwer.Compose(
        [jiwer.ToLowerCase(), jiwer.RemovePunctuation(), jiwer.RemoveMultipleSpaces(), jiwer.Strip()]
    )(text)


def summarize(records):
    summary = {}
    for suite in sorted({r["suite"] for r in records}):
        rows = [r for r in records if r["suite"] == suite]
        good = [r for r in rows if "error" not in r]
        scored = [r for r in good if r["reference"]]
        score = (
            jiwer.process_words(
                [normalize(r["reference"]) for r in scored], [normalize(r["text"]) for r in scored]
            )
            if scored
            else None
        )
        # FLEURS includes character-spaced references for some writing systems.
        # CER strips whitespace consistently; raw references remain published.
        cer = (
            jiwer.cer(
                ["".join(normalize(r["reference"]).split()) for r in scored],
                ["".join(normalize(r["text"]).split()) for r in scored],
            )
            if scored
            else None
        )
        times = [r["wall_ms"] for r in good]
        summary[suite] = dict(
            cases=len(rows),
            errors=len(rows) - len(good),
            wer=score.wer if score else None,
            cer=cer,
            substitutions=score.substitutions if score else None,
            deletions=score.deletions if score else None,
            insertions=score.insertions if score else None,
            p50_ms=float(np.percentile(times, 50)) if times else None,
            p95_ms=float(np.percentile(times, 95)) if times else None,
            aggregate_rtf=sum(times) / 1000 / sum(r["seconds"] for r in good) if good else None,
            hallucinated_silence=sum(bool(r.get("text", "").strip()) for r in good if not r["reference"]),
        )
    return summary


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", default="parakeet-v3", choices=MODELS)
    parser.add_argument("--limit", type=int, default=0)
    parser.add_argument("--suite", default="")
    parser.add_argument("--no-trim", action="store_true")
    parser.add_argument("--repeat", type=int, default=1)
    parser.add_argument("--manifest", default="fixtures/manifest.json")
    args = parser.parse_args()
    manifest = json.loads((ROOT / args.manifest).read_text())
    items = [r for r in manifest["items"] if not args.suite or r["suite"] == args.suite]
    if args.limit:
        items = items[: args.limit]
    if not items:
        raise SystemExit("No fixtures selected. Run benchmarks/prepare.py first.")
    engine = Engine()
    # Cold means process/model initialization with already-downloaded weights.
    # First decode/JIT is recorded separately and excluded from warm statistics.
    cold_start = time.perf_counter()
    cold = engine.transcribe(
        str(ROOT / items[0]["path"]),
        args.model,
        language=items[0].get("language", "en"),
        trim=not args.no_trim,
    )
    cold["wall_ms"] = (time.perf_counter() - cold_start) * 1000
    records = []
    name = args.model + ("-notrim" if args.no_trim else "") + (f"-{args.suite}" if args.suite else "")
    if args.manifest != "fixtures/manifest.json":
        name += "-" + Path(args.manifest).stem
    output = ROOT / "results" / f"{name}.json"
    for repeat in range(args.repeat):
        for item in items:
            path = ROOT / item["path"]
            if hashlib.sha256(path.read_bytes()).hexdigest() != item["sha256"]:
                raise ValueError(f"Fixture checksum mismatch: {path}")
            started = time.perf_counter()
            record = dict(item, repeat=repeat)
            try:
                record.update(
                    engine.transcribe(
                        str(path), args.model, language=item.get("language", "en"), trim=not args.no_trim
                    )
                )
            except Exception as error:
                record["error"] = f"{type(error).__name__}: {error}"
            record["wall_ms"] = (time.perf_counter() - started) * 1000
            records.append(record)
            print(
                f"{len(records)}/{len(items) * args.repeat} {item['id']} {record['wall_ms']:.0f}ms {record.get('text', record.get('error', ''))[:90]}",
                flush=True,
            )
    versions = {
        name: importlib.metadata.version(name)
        for name in ["mlx", "mlx-whisper", "parakeet-mlx", "mlx-audio", "numpy"]
    }
    result = dict(
        timestamp=datetime.datetime.now(datetime.UTC).isoformat(),
        model=args.model,
        model_spec=MODELS[args.model],
        platform=platform.platform(),
        machine=platform.machine(),
        hardware=subprocess.check_output(
            ["/usr/sbin/sysctl", "-n", "machdep.cpu.brand_string"], text=True
        ).strip(),
        memory_bytes=int(subprocess.check_output(["/usr/sbin/sysctl", "-n", "hw.memsize"], text=True)),
        source_sha256=hashlib.sha256(
            b"".join(
                p.relative_to(ROOT.parent).as_posix().encode() + b"\0" + p.read_bytes()
                for p in sorted(
                    list((ROOT.parent / "backend/ospr_backend").glob("*.py"))
                    + [
                        ROOT.parent / "uv.lock",
                        Path(__file__).resolve(),
                        ROOT.parent / "backend/ospr_backend/models.lock.json",
                    ]
                )
            )
        ).hexdigest(),
        git_commit=subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
        working_tree_dirty=bool(subprocess.check_output(["git", "status", "--porcelain"], text=True).strip()),
        versions=versions,
        options=vars(args),
        cold=cold,
        summary=summarize(records),
        process_peak_rss_bytes=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
        corpus={k: v for k, v in manifest.items() if k != "items"},
        records=records,
        limitations=[
            "Fixed public read-speech slices, not full corpora, spontaneous dictation or a multilingual leaderboard.",
            "Same host and power environment; no controlled thermal isolation or energy measurement.",
            "In-process audio-to-transcript timing excludes hotkey, capture, IPC, rewrite and text insertion.",
            "Shared model backends are not equivalent to testing competing app products.",
        ],
    )
    output.parent.mkdir(exist_ok=True)
    output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result["summary"], indent=2))
    print(output)


if __name__ == "__main__":
    main()
