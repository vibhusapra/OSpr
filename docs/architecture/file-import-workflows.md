# File import, retry and complete history export

File imports now retain an ordered per-file queue in Studio. Each row has a
filename, processing state, failure/warning and an Open transcript action when a
result exists. A failed file no longer disappears behind the final batch status.
The batch list lasts until quit; completed transcripts follow the history policy.

Retry uses the original batch configuration and only failed/cancelled entries.
Completed and warning-bearing transcripts keep their IDs. Cancellation after a
transcript is admitted marks it available with a warning, so retry cannot duplicate
it. Late results cannot turn cancelled entries into successes. A full new import
replaces the latest batch list, while its completed history records remain.

Drops collect every URL in order before admission. An unreadable or remote item
rejects the entire drop visibly. Previously each URL started a separate import;
the busy guard could discard subsequent files. Native drag/drop interaction is
still unverified; real NSItemProvider and AppModel tests cover this path.

## Source names and export semantics

The selected History detail shows the source filename. Individual export defaults
use a safe source stem plus the full transcript UUID. Duplicate source basenames
remain distinct; controls, path separators and excessively long stems cannot
become unsafe filenames. Later source adds filename labels and literal source
search to paged History; see [source-search storage and acceptance](history-source-search.md).
The native evidence below predates that schema-5 change.

History provides Export all history / Export all search matches in TXT, JSON,
SRT and VTT. This includes unloaded pages, not merely visible rows. The literal
query is captured for that export. TXT uses edited text; JSON retains edited and
original text/metadata; subtitle formats continue to use original timed content.
Each new directory includes an index with IDs, sources, filenames and count.
Audio is not copied. This is transcript export, not a restorable audio backup.

The serial history queue applies earlier pending edits, deletes and privacy
transitions before export. A failed pending commit aborts instead of exporting
stale disk text. Session-only records export from memory without creating a disk
archive. One full payload is decoded at a time across bounded metadata pages.
Later mutations wait behind export; the main actor does not perform its I/O.

A private staging directory uses mode 0700 and files use 0600. One exclusive
rename publishes the complete directory. Existing destinations, symlinks and
destinations created during export survive unchanged. Errors/cancellation before
publication remove staging. Cancellation does not roll back admitted history
transactions; publication that already won returns its completion receipt.

## Media errors and warm-worker recovery

Unreadable media, missing sources, read permissions and decoder timeouts produce
actionable messages rather than a full command/path diagnostic. Only typed
media-read rejections retain the healthy speech worker; runtime and malformed
protocol errors still restart it. Actual Swift IPC controls on cached Whisper
Small and Parakeet preserve the same PID, warm ASR and exact public-speech output
before/after malformed audio. This is recovery evidence, not a speed ranking.

```sh
swiftc -O -parse-as-library Sources/OSprCore/WorkerClient.swift \
  benchmarks/media_recovery.swift -o /tmp/ospr-media-recovery
printf 'Invalid public synthetic audio fixture.\n' > /tmp/ospr-invalid.wav
/tmp/ospr-media-recovery "$PWD" benchmarks/fixtures/audio/1272-128104-0000.wav \
  /tmp/ospr-invalid.wav whisper-small /tmp/ospr-media-recovery.json
```

Model weights must already be cached. The receipts record exact source/invalid
fixture digests and runner/client hashes. Repeat with `parakeet-v3`. No microphone,
UI or provider call.

## Native and source validation boundaries

The native functional checkpoint has complete source bytes equal to commit
`ee1eeb5a1d9d1c3a4fb1036461881a2fbfc6cd9e`, fingerprint `5677918c…`.
The QA binary was built from a dirty checkout and then re-signed for a private
Application Support profile; this is source-byte equivalence, not a clean-build
claim. It uses the verified standalone Python/dependencies plus all 29 current
backend source/assets, with deep signature and direct worker ping checked.

Actual native Open/Save dialogs and the real model pass a three-file mixed
batch: two transcripts, one readable failure, unchanged input hashes, deliberate
test-harness repair, and retry adding only the failed record. A before/after JSON
export proves the earlier IDs and payloads unchanged. Native all-history export
passes in all four formats; an edited result appears in TXT/JSON while subtitles
retain the original. The individual default name saves with its correct `.txt`
extension even though macOS hides that extension in the name field.

Retained attempts include the original command diagnostic, a checkout-runtime
Documents-folder TCC gate, and an incomplete private runtime fixture missing its
Python sibling. The complete bundled fixture passes. No permission was granted.
The normal app was never stopped and its five baseline data/app hashes match.

The Mac briefly locked before filtered checks; after control resumed, native
search export returned exactly two Quilter records and a complete zero-record
index for an unmatched query. The final source then passed a separate native
mixed batch, source-correct Open callback, repaired-file Retry and two-record
JSON export. This final GUI has fingerprint `c1ddeec3…`, built from a dirty
`ee1eeb5` checkout; no clean-build claim. Its dark card has inspected contrast.
Light/dark/compact offscreen actual-component renders add layout coverage without
implying further native events. Both private QA apps and owned workers stopped;
normal local-only OSpr visibly remains at eight sessions/265 words with all five
baseline hashes unchanged. Native drag/drop, active Cancel, VoiceOver, durable
batch resume and new release packaging remained open at that checkpoint. Source
list/search is implemented in the later change linked above; native interaction
acceptance for that change remains open. No new distributable archive is claimed.

Nine complete native directories and the individual TXT are retained.
The tests cover 234 session-only exports across pages, latest edits and deletion,
search over original text, safe/duplicate names, pending-write failure,
transaction/cancellation ordering, publication races and source fidelity. The
AppModel tests cover mixed results, original-config retry, late cancellation,
real NSItemProvider resolution and the non-batch watched-folder save path.

```sh
uv run --frozen --all-extras python benchmarks/verify_file_import.py
# Also check the historical native source object, when present locally:
uv run --frozen --all-extras python benchmarks/verify_file_import.py --native-source
```

[Native outputs and exact scope](../../benchmarks/results/file-import-native.json) ·
[Whisper recovery](../../benchmarks/results/media-recovery-whisper-small.json) ·
[Parakeet recovery](../../benchmarks/results/media-recovery-parakeet-v3.json).
Five altered-evidence controls reject changed output, omitted formats/records,
changed originals and unsafe paths. CI rechecks retained output/layout integrity;
it does not rerun native interaction or ASR. Reproduce offscreen renders by copying
`benchmarks/file_import_render.swift` temporarily into the platform test target,
running `swift test --filter FileImportRenderTemporary`, then removing that copy.
