# Review summary and note sources in the recording

History source quotes now show recognizer times. With retained audio, an explicit
click seeks and plays the supporting passage. Without audio, times remain useful
reference labels. Copied Markdown includes the same estimates and exact quotes.
No audio is retained automatically, and indexing does not play anything.

Python supplies optional `source_start_utf8` / `source_end_utf8` byte coordinates
for each exact excerpt. Unit IDs disambiguate repeated wording; the coordinates
are computed in one forward pass. Existing scalar `start` / `end` fields in
extractive worker responses remain available. Swift checks quote bytes against
both boundaries. Older saved quotes still decode; repeated legacy wording has
no time unless its occurrence is unambiguous. Invalid coordinates are rejected.

The complete original recognizer word stream must match the original transcript
literally, allowing whitespace gaps. Otherwise, the same check is applied to
segments. Times must be finite, ordered by start and inside the recording;
overlapping ends are preserved. There is no fuzzy alignment or interpolation.
Changed edited-source snapshots show an explanation instead of a guessed time;
an edited snapshot identical to the original can use its original alignment.
Recognizer times are estimates, not verified acoustic boundaries.

The cancellable index runs off the main thread and hides stale results as soon
as its source snapshot changes. Clicking rechecks the selected record, validated
summary/notes, source, timing arrays, retained filename, player readiness and
loaded duration. Recording startup, active recording and archive maintenance
block playback. Seeking still uses the existing transport's generation guards.

New coordinates are stored under a lazy, transactional History schema **6** fence.
Older writers must refuse rather than silently drop them. Legacy records without
locations retain schema 5. Removing quotes does not lower an existing fence.
Known new nested fields migrate; unknown fields still refuse migration. Notes
must match their raw source before any write. A failed batch rolls back both data
and the forward-version fence; memory/session transfers preserve them.

## Evidence

- **522 optimized Swift tests / 408 Python tests**, plus Ruff. Eleven new mapping
  and silent real-transport tests, two storage regressions and eleven Python
  metadata/replay cases supplement the parent suites. The two storage regressions
  failed before correction; the retained failure log is private test evidence.
- All forty production-study cases / 85 stored calls replay with identical
  prompts, order, results and rejection messages after stripping only the two
  added metadata fields. This is recorded-output compatibility, not new inference
  or semantic scoring. The earlier 120-case quality study is unchanged, and its
  status-prompt candidate remains withheld.
- One pinned, unchanged public **AMI ES2004a 180-second headset-mix file** passes
  actual local Metal Parakeet → 9B summary → 4B selection → Swift validation and
  SQLite reopening. All **15 summary / 6 notes** quotes map to segment estimates;
  ordinary transcription supplied 29 segments and no words. The checked-in
  public output fixture is replayed by CI. Word precision has synthetic tests;
  this file does not establish its acoustic accuracy.
  The [pinned AMI manifest](../../benchmarks/fixtures/ami.json) carries source
  hashes and attribution: AMI Meeting Corpus, CC BY 4.0, University of Edinburgh
  and corpus contributors; [original corpus](https://groups.inf.ed.ac.uk/ami/corpus/).
- The actual parent Core reader refuses the schema-6 fixture with its bytes
  unchanged. A disposable store and synthetic retained filename are used; the
  real-model probe does not retain or play audio.
- On one 128 GiB Apple M5 Max, 31 optimized construction trials with 120 quotes
  give **2.57 ms median / 2.75 ms p95** for 10,000 units and **25.77 / 30.58 ms**
  for 100,000 units. This is an indexing microbenchmark, excluding UI, models,
  playback, energy and competitor behavior.
- Light, dark and 390-point offscreen production-label layouts were inspected.
  These are component fixtures, not native user-flow acceptance.
- A clean Apple Development signed candidate, re-signed only for an isolated
  public-data profile, passes native summary source seek to **1:50** and extractive
  source seek to **2:39**, playback-state changes and pause. Leaving paused History
  for Studio and returning resets playback to **0:00**. The public fixture's
  substantive fields are unchanged. Normal OSpr is visibly restored at eight
  sessions / 265 words; all six fresh app/profile/target hashes match. These
  observations verify transport state, not audible route or acoustic boundaries.

[Real pipeline and pinned models](../../benchmarks/results/audio-quote-real.json) ·
[Public recognizer/summary/notes fixture](../../benchmarks/fixtures/audio-quote-record.json) ·
[Index trials](../../benchmarks/results/audio-quote-index.json) ·
[Older writer refusal](../../benchmarks/results/audio-quote-storage.json) ·
[Native source seek/pause](../../benchmarks/results/audio-quote-native.json) ·
[Light](../assets/quote-audio-light.png) · [Dark](../assets/quote-audio-dark.png) ·
[Narrow](../assets/quote-audio-compact.png).

## Reproduce

After `swift build -c release`, compile the headless helper:

```sh
swiftc -O -parse-as-library -I .build/release/Modules \
  benchmarks/audio_quote_probe.swift .build/release/OSprCore.build/*.o \
  -lsqlite3 -o .build/release/audio-quote-probe
.build/release/audio-quote-probe verify benchmarks/fixtures/audio-quote-record.json
.build/release/audio-quote-probe benchmark
```

`inference CHECKOUT AUDIO SHA256` runs local models against an explicitly supplied
public fixture and verifies its hash before processing. Keep the guardian next
to the helper. `HF_HUB_OFFLINE=1` requires complete pinned caches; models are
separate downloads. Missing weights and an initially missing sibling guardian
stopped earlier attempts; no runtime guard was weakened to obtain the passing run.
`verify RECORD NEW-DIRECTORY` optionally creates a fresh disposable schema-6 store
for the retained older-reader check. It refuses existing directories.

## Open acceptance work

Native selection changes/races, VoiceOver and long-recording responsiveness;
real word-timestamp coverage across engines/languages; alignment coverage and
acoustic boundary error on diverse recordings; user correction/review effort;
lower-memory and older-macOS checks. Summary truth/completeness, physical capture,
insertion, consumer comparisons, energy and notarized distribution remain separate
v0 gates. This feature does not establish full parity or a top-three ranking.
