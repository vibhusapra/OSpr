# Durable file-import recovery

The latest file batch now survives app restart when History saving is enabled.
Studio restores the list and its original recognition/writing settings, then
waits for an explicit **Resume**. Completed jobs keep their existing transcript
IDs. A new batch replaces this recovery queue; saved transcripts remain in
History. **Dismiss batch** removes the queue, without deleting transcripts or
source files. With saving off, batch state remains session-only.

The [October 27 native follow-up](native-batch-acceptance.md) now verifies explicit
Resume, Open, completed restart, Dismiss/restart and active Cancel on owned public
files, plus source-filename History search and filtered JSON export. The current
native source also fixes completed/dismissed header cues. Provider-reconfirmation
UI, VoiceOver, drag/drop and device/volume failures remain open.

## Commit and restart boundaries

Each item gets a stable planned result UUID before processing. An owner-only
checkpoint containing every planned ID must commit before the worker starts a
file. `transcribe` uses that planned ID instead of generating a new one. After
History acknowledges its commit, the queue marks the result saved and writes the
terminal state. A crash between those two writes is reconciled by a lightweight
History ID lookup; the existing result is offered through Open transcript.

On restore, an uncommitted queued/processing result becomes resumable. A confirmed
saved result that has since been deleted or expired becomes **unavailable** and
is not silently recreated. A History save failure pauses later files; retry first
flushes and reconciles admitted results. Cancellation and orderly quit preserve
remaining work. Quit still awaits the History barrier and its queue checkpoint.

`FileImportJournal` owns all metadata IO on an actor. Its synchronized payload
and atomic rename use a private 0700 staging directory / 0600 file. Monotonic
revisions fence older cancellation/save tasks after privacy clear, dismissal or
replacement. Owned v1 crash stages are cleaned on restart/clear; symlink targets
and unrelated files are preserved. Malformed/future/duplicate/remote metadata is
refused and preserved until explicit dismissal. Nonblocking open prevents a FIFO
at the metadata path from hanging startup. The caller holds AppInstanceLock.

## Privacy and routing

The JSON queue contains source URLs, result IDs, states/messages and a copy of
the recognition/writing settings. It contains no audio, API-key fields, focused
target, profile list, microphone ID or checkout path. Credentials remain in the
existing endpoint-scoped current Keychain flow. Current history/audio privacy
preferences and engine location apply on resume; the saved global preferences
are never installed as the current app settings.

Saving off clears the queue, including orphan stages. Delete all History also
removes the queue. Retention applies at startup and when saving a shorter policy.
Session-only retries cannot recreate persisted metadata. Recovery never inserts
into an old field. Saved remote speech or active remote rewrite routes require
an explicit provider confirmation after restart. The dialog names the saved
route and explains that an interrupted request may have already been processed
and that another request can incur charges. A changed current credential scope
can require configuring the saved endpoint again; keys are never read from the
queue. Verbatim local jobs do not request confirmation for an unused refiner.

The source files are **not snapshotted**. Resume reads their current contents;
missing, moved or unreadable files can fail. Selection through the file picker
may be needed again for access. A valid metadata file is bounded to 8 MiB and
10,000 jobs. The current journal rewrites the latest snapshot per checkpoint;
large-batch write amplification/throughput still needs profiling. Power-loss
durability, volume loss and external file replacement are not established by
the app-restart controls.

## Retained evidence

[Source/control manifest](../../benchmarks/results/durable-file-batches.json)
retains all seven development process controls and three real-ASR controls. Final
process and ASR controls build against the same application source fingerprint,
bind the temporary probe/test executable and refuse source changes during a run.
Earlier controls retain their original per-run provenance; unbound early
development outputs are not presented as final-source tests.

The process control uses a synthetic worker, three public fixture paths and four
actual separate XCTest processes. It intentionally SIGKILLs the live test after
the first result is saved and the second job starts. Restart performs no ASR
until Resume, reuses all planned IDs, runs only the two unfinished files, and
preserves all three payloads on another restart. Saving off then clears saved
History and the journal. Global model/language settings are changed between
processes; original batch settings still reach the worker. This is lifecycle/IPC
evidence, not recognition quality.

The first control passed its functional stages but left its isolated sleeping
fixture worker in Foundation Process's separate process group. That owned worker
was identified by PID/command/cwd and stopped. Later controls explicitly verify
ownership and stop the fixture child after killing the parent. All runs remain
retained. That harness cleanup alone does not establish production cleanup;
the later [native worker guardian](worker-lifetime.md) has its own production
owner-death and actual-ASR controls.

The real control uses the installed standalone Engine with all 29 backend
source/data files matching the checkout, pinned cached Parakeet, and offline Hub
mode. It imports a public LibriSpeech WAV plus malformed media, repairs only the
failed file, retries it with the original model/language despite changed global
settings, then restarts in a new process. Two IDs/results remain; the entire
first payload is byte-identical after retry/restart. The source WAV is unchanged.
No microphone, playback, cloud account, native GUI or insertion is involved.

Twelve new Core tests and seven platform tests cover identities, commit gaps,
atomic failure, revision fencing, cleanup, corrupt/future/symlink/FIFO metadata,
provider confirmation, privacy, retention, dismissal and History deletion.
Local full debug 483 tests and optimized 484 tests passed before the final FIFO
case; the final 27-case storage/workflow cohort passes. Python380 and Ruff pass. [Source CI40189125179](https://github.com/vibhusapra/OSpr/actions/runs/40189125179)
passes 485 permanent Swift / 380 Python tests, the actual synthetic process
control and standalone app/runtime/436-link/signature/artifact gates.
All development controls remain retained.

Actual component layouts were inspected in [light](../assets/durable-import-light.png),
[dark](../assets/durable-import-dark.png) and
[compact](../assets/durable-import-compact.png) arrangements. These are offscreen
views. At that source checkpoint, native control reported the Mac locked and no
normal app/data was changed. The later reliability preview includes this feature,
and the October 27 native follow-up above closes the scoped Resume/Open/Dismiss/
Cancel checks. Provider-dialog/VoiceOver and broader native acceptance remain open.

## Reproduce

```sh
swift test
cp benchmarks/durable_import_process.swift Tests/OSprPlatformTests/DurableImportProcessTemporary.swift
python3 benchmarks/durable_import_process.py --output /tmp/ospr-batch-process-new
rm Tests/OSprPlatformTests/DurableImportProcessTemporary.swift
cp benchmarks/durable_import_real.swift Tests/OSprPlatformTests/DurableImportRealTemporary.swift
python3 benchmarks/durable_import_real.py --engine /absolute/installed/Engine \
  --audio /absolute/public/speech.wav --output /tmp/ospr-batch-real-new
rm Tests/OSprPlatformTests/DurableImportRealTemporary.swift
```

Each output directory must be new. The runners build the copied exact temporary
probe, retain logs/receipts and bind source/executable hashes. CI runs the
synthetic process control; it does not download weights or run local-model ASR.
For layouts, temporarily copy `benchmarks/durable_import_render.swift` into the
platform test target and run `DurableImportRenderTemporary` with
`OSPR_RENDER_ROOT` set to the checkout, then remove the temporary test.
