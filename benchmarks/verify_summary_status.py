"""Replay all frozen summary calls/results without inference or quality scoring.

Optional --verify-prompts uses only cached pinned tokenizers to check every
rendered prompt and input-token count. Default CI checks stored-call/source/result
integrity; neither mode proves semantic quality, model execution or timing.
"""
import argparse
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import sys
import types

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "benchmarks/fixtures/summary-status-study.json"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def archive_module(source, notes):
    package = "ospr_summary_status_archive"
    if package not in sys.modules:
        module = types.ModuleType(package)
        module.__path__ = []
        sys.modules[package] = module
    for name, path in [(package + ".notes", notes), (package + ".summary", source)]:
        spec = importlib.util.spec_from_file_location(name, path)
        module = importlib.util.module_from_spec(spec)
        sys.modules[name] = module
        spec.loader.exec_module(module)
    return module


def replay(data, protocol, summarize, tokenizer=None):
    expected = [r["id"] for r in protocol["cases"]]
    assert data["status"] == "completed-development-comparison"
    assert data["selected_case_ids"] == expected
    assert [r["id"] for r in data["records"]] == expected, "Missing, duplicate or reordered case"
    assert data["model"] in protocol["models"] and data["completion_gate"] == "eos"
    assert data["encoding"] == "full" and data["decoding"] == "unconstrained"
    admitted, calls = 0, 0
    for case, record in zip(protocol["cases"], data["records"], strict=True):
        assert record["source_sha256"] == hashlib.sha256(case["text"].encode()).hexdigest()
        assert math.isfinite(record["wall_ms"]) and record["wall_ms"] >= 0
        assert record["calls"], "A nonempty cohort case needs an observed attempt"
        cursor = 0

        def complete(prompt, instruction, record=record):
            nonlocal cursor, calls
            assert cursor < len(record["calls"]), "Replay requested an unrecorded call"
            attempt = record["calls"][cursor]
            cursor += 1
            calls += 1
            if tokenizer is not None:
                rendered = tokenizer.apply_chat_template(
                    [{"role": "system", "content": instruction}, {"role": "user", "content": prompt}],
                    tokenize=False, add_generation_prompt=True, enable_thinking=False,
                )
                assert hashlib.sha256(rendered.encode()).hexdigest() == attempt["prompt_sha256"], "Rendered prompt differs"
                assert len(tokenizer.encode(rendered)) == attempt["input_tokens"], "Input-token count differs"
            if attempt["status"] == "failed":
                kind, message = attempt["error"].split(": ", 1)
                assert kind in {"ValueError", "RuntimeError"}
                raise {"ValueError": ValueError, "RuntimeError": RuntimeError}[kind](message)
            assert attempt["status"] == "completed"
            assert attempt["completion"]["finish_reason"] == "stop"
            assert 0 < attempt["completion"]["generation_tokens"] <= 4096
            assert attempt["input_tokens"] + 4096 <= 32768
            return attempt["output"]

        try:
            result = summarize(case["text"], complete)
        except (ValueError, RuntimeError) as error:
            assert record["status"] == "rejected-no-summary"
            assert record["error"] == f"{type(error).__name__}: {error}"
        else:
            assert record["status"] == "accepted-for-review"
            assert result == record["result"], "Stored result differs from frozen processing"
            admitted += 1
        assert cursor == len(record["calls"]), "Unconsumed recorded calls"
    return dict(cases=len(expected), calls=calls, admitted_for_review=admitted,
                rejected=len(expected) - admitted, rendered_prompts_verified=tokenizer is not None)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verify-prompts", action="store_true", help="Use cached pinned tokenizers; no weights or inference")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.output and args.output.exists():
        parser.error("Choose a new verification receipt")
    study = json.loads(MANIFEST.read_text())
    protocol_path = ROOT / study["protocol"]["path"]
    assert digest(protocol_path) == study["protocol"]["sha256"]
    protocol = json.loads(protocol_path.read_text())
    notes = ROOT / study["notes"]["path"]
    assert digest(notes) == study["notes"]["sha256"]
    tokenizers, results = {}, []
    for run in study["runs"]:
        path, implementation = ROOT / run["path"], ROOT / run["implementation"]["path"]
        assert digest(path) == run["sha256"] and digest(implementation) == run["implementation"]["sha256"]
        data = json.loads(path.read_text())
        assert data["algorithm"] == run["algorithm"]
        assert data["protocol_sha256"] == study["protocol"]["sha256"]
        assert data["implementation_sha256"][run["implementation"]["recorded_path"]] == run["implementation"]["sha256"]
        tokenizer = None
        if args.verify_prompts:
            model = data["model"]
            key = (model["repo"], model["revision"])
            if key not in tokenizers:
                from huggingface_hub import snapshot_download
                from mlx_lm.utils import load_tokenizer
                directory = Path(snapshot_download(key[0], revision=key[1], local_files_only=True,
                                                  allow_patterns=["*.json", "*.txt", "*.model", "*.jinja", "*.tiktoken"]))
                config = json.loads((directory / "config.json").read_text())
                tokenizers[key] = load_tokenizer(directory, eos_token_ids=config.get("eos_token_id"))
            tokenizer = tokenizers[key]
        result = replay(data, protocol, archive_module(implementation, notes).summarize, tokenizer)
        assert {k: v for k, v in result.items() if k != "rendered_prompts_verified"} == run["expected"], "Declared denominator differs"
        results.append(dict(name=run["name"], **result))
    result = dict(status="passed-frozen-summary-call-replay", runs=results,
                  boundary="Stored call/result/source integrity. Prompt mode additionally verifies cached rendered prompts/token counts. No new generation, semantic acceptance, authentic execution attestation, timing or product ranking.")
    if args.output:
        with args.output.open("x") as out:
            out.write(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result))


if __name__ == "__main__":
    main()
