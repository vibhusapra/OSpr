# Indexed history — implementation in progress

The storage engine and isolated benchmark are implemented on
`codex/indexed-history`, based on the verified v0 preview. Current source connects the asynchronous repository to paged history, details,
search, settings, edits and shutdown. Generated-fixture native history acceptance has passed. No real user archive has been
migrated, and this prototype is not included in the previously packaged preview.

## Storage contract

`HistoryDatabase` owns a single thread-confined system SQLite connection. Its
asynchronous `HistoryRepository` runs opening, migration, queries and writes on
a serial background queue. Constructing the repository performs no filesystem
work; closing its connection also stays on that queue. App-data migration requires the existing `AppInstanceLock`.
The core type is public for the CLI harness; it must not be called on the UI
executor by the app integration.

Each row retains the complete canonical `Transcript` JSON payload. List queries
fetch bounded summaries (at most 200 rows, each preview at most 480 Unicode
scalars) without decoding timing arrays, original text or notes. Detail loading
decodes one selected payload. Insertion order is independent of wall-clock dates;
edits preserve position. Keyset pagination tolerates new records arriving before
the current page. Aggregate word/session counts are maintained transactionally.

Search indexes edited and original text after stable Unicode case folding and
canonical composition. Accents are preserved. Three-or-more-scalar queries use
FTS5 trigram substring matching; shorter and embedded-NUL queries scan text
columns without materializing payloads. The whole query is quoted as a literal,
including punctuation, quotation marks and apparent FTS operators. This is a
defined search normalization, independent of changing system locale settings.

## Migration and privacy

The legacy array is streamed one object at a time. Unknown future fields,
duplicate IDs, malformed JSON and unsupported database versions stop migration
and preserve the original files. Every field, including word/speaker timing,
notes, raw/edited text and audio links, is retained. Per-record autorelease pools
bound Objective-C temporaries during large migrations.

Within one transaction, an ordered digest and count of all canonical source
records are compared with the actual persisted payloads. The source file is also
hashed again. A committed marker and source hash allow cleanup to resume after
interruption without importing deleted records again. The source is checked
again after commit before removal. An independently rewritten archive is kept
alongside the committed database and reported as a conflict. The app lock is
required to exclude concurrent GUI writers during the filesystem handoff.

The parent directory is mode 0700 and the database is created at 0600. Expected
parent symlinks are resolved with POSIX `realpath`; the database and legacy-file
symlinks are rejected. Rollback journals, full synchronous commits, in-memory
temporary SQL storage and a 4 MiB page-cache target are configured. Both SQLite
and FTS5 secure-delete options are enabled. Clearing removes records, search
entries, statistics, audio links and the legacy source fingerprint. This does
not promise forensic erasure from APFS snapshots, backups or the storage device.
The indexed route requires SQLite 3.42+ with FTS5/trigram support.

Deletes and expiry return only audio names no remaining record references.
Filesystem audio removal belongs after a successful database commit. Existing
audio eviction updates one payload at a time. Multi-record writes roll back as
a unit, preserving original payloads, counts and search entries after failure.

## Reproducible storage benchmark

```sh
swift build -c release --product ospr-cli
.build/release/ospr-cli benchmark-history-index 100000 3
```

The harness generates deterministic timing-rich synthetic records in an owned
temporary directory and removes that fixture afterward. Migration is a separate
fresh CLI process. A seeded random order runs each JSON/indexed trial in another
fresh process, so full JSON decoding cannot contaminate the indexed process's
peak RSS. Timings begin after CLI dispatch and exclude process spawn. Both
routes must return identical top-100 IDs for eight queries, equal word/session
counts and the same selected-record payload hash. Sources, executable and
fixture are fingerprinted. This does not measure SwiftUI rendering or app launch.

## Integration gates

- [x] Integrate the implemented serial repository into AppModel. Core tests cover
  coalescing, read-your-edit, failed batches, tombstones, clear barriers,
  whole-archive retention/audio changes and async/quit flushes. Opening and
  callbacks stay off MainActor. Session-only transitions have dedicated tests; the app now uses this repository.
- [x] Replace the full-array UI model with summary pages, aggregate counts and
  separately loaded selected/latest details. A summary must never overwrite a
  complete stored transcript. Fence stale detail/search/page responses.
- [x] Debounce search, reset cursors when queries change and preserve selection while
  recordings or watched imports arrive. Exercise long transcripts and histories.
- [x] Connect the tested complete-archive retention, disable-saving, clear-all and
  audio-eviction APIs to the UI. Preserve session-only semantics and make failed
  privacy/durability transitions visible. Confirm requested durability before
  releasing completed-take recovery.
- [ ] Broaden native validation beyond the generated history fixture: notes/reprocessing, all exports, recovery,
  watched imports, retained audio and settings transitions through the actual
  app. Repeat portable and distribution gates before replacing the preview.

Primary SQLite references:
[FTS5 and trigram matching](https://www.sqlite.org/fts5.html),
[transactions](https://www.sqlite.org/lang_transaction.html),
[connection flags](https://www.sqlite.org/c3ref/open.html),
[FTS5 secure-delete](https://www.sqlite.org/fts5.html#the_secure_delete_configuration_option).

The 100,000-record receipt is `benchmarks/results/history-index.json`. An
independent checker verifies expected fixture IDs, counts, complete selected
detail agreement, Git source hashes and every NumPy percentile:

```sh
.venv/bin/python benchmarks/verify_history_index.py benchmarks/results/history-index.json
```

Initial data p50 is 3,448.4 ms for JSON and 2.98 ms for the prototype; median
process peak RSS is 1,828,552,704 and 17,580,032 bytes respectively. Migration plus
initial data takes 32.34 s and peaks at 98.02 MiB. Per-read autorelease pools
reduced the initial migration's 891.91 MiB peak. These are synthetic storage
measurements; the shipped UI has not adopted this path.

The earlier storage-control database occupies 515,993,600 bytes versus 303,900,003 bytes of legacy JSON.
A separate 8 KiB page control measured 514,293,760 bytes (0.3% less) and a larger
181.27 MiB migration peak. It offered no useful packing improvement on this
fixture, so 4 KiB remains the default. Both complete raw controls are retained.
Packing/compression and broader real-history distributions remain future work.

The final receipt retains the exact measured CLI under `.local/history-index-measured-cli`. A rebuild from identical source need not have the same Mach-O hash. Use `--cli` only with the preserved measured binary; source provenance is independently checked against the recorded Git commit. Subsequent nested-field migration guards have their own correctness tests and are not represented as remeasured performance.

## Async admission and compatibility checks

`HistoryRepository` owns the database lazily on a private serial queue. Separate
new IDs retain admission order; repeated edits coalesce. Field-specific text and
notes mutations read the latest complete payload, preserving timing, other edits
and already evicted audio. Source-mismatched notes and edits to removed records
fail without resurrecting them. An atomic batch combines upserts, deletion
tombstones, clear, retention and audio removal; failed batches remain pending.
Only explicit clear can reset an unreadable archive. Audio cleanup is returned
after commit, and ordinary edits use indexed ownership checks rather than loading
all archive references. Audio-link stripping retains one payload at a time.

Canceled reads skip queued work and reject obsolete completed results. A running
SQL statement or migration finishes safely; read cancellation never interrupts
a transaction or discards admitted writes. Debounced UI search still needs its
own selection/query epochs. `flushAsync` is the ordinary durability barrier;
blocking `flush` is reserved for orderly quit and rejects callback reentry. The
latest coalesced observer receives batch completion on the repository queue,
including failures and explicit retry results. UI consumers must always perform
committed audio cleanup even when their presentation token is stale.

The storage stage passed 186 local Swift tests and macOS 15 CI run 39880778334.
Current source adds ten presentation/application regressions, including actual
AppModel startup migration, full detail/copy access, search/paging, notes/edits,
background-selection preservation, session mode and failed/successful quit. SQLite before 3.46.1 has a documented
[secure-delete format issue](https://www.sqlite.org/releaselog/3_46_1.html): its
special FTS delete command fails to update secure-delete format metadata. An
initial merge-before-diagnostics control passed nonempty cases but failed empty
ones in macOS 15 CI; that incomplete workaround is superseded.

Schema v2 uses normal FTS DELETE in BEFORE triggers, while the old content row
is still readable. Only changed normalized text/raw is reindexed; notes, audio
and case-only edits avoid index churn. Existing v1 databases upgrade in one
transaction. A temporary row containing nonempty probe text is inserted and deleted through the normal
API to update legacy format metadata, with no surviving probe and no rebuild of
existing index entries. The secure-delete format is seeded before user edits can fail and roll back; metadata is checked after commit. Full clearing recreates the empty FTS virtual table because older SQLite can keep a stale cached format after rebuild. Full integrity checks precede migration commit. A damaged v1 index
fails migration with its original file bytes intact. Future payload changes
require a storage-version review so older writers cannot silently drop fields.

Forty-five shell controls across SQLite 3.42.0, 3.43.2, 3.46.0, 3.46.1 and system
3.51.0 cover the original failure, current nonempty/empty state, successful
legacy empty/nonempty upgrades, full clearing, rollback-stable format metadata and rejection of damaged current/legacy indexes. These
controls do not replace full older-OS Swift CI or native-app acceptance. The
complete raw matrix is `benchmarks/results/history-sqlite-compatibility.json`;
the earlier limited merge control is retained separately.

The GUI passes its `AppInstanceLock` into the repository. The repository retains
that lease through queued operations and explicitly closes its SQLite connection
on the private queue before releasing the lease. A lifetime regression verifies
that a second owner is rejected until this teardown completes.

## Session-only history

Disabling saving is an ordered repository barrier. It snapshots every stored page
into a private `:memory:` database without materializing the transcript archive,
applies pending edits and removes audio links, then clears the persistent content
and search index. A new session-only archive creates no history file. Enabling
saving transfers the complete current session back through SQLite's transactional
[backup API](https://www.sqlite.org/backup.html). All subsequent writes stay off
disk while saving is disabled, including after a failed snapshot or purge.

Snapshot/purge/persist failures retain the request and pending changes. A memory
batch that already succeeded remains readable after a disk transition failure;
flush continues to throw and its observer reports failure until the requested
state succeeds. Cleanup receipts survive later edits/retries, and current audio
owners are rechecked before returning orphaned names. Unreadable legacy archives
are preserved until an explicit clear; disabling saving does not silently
destroy a source that could not be snapshotted.

Full-session visibility uses more memory than ordinary paged disk history.
Snapshots compact heavily unused pages in memory, and empty disk archives reclaim
space after the clear commit. The pure memory connection uses `SQLITE_OPEN_MEMORY`,
`PRIVATECACHE` and `temp_store=MEMORY`; a file-only temporary-storage runtime is
rejected. A nondefault SQLite VFS probe records zero file opens through inserts,
queries, deletion, compaction and integrity checks, with a positive control that
detects a real file open. This concerns application history storage; temporary
capture, unresolved-take recovery, intentional exports and OS memory management
remain separate boundaries.

The first 100,000-record transition control failed without a completed receipt.
A one-second sample while its worker was active at about 104 seconds found the
repository inside per-row FTS secure-delete work during full clearing. The helper
had a 180-second watchdog but did not retain the exact child exit reason. It is
a failed exploratory control, not a completed latency baseline. Its binary and
full profile remain private; the sanitized receipt fingerprints both.

Full clearing now drops only its own delete-maintenance trigger within the same
transaction, clears all content, recreates the empty index, resets counters and
restores the exact trigger. `secure_delete` stays enabled. Encoding failure later
in the batch rolls back content, index, counters and trigger together. Ordinary
individual deletions retain their normal maintenance. Current source checks
total 196 Swift tests, including 15 session tests, two bulk-clear and two v1-upgrade regressions.

The revised 100,000-record control passed. All ordered complete-payload hashes
and counts match before, during and after the round trip, as does the selected
detail. Disable/clear flush took 1,461.5 ms; enable/persist flush took 290.9 ms.
The disk archive shrank from 515,985,408 bytes to 49,152 bytes while off, then
returned to its original size on restore. Lifetime child peak RSS was 663,388,160
bytes (632.7 MiB), including the full snapshot and verification. This is one
exploratory round trip, not a p50/p95 or SLA. Timed barriers exclude migration,
fingerprint verification, GUI, CLI spawn and audio cleanup. Raw result:
`benchmarks/results/history-session.json`. The independent verifier checks its
shared fixture against the earlier storage control, all counts/hashes and every
committed Swift source fingerprint, plus the preserved measured CLI hash.

## App integration and isolated native acceptance

`HistoryModel` owns the current summary page(s), aggregate counts, latest and
selected complete records, and uncommitted new results retained for export after
a storage failure. Search is debounced 180 ms and canceled/epoch-fenced; detail
loads have an independent epoch. New background results preserve selection.
Context-menu copy resolves the complete record instead of copying a truncated
preview. Text and notes edits use repository field updates. Committed orphan
cleanup runs even when its presentation callback has been superseded.

AppModel construction no longer decodes `history.json`. Migration, retention and
archive-wide audio reconciliation run through startup background work. Settings
report success after the history policy/cleanup barrier, even when an unrelated
Keychain failure needs separate attention. App termination stops new admissions,
lets admitted maintenance finish, preserves unfinished capture, cancels inference
and asynchronously flushes edits. A failed flush offers keeping the app open or
explicitly quitting without saving.

For isolated local QA, set an absolute `OSPR_DATA_DIRECTORY` launch environment
variable (or an `OSprDataDirectory` string in a separately signed QA bundle).
`OSPR_DISABLE_BACKGROUND_SERVICES=1` or an `OSprDisableBackgroundServices` boolean
in that bundle suppresses global shortcuts, watcher, Keychain and login-item
operations. Use a distinct bundle identifier so single-instance activation does
not redirect to the regular app. These are explicit launch profiles, not normal
settings. The standard bundle continues to use Application Support/OSpr. Native
QA must use generated public fixtures, preserve the production archive and leave
the existing running preview untouched until upgrade acceptance is complete.

The native QA bundle at source `163a113eb187c565ae958a4d6862fdc43f57d769`
passed a generated 235-record migration, initial 100-summary page, indexed lookup
outside that page, full detail editing, load-more expansion to 235, session-only
disk content/counters/search clearing, saving restore, pending-edit quit flush
and restart. Every persisted full payload equals the fixture with only the two
intentional edits; original text and timing remain intact. Native TXT export and
summary-row context copy (pasted into an owned TextEdit file) both match all 1,407
characters of the complete edited record. See
`benchmarks/results/history-native-ui.json`. macOS 15 CI run 39881939294 passes
196 Swift/94 Python tests and the app/report/standalone runtime checks. These
checks do not measure end-to-end latency or validate microphone/shortcut/insertion.
