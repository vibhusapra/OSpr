# Interleaved artifact timing control

The workflow preview's repeated-hour requests took substantially longer than the
earlier preview session while producing identical recognized text and WER.
Five recognizer modules, dependency inventories and the long-file harness match.
Those different shared-Mac sessions cannot identify a causal code regression.
This follow-up freezes an interleaved comparison before inference.

## Frozen protocol

[Protocol](../../benchmarks/fixtures/artifact-latency-protocol.json) binds both
preserved signed artifacts by clean build metadata, app/CLI hashes and dependency
inventory hashes. A is the earlier v0-review artifact, B the workflow preview.
Both remain unmodified. It also pins input bytes, references, scorer/lock/runner
hashes, case order and timeout. The inputs are the public Quilter utterance and
the existing repeated-hour LibriSpeech fixture. Attribution and construction are
in [the source manifest](../../benchmarks/fixtures/long-session.json).

| Group | Cold model | Artifact order |
| --- | --- | --- |
| Short utterance | Parakeet v3 | A B B A |
| Short utterance | Qwen3 ASR | B A A B |
| Repeated hour | Parakeet v3 | B A A B |
| Repeated hour | Qwen3 ASR | A B B A |

These are sixteen new CLI processes, two observations per artifact/group. Model
objects are cold; filesystem, Hub and driver/JIT caches are not cleared. A tiny
Metal arithmetic preflight runs in each bundled interpreter before measurement;
it does not load a speech model. Cached weights only; networking is offline.

The command is the same default `transcribe` route in both signed CLIs, with no
language/trim override. The outer timeout stays 650 seconds, matching the prior
long-file harness. Production worker deadlines are unchanged. Raw terminal
attempts include failures/timeouts/invalid responses; they are never silently
removed to improve latency statistics. Successful latency summaries include their
attempt and failure denominator. Changed or empty recognition is scored and
retained, not excluded as a timing outlier.

## Measurements and limits

Every request records wall, backend load/decode/total times, raw speech response,
WER, preserved source hash and post-run signature. Wall time includes process
launch, polling/scheduling and JSON output. Backend timing is an observation,
not an independently calibrated GPU timer. Every result remains tied to the
frozen protocol/runner and exact CLI bytes. Terminal case receipts cannot be
overwritten. Interrupted private stdout/stderr attempts remain retained.

A one-second observer records OS load averages, aggregate `ps` CPU percentages
with the owned CLI/worker descendants separated, and three driver-reported GPU
utilization fields. Neither process names/PIDs nor arbitrary registry properties
are published. GPU utilization includes the owned inference; it does not measure
background GPU load independently. Missing observations are explicitly marked,
not treated as zero. The observer itself adds overhead equally to both routes.

The Mac remains in ordinary use. No power/thermal mode, app priority, background
program, system permission or normal OSpr preference is changed. The private
normal-file baseline is checked before/after requests; only its unchanged flag
is published. Unexpected changes stop further requests without overwriting or
restoring the user's files.

This small counterbalanced development control can expose a reproducible artifact
or order-dependent effect. It is not a statistically powered speed comparison,
energy measurement, physical microphone/endpoint/insertion test or new accuracy
holdout. It cannot certify isolated background GPU access or causality by itself.
Report every case and the observed spread before proposing a production change.

## Observed results, 2026-10-25

All sixteen requests completed, with zero command failures. Within each of the
four model/input groups, all four exact recognized texts and WER values match.
The independent retained-data audit verifies individual files, full case count,
chronology, hashes, WER and failure denominators. Eight ingestion controls check
missing/relabelled/changed evidence and retain a synthetic reported timeout.

| Group | Earlier A: median [range], seconds | Workflow B: median [range], seconds |
| --- | --- | --- |
| short-parakeet | 1.69 [1.26, 2.12] | 1.45 [1.42, 1.48] |
| short-qwen | 11.36 [9.36, 13.37] | 8.97 [8.70, 9.24] |
| hour-parakeet | 153.89 [142.46, 165.32] | 127.70 [49.05, 206.36] |
| hour-qwen | 470.26 [404.50, 536.01] | 279.13 [259.18, 299.07] |

There are only two observations per artifact/group. B has a lower observed median
in each group, reversing the direction suggested by the earlier unmatched
historical sessions. This does not establish a speed win or equivalence. B's
Parakeet hour requests themselves span 49–206 seconds; A's Qwen hour requests
span 404–536 seconds. The earlier slow behavior is not uniquely tied to B.
Causality remains unresolved, and neither artifact is accepted against a latency
SLA by this experiment. Do not discard slow requests, pick only one pair or
compare these observer-instrumented times directly with the historical harness.

Five selected Python/MLX runtime binaries have identical bytes after removing
signatures from temporary copies. Original files and signatures are unchanged.
This comparison covers those five files only; it is not a claim that every
runtime dependency, driver/JIT state or model weight was revalidated here.
A single post-hoc system read reported thermal state 0 and low-power mode false;
it does not provide per-request thermal coverage or exclude thermal effects.

Both earlier ZIP hashes, all six owned normal/test baseline files and original
app signatures remain unchanged. No native UI, microphone, playback or provider was operated by the experiment;
no priority/power setting or existing background program was reconfigured.
The observer, ordinary desktop work, documentation/lint/help commands and managed
Git worktree preparation were concurrent. This task explicitly launched no local
build/test or parallel speech inference during the timed sequence. These
conditions do not isolate background workload and can bias such a small sample.

[All attempts and observations](../../benchmarks/results/artifact-latency-control.json) ·
[Individual immutable cases](../../benchmarks/results/artifact-latency-control/short-parakeet-1.json) ·
[Independent integrity audit](../../benchmarks/results/artifact-latency-control-validation.json) ·
[Selected unsigned runtime payloads](../../benchmarks/results/artifact-latency-runtime-payloads.json) ·
[Machine/baseline/thermal context](../../benchmarks/results/artifact-latency-context.json).

The source/runner protocol remains byte-identical to pre-inference commit
`e3e9cf831db7982a84da6fa28b82432bc0e498ac`. This is checked locally using
`--frozen-commit`; CI can verify stored evidence without model weights or old
application bundles.

## Reproduce

Use the preserved exact artifacts and cached weights named in the protocol.
Provide a private SHA256 mapping of owned normal files; never publish its paths
or contents. Select a fresh result path if a terminal aggregate already exists.

```sh
.venv/bin/python benchmarks/artifact_latency.py \
  --normal-baseline /absolute/private/normal-before.json
.venv/bin/python benchmarks/artifact_latency.py \
  --verify benchmarks/results/artifact-latency-control.json
```

`--only` resumes named remaining cases after diagnosing an interrupted invocation.
First confirm the prior process/child is terminal; an observation timeout is not
proof of termination. A completed case cannot be rerun into the same receipt.
Retain prior attempts. Any runner/protocol change needs a new frozen experiment;
results from different hashes cannot be combined.

For the additional audits:

```sh
.venv/bin/python benchmarks/verify_artifact_latency.py \
  --frozen-commit e3e9cf831db7982a84da6fa28b82432bc0e498ac
.venv/bin/python benchmarks/runtime_payloads.py \
  --a "dist/v0 review/OSpr.app" --b "dist/workflow preview/OSpr.app" \
  --output /absolute/fresh-runtime-observations.json
```

The latter copies only the five named files into a temporary directory, removes
signatures from copies and hashes them; original artifact bytes/signatures are
checked before and afterward. Never remove a signature from either original.
