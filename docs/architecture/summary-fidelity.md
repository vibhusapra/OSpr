# Source-grounded summary reconciliation and bounded repair

Experimental developer preview. This change improves what the local summary model sees when reconciling or repairing notes; it does not establish semantic acceptance or full meeting parity.

The production candidate now gives reconciliation the original exact source excerpts cited by the chunk drafts. Earlier reconciliation saw only paraphrases and could amplify their mistakes. It includes every cited source ID once, in source order; material omitted by all drafts is still unavailable to this pass. New instructions distinguish pending from rejected, prohibition from postponement, and stated status from invented questions.

One format/source repair remains the limit. Its local prompt now includes the rejected draft (at most 12,000 characters), content-free validation reason and at most 4,000 serialized characters of item-specific checks. The original transcript/evidence stays present. Checks identify invalid sections, uncited numeric spellings and changed English date qualifiers. Public worker errors keep the existing content-free strings. Model/runtime/context/EOS failures remain outside this format-repair loop. No transcript is uploaded, no task executes and failed requests preserve previous notes/transcript.

The repair and source-evidence changes are production source changes in this branch. XGrammar, source encoding and the 35B model are research-only. The existing application model/dependency locks, default choices, generation budgets, EOS gate, storage and native UI remain unchanged. The previously packaged text-preparation ZIP predates these summary changes; it must not be represented as this branch's executable.

## New development controls

The previous 14-case protocol and its raw failures remain unchanged. A separate 18-case public synthetic development protocol includes explicit rejection/pending/revocation, conditional or declined ownership, prohibited dates, dissent, project scope, correction, quoted instructions, six source-language controls and two long repetitive transcripts. The longest has 91,925 characters. English reference expectations are retained for review and never fed to the model. These authored controls are not a sealed holdout or independent semantic evaluation. Their empty required_source_phrases fields do not measure completeness.

All comparisons use pinned local MLX models, fixed greedy non-thinking decoding and the existing 32,768 total / 4,096 output token limits. EOS admission and production validation remain active. Every response and failure is saved, including context/output-limit attempts. Runs are serial with one fresh model per variant, but this is a shared active M5 Max 128GB Mac. The table's summed case wall time includes repair/reconciliation and grammar compilation; initial model load and tokenizer/grammar initialization are separate in receipts. This is not isolated latency, energy, p95 or a consumer-app ranking.

| Variant | Schema/source admitted | Case-wall sum | Peak MLX | Input tokens incl. repairs |
|---|---:|---:|---:|---:|
| baseline-4b | 17 / 18 | 173.2 s | 3.23 GiB | 53,909 |
| candidate-4b | 17 / 18 | 129.8 s | 4.45 GiB | 64,843 |
| compact-4b | 17 / 18 | 102.6 s | 3.59 GiB | 44,521 |
| baseline-9b | 16 / 18 | 144.8 s | 6.25 GiB | 46,296 |
| candidate-9b | 17 / 18 | 155.6 s | 6.25 GiB | 48,358 |
| grammar-9b | 18 / 18 | 211.3 s | 6.25 GiB | 47,650 |
| compact-9b | 18 / 18 | 122.1 s | 6.25 GiB | 36,347 |
| baseline-35b | 18 / 18 | 112.5 s | 19.98 GiB | 46,118 |
| candidate-35b | 17 / 18 | 106.0 s | 19.98 GiB | 50,603 |
| compact-35b | 17 / 18 | 64.5 s | 19.90 GiB | 36,924 |

## Research experiments and promotion decision

**Grammar:** isolated XGrammar 0.2.8 / apache-tvm-ffi 0.1.15.post0, direct Metal token-mask kernel and a new strict matcher each generation. A cached structural JSON schema constrains categories, fields and broad bounds. It does not constrain source-ID membership, entailment, completeness or all narrower prompt targets; production validation still runs. It improves structural admission in the observed 9B controls while adding preparation and decoding cost. The 9B grammar-only control is retained. The upstream packaged MLX adapter cannot import its referenced kernel in this version; the research adapter directly calls the available official Metal kernel. No application dependency was added.

**Exact-text references:** only repeated, byte-identical source texts are aliased to an earlier source ID within the same chunk. Every original ID, order and unique text is retained; Unicode spellings are not normalized. The producer verifies an exact round trip before inference and only encodes when serialized prompt plus instruction becomes smaller. Two hundred deterministic layouts and malformed/forward/cyclic/Unicode controls pass. Models still have to understand this representation; mathematical losslessness does not guarantee semantic fidelity. Repair and reconciliation remain bounded. The 9B paired grammar/full versus grammar/encoded runs isolate this representation on these inputs; 4B/35B compact variants combine two changes and cannot identify each contribution.

**Research model:** pinned `mlx-community/Qwen3.6-35B-A3B-4bit` at `38740b847e4cb78f352aba30aa41c76e08e6eb46`. All 16 selected files (20,429,167,693 bytes) match upstream size and LFS SHA-256 or Git blob SHA-1 metadata. No remote Python code downloaded. Built-in MLX-LM architecture support loads it locally. Apache 2.0 model cards, a large-memory research candidate; not an app model option or new default. This fixed greedy control does not claim to match Qwen's recommended stochastic non-thinking configuration or define its quality ceiling.

Neither grammar, encoding nor 35B is promoted into the application here. Further adversarial grammar/EOS/Unicode/state testing, representative independently reviewed meetings, less repetitive long inputs, sampling ablations, small-memory devices, native cancellation/privacy and matched end-to-end measurements remain necessary.

## Review observations, not a quality score

Source-quote membership and schema acceptance cannot establish correctness. Retained observations include:

- Current unconstrained 9B still rejects the English conditional-owner control after its one repair. Grammar makes that response structurally admissible, but also produces status-as-decision/question classifications and labels tentative Mira/Li Ming help as actions.
- Current 4B preserves the legal condition better than its baseline, yet Spanish omits Lucía/Thursday and changes an undecided Friday into a stronger no-publication assertion. All three 4B variants reject the explicit-rejection control on numeric-source validation.
- Full-source 9B (baseline, current and grammar-only) omits Rosa's late reporting commitment in the near-limit control even though every batch was processed. Grammar plus exact references retains it in this one replay. This is a coverage improvement on an authored repetitive fixture, not a general solution to long-context omission.
- In the long project correction, current 4B and compact 4B omit Maple's actual Thursday approval. Smaller or faster output is not proof of a better summary.
- The larger model also has omissions; its baseline French response drops explicit not-rejected status and its quoted-instruction control omits the plans' unapproved status. Larger weights do not remove the need for review.

## Reproduction and evidence

Install the regular frozen application environment first. Optional grammar wheels must be installed into an isolated research path from `benchmarks/summary-research-requirements.txt`, then included in PYTHONPATH; they are deliberately absent from the application lock. Example:

```sh
HF_HUB_OFFLINE=1 PYTHONPATH=backend:/absolute/research/grammar-python \
  .venv/bin/python benchmarks/meeting_summary_eval.py \
  --protocol benchmarks/fixtures/summary-fidelity-protocol.json \
  --model qwen3.5-9b --algorithm current --decoding xgrammar \
  --encoding exact-references --output /tmp/new-summary-run.json
```

The output path must be new. Use `--algorithm pre-fidelity --decoding unconstrained --encoding full` for the exact archived baseline. Each result binds model revision, implementation/producer/helper hashes, source commit/dirty state, protocol/input hashes, raw calls, completion status, grammar cost, exact encoding checks and MLX allocation. Running only selected `--case` IDs is diagnostic, not the complete comparison.

[Study and raw-run bindings](../../benchmarks/results/summary-fidelity-study.json) · [New protocol](../../benchmarks/fixtures/summary-fidelity-protocol.json) · [Model download integrity](../../benchmarks/results/summary-fidelity-model-candidate.json). Official sources: [Qwen model](https://huggingface.co/Qwen/Qwen3.6-35B-A3B), [pinned MLX conversion](https://huggingface.co/mlx-community/Qwen3.6-35B-A3B-4bit/tree/38740b847e4cb78f352aba30aa41c76e08e6eb46), [XGrammar](https://github.com/mlc-ai/xgrammar), [MLX LM](https://github.com/ml-explore/mlx-lm).

The current unconstrained 35B and its compact/grammar variant also reject the revocation control: the model writes inline `(0, 1)` / `(2)` citation numbers in prose and repeats them on repair. The numeric guard refuses these extra spellings. Its baseline passes that control. This is an availability regression, retained rather than silently deleting generated numbers. Model selection must weigh this alongside the better long-input coverage and ~20 GiB allocation.
