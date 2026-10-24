"""Replay public synthetic text through local refiners; retain every raw output.

Example (optional baseline is a saved prior engine.py alongside its models.lock.json):
  HF_HUB_OFFLINE=1 PYTHONPATH=backend .venv/bin/python benchmarks/refinement_eval.py \
    --baseline-engine .local/refinement-baseline-engine.py --baseline-commit <sha> \
    --output .local/refinement-evaluation.json

This is a development/challenge fidelity probe, not a semantic quality or speed
ranking. It does not call a cloud provider or overwrite earlier benchmark data.
"""

import argparse
import datetime
import gc
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess

from ospr_backend.engine import Engine, MODEL_LOCK

ROOT = Path(__file__).resolve().parents[1]
INSTRUCTION = "Remove filler words, false starts and accidental repetitions. Fix punctuation. Preserve the speaker's voice."


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--baseline-engine", type=Path)
    parser.add_argument("--baseline-commit")
    parser.add_argument("--model", choices=["rewrite-quality", "meeting-quality"], default="rewrite-quality")
    args = parser.parse_args()
    if args.output.exists():
        parser.error("Output already exists; choose a new receipt path.")
    case_file = ROOT / "benchmarks/refinement_cases.json"
    cases = json.loads(case_file.read_text())["cases"]
    variants = []
    if args.baseline_engine:
        if args.model != "rewrite-quality":
            parser.error("Historical prompt comparison requires the original rewrite-quality model.")
        if not args.baseline_commit:
            parser.error("A saved baseline needs --baseline-commit for source/lock verification.")
        baseline_commit = subprocess.check_output(["git", "rev-parse", args.baseline_commit], cwd=ROOT, text=True).strip()
        for relative, saved in [("backend/ospr_backend/engine.py", args.baseline_engine),
                                ("backend/ospr_backend/models.lock.json", args.baseline_engine.with_name("models.lock.json"))]:
            expected = subprocess.check_output(["git", "show", f"{baseline_commit}:{relative}"], cwd=ROOT)
            if saved.read_bytes() != expected:
                parser.error(f"Saved baseline differs from {baseline_commit}:{relative}")
        if json.loads(args.baseline_engine.with_name("models.lock.json").read_text())["rewrite-quality"] != MODEL_LOCK["rewrite-quality"]:
            parser.error("Baseline and candidate must use the same pinned refiner for this prompt comparison.")
        spec = importlib.util.spec_from_file_location("ospr_backend._baseline_engine", args.baseline_engine)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        variants.append(("baseline", module.Engine, sha(args.baseline_engine)))
    variants.append(("candidate", Engine, sha(ROOT / "backend/ospr_backend/engine.py")))
    records = []
    for variant, engine_class, engine_sha in variants:
        engine = engine_class()
        try:
            for case in cases:
                import mlx.core as mx
                mx.reset_peak_memory()
                result = engine.rewrite(case["input"], INSTRUCTION, **({"model_id": args.model} if variant == "candidate" else {}))
                output = result["text"]
                missing = [fact for fact in case["facts"] if fact.casefold() not in output.casefold()]
                invented = [fact for fact in case["forbidden"] if fact.casefold() in output.casefold()]
                row = dict(case, variant=variant, engine_sha256=engine_sha, **result,
                           peak_mlx_bytes=mx.get_peak_memory(),
                           missing_facts=missing, forbidden_present=invented,
                           lexical_pass=not missing and not invented)
                records.append(row)
                print(json.dumps({"variant": variant, "id": case["id"], "lexical_pass": row["lexical_pass"]}), flush=True)
        finally:
            # Avoid comparing two simultaneously resident copies of the refiner.
            engine.rewriter = None
            del engine
            gc.collect()
    receipt = dict(
        schema_version=1, verified_at=datetime.datetime.now(datetime.UTC).isoformat(),
        git_commit=subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        tracked_changes=bool(subprocess.check_output(["git", "diff", "--name-only", "HEAD"], cwd=ROOT)),
        cases_sha256=sha(case_file), harness_sha256=sha(Path(__file__)),
        refinement_sha256=sha(ROOT / "backend/ospr_backend/refinement.py"),
        dependency_lock_sha256=sha(ROOT / "uv.lock"), model=MODEL_LOCK[args.model],
        model_id=args.model,
        instruction=INSTRUCTION, records=records,
        limitations=[
            "Twelve existing development cases plus 24 fresh synthetic challenge cases; not a representative held-out benchmark.",
            "Exact substring sentinels can pass explanations or miss equivalent currency and contraction forms. Read raw outputs.",
            "Sequential runs on a shared Mac, one output per case. Timings are diagnostic, not a latency comparison.",
            "These are raw model outputs. Native fallback, application delivery and semantic correctness are separate checks.",
        ],
    )
    if args.baseline_engine:
        receipt["baseline_source_commit"] = baseline_commit
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + "\n")


if __name__ == "__main__":
    main()
