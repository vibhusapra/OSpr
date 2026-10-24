# Local text model choice and spelling preservation

Settings now offers optional **Local MLX · Qwen3.5 9B 4-bit · experimental**
alongside the existing Qwen3 4B option. Off remains the default. Existing local
preferences retain 4B. Cloud endpoint/model/key fields remain separate and survive
switching local choices. Models exposes the shared 9B asset for refinement and
meeting summaries; no second copy or new model/dependency pin is introduced.

The 9B refinement route requires its weights to be prepared explicitly in Models
or with `download meeting-quality`. Missing weights fail before inference or a
download. The typed `text-model-not-prepared` rejection preserves the warm worker
only for `rewrite`; unrelated failures retain their restart behavior. An actual
isolated-cache Swift replay keeps the same worker PID, resident Parakeet and
identical warm recognition after this rejection. Its private cache contains only
a link to the existing public Parakeet model and is removed after checking.
Already resident 9B can continue if shared cached files are removed externally.
Summary generation keeps its existing explicit download and one-hour deadline.

## Generation, delivery and compatibility

The native request snapshots the chosen model with the recording's other settings.
Worker requests accept only `rewrite-quality` and `meeting-quality`; arbitrary Hub
repositories are rejected. One speech and one optional text model remain resident;
switching text choices evicts the prior text model before loading the next.
Native/CLI receivers require the selected repository, completed finish reason and
valid token count. An older engine ignoring model selection cannot silently
return the smaller model or an unacknowledged draft. The worker's EOS gate remains
mandatory. Failed selected-text edits still do not insert unexecuted instructions.

Settings uses provider tag `local-9b` without adding a settings/history field or
reusing cloud model IDs. Existing string-based settings round-trip the tag. The
older Core provider implementation refuses it before validating an endpoint or
transporting text; a retained pre-change binary probe confirms that behavior.
This is not a native downgrade/installer test. The new app's local privacy label
recognizes both model choices, even when an unused cloud endpoint is saved.

The CLI now shares native Clean-mode preservation behavior. It returns `original`,
`raw_text`, delivered `text`, `rewrite_accepted` and `warning`. Raw text is an
acknowledged completion; it can still be semantically wrong. On a fidelity
tripwire, delivered text is the original. Protocol/completion errors return no
partial stdout. Empty input still bypasses inference. MCP `rewrite_text` adds an
optional `model` parameter and continues returning raw output with the original
for review; it does **not** apply the Swift guard or perform insertion.

```sh
ospr-cli download meeting-quality
ospr-cli rewrite 'Um, ask Zoë, not the other team.' meeting-quality
# Omit the model argument for the existing 4B choice.
```

## Measured development tradeoff

Both pinned models used identical production prompts, budgets and greedy/nonthinking
generation on the existing 36 synthetic refinement cases. Every completed output
and lexical check is retained. These are reused development/challenge cases, not
representative independently graded or held-out quality.

| Check | Qwen3 4B | Qwen3.5 9B |
| --- | ---: | ---: |
| Raw lexical sentinels | 31/36 | 34/36 |
| Native fallback before spelling fix | 6/36 | 2/36 |
| Delivered lexical sentinels before fix | 36/36 | 35/36 |
| Native fallback after spelling fix | 6/36 | 3/36 |
| Delivered lexical sentinels after fix | 36/36 | 36/36 |
| Maximum observed MLX allocation, these short text probes only | 2.64 GiB | 5.29 GiB |

The 9B raw output changes `Zoë` to `Zoe`, which the older native tripwire accepts.
The new guard preserves counts of tokens with non-ASCII Latin spellings, including
repeated names and Turkish dotted I. Canonically equivalent Unicode, case and
smart-apostrophe typography remain allowed. It applies to Clean/email/bullets/code;
deliberate selection edits, translation and custom instructions retain their
different contracts. The regex is cached and ASCII tokens bypass it.

This conservative spelling tripwire can reject legitimate inflection/spelling
changes. It does not identify every name, protect all scripts, detect altered
associations or prove semantics. Both models still execute the literal-tag and
two-speaker passages incorrectly; original-text fallback catches those cases.
Other meaning errors can pass. Fewer fallbacks on this corpus do not establish a
general model winner, and 9B is not promoted automatically. Allocation excludes
ASR, OS/RSS and longer-context needs. Fixed-order shared-Mac timers are diagnostic,
not comparative latency, energy, lower-memory-Mac or consumer-app acceptance.

## Evidence

- [4B raw outputs](../../benchmarks/results/local-model-refinement-4b.json), [9B raw outputs](../../benchmarks/results/local-model-refinement-9b.json)
- [Earlier guard on 9B](../../benchmarks/results/local-model-refinement-9b-guard-before.json), [current 4B](../../benchmarks/results/local-model-refinement-4b-guard.json), [current 9B](../../benchmarks/results/local-model-refinement-9b-guard.json)
- [Actual CLI contracts and inference](../../benchmarks/results/local-model-cli.json), [actual MCP schema/model checks](../../benchmarks/results/local-model-mcp.json)
- [Missing-weight/warm-ASR replay](../../benchmarks/results/local-model-preparation.json), [older provider binary probe](../../benchmarks/results/local-model-old-provider.json)
- Source-rendered Settings section: [light](../assets/local-model-settings-light.png), [dark](../assets/local-model-settings-dark.png), [narrow](../assets/local-model-settings-narrow.png). These are isolated services-disabled renders, not native picker/preparation/Keychain interaction acceptance.

Model selection, settings restart and generated request/acknowledgement boundaries
have source tests. Native dictation/selection/Settings interaction, broader
multilingual fidelity, lower-memory devices and full product ranking remain open.

## Frozen package and CI

Signed runtime `e27b374` passes [package gates](../../benchmarks/results/local-model-package.json):
relocated offline six-engine/neural/extras, actual bundled CLI/MCP model selection,
missing-9B and output-limit warm-ASR retention, summaries/provider regressions,
ZIP CRC/extraction/signatures/executable/source/license checks and 286 frozen help
links. The 396,791,467-byte ZIP has SHA-256
`665d2c17c14d2abf76c5aae3d0be7d50321b9ed15d73373d6a8f03c8191ddd89`.
Apple Development signed macOS 26.6.2 arm64; weights separate; not notarized.
The bundled report predates final receipts.

[Clean-runner CI 40116390475](https://github.com/vibhusapra/OSpr/actions/runs/40116390475)
passes 408 Swift / 330 Python tests, ten local-model/eight summary/41 provider
contracts, app/report/runtime imports and 286 links. Initial CI exposed a race in
the new restart test: history teardown had not released the GUI instance lock.
Test-only `e564819` waits for actual lock reacquisition and model release; runtime
locking is unchanged. Five focused repetitions and the full suite pass. Its product
sources match the package fingerprint. [Bound validation](../../benchmarks/results/local-model-source-validation.json).

Separate fixed-text native checks on the older preserved insertion component
proved TextEdit delivery but reproduced browser AX success without visible changes.
[Native receipt and precise scope](../../benchmarks/results/native-insertion-component.json).
That is not native acceptance of this model-choice candidate.
