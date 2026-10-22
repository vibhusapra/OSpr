# Indexed history — implementation in progress

The storage engine and isolated benchmark are implemented on
`codex/indexed-history`, based on the verified v0 preview. The app still uses its
existing JSON history and coalescing writer. No real user archive has been
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

- Integrate the implemented serial repository into AppModel. Core tests cover
  coalescing, read-your-edit, failed batches, tombstones, clear barriers,
  whole-archive retention/audio changes and async/quit flushes. Opening and
  callbacks stay off MainActor. UI wiring and session-only transitions remain.
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

The database occupies 515,993,600 bytes versus 303,900,003 bytes of legacy JSON.
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

Eighteen repository regressions and twenty-one database regressions pass as
part of 166 Swift tests. The initial macOS 15 CI run exposed SQLite's documented
[pre-3.46.1 secure-delete integrity false positive](https://www.sqlite.org/releaselog/3_46_1.html).
A conditional FTS `optimize` before diagnostics merges the existing index; it
does not rebuild it from transcript content. Controls on SQLite 3.42.0, 3.43.2,
3.46.0, 3.46.1 and the system 3.51.0 reproduce the old report, pass the correction
and still reject a deliberately divergent index. The actual Swift test also
checks the legacy branch with a damaged index. The macOS 15.7.9 Swift suite (165 tests), Python checks (94 tests) and standalone
runtime gates passed on Apple SQLite 3.43.2 in run 39873308963 on commit dabd41b; the subsequent lease-lifetime test also passes locally.
The shell controls are not native-app acceptance or timing results.
See `benchmarks/results/history-sqlite-compatibility.json` and the reproduction
script `benchmarks/history_sqlite_compatibility.py`.

The GUI passes its `AppInstanceLock` into the repository. The repository retains
that lease through queued operations and explicitly closes its SQLite connection
on the private queue before releasing the lease. A lifetime regression verifies
that a second owner is rejected until this teardown completes.
