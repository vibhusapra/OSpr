# Local meeting summaries with source quotes

**Experimental developer-preview feature; semantic acceptance remains open.**
History now has a separate **Local notes → Summarize original with source quotes**
action. It drafts overview, decisions, actions and open questions, with expandable
original quotes for each point and a Markdown copy including source links.
Existing exact-excerpt notes, original/edited text, timing and audio links remain
separate. The action always uses `rawText`, not changes in the text editor.
Selecting the edited transcript as the source and audio-timestamp citation seeking
remain work to do. No task, email, calendar action or insertion is executed.

## Models and local routing

Summaries explicitly use pinned `meeting-quality`:
[`mlx-community/Qwen3.5-9B-4bit`](https://huggingface.co/mlx-community/Qwen3.5-9B-4bit)
at `8b2b98c00a6b4d291155e4890773ca8f769aee53`, Apache 2.0. The two weight
shards are checked against upstream LFS SHA-256 metadata in the retained receipt.
The optional download is about 6 GB; weights remain separate from the app.
MLX LM uses its installed Qwen3.5 implementation, including text-weight
sanitization; no remote implementation code is loaded. This route uses text only.
The app exposes this asset in Models, with cache/download/release controls.
Ordinary refinement and exact-excerpt selection retain the smaller Qwen3 4B.
One optional text model remains resident at a time, alongside the speech worker.

This is a task-specific choice from development measurements, not a universal
model winner. The [parent model card](https://huggingface.co/Qwen/Qwen3.5-9B)
documents non-thinking mode and other sampling settings. This implementation
uses `enable_thinking=False` and MLX LM's greedy sampler for repeatable contract
replay; it does not claim to match the vendor's general sampling recommendations.
Memory, first-use time and quality need broader device and corpus measurements.

The transcript goes only to the local stdio worker. Hub traffic downloads public
weights; it does not upload the transcript. No BYOK credential is requested or
used, and no silent cloud fallback exists.

## Generation and preservation contract

- Every local model call now requires [EOS acknowledgement](local-completion.md)
  before schema/source validation. Valid JSON at a token limit fails without
  publication or format repair. Earlier saved development results predate this
  gate; the new harness defaults to EOS and offers explicit `--completion legacy`.
- The full supplied transcript is split into exact source units, then batches of
  at most about 8,000 source characters. Every batch is read, without a silently
  truncated prefix. Inputs above 100,000 Python characters are rejected. Each
  model call also has a 32,768-token total budget including 4,096 output tokens;
  some inputs within the character limit still require splitting.
- Per-batch paraphrases carry source IDs. A second pass sees every candidate
  with its chunk ordering and reconciles duplicates, corrections and conflicts.
  It now also receives the exact original source excerpts cited by those candidates.
  Material omitted by all drafts is still unavailable to reconciliation; source
  access does not prove the resulting paraphrases. A writing-
  system hint helps retain non-Latin scripts without guessing the language.
- A strict JSON schema rejects unknown/duplicate keys, malformed categories,
  invalid/duplicate source IDs and empty final reconciliation of nonempty notes.
  Prompt style targets are softer than safety ceilings: up to 32 final points,
  1,000 characters per point and 512 distinct source quotes. References and text
  are never silently trimmed merely to satisfy a style target.
- Numeric spellings must occur in the cited units. Limited English weekday,
  month/day and clock-qualifier tripwires reject known changes such as **on June
  5 → by June 5** when that explicit qualifier is present. These checks do not
  prove entailment, preserve every name/polarity/condition, or cover all languages,
  relative dates, novel weekdays or numbers written as words.
- A failed format/source check gets one bounded generation repair using the
  same source input and a stricter instruction, bounded rejected draft and item-
  specific validation feedback. It never bypasses validation.
  Model/load/timeout/cancellation failures are not automatically retried by this
  mechanism. If repair fails, the whole request fails; no partial notes are saved.
- Swift independently checks source-quote membership, source fingerprint,
  category/reference/count bounds, numeric spellings and supported qualifier
  swaps before a result is saved. A source change or deleted record rejects the
  save; selection changes do not redirect it to another record. A response that
  arrives after cancellation is not published. A save already admitted before
  cancellation may complete.

Native summary requests and explicit model-download operations can run for up to
one hour and remain cancellable. Ordinary worker inference deadlines are
unchanged. Download/loading, batch, reconciliation and repair progress are
separate from final completion. The larger download exceeded ten minutes in the
observed HTTP test; the earlier Xet attempt stalled and was intentionally stopped
before switching transport. The product's normal Hub transport behavior still
needs fresh-cache native acceptance.

## Durable data and compatibility

`Transcript.summary` is optional and independent of `notes`. Old records decode
without it. Repository mutations preserve current editor text, retained-audio
policy changes, timing and existing excerpt notes. Summary bytes survive save,
restart, session-only memory snapshots and durable transfer. Legacy JSON migration
preserves all known summary fields and refuses unknown nested fields intact.

Only the first persisted summary upgrades the SQLite writer marker from v2 to
v3, transactionally with its data. Older v2 readers refuse v3 rather than silently
rewriting away the new fields; removing a summary does not downgrade the archive.
A separate helper linked to the retained pre-summary release Core opens a v2
public fixture, refuses its v3 counterpart, and changes neither database's bytes.
This is a synthetic headless compatibility probe, not an installer/native upgrade
or a test against the user's original archive.

## CLI and MCP

```sh
# Local 9B inference; the UTF-8 input file is never edited by this command.
ospr-cli summarize-file /absolute/path/transcript.txt

# Actual Swift child/protocol rejection tests; no weights needed.
python benchmarks/meeting_summary_cli.py --cli .build/debug/ospr-cli \
  --contracts-only --output /tmp/summary-contracts.json

# Include three offline local 9B file-to-worker-to-Swift replays.
python benchmarks/meeting_summary_cli.py --cli .build/debug/ospr-cli \
  --output /tmp/summary-cli.json
```

The optional stdio MCP server now exposes `summarize_text` alongside the existing
three tools. It accepts supplied text only, with no microphone, UI, history,
provider-account or task-execution access. Oversize input returns an MCP tool
error without echoing the supplied text. The SDK redacts ordinary handler error
messages; the tool description states the character limit.

## Development evidence and remaining acceptance

The frozen 14-case protocol includes four reused synthetic sentinels, new
number/negation/correction/ownership/injection/script controls, a multi-chunk late
correction and two reused three-minute AMI reference transcripts. The original
strict-style v1 implementation is archived exactly for reproduction. Its 4B/9B
results retain all responses and failures. Current 4B/9B runs use the same newer
implementation, source inputs and greedy decoding.

These are calibration cases used while developing the prompts and validation,
not a sealed holdout. **Accepted-for-review means schema/source tripwires passed,
not that the paraphrase is correct.** Critical-source coverage counts cited input
phrases, not whether every fact was expressed correctly; a large source unit can
make that score trivially high. Cold load is separated in receipts, but timing
uses a shared active Mac and is not an isolated latency or consumer comparison.

Current 4B produces valid output for 11/14 cases, and selected 9B for 13/14. The
remaining 9B failure repeats an on-June-5 → by-June-5 change and is rejected even
after its one repair attempt. Review of accepted 9B outputs also finds real
limitations: “not approved” becomes “rejected” in the price sentinel; the
Japanese case recasts unapproved pricing as an open question and implies a delay;
and the long case has redundant “no decisions” overview material alongside an
actual decision section. These are not fixed by merely having exact citations.
No summary quality or full meeting parity certificate is claimed.

Local **399 Swift / 279 Python tests** and Ruff pass. The actual CLI passes eight
contracts plus three offline 9B file replays; actual MCP summary/oversize rejection
and the separate old-Core reader fence pass. Process peak MLX allocation in the
development runs is 3.21 GiB for 4B and 6.25 GiB for 9B; it is not RSS or an
end-to-end memory/energy acceptance result. CLI/MCP probes, layout-body renders
and archive-fence receipts are retained with this branch. Frozen source `566c637` [CI 40108225943](https://github.com/vibhusapra/OSpr/actions/runs/40108225943)
passes matching tests, eight summary contracts, 41 provider regressions, app/runtime
and 264 help links. Its separate `dist/meeting-summaries-v0/OSpr.app` passes offline
relocated six-engine/neural/extras, ten cached assets/four MCP tools, eleven exact
bundled summary CLI cases, actual bundled MCP summary/oversize rejection and
provider/archive gates. The ZIP is 396,453,429 bytes with SHA-256
`391dc41bc29c3e28b2f2178393f3529217ff3262fcce9bc1ff58ade5722a1e5b`.
It is Apple Development signed for macOS 26.6.2 arm64, weights separate; the
bundled report is the frozen source snapshot before final receipts.
[Package manifest](../../benchmarks/results/meeting-summary-package.json) ·
[Source validation](../../benchmarks/results/meeting-summary-source-validation.json) ·
[Portable replay](../../benchmarks/results/meeting-summary-portable.json) ·
[Exact bundled CLI](../../benchmarks/results/meeting-summary-bundled-cli.json) ·
[Exact bundled MCP](../../benchmarks/results/meeting-summary-bundled-mcp.json).
Native interaction and semantic/distribution acceptance remain open. Layout renders use the actual SwiftUI content
body outside the native ScrollView; they do not verify disclosure/copy/scroll
interaction. Remaining work includes representative, independently reviewed
meeting summaries, source-language fidelity, cross-chunk scope/reconciliation,
corrected-transcript source selection, editable/reviewed summaries, timestamp navigation, native operation/
cancellation/copy/privacy flows, lower-memory Macs and comparison with equivalent
consumer workflows. The overall original goal remains open.

## Later source-fidelity study

The 14-case results above remain a frozen earlier development snapshot. See
[source-grounded reconciliation and bounded repair](summary-fidelity.md) for the
new 18-case/ten-run study, exact baseline archive, current algorithm, retained
failures, research-only grammar/source encoding and larger model. The earlier
meeting-summary and text-preparation packages do not contain this newer source.
