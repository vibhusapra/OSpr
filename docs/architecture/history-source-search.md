# History filenames and source search

History now shows the cleaned source leaf above each text preview. Long names
truncate in the middle and have a full-name help label. Search matches edited
words, original words, or source names. A filename-only query also selects the
complete matching archive for bulk export, including unloaded pages and pending
edits. Source labels such as `dictation` remain searchable; an absent source does
not gain a generic `Dictation` search term.

The change is source-only. Existing standalone previews and their archives are
preserved and do not include it. Native List/search/tooltip/VoiceOver acceptance
remains open: macOS locked before the separate services-disabled QA app could
launch. No permission, microphone, provider, clipboard or destination-field
action was performed for this feature.

## Storage contract

Schema **5** adds lightweight `source_name` (original display case) and
`source_search` (POSIX case fold, canonical Unicode normalization) columns.
`Transcript.sourceFilename` shares the existing basename/control/bidi sanitation
with detail and export labels. Parent paths never enter these new search fields;
text that actually mentions a path remains searchable as text. Canonical payloads
retain their original source value.

The external-content FTS5 trigram index has a separate source column. Literal
queries are quoted, so quotes, operators and punctuation do not become query
syntax or cross-column phrases. One/two-scalar and NUL-containing queries scan
only the lightweight folded fields. Pages never decode transcript payloads.
Filename edits update the index; case-only edits update display metadata without
reindexing an unchanged folded value. Deletion, retention and clear maintain all
three fields; filename erasure is tested in the SQLite file bytes.

Existing schema 1–4 stores upgrade off the UI executor. The old index must pass
integrity validation. A transaction adds columns, decodes one payload at a time,
backfills only derived values, recreates the index/triggers, seeds secure-delete
format and verifies integrity before setting schema 5. Payload bytes, order,
counts and audio links are preserved. Backfill/integrity failures roll back;
damaged old indexes are refused rather than silently repaired. Existing schema-1
trigger and earlier secure-delete repairs still run using the old physical
columns before source backfill.

SQLite FTS's internal secure-delete **format 5** is a separate version from our
schema `user_version=5`. Normal insertion/deletion of a temporary probe commits
the FTS format on older SQLite too. Clearing recreates and seeds the three-column
index. Old OSpr readers/writers refuse schema 5 before content mutation.

## Checked evidence

[Raw source/storage receipt](../../benchmarks/results/history-source-search.json)
binds the application fingerprint, helper executables and four component renders.
Twelve new Core cases cover Unicode/literals/short queries, path exclusion,
no-payload pages, rename/delete/retention/clear, file-byte erasure, keyset paging,
filename-filtered export, memory/durable transfer, actual physical schema 2–4
upgrades (including summaries), failed backfill and damaged-index refusal. One
new HistoryModel case checks asynchronous filename filtering and selected-detail
preservation. Existing schema-1 fixtures now use actual old physical columns.

The first full run retained twelve failures from old schema-version assertions.
Those assertions now expect the stronger schema-5 fence; no production error or
failed case was discarded. The corrected full suite passed 465 tests, followed
by 36 focused tests after the filename-erasure case and shared row extraction.
The final optimized **466 Swift / 380 Python** suites and Ruff pass; release app
build/signatures pass. CI validation is recorded in the progress ledger.

An actual retained schema-4-capable Core from `769922a` opened a **3,000-record**
public JSON fixture into schema 2. Current Core upgraded it to 5, verified every
label and byte-ordered payload fingerprint, counts and a memory snapshot. The
older executable then exited 1 with a newer-version message; the database file
hash stayed unchanged. A private copied eight-record/265-word archive and its
two audio files also passed; the original files were untouched. No private
payloads, audio or paths are published.

The single public observation was about **98 ms to open/upgrade** and **1.3 ms
for the first 37 filename matches** on this shared M5 Max. It is one nonisolated
storage observation, not p50/p95, a cold-disk test, ASR latency, or a product
ranking. No inference or cloud call was part of this change.

Four offscreen layouts render the **shared production row component** in a
plain stack: [light](../assets/history-source-light.png),
[dark](../assets/history-source-dark.png),
[220-point list](../assets/history-source-compact.png), and
[filename-only filter](../assets/history-source-search.png).
The full offscreen AppKit List did not materialize its rows; those initial empty
renders were rejected. These component layouts do not establish native events.

## Reproduce

Use a disposable directory, never an active application profile:

```sh
swift test
swiftc -parse-as-library -I .build/debug/Modules \
  .build/debug/OSprCore.build/*.o benchmarks/history_sources.swift \
  -o /tmp/ospr-history-sources
/tmp/ospr-history-sources fixture /tmp/ospr-source-public-unique 3000
# Build benchmarks/history_archive_reader.swift against retained 769922a Core.
/tmp/ospr-old-history-reader /tmp/ospr-source-public-unique
/tmp/ospr-history-sources verify /tmp/ospr-source-public-unique
# Must refuse the upgraded schema, without changing its file hash:
/tmp/ospr-old-history-reader /tmp/ospr-source-public-unique
```

Copy `benchmarks/history_source_render.swift` temporarily into platform tests,
run only `HistorySourceRenderTemporary` with `OSPR_RENDER_ROOT` set to the
checkout, then remove that temporary test. Render artifacts do not change the
permanent suite count. Native QA uses a different bundle identity, private public
fixture profile and `OSprDisableBackgroundServices=true`.

The later [durable batch source change](durable-file-batches.md) also preserves
the latest import queue across restart; its native acceptance remains open.
