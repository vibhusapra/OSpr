"""Local-model development comparison; schema/citation checks are not entailment."""

import argparse
import datetime
import hashlib
import json
from pathlib import Path
import time

from ospr_backend.summary import summarize

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True, choices=["qwen3-4b", "qwen3.5-9b"])
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--algorithm", choices=["current", "v1"], default="current")
    parser.add_argument("--completion", choices=["eos", "legacy"], default="eos",
                        help="Require production EOS acknowledgement; legacy reproduces historical string-only runs.")
    args = parser.parse_args()
    implementation = ROOT / "backend/ospr_backend/summary.py"
    summarize_function = summarize
    if args.algorithm == "v1":
        import importlib.util

        implementation = ROOT / "benchmarks/fixtures/meeting_summary_v1.py"
        module_spec = importlib.util.spec_from_file_location(
            "ospr_backend._meeting_summary_v1", implementation
        )
        module = importlib.util.module_from_spec(module_spec)
        module_spec.loader.exec_module(module)
        summarize_function = module.summarize
    protocol_path = ROOT / "benchmarks/fixtures/meeting-summary-protocol.json"
    protocol = json.loads(protocol_path.read_text())
    spec = next(model for model in protocol["models"] if model["id"] == args.model)
    from huggingface_hub import snapshot_download
    from mlx_lm import load, generate, stream_generate
    from ospr_backend.local_completion import completed_text
    import mlx.core as mx

    started = time.perf_counter()
    directory = snapshot_download(
        spec["repo"],
        revision=spec["revision"],
        local_files_only=True,
        allow_patterns=["*.json", "*.safetensors", "*.txt", "*.model", "*.jinja"],
    )
    model, tokenizer = load(directory)
    loaded_ms = (time.perf_counter() - started) * 1000
    records, calls = [], []

    def complete(prompt, instruction):
        conversation = [{"role": "system", "content": instruction}, {"role": "user", "content": prompt}]
        rendered = tokenizer.apply_chat_template(
            conversation, tokenize=False, add_generation_prompt=True, enable_thinking=False
        )
        tokens = len(tokenizer.encode(rendered))
        if tokens + 4096 > 32768:
            raise ValueError("Summary context exceeds the local model budget")
        begin = time.perf_counter()
        completion = (completed_text(stream_generate(model, tokenizer, prompt=rendered, max_tokens=4096),
                                     eos_token_ids=tokenizer.eos_token_ids, max_tokens=4096)
                      if args.completion == "eos" else {})
        text = completion.get("text") if completion else generate(model, tokenizer, prompt=rendered, max_tokens=4096, verbose=False)
        calls.append(
            dict(
                prompt_sha256=hashlib.sha256(rendered.encode()).hexdigest(),
                input_tokens=tokens,
                output=text,
                completion=({key: completion[key] for key in ["finish_reason", "generation_tokens"]} if completion else {"finish_reason": "unobserved-legacy-string-api"}),
                wall_ms=(time.perf_counter() - begin) * 1000,
            )
        )
        return text

    for case in protocol["cases"]:
        before = len(calls)
        begin = time.perf_counter()
        record = dict(
            id=case["id"], kind=case["kind"], source_sha256=hashlib.sha256(case["text"].encode()).hexdigest()
        )
        try:
            result = summarize_function(case["text"], complete)
            cited = [r["text"] for r in result["excerpts"]]
            required = case["required_source_phrases"]
            coverage = [
                dict(phrase=phrase, cited=any(phrase in text for text in cited)) for phrase in required
            ]
            record.update(
                status="accepted-for-review",
                result=result,
                required_source_coverage=coverage,
                exact_source_only=all(text in case["text"] for text in cited),
            )
        except (ValueError, RuntimeError) as error:
            record.update(status="rejected-no-summary", error=f"{type(error).__name__}: {error}")
        record.update(calls=calls[before:], wall_ms=(time.perf_counter() - begin) * 1000)
        records.append(record)
        print(case["id"], record["status"], flush=True)
        receipt = dict(
            timestamp=datetime.datetime.now(datetime.UTC).isoformat(),
            status="running" if len(records) < len(protocol["cases"]) else "completed-development-comparison",
            model=spec,
            algorithm=args.algorithm,
            completion_gate=args.completion,
            model_load_ms=loaded_ms,
            protocol_sha256=hashlib.sha256(protocol_path.read_bytes()).hexdigest(),
            implementation_sha256={str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
                                   for path in [implementation, *([ROOT / "backend/ospr_backend/local_completion.py"] if args.completion == "eos" else [])]},
            records=records,
            peak_mlx_bytes=mx.get_peak_memory(),
            boundary=protocol["boundary"],
        )
        args.output.write_text(json.dumps(receipt, indent=2, ensure_ascii=False) + "\n")


if __name__ == "__main__":
    main()
