# Summarize edited text with retained evidence

History → Local notes offers explicit original-transcript and edited-text summary
sources. If ASR says “Ship Friday” but the corrected editor says “Do not ship
Friday,” selecting edited text sends the correction to the same local summary
worker. Original remains the default. Exact excerpt notes and subtitle timing
continue to use original text.

The app captures the chosen text before the asynchronous request. Host-selected
provenance cannot be overridden by worker metadata. Edited results require the
original record and the captured edited field to match byte-for-byte when saved;
a changed source, cancellation, removed record or invalid response retains the
previous summary. Changing history selection cannot redirect the result.

Edited summaries retain their complete source snapshot, SHA-256 and exact quotes.
Later editing preserves this evidence and displays a stale warning. The saved
source is expandable, and copied Markdown identifies its source and fingerprint.
Original summaries keep their existing six-field JSON representation and rely on
the immutable original transcript rather than duplicating it.

## Retention and removal

The menu explains before generation that edited summaries retain a source
snapshot. Removing words from the current editor does **not** remove that saved
copy. “Remove summary and saved source” removes the summary, its quotes and its
snapshot from that record without changing text, original recognition, timing,
excerpt notes or retained audio. A compare-and-swap guard refuses an old removal
action if a newer summary replaced it. This is a logical history removal, not a
claim to erase previously copied text, exports, backups or forensic remnants.

Snapshots follow the existing history saving and retention policy. Session-only
history keeps them in memory; explicitly enabling saving persists them. Disabling
saving purges disk history while keeping the current session available until
quit. All policies remain local; this change introduces no provider, credential,
model, runtime dependency or automatic generation.

## Storage compatibility

The first edited-summary save transactionally advances SQLite `user_version` to
4. Original-summary archives stay at 3; fresh archives stay at 2 until summary
features require a fence. Removing the summary never downgrades the writer fence.
Invalid batches roll back both content and version. Migration rejects unknown
source kinds, invalid snapshots and future nested fields while preserving the
legacy JSON archive. Session transfer and restart preserve stale snapshots.

A separately compiled Core from parent `3c30ac7` opens v3 originals and refuses
v4 edited summaries without changing SQLite bytes. The current reader opens both.
See [old-reader receipt](../../benchmarks/results/edited-summary-upgrade-fence.json).
This is a synthetic storage compatibility test, not a native installer or user
profile upgrade claim.

## Validation and reproduction

The source receipt records the final suite counts and fingerprint:
[validation](../../benchmarks/results/edited-summary-source-validation.json).
Twelve new Core tests cover legacy encoding, Unicode byte identity, invalid and
forged provenance, rollback, restart/migration/transfer, stale admission, removal
races and session-only retention. Two new application lifecycle tests cover
selection changes, edited request capture, stale completion, cancellation and
removal. Existing original-source lifecycle tests still pass.

One actual cached local Qwen3.5 9B call ran through WorkerClient, host source
validation and SQLite persistence. It used “Do not ship Friday. The price is
$12.50.” while original text had the opposite instruction and $15.50. Both exact
quotes were retained; after another editor change the stored source remains valid
and is correctly stale. [Raw public result](../../benchmarks/results/edited-summary-local-inference.json).
Its ~6.1-second call is one shared-machine observation, not an isolated latency,
quality, semantic correctness or consumer ranking benchmark. All summary meaning
and coverage caveats from the fidelity study still apply.

```sh
swift test
swift build -c release
swiftc -parse-as-library -I .build/debug/Modules \
  benchmarks/edited_summary_storage.swift .build/debug/OSprCore.build/*.swift.o \
  -o /tmp/edited-summary-storage
/tmp/edited-summary-storage fixtures /tmp/ospr-fresh-summary-fixtures
HF_HUB_OFFLINE=1 /tmp/edited-summary-storage inference \
  /tmp/ospr-fresh-summary-inference "$PWD"
uv run --frozen --all-extras python benchmarks/meeting_summary_cli.py \
  --cli .build/debug/ospr-cli --contracts-only --output /tmp/summary-contracts.json
```

Use fresh disposable directories. For the old-reader test, retain parent
`3c30ac7f7f9c3226822289932feed305bd49cf60` Core sources in a separate SwiftPM package,
compile `benchmarks/history_archive_reader.swift` against that module, run it on
the two generated directories, and compare file hashes before/after. v3 exits 0;
v4 exits 1 with a content-free newer-version message.

Five actual source renders were inspected: [original](../assets/edited-summary-original.png),
[current edited](../assets/edited-summary-edited-current.png),
[stale light](../assets/edited-summary-stale-light.png),
[stale dark](../assets/edited-summary-stale-dark.png) and
[stale narrow](../assets/edited-summary-stale-narrow.png). They are simulated
SwiftUI body renders, not native interactions. An isolated debug app launched with
a unique identity, disposable synthetic profile and background services disabled;
native inspection timed out twice. The QA process was stopped and the normal app
was verified idle, local-only, with unchanged settings/history. No microphone,
audio playback or insertion was used. Native menu selection, source disclosure,
copy, removal and reopen acceptance remain open. Earlier signed standalone ZIPs
predate this source; no new distribution claim.
