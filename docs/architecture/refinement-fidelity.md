# Local refinement fidelity

Ordinary dictation must preserve a spoken question or command as text. The old
local prompt sometimes answered a question, followed a dictated instruction or
explained a file command. A JSON envelope now separates the transcript from the
trusted editing task. This reduces observed failures; it does not make a language
model a lossless editor. Refinement remains optional and off by default.

## Three tasks

- `transcript` applies a configured formatting instruction to the JSON-quoted
  transcript. The prompt asks the model to preserve questions, commands, facts,
  negations, uncertainty, identifiers and numerical forms.
- `edit-selection` applies the deliberate spoken editing request to the supplied
  passage. The native app explicitly chooses this task for Edit selection. It
  must not be mistaken for ordinary dictated text that happens to contain a
  command. This route retains the full editing output budget.
- `source-selection` keeps the meeting-notes ID-selection contract and its
  128-token budget. Displayed excerpts still come from exact source offsets;
  generated prose cannot become an excerpt.

Input types, task names, the 100,000-character text limit and the 16,000-character
instruction limit are checked before model loading. One refiner stays resident;
the model and dependency locks are unchanged. BYOK prompt construction is
unchanged by this local fix.

## Recorded checks

Source `f8ba4a0` uses the pinned Qwen3 4B Instruct 2507 4-bit conversion. The same
Clean-mode instruction, model and 36 synthetic inputs ran through the previous
engine at `3e964bd` and the candidate. Twelve inputs are existing development
cases; 24 fresh challenge cases were frozen after prompt development. The final
source replay repeated all 72 raw outputs exactly.

| Check | Previous prompt | Candidate prompt |
| --- | ---: | ---: |
| Existing lexical sentinels | 10/12 | 11/12 |
| Fresh challenge lexical sentinels | 18/24 | 20/24 |
| Original-text fallbacks using the same current Swift guard | 12/36 | 6/36 |
| Final lexical sentinels after those fallbacks | 36/36 | 36/36 |

These are substring checks, not semantic scores. The previous prompt's path
explanation and refusal to explain a short sentence both passed their lexical
checks. The candidate still dropped content in the delimiter and two-speaker
cases, lost negations in the time/name cases, changed a written-out price and
escaped a Windows path. All six candidate outputs were rejected by the actual
Swift tripwire and replaced by their original input in the replay.

The native guard now recognizes curly apostrophes and additional English negative
contractions. Clean-mode questions cannot lose every question mark, and very short
inputs receive the same expansion limit as longer inputs. Length, word overlap,
negation counts and digit counts remain heuristics. They cannot prove signs,
ordering, associations, multilingual meaning or an absence of invented facts.

Eight synthetic task smokes covered three selection edits, translation, custom
uppercase, code, email and bullets. Two notes smokes checked exact source spans,
including a dictated request to select an invalid ID. All passed their limited
checks. These are engine tests; native selection replacement remains unverified.
All 224 Swift tests, 105 Python tests, lint, the release build and strict signature
verification pass locally. The development app uses ad-hoc signing and its checkout.
Source/docs head `3b7ddb0` also passes macOS 15 CI 40016038194 with the same
224/105 test counts, lint, app/report build and clean-runner standalone runtime.
A separate Apple Development signed portable candidate at that head passed
relocated/offline six-engine inference and the existing notes, speaker, audio,
model-management, CLI review and MCP smokes. Three explicit rewrite examples also
passed through its bundled Swift CLI/worker from a foreign cwd with hostile
PYTHONPATH. These are runtime smokes; full hour-file, upload and release-package
gates have not yet been rerun on that candidate. Its bundled report predates the
portable and CI receipt updates.

- [Complete before/after outputs and native fallback decisions](../../benchmarks/results/refinement-fidelity-v1.json)
- [Task and source-selection outputs](../../benchmarks/results/refinement-task-smoke.json)
- [Build and validation boundary](../../benchmarks/results/refinement-validation.json)
- [Portable runtime checks](../../benchmarks/results/refinement-portable-app-smoke.json)
- [Bundled rewrite CLI checks](../../benchmarks/results/refinement-bundled-cli-smoke.json)

## Reproduction

Save both baseline source files next to one another, then run the offline harness
with the already downloaded pinned weights:

```sh
git show 3e964bd:backend/ospr_backend/engine.py > .local/refinement-baseline-engine.py
git show 3e964bd:backend/ospr_backend/models.lock.json > .local/models.lock.json
HF_HUB_OFFLINE=1 PYTHONPATH=backend .venv/bin/python benchmarks/refinement_eval.py \
  --baseline-engine .local/refinement-baseline-engine.py --baseline-commit 3e964bd \
  --output .local/refinement-new-receipt.json
swift test --filter RefinementGuardTests
```

The harness verifies saved baseline source/lock bytes against the Git revision and
requires the same refiner lock for both variants. It refuses to overwrite a receipt.
The Swift test replays the committed recorded outputs through the real guard.
Sequential shared-Mac timings are diagnostic; they are not a speed comparison.
No representative held-out evaluation, consumer-app ranking or full-product
latency claim follows from these tests. The frozen Soniox preview ZIP predates
this change. Native dictation, selection and full distribution acceptance remain open.
