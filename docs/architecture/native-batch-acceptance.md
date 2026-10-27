# Native file-batch and filename acceptance

On October 27, two isolated Apple Development signed candidates exercised the
real native app with manifest-bound public speech. No microphone, playback,
insertion, new permission grant or real provider account was used. The normal
app was restored afterward; its six baseline app/profile/owned-target hashes
remain unchanged. This is scoped acceptance, not general dictation readiness.

## Native observations and independent stored checks

| Native action | Observed result | Independent evidence |
| --- | --- | --- |
| Launch a saved three-file batch | Two complete files, one failed file; explicit Resume button, no automatic completion | Fresh AppModel preparation with actual bundled Parakeet; two committed records and stable planned IDs |
| Change current model/language | Current settings become Whisper Small/French; saved batch still advertises Parakeet/Verbatim | Settings file checked after quit; completed repair record uses Parakeet and matches original English/raw text |
| Resume the repaired source | Explicit click completes 3/3; prior completed files remain available | All three planned IDs preserved; earlier canonical payload hashes unchanged; zero audio references |
| Open the repaired transcript | History selects `Resume Repair.wav` with its Parakeet transcript | Correct planned repair ID and source metadata preserved |
| Search `repair.wav` | Exactly one row remains although that filename is absent from spoken text | Filtered native JSON export contains precisely that record and query; source/model/raw text preserved |
| Export all search matches as JSON | One exported transcript | Files mode 0600, folder mode 0700, no audio; record/index hashes retained |
| Quit and relaunch completed batch | Saved 3/3, no Resume button | A separate process verifies three records, unchanged IDs/payloads and no retry |
| Dismiss and restart | Batch card stays absent; three transcripts remain | Journal absent after restart; all three canonical payload hashes unchanged |
| Import two owned hour files, then Cancel | First file visibly Processing and second Queued; both become retryable cancellations | After quit/restart both jobs remain cancelled, no new transcript/audio, prior three records intact, both source copies unchanged |

The native UI was operated through Cua. Headless helpers prepare and verify
controlled profiles; they explicitly report `native_interaction_proven: false`
and cannot press buttons or establish UI acceptance themselves. The combined
receipt keeps those stored-state checks separate from native observations.

## Defects found and corrected

The completed-batch restart still said “resume when you choose,” despite having
no unfinished work or Resume button. Dismiss also left that obsolete header.
Two lifecycle assertions reproduce these failures within the existing twelve
import-workflow cases. After the fix, all twelve pass and the full optimized
suite passes **507 tests**, with Ruff passing. No inference deadline, model,
provider, queue identity, History or audio-retention policy was changed.

Startup now shows a resume cue only when retryable work remains; otherwise it
shows the completed count. Dismiss immediately shows “Import batch dismissed.”
Settings now explains that disabling retention also affects the current take,
and re-enabling applies only to newly started takes. The caption describes the
existing revocation behavior rather than changing it.

A fresh native profile on clean source
`fa2c63ca1cb66e71867121a8e157cbab90798607` repeats Resume, completed restart and
Dismiss. Its actual window shows “Saved import batch · 3/3 transcripts,” then
“Import batch dismissed.” Native Settings exposes the corrected current-take
caption. Separate stored checks again preserve all records and payloads.

## Provenance and reproduction boundary

The first native candidate uses the frozen reliability-preview c906 application
and engine. The second overlays clean fa2 application/CLI/guardian binaries and
build metadata on those unchanged bundled engine/resources, with an isolated
Info data-directory override and a fresh signature. These are QA candidates;
the preserved, independently qualified distribution ZIP still has its original
c906 bytes and older header/caption text. No archive was silently modified.

`benchmarks/native_batch_acceptance.py --stage prepare --app /absolute/selected.app
--output /absolute/new-private-root` binds the app/backend/input/probe bytes,
freshly builds a temporary XCTest probe, prepares two real completed results plus
one deliberate malformed-input failure, then repairs only that owned source.
Point a separately signed QA app's `OSprDataDirectory` Info key to the printed
profile. Launch it normally and perform the native actions; close it before
running `verify-resumed`, `verify-dismissed` or `verify-cancelled` against the
same root. Those stages verify storage only. A changed app, runner, Swift probe
or compiled test executable is refused; existing result receipts are not replaced.
Three deliberately mismatched protocol controls stop before running a probe or
creating a profile. CLI help and optional Swift typechecking are included in CI;
CI does not claim to exercise the user's native UI or cached speech models.

The native controls freeze the original producer bytes. Later preflight checks
strengthen future mismatch refusal; their separate negative controls do not
rewrite or relabel either native run. Protocols and full logs remain private;
published receipts contain public-fixture metadata, counts, IDs and hashes.

## Remaining gates

The short speech clip is reused, and the cancellation files repeat public speech.
This is not representative recognition quality, a natural meeting, latency,
energy or product-ranking evidence. Drag/drop, provider-reconfirmation UI,
VoiceOver, moved/permission-lost/volume-failure cases and large native queues
remain open. Physical microphone/Fn/PTT/device/acoustic and current cross-app
insertion/clipboard acceptance remain separate, as do clean-Mac/older-OS,
Developer ID/notarization and updater qualification. No full-parity/top-three claim.

[Original native run](../../benchmarks/results/native-batch-acceptance-baseline.json) ·
[Corrected native run](../../benchmarks/results/native-batch-acceptance-updated.json) ·
[Provenance negative controls](../../benchmarks/results/native-batch-acceptance-preflight.json) ·
[Saved batch](../assets/native-batch-saved.png) · [Resumed batch](../assets/native-batch-resumed.png) ·
[Filename search](../assets/native-filename-search.png) · [Cancelled jobs](../assets/native-batch-cancelled.png) ·
[Corrected completed status](../assets/native-completed-status.png) · [Corrected Dismiss status](../assets/native-dismissed-status.png).
