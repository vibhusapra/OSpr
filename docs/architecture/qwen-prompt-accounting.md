# Qwen redundant frontend work: opt-in research, no latency win

The checked streaming-v0 app/ZIP remains unchanged. Normal operation delegates to
upstream `generate` without installing hooks. Set `OSPR_QWEN_FEATURE_REUSE=1` only
for the experimental prompt-count path; `0` instruments the original loop for
paired comparisons. Other values use the normal unwrapped path.

## What was removed

MLX Audio 0.6.1's Qwen single-chunk loop runs `stream_generate`, which extracts
features and builds its actual prompt. After the first yielded token, the loop
extracts the same audio and rebuilds the prompt solely to count input tokens.
The opt-in adapter captures the real prompt length and reuses that integer for
accounting. Encoding, sampling, language hints, tokenizer decoding, Torch feature
extraction and token budgets remain upstream. No PCM or feature tensors are
retained by the adapter. Zero-token outputs keep the original zero prompt count.

Only the exact supported private chunk implementation is replaced, checked by
its dedented source AST hash. An unknown implementation, unavailable source or
nonzero frontend dither uses the original loop. If a custom stream yields without
building a prompt, accounting also falls back. Mid-stream extractor/randomness
changes retain original accounting. Hooks restore inherited/preexisting methods
on success or error, and nested scopes do not replace an active outer scope.
The serial worker owns the model; this is not a concurrent model-sharing API.

Loaded model views can retain a `generate` method bound to a different object.
The adapter operates on the actual bound owner. A regression test covers this.
The token loop is adapted from MIT-licensed MLX Audio; the attribution and full
license are in NOTICE and `licenses/mlx-audio-MIT.txt`, included by the bundler.

## Frozen protocol and results

`benchmarks/fixtures/qwen-feature-reuse-protocol.json` fixes 35 known cases:
twenty English clips, ten original/−40 dB multilingual clips across five languages,
and five nonspeech controls. Three counterbalanced paired repeats yield 105 pairs
and 210 direct Engine requests. Exact-zero audio can bypass model inference.
Each pair compares text, language, durations, segments and words exactly.

The native CLI runs four fresh worker blocks in baseline/reuse/reuse/baseline
order. Each has one cold call followed by thirty warm calls on the same public
5.215-second Nelly regression clip, using automatic language. Direct cases use
explicit language hints. That produces 60 warm samples per policy and 124 native
payloads. The gate was declared before measuring: native aggregate reuse p50 must
be strictly lower, with p95 at most 5% higher, after output and work checks pass.

| Candidate | Native p50 baseline → candidate | Native p95 baseline → candidate | Gate |
| --- | --- | --- | --- |
| One-entry exact PCM/feature cache (`dbde1e5`) | 139.437 → 139.574 ms | 142.108 → 141.166 ms | Fail |
| Prompt-count reuse (`99d439f`) | 162.507 → 162.800 ms | 172.176 → 171.434 ms | Fail |

Both completed studies preserve all 105 paired payloads and all 124 native
payloads. In each, 96 direct pairs reduce frontend evaluations 2→1; six zero-token
pairs remain at one and three exact-zero pairs remain at zero. Every native
optimized call reduces evaluations 2→1. The diagnostic field
`frontend_cache_hits` counts avoided frontend accounting calls in the new path;
it does not indicate a retained feature cache.

The generic cache hashes PCM and retains one tensor tuple. It was replaced by
the smaller integer-only design, but neither passes the latency gate. Median
changes are +0.098% and +0.180% respectively. **No speedup is established and the
optimization stays off by default.** The two experiments ran at different times;
their absolute milliseconds are not a comparison between candidate designs.

An independent checker reconstructs input PCM hashes and pair order, compares
all payload fields, audits work counters and recomputes native quantiles from
raw responses. It binds the producer and source files to each producing commit;
it does not independently rerun recognition or measure native calls.

Two incomplete attempts are also retained: an initial hook patched a neighboring
model view rather than the bound owner; a later source guard rejected its own
runtime because docstring indentation changed during source normalization.
Both fell back without changing output but failed required work counters. The
producer stopped and did not emit a completed receipt. The attempt index retains
source commits, raw trace hashes and the rejection reasons.

## Limits and next gates

This is an unpaced known-input study on a shared M5 Max, with visible block drift.
It is not a significance test, energy measurement, microphone/UI latency test,
consumer-product comparison or general model ranking. Timing baselines include
adapter counter bookkeeping; the normal default avoids those hooks entirely.
A lower operation count alone does not justify promotion. A future optimization
needs its own predeclared quality/timing protocol, broader duration controls and
stable-system measurements before changing defaults or a checked package.

The earlier TextEdit focus handoff in the existing isolated 9a51603 QA build
also remains unaccepted: its AX field reported
focus while OSpr captured Google Chrome as the target. The take was discarded
before ASR or insertion; normal OSpr was visibly restored at eight sessions and
265 words with identical settings/history hashes. This is separate from these
headless frontend results and requires no renewed permission grants.

A separate local test bundle at source `7cf7ce2` passes the copied-path/foreign-cwd/
hostile-PYTHONPATH replay: six offline engines, six native neural-edge routes,
exact-zero abstention, audio review, notes/speaker attribution/mix/upload routes,
model inventories/progress and MCP tools. All 190 bundled help links resolve,
the MIT license matches its source bytes, and the signature remains valid. This
is an ad-hoc development test bundle, not a new checked distribution or native
GUI acceptance. See `qwen-prompt-portable.json`. Its bundled help predates this
final artifact receipt; the latest source report includes it.
