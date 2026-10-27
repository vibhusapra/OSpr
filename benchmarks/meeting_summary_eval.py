"""Local-model development comparison; schema/citation checks are not entailment."""

import argparse
import datetime
import hashlib
from importlib.metadata import version
import json
import subprocess
from pathlib import Path
import time

from ospr_backend.summary import summarize

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True, choices=["qwen3-4b", "qwen3.5-9b", "qwen3.6-35b-a3b"])
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--algorithm", choices=["current", "v1", "pre-fidelity", "pre-status"], default="current")
    parser.add_argument("--protocol", type=Path, default=ROOT / "benchmarks/fixtures/meeting-summary-protocol.json")
    parser.add_argument("--case", action="append", dest="case_ids", default=[])
    parser.add_argument("--decoding", choices=["unconstrained", "xgrammar"], default="unconstrained")
    parser.add_argument("--encoding", choices=["full", "exact-references"], default="full")
    parser.add_argument("--completion", choices=["eos", "legacy"], default="eos",
                        help="Require production EOS acknowledgement; legacy reproduces historical string-only runs.")
    args = parser.parse_args()
    if args.output.exists():
        parser.error("Choose a new receipt path; existing model outputs are preserved.")
    implementation = ROOT / "backend/ospr_backend/summary.py"
    summarize_function = summarize
    if args.algorithm in {"v1", "pre-fidelity", "pre-status"}:
        import importlib.util

        implementation = ROOT / "benchmarks/fixtures" / (
            {"v1": "meeting_summary_v1.py", "pre-fidelity": "meeting_summary_pre_fidelity.py",
             "pre-status": "meeting_summary_pre_status.py"}[args.algorithm]
        )
        module_spec = importlib.util.spec_from_file_location(
            "ospr_backend._meeting_summary_v1", implementation
        )
        module = importlib.util.module_from_spec(module_spec)
        module_spec.loader.exec_module(module)
        summarize_function = module.summarize
    protocol_path = args.protocol.resolve(strict=True)
    protocol = json.loads(protocol_path.read_text())
    unknown = set(args.case_ids) - {row["id"] for row in protocol["cases"]}
    if unknown:
        parser.error("Unknown case IDs: " + ", ".join(sorted(unknown)))
    cases = [row for row in protocol["cases"] if not args.case_ids or row["id"] in args.case_ids]
    spec = next((model for model in protocol["models"] if model["id"] == args.model), None)
    if spec is None:
        parser.error("The selected model is not pinned in this protocol.")
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
    grammar = None
    grammar_start = time.perf_counter()
    if args.decoding == "xgrammar":
        from summary_experiments import GrammarResearch
        configuration = json.loads((Path(directory)/"config.json").read_text())
        vocabulary = configuration.get("text_config", configuration)["vocab_size"]
        grammar = GrammarResearch(tokenizer, vocabulary)
    grammar_init_ms = (time.perf_counter()-grammar_start)*1000
    versions = {name:version(name) for name in ["mlx", "mlx-lm", "transformers"]}
    if grammar:
        versions.update({name:version(name) for name in ["xgrammar", "apache-tvm-ffi"]})
    records, calls = [], []

    def complete(prompt, instruction):
        encoding = None
        if args.encoding == "exact-references":
            from summary_experiments import compact_source
            prompt, instruction, encoding = compact_source(prompt, instruction)
        conversation = [{"role": "system", "content": instruction}, {"role": "user", "content": prompt}]
        rendered = tokenizer.apply_chat_template(
            conversation, tokenize=False, add_generation_prompt=True, enable_thinking=False
        )
        tokens = len(tokenizer.encode(rendered))
        begin = time.perf_counter()
        attempt = dict(prompt_sha256=hashlib.sha256(rendered.encode()).hexdigest(),
                       input_tokens=tokens, output="", encoding=encoding, status="running")
        calls.append(attempt)
        pieces = []

        def observed_stream(processors):
            stream = stream_generate(model, tokenizer, prompt=rendered, max_tokens=4096,
                                     logits_processors=processors)
            try:
                for response in stream:
                    pieces.append(response.text)
                    attempt["observed_finish_reason"] = response.finish_reason
                    attempt["observed_generation_tokens"] = response.generation_tokens
                    yield response
            finally:
                stream.close()

        try:
            if tokens + 4096 > 32768:
                raise ValueError("Summary context exceeds the local model budget")
            compile_start = time.perf_counter()
            processors = [grammar.processor(prompt)] if grammar else []
            attempt["grammar_prepare_ms"] = (time.perf_counter()-compile_start)*1000
            completion = (completed_text(observed_stream(processors),
                                         eos_token_ids=tokenizer.eos_token_ids, max_tokens=4096)
                          if args.completion == "eos" else {})
            text = completion.get("text") if completion else generate(
                model, tokenizer, prompt=rendered, max_tokens=4096, verbose=False,
                logits_processors=processors,
            )
            attempt.update(status="completed", output=text, completion=(
                {key: completion[key] for key in ["finish_reason", "generation_tokens"]}
                if completion else {"finish_reason": "unobserved-legacy-string-api"}))
            return text
        except Exception as error:
            attempt.update(status="failed", output="".join(pieces), error=f"{type(error).__name__}: {error}")
            raise
        finally:
            attempt["wall_ms"] = (time.perf_counter()-begin)*1000

    for case in cases:
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
            status="running" if len(records) < len(cases) else "completed-development-comparison",
            model=spec,
            algorithm=args.algorithm,
            decoding=args.decoding,
            encoding=args.encoding,
            source_commit=subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
            tracked_changes=bool(subprocess.check_output(["git", "diff", "--name-only"], cwd=ROOT, text=True).strip()),
            selected_case_ids=[row["id"] for row in cases],
            completion_gate=args.completion,
            model_load_ms=loaded_ms,
            grammar_init_ms=grammar_init_ms,
            package_versions=versions,
            mlx_default_device=str(mx.default_device()),
            protocol_sha256=hashlib.sha256(protocol_path.read_bytes()).hexdigest(),
            implementation_sha256={str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
                                   for path in [implementation, Path(__file__).resolve(),
                                                ROOT / "benchmarks/summary_experiments.py",
                                                *([ROOT / "backend/ospr_backend/local_completion.py"] if args.completion == "eos" else [])]},
            records=records,
            peak_mlx_bytes=mx.get_peak_memory(),
            boundary=protocol["boundary"],
        )
        args.output.write_text(json.dumps(receipt, indent=2, ensure_ascii=False) + "\n")


if __name__ == "__main__":
    main()
