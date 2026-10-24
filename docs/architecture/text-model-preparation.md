# Prepare local text models before dictation

Models now offers **Prepare on Metal** for cached 4B and 9B text weights. It loads
the selected text model, runs a short synthetic production-prompt completion and
discards the output. The app retains the worker afterward. This moves first-use
work before dictation and keeps any already loaded speech model resident. It does
not enable refinement or change the selected provider, model, mode or history.
Off remains the default. Download and preparation are separate actions.

The action is cache-only even while online. The resolver cannot enter its repair
or network-download path; missing weights reject before either resident model is
evicted. An already resident text model can continue after external cache removal.
Only one text model is retained; choosing the other releases the prior text model
before loading. Load failure clears the residency/preparation marker. Other model,
dependency and history/storage pins/schemas are unchanged.

## Readiness and recovery

The preparation marker is set only after the production decoder acknowledges a
completed EOS. The reply carries the selected model/repository, typed cache-only,
primed and already-prepared flags, token count and finite timings. Native/CLI
receivers validate them. A second preparation of the same resident model has
zero generated tokens and zero priming time. Missing/old/wrong-model replies do
not claim readiness. Invalid/non-finite JSON dictionaries are refused before
Foundation serialization can raise an Objective-C exception.

Only typed missing-text-weight and verified output-limit rejections keep the
healthy serial worker and speech readiness. Unexpected runtime/protocol failures
and cancellation clear it. Stale inventory/progress/late completion cannot overwrite
a newer operation. Preparation makes no transcript/history record and returns no
synthetic text. This prepares one short prompt shape; later lengths/tasks and GPU
allocations can still incur work. A marker is the last observed resident state,
not a guarantee against external process termination.

## Frozen-source diagnostic

Source `e74ddf3` uses three alternating-order fresh-worker pairs per model. Every
worker first recognizes the same 5.855-second public speech fixture with Parakeet.
One public synthetic three-sentence rewrite uses the actual native Clean instruction,
completion receiver and Swift fidelity guard. The prepared branch first runs
synthetic preparation. Timers include IPC/receiving; first-rewrite time excludes
preparation. A later speech control requires the same PID, resident Parakeet and
identical warm recognition. Repeated preparation must perform no generation.

| Model | First rewrite without preparation | Preparation beforehand | First rewrite after preparation | Preparation + first rewrite |
| --- | ---: | ---: | ---: | ---: |
| Qwen3 4B | 2.477 s | 2.226 s | 0.252 s | 2.478 s |
| Qwen3.5 9B | 3.035 s | 2.749 s | 0.461 s | 3.210 s |

These are medians of three observations per path, on a shared M5 Max Mac. Paired
raw and delivered text matches in all six pairs. Combined cost remains visible;
there is no claim of less total work, isolated p50/p95, physical microphone latency,
energy/battery improvement, lower-memory-Mac acceptance or consumer ranking.
The earlier working-source diagnostic is preserved separately rather than replaced.

An additional prepared replay of the existing 36 development cases/model returns
all **72 raw outputs identical** to the prior model-choice probe. Raw lexical
sentinels remain 31/36 for 4B and 34/36 for 9B. Actual Swift fallback preserves
36/36 lexical sentinels, with six and three fallbacks. These are reused synthetic
challenges and lexical/heuristic checks; semantic and representative multilingual
quality remain unproven. Existing literal-tag/two-speaker errors and the 9B accent
loss still occur and trigger fallback.

## Commands and acceptance boundaries

```sh
ospr-cli download rewrite-quality
ospr-cli prepare-text rewrite-quality
ospr-cli download meeting-quality
ospr-cli prepare-text meeting-quality
```

Each CLI invocation releases its worker at exit, so `prepare-text` is a diagnostic
for that invocation. Use the app's Models action to retain preparation for later
dictation. Native picker/preparation/recording interaction is not yet accepted.

Source checks pass **418 Swift / 341 Python tests** and Ruff. Eleven actual Swift
CLI admission/acknowledgement cases pass. A disposable cache exposing only existing
public Parakeet weights rejects preparation for both 4B and 9B, with unchanged warm
ASR and PID; no text download occurs and the private cache is removed. AppModel
fake-worker tests cover actual action/acknowledgement, speech readiness, unchanged
settings/history, cancellation/release, wrong replies, missing weights and a stale
inventory query. Source-rendered Models sections in light/dark/390px layouts were
inspected; these are not native interaction evidence.

[Source CI 40121755671](https://github.com/vibhusapra/OSpr/actions/runs/40121755671)
passes matching 418/341 tests, eleven preparation/ten local-choice/eight summary/41
provider contracts, app/report/standalone imports and 296 frozen help links.
[Bound source/CI validation](../../benchmarks/results/text-preparation-source-validation.json).
A new signed standalone artifact and native Models checks are being prepared.
The normal app/data and older candidates remain preserved. The independent
TextEdit foreground-focus question remains pending; no recording/playback or sound
setting is needed for this feature's checks.

## Evidence

- [Frozen timing records](../../benchmarks/results/text-preparation.json), [comparison](../../benchmarks/results/text-preparation-comparison.json), [earlier working-source records](../../benchmarks/results/text-preparation-development.json)
- [4B prepared replay](../../benchmarks/results/text-preparation-refinement-4b.json), [9B prepared replay](../../benchmarks/results/text-preparation-refinement-9b.json)
- [Actual Swift 4B guard](../../benchmarks/results/text-preparation-refinement-4b-guard.json), [9B guard](../../benchmarks/results/text-preparation-refinement-9b-guard.json)
- [CLI contracts](../../benchmarks/results/text-preparation-cli.json), [isolated-cache/warm-ASR proof](../../benchmarks/results/text-preparation-cache.json)
- Source layouts: [light](../assets/text-preparation-models-light.png), [dark](../assets/text-preparation-models-dark.png), [narrow](../assets/text-preparation-models-narrow.png)
