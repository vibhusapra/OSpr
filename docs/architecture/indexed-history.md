# Indexed history — implementation in progress

The storage engine and isolated benchmark are implemented on
`codex/indexed-history`, based on the verified v0 preview. The app still uses its
existing JSON history and coalescing writer. No real user archive has been
migrated, and this prototype is not included in the previously packaged preview.

## Storage contract

`HistoryDatabase` owns a single thread-confined system SQLite connection. Its
eventual repository must run opening, migration, queries and writes on a serial
background executor. App-data migration requires the existing `AppInstanceLock`.
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

- Add the serial asynchronous repository and incremental, coalescing upserts.
  Preserve failed pending edits, ordering around deletion, explicit reset and
  orderly-quit flush. Test that callbacks and filesystem work stay off the UI.
- Replace the full-array UI model with summary pages, aggregate counts and
  separately loaded selected/latest details. A summary must never overwrite a
  complete stored transcript. Fence stale detail/search/page responses.
- Debounce search, reset cursors when queries change and preserve selection while
  recordings or watched imports arrive. Exercise long transcripts and histories.
- Apply retention, disable-saving, clear-all and audio eviction to the complete
  archive. Preserve session-only behavior without leaving content/index copies
  on disk. Confirm storage before releasing completed-take recovery.
- Validate migration/restart, edits/notes/reprocessing, all exports, recovery,
  watched imports, retained audio and settings transitions through the actual
  app. Repeat portable and distribution gates before replacing the preview.

Primary SQLite references:
[FTS5 and trigram matching](https://www.sqlite.org/fts5.html),
[transactions](https://www.sqlite.org/lang_transaction.html),
[connection flags](https://www.sqlite.org/c3ref/open.html),
[FTS5 secure-delete](https://www.sqlite.org/fts5.html#the_secure_delete_configuration_option).
