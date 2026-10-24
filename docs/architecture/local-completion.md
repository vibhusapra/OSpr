# Require local generation completion

Local cleanup, selection editing, source-excerpt selection and meeting summaries
previously used MLX's string-only `generate` API. It returns accumulated text even
at its output budget. Valid JSON or a plausible sentence can therefore reach
later validators without a completion acknowledgement.

The production path now consumes `stream_generate`, using the locked MLX-LM
0.32.2 contract. It requires a final `stop` reason **and** a token in the loaded
tokenizer's EOS IDs, sequential token counts within the existing budget, nonempty
assembled text, and no frames after termination. Final detokenizer flush and
Unicode are retained. Missing/malformed termination, unknown reasons, runtime
errors and length-limited drafts return no text. Generator cleanup runs on early
rejection to leave MLX's wired-memory context.

These checks do not prove semantic fidelity. Existing lexical/source checks and
known summary paraphrase errors remain. Model pins, prompts, greedy/nonthinking
sampling, budgets, deadlines, dependency lock and optional/off defaults are
unchanged. Empty input continues to bypass generation.

## Warm speech after an expected output limit

The later [local model choice](local-model-choice.md) also preserves warm speech
after its typed, pre-inference 9B preparation rejection on `rewrite` only.

A fully consumed, well-formed `length` response at exactly the configured budget
has one narrow IPC classification: `error_kind: text-output-limit`. The shared
Swift client preserves its owned worker only for this code on `rewrite`, `notes`
or `summary`, avoiding eviction of healthy resident speech models. Ordinary
inference errors, missing EOS, malformed frames, unknown codes and this code on
speech/warming actions still restart. Expected audio-preparation rejection keeps
its existing behavior. Generator cleanup failure cannot be recoverable.

No partial generation is included in errors. Existing app handling retains the
original transcript/previous notes; failed selection editing does not insert the
unexecuted instruction. CLI/MCP failures deliver no partial result. There is no
automatic retry, continuation or budget increase.

## Evidence and reproduction

Eight pre-fix mocked draft deliveries across four tasks became rejections.
Permanent tests cover EOS-at-budget success, final flush/Unicode, missing or
wrong EOS, bad counts/types, extra frames, invalid configuration, runtime/cleanup
failure, narrow worker classification and worker restart/residency.

[Actual cached-model controls](../../benchmarks/results/local-completion-real.json)
compare old/new output with the same prompt and budget on pinned Qwen3 4B and
Qwen3.5 9B: all eight completed outputs are identical. Two deliberately constructed
budget sentinels return complete, balanced JSON through the old API and are
rejected by the EOS gate. They demonstrate the defect without estimating its
prevalence or natural-summary quality.

[The shared Swift worker replay](../../benchmarks/results/local-completion-worker.json)
recognizes one public LibriSpeech fixture, exhausts the existing 130-token editing
budget, then observes the same worker PID, resident Parakeet and identical warm
recognition. It does not record/play audio, write history or test native insertion.
It establishes avoided eviction without a comparative latency/energy claim.

```sh
PYTHONPATH=backend HF_HUB_OFFLINE=1 .venv/bin/python benchmarks/local_completion.py --output /tmp/completion.json
HF_HUB_OFFLINE=1 .build/release/ospr-cli _verify-local-completion benchmarks/fixtures/audio/1272-128104-0000.wav
```

The summary development harness defaults to this EOS gate; explicit
`--completion legacy` reproduces earlier string-only experiments. Earlier saved
receipts remain unchanged. Their 11/14 and 13/14 counts are structural/source
acceptance, not semantic success.

Primary implementation checked locally and against pinned upstream
[MLX-LM 0.32.2 generation source](https://github.com/ml-explore/mlx-lm/blob/v0.32.2/mlx_lm/generate.py)
on 2026-10-24. Native microphone-to-insertion, lower-memory Macs, representative
semantic quality, comparative consumer benchmarks and distribution acceptance
remain separate open gates.
