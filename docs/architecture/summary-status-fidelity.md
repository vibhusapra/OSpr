# Full-meeting summary controls and citation repair

**The status prompt is not promoted.** It improves some short cases and makes
9B output structurally admissible on two full meetings, but loses a material
prohibition and still produces contradictory or incomplete meeting notes. A
passing schema/citation check is not a semantic quality score.

The production change supplies item-specific citation failures to the existing
bounded local repair: missing, duplicate, non-integer, unavailable, wrongly typed
or excessive citations, and invalid note text. Previously most of these produced
only a generic error. Four controlled cases fail before the change and pass
afterward. The repair can explain that an empty-section placeholder should be
omitted; **code does not silently remove model items**. All existing validation,
the one-repair limit, numeric/date checks, EOS, model choices, generation budgets,
storage and UI remain unchanged. Public error strings remain content-free.

This feedback does **not** establish an availability or semantic improvement in
the real-model cohort: baseline and feedback variants have identical admission
status and admitted results in all forty paired cases. It improves the repair
contract, while the model-quality problem remains open.

## Cohort frozen before candidate inference

The twenty-case development cohort contains the existing eighteen status,
negation, ownership, multilingual and long-context cases plus **complete AMI
scenario meetings ES2004c and ES2004d**. These are role-played design-team meetings,
not uncontrolled business meetings. Together they last 4,484 seconds, about
75 minutes, and share one team; they are correlated and unrepresentative.

The pinned manual-annotation archive is SHA-verified. The preparer requires every
annotated `w` token, **including punctuation**, exactly once: 7,850 / 7,337 tokens.
It serializes source segments by start time then speaker, joins exact word tokens
with spaces and adds annotated speaker roles. The two inputs contain 47,350 /
46,084 characters. This differs from actual ASR text, automatic speaker labels,
punctuation and overlapping-speaker order. No audio or ASR is evaluated here.

Human abstractive summaries are separate review metadata and never enter the
model prompt. They may omit true transcript details; disputed claims require the
full transcript. A review rubric and candidate hypothesis were saved before
candidate inference. The candidate also explicitly addresses baseline placeholder
and numerical-spelling failures, so this is development, not a sealed holdout.

AMI Consortium / University of Edinburgh, J. Carletta et al. (2006), manual
annotations v1.6.2. The archive's `LICENCE.txt` releases the corpus and annotations
under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). Source:
[AMI Corpus](https://groups.inf.ed.ac.uk/ami/corpus/) and
[official overview](https://groups.inf.ed.ac.uk/ami/corpus/overview.shtml).
The fixture records mirror revision, archive/member hashes and serialization.

## All six runs retained

Each variant uses the same pinned 4B or 9B model, greedy non-thinking decoding,
32,768 total / 4,096 output-token budgets, EOS gate and full-input chunking. The
status candidate adds explicit section/status rules to both drafting and
reconciliation; it is a research fixture. No grammar dependency or new model is
added to the app.

| Variant | Admitted for review | Refused | Generation calls | Case-wall sum | Peak MLX |
|---|---:|---:|---:|---:|---:|
| baseline 9B | 17/20 | 3 | 42 | 143.1 s | 6,502 MiB |
| citation feedback 9B | 17/20 | 3 | 42 | 149.6 s | 6,501 MiB |
| status candidate 9B | 20/20 | 0 | 49 | 364.5 s | 6,717 MiB |
| baseline 4B | 17/20 | 3 | 43 | 139.7 s | 4,552 MiB |
| citation feedback 4B | 17/20 | 3 | 43 | 131.4 s | 4,552 MiB |
| status candidate 4B | 15/20 | 5 | 32 | 80.0 s | 3,589 MiB |

There are **120 case attempts and 251 generation calls**, including every repair
and failure. Refused cases can stop before later chunks or reconciliation. These
case-wall totals therefore compare different amounts of completed work; the
apparently fast 4B candidate is not a speed improvement. Initial model load is
separate. Runs were serial on a shared active M5 Max 128GB, reporting MLX GPU;
allocation is not RSS, total system memory or an acceptable minimum-device size.
There is no isolated latency, p95, energy or consumer-app ranking claim.

## What the outputs actually show

- Both baseline models and both feedback variants refuse both complete meetings.
  9B repeats an uncited `None` placeholder in one; in the other it converts spoken
  number words to digits absent from the cited text. Clearer feedback alone does
  not resolve these failures.
- The 9B status candidate fixes the conditional-owner refusal and improves some
  French/Spanish and declined-owner distinctions. It restores Rosa's late report
  in the near-limit case.
- The same candidate **drops the Saturday deployment prohibition**, omits an
  explicit Japanese not-rejected qualifier and still puts uncommitted Chinese
  assistance/unassigned status in Actions. Its full ES2004c notes contain both a
  beeper-rejected decision and a whether-beeper-was-rejected question. Its 32-point
  ES2004d notes do not retain the head-office recommendation about voice
  recognition as an action and mix earlier discussion with current choices.
- The 4B candidate admits the earlier rejection case but adds three refusals. It
  omits Ada's quote-removal task and still strengthens Spanish uncertainty into
  no Thursday/Friday publication. Its lower admission count and early failures
  must not be disguised as reduced latency or memory use.

The item-level review is by the Codex agent: it is authored development review,
not blind, independent, human or fluent-language acceptance. No aggregate semantic
percentage is claimed. Original outputs, errors and citations remain inspectable.

## Verification and reproduction

All 397 Python tests and Ruff pass. This includes five corpus-preparation controls,
four repair regressions and seven retained-output mutation controls. The actual
Swift file CLI passes eight protocol/rejection cases plus three offline 9B
inferences, preserving inputs and checking source quotes. These are contract and
integration checks, not semantic or native-app acceptance.

The verifier replays every captured completion through the exact frozen variant
and source-unit implementation, reproduces the result/refusal and consumes every
call. Missing, duplicated, reordered or altered evidence is rejected. Local
`--verify-prompts` additionally loads only cached pinned tokenizers and reproduces
all rendered prompt hashes and token counts. CI uses the model-free stored replay.
Neither mode independently attests that model execution happened or proves
entailment, completeness or fair timing.

```sh
# Cached annotation archive; output must be new.
.venv/bin/python benchmarks/prepare_summary_status.py --output /tmp/new-cohort.json

# One complete model/variant run; previous output is never replaced.
HF_HUB_OFFLINE=1 PYTHONPATH=backend .venv/bin/python benchmarks/meeting_summary_eval.py \
  --model qwen3.5-9b --algorithm pre-status \
  --protocol benchmarks/fixtures/summary-status-protocol.json \
  --output /tmp/new-baseline.json

# Stored replay needs no models; optional prompt mode needs cached tokenizers.
.venv/bin/python benchmarks/verify_summary_status.py
HF_HUB_OFFLINE=1 .venv/bin/python benchmarks/verify_summary_status.py --verify-prompts
```

Use `--algorithm current` for production citation feedback or `status-candidate`
for the withheld prompt. The latter's 20/20 structural count must not be described
as twenty correct summaries. The first local prompt-replay setup expected an
irrelevant missing `.gitattributes` cache entry; restricting selection to required
tokenizer files resolved it without downloading anything. The failed log remains.

[Run bindings and frozen implementations](../../benchmarks/fixtures/summary-status-study.json) ·
[Cohort and separate human references](../../benchmarks/fixtures/summary-status-protocol.json) ·
[All-case review and decision](../../benchmarks/results/summary-status-review.json) ·
[Exact prompt/output replay](../../benchmarks/results/summary-status-replay.json) ·
[Source and red/green validation](../../benchmarks/results/summary-status-source-validation.json) ·
[Actual CLI controls](../../benchmarks/results/summary-status-cli.json).

Frozen replay sources: [baseline](../../benchmarks/fixtures/meeting_summary_pre_status.py),
[citation feedback](../../benchmarks/fixtures/meeting_summary_citation_diagnostics.py),
[withheld candidate](../../benchmarks/fixtures/meeting_summary_status_candidate.py),
and [source units](../../benchmarks/fixtures/summary_status_notes.py). These public
fixtures are also retained as readable source in newly built standalone help.

## Remaining product work

Semantic quality remains an open release gate. The next candidate needs to retain
material prohibitions, final versus proposed choices, ownership/conditions and
late commitments across full meetings. A stronger model or different planning /
verification algorithm should be compared on this frozen cohort and additional
independent meetings, with correction effort and fluent-language review. Smaller
or structurally valid output is not the requested outcome.

Native microphone/insertion/provider-dialog/device/VoiceOver checks, representative
consumer/energy/latency evaluation and production distribution remain separate.
The normal app/profile and older qualified standalone ZIP are preserved; this
source change is not a new standalone release. Full parity and a top-three ranking
remain unproven.
