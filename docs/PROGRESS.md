# OSpr v0 progress

Started 2026-10-22, from an empty repository. Branch: `codex/ospr-v0`.

## Later validation: stop packets through the native worker boundary

A frozen standalone Swift harness compiles the unchanged shipping WorkerClient
and runs cached Metal Nemotron through its real owned Python process. All ten
44.1/48 kHz scenarios pass: normal packet/tail/flush, already-canceled caller,
cancellation between request and return, replacement with a stale cancel, and
full-file fallback after a sample-rate error/worker restart. All final texts
match controls. Six stop-path texts and both fallback texts have zero WER on one
known English source; both replacement controls retain 5.88% WER (`Mr.` vs
`MISTER`). An independent source/ordering/text-distance checker passes. The
probe and owned workers exit; the separate idle QA worker stays untouched.

This narrows the open IPC cancellation gate. It does not establish physical
stop, Capture/AppModel behavior, active GPU-kernel cancellation or UI/insertion
acceptance. No app/model/default/package changes. Final Mac CI at `0bc0acc` is
also green. Native QA cleanup still requires unlock; no new capture or playback
started. See `native-stream-stop.json`, raw traces/checker and
`docs/architecture/native-stream-stop.md`.

## Current work: continuous native-rate preview normalization

Branch `codex/stream-normalization` fixes packet normalization with a bounded,
phase-aligned FIR halo and explicit final tail. Native packets are validated
before decode allocation; sample-rate changes reject the preview instead of
mixing clocks. Cancel, replacement and successful finalization release state.
Full-file import normalization is unchanged. Preview stays opt-in.

All **230 Python tests** pass, including 52 new contracts across fourteen
supported native rates, clipping, tiny tails, random partitions, bounded retained
state, packet limits and engine lifecycle. A frozen real replay completes **36
Nemotron sessions**: three known public English clips, 44.1/48 kHz, two fixed
partitions, old/new/whole-normalized controls. Every corrected/control PCM hash
matches, and all twelve corrected final texts match controls. All policies have
3.39% WER; no accuracy gain is claimed. Legacy normalization differs in all
twelve PCM/count cases. Fifteen synthetic cases and two 120-second stress streams
also match exact whole-file bytes; retained raw state peaks at 507 / 73 samples.
The independent checker reconstructs source/legacy PCM, sample positions and edit
distances without importing the candidate normalizer. Mac CI at `aec096f` passes
310 Swift / 230 Python tests, lint, app/report build, clean-runner bundled imports
and signature checks. Draft PR: #14.

Native latency, energy, physical capture/rate changes, preview failure and stop
cancellation remain gates. The latest checked ZIP at 9a51603 predates this change;
no new standalone package is promoted. The approved public WAV was prepared in
QuickTime and the isolated old checked profile was warmed for a fresh TextEdit
focus handoff. No new recording or playback started. macOS then locked before
cleanup: QA is idle, normal app is stopped and restoration needs an unlocked
desktop. Normal settings/history hashes remain identical; zero QA recovery files.
See `stream-normalization-real.json`, its raw traces/checker and
`docs/architecture/stream-normalization.md`.

## Current work: stop preview cadence drifting with decode time

Branch `codex/preview-cadence` replaces sleep-after-work with monotonic deadlines,
keeps one request in flight, checks the generation again before snapshot and
shows a visible preview-failure message while preserving final fallback. Missing
session IDs no longer route incremental packets through offline transcription.
Preview remains off by default; request frequency/energy can increase.

Five scheduler tests and the complete **310-test Swift suite** pass. The release
CLI includes a bounded probe for the actual Core schedule. Release app/CLI,
**178 Python tests** and lint also pass. Six real Nemotron sessions preserve all
960,000 samples and return identical text (zero WER on one repeated public
sixty-second fixture). Independent schedule/metric checks pass. Request counts
increase; modeled first-partial delivery improves only at 40 ms work and regresses
at 120/600 ms. Those results remain published, without a native latency claim.

A separate fifteen-case diagnostic confirms a pre-existing native-rate packet
normalization defect: all ten 44.1/48 kHz cases differ from full-file PCM. At
1,024 native frames per packet, one second yields 16,021 / 16,031 normalized
samples instead of 16,000. Counts can also match while waveforms differ. All five
16 kHz controls match. The later source change above repairs continuous PCM normalization;
the cadence change alone did not establish native continuity or energy benefit.
See `preview-cadence-real.json`, its checker, `preview-native-packet-normalization.json`
and `preview-cadence-source-validation.json`. The current checked
9a51603 preview is unchanged and predates this source change.

The host-browser insertion alternative cannot proceed: native control of the
host Codex app is restricted, and macOS locks before QuickTime preparation. No
new take or playback starts; normal OSpr remains restored and QA is stopped.
Actual TextEdit focus still requires a fresh physical handoff after preparation.
See `docs/architecture/preview-cadence.md`.

## Latest native check: warning, exports and normal-app restoration

During an unlocked interval, normal OSpr is visibly restored with its eight
sessions/265 words and identical settings/history hashes. The generated TextEdit
space is removed and saved through native UI. The separate checked `9a51603` QA
build starts with existing permissions and warms locally. A real countdown take
again captures ChatGPT instead of TextEdit; it is immediately discarded before
ASR or public fixture playback. Positive insertion remains unverified.

The same isolated build imports the quiet public Japanese `ja_jp/005.wav` through
the native picker with Whisper Small/ja and both edge filters off. Studio and
History visibly show the timing-bound warning. Native SRT and JSON exports both
end at **6.960 s**, with JSON retaining the warning and 6.96-second duration.
Both exports are mode 0600. One public QA history record remains, zero recovery
files; QA/worker are stopped and the normal older app is visibly restored again.
Seeking, VTT interaction and physical microphone/shortcut/insertion/device gates
remain. See `full-audio-native-timing.json` and `docs/assets/timing-warning-history.png`.

## Current work: evaluate a local Voxtral streaming candidate

Branch `codex/voxtral-streaming-eval`, draft PR #12, adds a separate research
candidate for the remaining first-partial latency gap. Exact MLX 4-bit model
revision and all file hashes, runtime, options and 75 known inputs are frozen
before recognizer outputs: twenty English, fifty FLEURS in five languages and
five synthetic nonspeech controls, full-file plus 320 ms packet routes. No
shipping model/default changes; full-audio-v0 remains the checked preview.

The pinned weight download and all file hashes verify. Compatibility smoke passes
both routes with identical text. The complete study performs **150 recognizer
calls**, no API errors or early completions; all 150 normalized sample/hash checks
and independent WER/CER calculations pass. Seventy of 75 text pairs are identical.
One quiet Japanese source (`fleurs-ja_jp-005`, original RMS 0.00107) returns empty
in both modes. All five raw nonspeech controls stay empty in both modes.

English WER is 2.86% for both paths on twenty known clips; median first-partial
input position is 1.60 s and final flush is about 371 ms. This is not microphone
latency or an established win over the earlier Nemotron replay (1.28 s / 14.7 ms,
with a different driver and explicit English hint). Group WER/CER and every
partial remain published. Peak MLX allocation is 6,024,226,688 bytes, not total
process RAM. Raw/adapter retention still needs bounded integration work.

The standalone mel diagnostic completes twenty partition cases: all shapes
match, eighteen exceed fixed tolerance 2e-5, maximum difference 2.0528e-4. The
threshold is retained; this numerical failure alone does not establish ASR harm.
The unchanged speaker-bootstrap producer is renamed to avoid shadowing Python's
standard-library statistics during model imports. Lint passes; app-source CI at
`df0e19c` is green. No shipping model/default or new ZIP promotion. Native
interaction remains partly open; the later native check above verifies restoration and timed export.
See `voxtral-study.json`, its traces/checker, `voxtral-source-validation.json` and
`docs/architecture/voxtral-realtime-evaluation.md`.

## Previous work: preserve quiet audio by default

Branch `codex/full-audio-defaults` follows the timing fix. New or missing native
settings, CLI/worker requests and direct Python/MCP calls now use full normalized
audio without RMS or neural edge filtering. Explicit stored choices survive.
Exact-zero normalized input skips model loading; very quiet nonzero samples
remain eligible. Every empty result leaves completed recording recovery available,
including a silence flag. This does not fix partial ASR deletions or establish
native recovery/insertion acceptance. Older deliveries predate these changes.

Source checks pass **178 Python / 305 Swift tests**, lint, 17 profile CLI cases,
release build and signature checks. The fixed real-ASR regression passes all
**52 actual default requests** against prior full-audio text on source 000 in each
supported language, original and −40 dB, across all six models. Every request
recognizes the complete normalized range and returns identical text. The
selection was fixed before running. Results: `full-audio-defaults-real.json` and
`full-audio-defaults-source-validation.json`. Draft PR: #11.
Two real bundled MCP requests match original/quiet German full-audio controls.
A paired nonspeech check runs 60 default/RMS requests: false positives match on
both routes (Parakeet/Cohere/Nemotron 0/5, Turbo 4/5, Small 1/5, Qwen 2/5).
This is not a hallucination fix or a real-world false-positive estimate.
Source CI at `a147930` and the complete receipt/report head `3c07c02` are green:
305 Swift / 178 Python / 17 CLI cases, including
app/report build and clean-runner bundled imports. A fresh signed standalone
preview at `9a51603` has the same application fingerprint and passes relocation,
six-engine offline/neural checks, two default hour-file requests and all three
80-minute sample-preserving provider transports. Both additional neural hour
requests pass at the same 2.72% Parakeet / 2.37% Qwen WER. ZIP CRC, extracted
signatures and extracted CLI inventory pass. The archive is 391,502,064 bytes,
SHA-256 `e4ba51c3984e74454fc250c07e4243f6b58097151c8629ea17e09f8801cd42b4`.
See `full-audio-package-gates.json` and `full-audio-release-package.json`.
A later CUA restoration request reopens the exact normal-app process, but its UI
is unavailable while macOS remains locked. Visible restoration and cleanup of the
single generated TextEdit test space are still pending. Isolated QA is stopped;
normal settings/history hashes remain unchanged. No new microphone take,
playback, insertion or native recovery interaction occurred during this work.
The stopped isolated QA bundle is prepared from checked source `9a51603`, with
its own data directory and the existing signing identity, ready for later tests.
See `docs/architecture/full-audio-defaults.md`.

## Previous work: keep recognition timings inside analyzed audio

Branch `codex/asr-timing-bounds` follows the multilingual failure study. A common
local return-path guard now bounds segment/word estimates to the actual selected
source range and preserves transcript text. Unusable or wholly outside alignment
falls back to a visible approximate utterance range with word timing unavailable;
speaker attribution rejects missing word timing. History receives the warning.
The neural-edge description now warns about partial quiet/multilingual deletions.

Local checks pass **163 Python / 304 Swift tests**. The first full Swift run had
a 0.5-second fake-worker timeout failure during concurrent work; the focused
forced-termination test and a complete sequential rerun both pass. Worker code
and its timeouts were unchanged. Frozen-response replay passes all 1,010 actual
model responses and corrects all 12 overruns. A real paired old-bundle/new-source
check reproduces and corrects all twelve again across eleven inputs and 22 route
pairs (42 inferences, two detector abstentions), with every text string unchanged.
Source CI at `529359b` is green at 304 Swift / 163 Python / 17 CLI cases,
including app/report build and clean-runner bundled imports. The later native check above verifies warning and JSON/SRT export on one
public fixture; seeking and broader interaction remain open. The existing signed
neural-edges-v0 ZIP remains at source `2f7f2a8` and does not include this fix;
the later full-audio-v0 ZIP above does. See
`docs/architecture/timing-bounds.md`.

### Native preflight and pending restoration

During an unlocked interval, the idle normal app was quit through native UI and
the separate QA app was updated to source `873411d`, retaining the authorized
Apple Development identity and isolated data directory. Startup, prior
microphone/insertion permissions and native local model loading pass. The actual
TextEdit test field is visible. A modified-space simulation does not start
recording and adds one space. Two countdown attempts reject inconsistent
destination focus before microphone startup, including after AX Raise/direct
field click. No fixture plays, recording starts or transcript is inserted. Guards
were kept intact.

macOS locks again before the public-file warning/export check. Only owned QA
process/worker are stopped; QA has zero sessions/recovery files and normal
settings/history hashes are unchanged. **The normal app is currently stopped;
reopening it and removing the test space await manual unlock.** An asynchronous
unlock request is pending. The native preflight is partial, not acceptance.
See `benchmarks/results/asr-timing-native-preflight.json`.

## Exact final-ASR neural edges

### Multilingual follow-up: quality failure, not promotion

Frozen harness `ff80e98` uses the delivered source `2f7f2a8` CLI on all fifty
existing FLEURS clips, original and fixed −40 dB gain. Documented language
coverage excludes Parakeet Hindi/Japanese/Mandarin and Cohere Hindi before model
output is observed. Japanese/Mandarin use CER; the others use WER. All 1,040
routes finish (520 pairs, 1,010 actual ASR calls, 30 detector abstentions), but
there are **32 new empty transcripts**, including two nonempty detector ranges
whose ASR output becomes empty. Counts by model: Parakeet 1, Turbo 6, Small 7,
Qwen 6, Cohere 5, Nemotron 7. Partial deletions remain too: quiet German Parakeet
WER changes 4.10% → 22.13%, and quiet Mandarin Qwen CER 5.99% → 30.52%.

All 100 normalized waveform hashes and 520 ranges match independently recomputed
old-CLI controls. The new empty outputs are therefore a quality limitation of
the policy, not a range-transfer mismatch. The English slice's zero new empty
result does not generalize. These are small known read-speech slices, with no
new negative, spontaneous or real-whisper coverage. Defaults remain off. Keep
neural edges off for quiet/multilingual use while selection is improved.

The checker also exposes **12 Whisper intervals extending past the analyzed
range**, six beyond the complete source. One selected 0.8-second German range
receives a 29.98-second segment. A timestamp-boundary fix is next; the current
ZIP has not been changed. Original source/hypotheses and arithmetic failures are
preserved in `neural-edges-multilingual-v1{.json,.traces.json.gz,-checks.json}`.

Branch `codex/neural-edges` follows the neural capture/UI PRs. A separate opt-in
edge setting now uses pinned native CPU analysis on the worker's exact normalized
float32 audio, with full-waveform hash checks before recognition. It preserves
interior silence and original timestamp offsets and disables a second RMS trim.
It applies to local dictation/imports and timed ASR for speaker-labeled imports.
The CLI uses the same orchestration. Empty detector ranges retain completed
recovery; a new retry uses the full audio for one attempt. Defaults, normal app
data and the delivered preview remain unchanged.

Focused and full checks pass: **304 Swift / 141 Python tests**. Frozen source
`efe99b4` completes **1,320 routes** through six actual local engines on 110 known
inputs, with 1,278 inferences and 42 detector abstentions. All 660 ranges/PCM hashes
match their references, with zero new empty result across 618 speech/model pairs.
The checker rehashes every waveform and recomputes bounds and WER totals. The 104
frozen inputs reuse 33 English speakers/three transforms/five negatives; six
additional stereo transport inputs repeat one speaker and a tone. These are not
new held-out samples. Quality can regress: Qwen noisy WER rises 4.93% → 5.86%, while
Nemotron quiet WER falls 13.10% → 9.09%. Every hypothesis/regression is retained.
Native edge controls, recovery retry, physical shortcut,
microphone and insertion acceptance remain open. The latest insertion handoff
again encountered the macOS lock, before any recording was started. PR #8's final
head `12361fd` has green macOS CI including clean-runner packaging.

### New local preview

`dist/neural-edges-v0/OSpr.app` and its ZIP are frozen at source `2f7f2a8`, with
the same application fingerprint as the six-engine study. Apple Development
signing is preserved; this is not Developer ID/notarized distribution. Source CI
passes 304 Swift / 141 Python / 17 CLI cases. The 390,800,816-byte ZIP has SHA-256
`5bc611c311973507bdd0a10e5a3b22efb31f9f195db2d16c07f439b2e697b2d9`.

Actual copied-bundle offline checks pass all six ASR engines, all six native
neural-edge paths, detector abstention, nine inventories, source-excerpt notes,
speaker word attribution, mixing/upload preparation, history/audio review and
MCP. A path with spaces, foreign cwd and poisoned PYTHONPATH are exercised; 113
bundled help links resolve and signatures remain valid. Bundled MLX reports GPU
as default and Metal available. Both hour-file models pass with and without
neural edges, with identical WER in this repeated fixture (Parakeet 2.72%, Qwen
2.37%). Neural scans verify all 57,704,488 normalized samples before selection.
The three local fake-provider checks each pass nine exact-sample parts over 80
minutes, including owned Soniox cleanup. ZIP CRC, extraction, signatures and the
extracted offline CLI pass. These tests do not establish paid recognition,
natural-meeting quality or comparative latency/energy.

The normal app and previous previews remain in place. New neural options stay
off by default. Native controls/recovery/preview-to-final, microphone/shortcuts,
insertion, devices, clean-Mac distribution and updater acceptance remain open.
See `benchmarks/results/neural-edges-package-gates.json` for bound receipts.

## Working implementation

- [x] Native SwiftUI Studio, History, Models, Dictionary, Modes, Settings,
  Research, menu bar and nonactivating recording HUD. Initial window visually
  inspected; native public-file/review/export checks recorded. Latest setup/private TXT/SRT exports and microphone start/cancel/empty-result
  recovery/retry retested. Physical Fn/PTT and insertion acceptance remain open.
- [x] Parakeet v3, native-layout Cohere 8-bit, Whisper Turbo/Small, Qwen3 ASR
  and Nemotron local MLX/Metal paths.
  Pinned weights/dependencies; bounded resident ASR plus optional refiner.
- [x] Toggle and push-to-talk shortcut, visual shortcut editor, optional AX-gated
  Globe/Fn observer with chord/lost-release cancellation, duplicate/stale Carbon edge
  guards and capture-generation ownership. Default remains modified-key. Physical
  Fn acceptance is pending. Microphone choice,
  bounded off-callback recording writes, waveform, duration, auto-stop option.
- [x] Captured-target AX insertion plus clipboard fallback, clipboard restoration,
  secure-field rejection, app/field/cursor revalidation.
- [x] Local history, edit/search/copy/delete/retention, raw/edited text separation,
  vocabulary, literal snippets, opt-in spoken punctuation and app modes.
- [x] Local optional refinement, separate BYOK audio/text routes, native Deepgram prerecorded, compatible,
  Anthropic and Ollama paths, Keychain storage, no silent cloud fallback.
- [x] File and sequential batch import, FFmpeg media fallback, TXT/JSON/SRT/VTT.
- [x] Cached Nemotron preview/finalization; rolling preview for other models.
- [x] Completed-take recovery through inference failure/restart. Private audio,
  retry/export/discard; retry never inserts into a stale app target.
- [x] Native CLI and optional stdio MCP with explicit file/text tools.
- [x] GUI startup guard before model/store construction, private nonblocking
  interprocess lock, close-on-exec descriptor and legacy-instance activation. Four
  ownership/lifetime/symlink/process tests pass; native second-copy launch left one original GUI; foreground activation remains unproven.
- [x] Long BYOK imports normalize locally into contiguous PCM16 parts of at most ten minutes.
  Serial requests stay below 25,000,000 bytes including multipart framing; repetitions
  and timeline offsets are preserved. Failure/cancel returns no completed partial
  transcript. An 80-minute public fixture passed every-sample transport verification;
  provider responses were deterministic sentinels, not recognition. The native picker,
  Studio and persisted-history route also passed all nine parts and exact time offsets.
  Retry resends all parts.
- [x] Cancel now cancels the active processing Task as well as invalidating output;
  a delayed loopback-provider test verifies URLSession cancellation.
- [x] Model cache manager: eight pinned inventories with artifact size checks, download-only,
  prepared-byte progress, reveal in Finder and explicit engine memory release. Shared
  caches are never deleted by OSpr. Protocol/CLI tests and a real fresh-cache hub
  download passed; physical native interaction and large interrupted download pending.
- [x] Persistent debug logs off by default; private worker audio cleanup, including
  next-use cleanup of orphan directories owned by dead workers.
- [x] Explicit model loading primes first-use kernels with synthetic audio,
  discarding the output; paired fresh-process warmup measurements retained.
- [x] Reviewed cancellation keeps recoverable takes, credentials write only when
  edited, old settings gain defaults, shortcuts retain their previous binding on
  conflict, and the menu bar can reopen a closed workspace.
- [x] Current official-source guide: 27 offerings, plans, feature comparison,
  47-item acceptance ledger, model strategy, ten optimization tracks, training plan.
- [x] Relocatable app bundle; all six engines passed offline after moving it to
  a path with spaces, from a temporary cwd and with an unrelated PYTHONPATH.
- [x] Portable app rechecked after capture/notes changes: six offline ASR engines,
  exact-source notes, speaker word attribution, clocked track mixing, local upload
  preparation and MCP.
  Receipt includes the native executable hash and application build provenance.
  Bundled CLI/symlink discovery, poisoned PYTHONPATH/cwd isolation and signature
  validity after all inference/MCP calls also passed.
- [x] Apache 2.0 code license, attribution notice and macOS CI configuration.
- [x] Bundled long-file gate: separate cold Parakeet/Qwen hour-long requests passed
  offline from a foreign cwd, with chunk/sample/timing metadata and signatures.
  This is a functional regression check, not a latency or native UI benchmark.
- [x] Repeatable release packaging: matching exact-app portable/long-file receipts and test
  logs required; ZIP CRC, real ditto extraction, moved offline CLI and signature
  checks precede archive replacement. Only an Apple Development identity is
  available locally; Developer ID/notarization remains open.

- [x] History persistence moved off the editor path: 300 ms coalescing, serial
  writes, quit flush, unreadable-file protection and recording recovery retained
  until storage confirmation. Five ordering/failure tests; deterministic 10,000-row
  benchmark retains identical final bytes with one write instead of fifty.

- [x] Native Deepgram prerecorded API: binary mono audio, Token auth, Nova-3
  vocabulary keyterms, explicit/automatic language, utterance/word timing and
  preserved numeric/filler wording. A literal-plus query bug was found and fixed.
  Loopback contracts cover malformed timing/responses, late failure and cancellation;
  real CLI/worker 80-minute every-sample transport passed. No paid API, model-quality
  or cloud-streaming claim. Native picker/defaults, Keychain restart and 80-minute binary import/history with
  exact utterance/word offsets also passed. The Mac then locked: saved local-only
  defaults are restored and the loopback fixture server is stopped; restoring the
  running GUI preferences awaits manual unlock.

## Verification and evidence

- [x] Native tests: 127 passed, covering text fidelity rules, Unicode snippets, retention/storage,
  provider endpoint restrictions, multipart/chat/Anthropic loopback contracts,
  30 concurrent worker requests, timeout/restart, audio frame integrity/overflow,
  secure-field early rejection and recovery store restart/corrupt-metadata cases.
- [x] Backend tests: 94 passed, covering normalization, invalid/media input, real AAC/FFmpeg decoding,
  silence without loading weights, stdio recovery, MCP boundary, Cohere layout
  adapter and streaming session fencing/packet bounds.
- [x] Direct bounded Parakeet long-file decoding: no temporary WAV/FFmpeg round trip,
  no overlap token merger, preserved repetitions, independent and bounded word times.
  Hour-long synthetic WER 12.38% → 2.72%; 482/485 existing outputs identical.
  Four natural AMI controls had mixed WER changes and unchanged poor speaker DER.
- [x] Qwen long-file budget reset: contiguous low-energy chunks, fresh per-chunk
  token limits, no text deduplication, and explicit failure on exhausted budget.
  Hour-long output and memory improved; the ten-minute fixture worsened slightly.
  All 515 existing suite cases reran without errors; 512 outputs stayed identical.
- [x] Real human audio: deterministic 200 test-clean / 165 test-other slices,
  73 speakers, plus 100 regression/stress cases and small five-language FLEURS set.
- [x] Persistent Metal whisper.cpp runtime baseline on the same English slices.
- [x] Research-only Voxtral Realtime MLX 4-bit replay, pinned revision and upstream
  large-artifact SHA-256 verified: twenty shared clips at 160/480/960 ms delays,
  zero runtime errors. At 480 ms: 2.86% WER, 2.41 s compute p50 and 1.60 s median
  first-partial audio position. Nemotron's shared small replay was 4.30% / 0.15 s;
  this does not establish a quality winner, and the replay boundaries differ.
  Voxtral stays outside shipping pending broader quality/integration gates.
- [x] Cold/warm timings, raw hypotheses, versions, weights/corpus revisions,
  native IPC boundary, paired frontend ablation, RMS sweeps, cached packet replay,
  synthetic rewrite fidelity cases and seeded speaker-cluster bootstrap intervals.
- [x] HTML filters, benchmark rendering, feature-group interaction and desktop
  layout checked in the in-app browser. Narrow layout geometry fits without horizontal page overflow; first section visually checked.

- [x] Stable development signing retained Accessibility and microphone authorization
  across restart. A public speech playback was recognized through the microphone;
  destination labeling and app-switch insertion rejection were observed. Successful
  insertion still needs acceptance. Native BYOK save/restart/import passed with a
  dummy Keychain credential and exact public fixture against loopback; local
  preferences saved and verified again after restart. Permissions survived the signed
  update. No paid/provider recognition claim.
- [x] Normalized input samples and default ASR cuts are bit-identical across all
  515 existing short-suite cases after avoiding recursive FFmpeg decoding above
  256 MiB. This is input equivalence, not a model rerun.

## Release gates and remaining parity

- [ ] Live microphone reference-speech check passed; remaining physical PTT/toggle, selected device, device loss,
  auto-stop, interruption and sustained-session checks on an unlocked Mac.
- [ ] Target app matrix: TextEdit, browser, editor, secure fields, moved cursor,
  clipboard restoration and selection editing. Current code/tests are not this QA.
- [x] Native public-file import, history edit, playback clock/end/pause, 0.5×/2× rate,
  slider/segment seeking, reprocessing preserving edits, WAV and TXT/SRT export.
  WAV preserved full float samples. Manual transcript mode 0644 and setup/privacy
  copy issues were found, fixed and retested on the native build.
- [ ] Native recovery retry/export/discard, incremental streaming, recognizer-word
  seeking and human audible-output acceptance.
- [ ] Clean standalone installation, move/upgrade, signing/notarization and updater.
- [ ] Neural endpointing/VAD calibration, word alignment, deeper URL/app context.
- [x] Opt-in local audio review, speed/scrubbing, segment/word seeking and WAV
  export. Float WAV retains the full normalized timeline without imported video
  or tags; private size budgets, history expiry and audio-only erasure apply.
  Reprocessing uses the selected speech model and an independent private input
  copy, creates a new verbatim transcript, and keeps existing edits.
  Native Core/worker/Metal/store-restart/AVFoundation integration passed;
  native controls and WAV/TXT/SRT export exercised; human audible listening remains.
- [x] Paged large-history loading and indexed search. Implemented on
  `codex/indexed-history`: transactional SQLite, streaming verified migration,
  summary pages, on-demand detail, literal Unicode substring search and counters.
  Twenty-six database, eighteen repository and fifteen session regressions pass; the storage stage totals 186 Swift tests and passes macOS 15 CI.
  In six fresh storage-only processes on a deterministic 100,000-record archive,
  initial data p50 is 3.45 s for JSON versus 2.98 ms for the indexed prototype;
  median process peak RSS is 1.83 GB versus 17.6 MB. Matching IDs/counts/detail
  and every percentile pass an independent verifier. One-time migration takes
  32.34 s with 98 MiB peak after fixing retained FileHandle read buffers
  (earlier 892 MiB). Index disk size is 516 MB versus 304 MB of legacy JSON.
  An 8 KiB page control saved only 0.3% disk and had a larger observed migration
  peak, so the default remains 4 KiB. Raw results for both controls are retained.
  The serial asynchronous repository is implemented and tested, including coalesced
  edits, failed-write retry, deletion/clear barriers, whole-archive maintenance
  and canceled reads. Session-only snapshots, disk clearing/restore, failed privacy
  transitions, retained cleanup receipts and disk-space reclamation are tested. A
  VFS probe detects no file opens during in-memory work and detects its positive
  control. A 100,000-record transition attempt exposed slow per-row full-index
  clearing; a transactional bulk-clear route replaces it, with rollback/trigger
  restoration regressions. The revised 100,000-record round trip preserves every
  complete payload hash/count, with 1.46 s disable/clear and 291 ms restore in one
  exploratory trial. The empty disk archive is 48 KiB; lifetime transition-child
  peak is 633 MiB, explicitly above ordinary paged-history memory. Older SQLite special-delete format metadata failures, including empty indexes,
  are avoided through normal before-content FTS deletes and transactional v1
  upgrades. Forty-five controls across five runtimes still reject damaged indexes.
  Current source wires the repository into AppModel and a paged/debounced history
  UI, field-specific edits/notes, full-record copy/export, settings durability
  and an asynchronous quit barrier. Eleven presentation/application regressions add
  coverage for startup migration, complete details, selection and failed saves/quit.
  A separate 235-record native QA profile passes migration, full edits, pagination,
  session-only/restore, pending-edit quit/restart, complete TXT export and context
  copy through TextEdit. Every persisted full payload is verified. The application stage passes macOS 15 CI with 196 Swift/94 Python tests; the
  additional no-query audio-lease regression raises local coverage to 197 Swift
  tests. Distribution remains a developer preview; normal-archive upgrade and
  broader native workflow acceptance are separate from isolated history QA. See `architecture/indexed-history.md`.
- [x] Experimental speaker-labeled file imports with recognizer word timestamps;
  stitched-speech and natural AMI prefix measurements. Labels still need review.
- [x] Experimental ScreenCaptureKit desktop plus optional microphone capture, separate
  timestamped tracks, bounded writers, recoverable raw tracks and local FFmpeg mix.
  Physical capture/permissions and echo/device-route acceptance remain open.
- [x] Local extractive meeting notes: exact original quotations selected by a 4B
  model, validated source references/fingerprint, copyable Markdown and JSON history.
  Four synthetic coverage sentinels passed; natural relevance and context review remain.
- [ ] Improve diarization quality and evaluate complete abstractive summaries.
- [x] Watched-folder implementation, stability/deduplication/backoff/scanner tests;
  native folder selection, public-file ingestion, History save, four private exports
  and repeated-scan deduplication passed; large/interrupted queue matrix remains.
- [ ] Native webhook/automation destinations.
- [x] Exploratory rootless system-power experiment: six shipping engines plus the
  rejected legacy Cohere control, public speech, resident-model idle/load/idle,
  filtered telemetry, exact tool/source/model provenance and signed idle subtraction.
  Shared-system drift is visible; post-fix Parakeet power was inconclusive with
  another render active. No calibrated attribution or battery claim.
- [x] Actual released-product CLI pilot: official signed/notarized Vibe 3.2.2 and
  bundled OSpr, 20 preselected speakers, three fresh processes per route/case,
  180 seeded-random serial commands with zero failures. Vibe fresh-command p50
  0.93 s vs OSpr Parakeet 1.87 s / Whisper Turbo 1.98 s. Quality totals differ by
  one or two word errors among 485 reference words; no accuracy winner claim.
  Cache-primed process starts, different default preprocessing, no GUI/voice/energy
  or top-three ranking claim. Raw results and official-release provenance retained.
- [x] Profile and reduce the measured Parakeet cold-process startup gap.
  Initial import tracing found `scipy.signal` consuming about 901 ms inclusive
  during a 1,121 ms instrumented worker boot. The raw diagnostic is retained;
  candidate code now imports resampling only when needed and loads Parakeet's
  fixed, checksum-verified mel bank without constructing it through librosa.
  All 697 parameter arrays (627,052,166 values), preprocessor values and all 515
  public-suite texts/segments/word timings match upstream loading exactly.
  All 515 normalized inputs plus eight mono/stereo rate controls are bit-identical
  to the earlier audio path. Explicit preparation now primes 48 kHz conversion.
  The identical 180-command product pilot reran without failure: Parakeet p50
  1.866 → 0.757 s (59.5% lower), p95 0.805 s; Vibe rerun p50 0.943 s.
  Whisper Turbo did not improve (1.985 → 2.108 s). Every one of the 180 texts
  matches the earlier pilot. These are 16 kHz CLI file commands on a shared Mac,
  with primed OS caches; no GUI/microphone/top-three ranking claim.
  Twenty-four paired worker controls show boot around 1.10 → 0.21 s. Native-rate
  conversion is deferred on an unprepared 48 kHz request; explicit preparation
  now includes it, and prepared 16/48 kHz requests remain around 55 ms.
  Three trials per combination and one clip do not establish a latency SLA.
  The final development-signed bundle has the exact measured application-source
  fingerprint. Relocated offline checks pass all six engines and 48 kHz preparation;
  both cold hour-long requests and both 80-minute every-sample upload checks pass.
  Matching-receipt ZIP CRC, actual extraction, extracted signatures and offline CLI
  gates pass with 127 Swift / 94 Python tests. See `release-package.json`.
  The running older GUI remains untouched while the Mac is locked; its live provider
  reset and remaining native interaction acceptance still need an unlocked session.
- [ ] Equivalent installed consumer-app GUI/dictation benchmarks, correction effort and energy;
  broader speaker/accent/noise/spontaneous dictation and code-switching evaluation.
- [ ] Validate on lower-memory and older Apple Silicon hardware.
- [ ] Mobile/sync/LAN offload and enterprise administration are deferred tracks.

## Decisions from failed experiments

- The initial Swift-layout Cohere conversion lost utterances despite strict
  learned-weight coverage. Native-layout full-precision and 8-bit controls
  recovered them; the pinned native-layout 8-bit route passed the larger suites
  and is a new quality option. The legacy conversion remains research-only.
- Smaller Nemotron attention context increased compute without improving median
  first-partial audio position on twenty clips. Keep the model default.
- The 1.7B text model dropped substantive content. The 4B alternative still fails
  cases, including dictated prompt injection. Refinement defaults off; keep raw
  text and fail back conservatively. No guard is a semantic correctness proof.
- Small clean-English point-estimate gaps do not establish a model winner.
- No “top three” product ranking, full feature union parity, official leaderboard
  score, paid provider validation or battery-life result is claimed.

The machine-readable acceptance ledger is authoritative for feature status;
`research.html` is generated from that ledger and the raw measurement files.

- Native empty-speech microphone completion retained a recoverable take; retry kept it.
  Recovery exports now use owner-only staged copies off the UI thread, including
  raw-track metadata. Unfinished-take deletion now requires a native confirmation.
  Recovery export and canceling discard were retested; original bytes and owner-only
  permissions confirmed. Private microphone data is excluded from Git.

- Accessibility enabled for the exact packaged app; native Fn listener registration
  passed and modified-key default restored. Automated Control–Option–Space reaches
  the shortcut editor but did not exercise global delivery. Setup permission refresh
  and a visible recording destination label were added; native retest follows.

- Duplicate test bundle registrations caused ambiguous permission identity;
  macOS Show in Finder exposed the older copy. Build scripts now accept an
  explicit signing identity, keeping ad-hoc default for CI and anonymous builds.
  Local Apple Development signing passed. Different bundle CodeDirectory hashes
  retained the same designated requirement; signatures and source fingerprint
  verified. Exact-bundle Accessibility readiness survived GUI restart. Microphone
  prompting was delayed by macOS; native control then reported a locked Mac.
  Manual unlock/consent is pending. No physical insertion or global-key pass is claimed.

## Indexed-history candidate delivery

- [x] Source `af59a186861c313ee07810cd345887adc8fcd436` passes macOS 15
  CI run 39884037124 with 197 Swift/94 Python tests.
- [x] A new standalone candidate is at `dist/history-v0/OSpr.app`; the verified
  ZIP and SHA-256 manifest sit beside it. All six offline engines, preparation,
  notes/speakers/MCP, relocated runtime/help links, both hour-file models and
  both 80-minute multipart adapters pass on this exact artifact. CRC, extracted
  signatures and extracted CLI are verified. Versioned receipts start with
  `benchmarks/results/history-`; `history-release-package.json` pins the archive.
- [ ] Normal-archive upgrade and remaining microphone/Fn/PTT/insertion, streaming
  and system-capture native acceptance are separate. The normal preview’s stored preferences remain
  local MLX with refinement off; its archive was not used as a destructive fixture.

The package is a frozen source snapshot; the repository's newer prose ledger
clarifies SQLite acceptance. Native history UI acceptance was performed at source
`163a113`, before the subsequent audio-lease fix (covered by the 197-test suite).
This is an Apple Development signed macOS 26.6.2 arm64 preview, not a notarized
distribution or a claim of full union parity/top-three product placement.

## Native Soniox BYOK work

- [x] Source-level native Files/Transcriptions adapter, async model preset, app and
  CLI dispatch, locally prepared parts, token-derived word groups, bounded polling,
  cancellation, safe resource IDs, no-redirect credentials and cleanup warnings.
- [x] Eighteen Soniox contract/regression cases; total 215 Swift/94 Python tests.
  Deadline testing found and fixed an invalidated-session task-creation crash.
- [x] Source `4fae54b` real Swift/worker 80-minute loopback control: nine parts,
  all 76,800,000 PCM samples checked, token time offsets and all owned remote
  resources removed. Compatible and Deepgram regressions passed on the same CLI.
  Receipts: `soniox-upload-parts.json`, `soniox-compatible-regression.json` and
  `soniox-deepgram-regression.json` under `benchmarks/results/`. Fake provider
  sentinels prove transport, not real recognition, account quotas or latency.
- [x] Native Soniox picker defaults, dummy Keychain save/quit/restart/use, short
  public-file import and persisted text/times passed. Injected cleanup failure
  retains text and a History warning. Source `054de0b` also shows this warning in
  Studio after restart and discloses cloud charges in the footer. Dummy key
  removed, isolated app reset local-only/quit, fixture server stopped; normal
  preview settings/history remain unchanged. Receipt: `soniox-native-ui.json`.
- [x] Source `e9b196c` passes macOS 15 CI run 39891673474 (215 Swift/94 Python,
  report/app build and clean-runner standalone runtime). The later Studio-only
  fix compiled and passed native presentation checks; its CI is separate.
- [ ] Soniox long-file native UI, real account quality/quota and WebSocket
  streaming remain. See `architecture/soniox-byok.md`. The frozen history-v0 ZIP
  predates this source integration.
- [x] After manual unlock, the same-identity history candidate loaded its separate
  fixture profile with both permissions ready. The shortcut recorder accepted
  Command–Shift–Y, but neither that chord nor Control–Option–Space started capture
  via automated native key input, even with OSpr foreground. No global shortcut,
  PTT or insertion pass is claimed. The normal standalone app was restored; UI
  confirms Local MLX and refinement off, and normal settings/history bytes match
  the private pre-test backup. Its archive was not migrated or replaced.


## Soniox preview delivery

- [x] Frozen source `fb2ad6f` passes macOS 15 CI 39892523094: 215 Swift / 94
  Python tests, app/report build and clean-runner standalone runtime.
- [x] New `dist/soniox-v0/OSpr.app` includes Soniox and the Studio warning fix.
  Relocated offline checks pass all six ASR engines, notes, speaker attribution,
  track mix, review, preparation, MCP and 48 kHz model priming.
- [x] Both bundled synthetic hour files pass (Parakeet WER 2.72%, Qwen 2.37%).
  These are regression checks on repeated public speech, not natural meetings
  or a product latency comparison.
- [x] All three bundled 80-minute transports preserve every normalized sample,
  repeated text and offsets. Soniox deletes every owned fake job/file. The
  release gate also rejects stale builds, retained resources and missing deletes.
- [x] Verified ZIP: 383,131,695 bytes; SHA-256
  `fc1c5a5e6218465f574fef152ad43843eb1f0cbb0dc1568ca37e03405da057a9`.
  CRC, extracted deep signatures and extracted CLI inventory pass. See
  `benchmarks/results/soniox-release-package.json` and the `soniox-package-*`
  receipts. The bundled report is a frozen snapshot preceding these receipts.
- [ ] Full native microphone/shortcut/insertion, streaming/desktop acceptance,
  real-account quality/quota behavior, clean-Mac installation, Developer ID,
  notarization and an updater remain. No full feature union or top-three claim.


## Mouse-start dictation

- [x] Explicit three-second Studio countdown and nonactivating HUD; destination
  capture happens at the end. Microphone permission must already be granted.
  Password-field protection and original app/field/cursor checks still apply.
- [x] HUD/Studio cancellation, global-shortcut cancellation and quit teardown
  invalidate the timer. Staying in OSpr at expiry reports a destination error.
  Selected-text editing can use the focused selection at expiry.
- [x] Four timer regressions cover tick ordering, late cancellation/replacement,
  owner teardown and reentrant callbacks. All 219 Swift tests pass. The initial
  restricted run could not use loopback fixtures/isolated pasteboards; the
  authorized full run passes without skips. Source log is private under `.local`.
- [x] Source `643b631` passes macOS 15 CI 39915171803: 219 Swift / 94 Python
  tests, app/report build and clean-runner standalone runtime.
- [x] Same-identity native candidate retained both permissions. Countdown expiry
  started the real local microphone; native Cancel discarded three starts with
  zero history/audio retention. Normal preview restored; settings/history match
  the private pre-test backup. Receipt: `countdown-native-ui.json`.
- [ ] Native early countdown/HUD rendering, cancel before expiry, public acoustic
  auto-stop and successful insertion remain. App-bound TextEdit control and
  Bring All to Front did not change the captured macOS foreground app, so all three
  takes were discarded before recognition. After the human focus handoff the
  captured app was Google Chrome. Only a silent 0.1-second public-fixture
  playback preflight ran; no speech was played into an unintended target.
  The frozen Soniox ZIP and its 215-test evidence remain an older snapshot.

## Local refinement fidelity

- [x] JSON-quoted transcript data and explicit task routing separate ordinary
  cleanup from deliberate selection editing and extractive source-ID notes.
  Type/task/size validation happens before model loading; the pinned refiner,
  one-resident-model policy and source-selection output budget are unchanged.
- [x] Clean questions cannot lose every question mark; short inputs also receive
  expansion checks. Curly apostrophes and additional English negative
  contractions are recognized by the native preservation tripwire.
- [x] A source-verified old engine and final source `f8ba4a0` replayed the same
  36 synthetic cases with the actual Clean instruction. Raw lexical checks:
  28/36 → 31/36. All 72 raw outputs repeated exactly. The same current Swift
  guard rejected 12 old-prompt and six candidate outputs. All final lexical
  sentinels survived by using the original when rejected; this is not a semantic
  score or a measure of successful model edits. Raw negation/content losses remain.
- [x] Eight task smokes and two exact-span notes smokes passed on the cached local
  4B refiner. Five Swift guard regressions include all 72 recorded-output decisions.
  Local full validation: 224 Swift / 105 Python tests, lint, release app build and
  strict signature verification. Build source is clean `f8ba4a0`; the app is an
  ad-hoc development build. Receipts: `refinement-fidelity-v1.json`,
  `refinement-task-smoke.json`, `refinement-validation.json`.
- [x] PR #5 source/docs head `3b7ddb0` passes macOS 15 CI 40016038194:
  224 Swift / 105 Python tests, lint, app/report build and clean-runner
  standalone runtime. Decoded job 120628218162 logs confirm the counts.
- [x] A separate Apple Development signed portable candidate at `3b7ddb0` passed
  relocated/offline six-engine inference, notes, speaker words, audio utilities,
  model management/progress, native CLI review and MCP listing. Three explicit
  bundled Swift CLI rewrite smokes also passed from a foreign cwd with hostile
  PYTHONPATH. Receipts: `refinement-portable-app-smoke.json` and
  `refinement-bundled-cli-smoke.json`. Its bundled report predates these receipts.
  The subsequent hour-file/upload/package checks are recorded below.
- [ ] Representative, independently graded rewrite fidelity and native selection
  replacement remain open. The new prompt does not guarantee preservation;
  refinement stays optional/off. The frozen Soniox ZIP predates these changes.


## Countdown/refinement preview delivery

- [x] Frozen source `3b7ddb0` includes indexed history, Soniox, mouse-start
  countdown and explicit local refinement tasks. CI 40016038194 passes 224 Swift /
  105 Python tests, app/report build and clean-runner standalone runtime. Later
  receipt/docs head `ce06c48` also passes CI 40017019983 with the same counts.
- [x] The separately signed portable candidate passes relocated/offline six-engine
  and extras smoke plus three raw rewrite checks through its bundled Swift CLI.
  Its bundled MLX runtime reports GPU as the default device and Metal available.
- [x] Both bundled synthetic hour-file regressions pass: Parakeet WER 2.72%,
  Qwen 2.37%. All three 80-minute transports pass every-sample, repetition and
  timestamp checks in nine bounded requests each. Soniox removes all nine fake
  jobs/files with 36 matching lifecycle events. These are completeness/transport
  checks; timings are shared-system diagnostics, not product speed or provider quality.
- [x] Verified ZIP: 383,227,858 bytes; SHA-256
  `ae0415014b57769448263e4f97f03f1a8f7f591aec54ecb88213b583e1e33f2e`.
  CRC, extraction, deep signatures and extracted CLI inventory pass. Receipts:
  `refinement-release-package.json`, `refinement-native-long-files.json` and
  `refinement-package-{compatible,deepgram,soniox}.json`. The earlier Soniox
  package is preserved. The new bundled report predates these final receipts.
- [ ] The owned Chrome textarea and isolated native profile are prepared, but
  native control reported the Mac locked before candidate launch. No new native
  take or audio playback started, and the normal app was not quit or changed.
  See `browser-insertion-preflight.json`. Full native microphone/Fn/PTT/insertion,
  streaming/desktop acceptance, real provider accounts, clean-Mac installation,
  Developer ID/notarization and updater acceptance remain. No full union parity
  or top-three claim follows from this preview.


## App and site profiles

- [x] Source `2b7c02f` adds exact app/site rules, segment-bounded path prefixes,
  deterministic specificity/fallback and immutable per-take settings. Profiles
  choose writing mode, local model, recognition hint, Custom instruction and
  translation target. Provider endpoints/credentials, insertion and retention
  remain global choices. Imports/desktop capture retain their explicit settings.
- [x] The editor adds app selection, naming, enable/disable, edit and duplicate-rule
  validation. Studio reflects the active take's model/style; the HUD labels a profile.
  Legacy app-only settings decode; extended profiles encode inactive for older
  decoders so a site rule cannot silently broaden to its whole app.
- [x] URL lookup is opt-in by enabled site rule for that app, follows at most 24
  owned ancestors, selects the outer web area/window metadata and strips query/
  fragment before matching. It reads no page text/address-bar/clipboard data.
  An 80 ms admission deadline and temporary 10 ms per-object timeouts are not a
  measured latency SLA. AX ownership is checked before selected-text capture
  and before insertion; inconsistent initial focus prevents microphone start.
- [x] Full local validation: 244 Swift / 105 Python tests, lint and release build.
  Twenty new Swift contracts and 17 real dry-run CLI cases pass; the CLI harness
  is in CI. CLI resolution runs with an unavailable engine root and calls no
  model, microphone or provider. See `context-profiles-validation.json` and
  `context-profile-cli.json`; implementation references are checked separately.
- [x] Native startup and Modes presentation worked in a separate development-signed
  fixture profile with both permissions ready. The normal app was restored and
  settings/history match its private backup; zero QA history/audio was admitted.
- [ ] Add profile inspection crashed SkyComputerUseService, including full AX and
  screenshot attempts; OSpr stayed running. The disposable QA process was stopped.
  No sheet visual/save/restart, live Chrome/Safari URL, model/language switch or
  insertion pass is claimed. See `context-profiles-native-ui.json`. The existing
  `refinement-v0` archive is preserved and predates these source changes.

## App/site profile preview delivery

- [x] Packaged source/docs head `db0987a` passes macOS 15 CI 40024734584:
  244 Swift / 105 Python tests, 17 CLI profile cases, lint, app/report build and
  clean-runner bundled-runtime imports. Decoded job 120657954042 confirms counts.
- [x] New `dist/context-profiles-v0/OSpr.app` includes the profile implementation
  and has the same application source fingerprint as the locally tested `2b7c02f`.
  Relocated offline tests pass all six ASR engines, notes, speaker words, audio
  utilities, model management/progress, CLI review and MCP. Metal is available;
  the bundled MLX interpreter reports `Device(gpu, 0)` as its default.
- [x] All 17 profile cases and three raw rewrite smokes pass through the bundled
  Swift CLI. Both synthetic hour files pass again: Parakeet WER 2.72%, Qwen 2.37%.
  All three 80-minute provider transports preserve every sample and timestamp
  offset; Soniox removes all nine fake jobs/files. Timings and fake responses are
  functional diagnostics, not product speed or provider-quality measurements.
- [x] Verified ZIP: 383,408,121 bytes; SHA-256
  `2d1ab59699891f28a97e8240860c6b61a415380ec688cc00c032a833915a096e`.
  CRC, extraction, deep signatures and extracted CLI inventory pass. The 66,898
  archive entries exclude private test directories, stores and checkout markers.
  Receipts: `context-profiles-release-package.json` and
  `context-profiles-delivery-validation.json` bind the exact app and related checks.
  The bundled report precedes these final receipts; earlier previews are preserved.
- [x] An isolated same-identity copy retained both permissions and started the
  real microphone after countdown. TextEdit's owned fixture appeared focused to
  automation, but OSpr captured another foreground app. The take was discarded
  before recognition; no speech fixture played or insertion attempted. Zero QA
  history/audio/recovery remains. Normal app/settings/history were restored
  unchanged. See `context-profiles-insertion-preflight.json`.
- [ ] Native profile sheet/save/restart, real browser metadata and model/language
  routing, physical Fn/PTT, successful owned-field insertion, streaming/desktop
  acceptance, clean-Mac installation, Developer ID/notarization and updater remain.
  The preview is Apple Development signed, with separate model downloads.
  Full feature-union and top-three product placement remain unproven.

## Neural endpointing evaluation (work in progress)

- [x] Local compiled Core ML speech-probability adapter, explicit recurrent/context
  reset, strict shapes/precision/finiteness, reusable input arrays and serial API.
- [x] Audio-time endpoint policy with hysteresis, minimum onset, examined-silence
  budget, one-shot completion and fail-closed discontinuities. Twelve new native
  input/policy tests pass. A real WAV short read exposed 533 unread frames; the
  native input reader now drains the full declared sample timeline.
- [x] Actual Core ML reset, partial-padding and invalid-input controls pass for
  both pinned conversions. Compiled MLX CPU probabilities match the eager path
  within 1.5e-7 on the first public control. These are initial controls, not a
  completed corpus result or a calibrated production detector.
- [x] Model revisions/full file hashes and a preselected 179-case public protocol.
  The CLI can analyze a supplied local model; no model download or service occurs
  inside native inference. See `architecture/neural-endpointing.md`.
- [x] Frozen `5fc2bc8` completes 179 cases, 24 compute-eligibility probes and
  750 ASR quality records (520 actual model inferences, 42 unique bypasses and
  reused equal inputs). All 256 Swift/105 Python tests pass. The verifier checks
  every input/model hash, 537 native event replays and WER arithmetic. Raw traces
  are preserved in a 1.84 MB gzip archive beside `vad-candidate-v1.json`.
- [x] Native 32 ms CPU prediction p95 is 0.0759 ms on the shared M5 Max. Its
  candidate edge improves Parakeet original/noisy WER; −40 dB WER is 4.34% versus
  95.09% for default RMS edges, but two utterances still become empty. The
  candidate is not promoted. Auto-finish cuts remain a separate quality risk.
- [x] Freeze a causal eight-frame score and validate on excluded speakers; the
  completed follow-up below preserves failures and all ASR hypotheses.
- [ ] Bounded off-callback native capture/resampling, recovery and device tests.
  Delivered previews and the GUI retain their existing behavior.

## Causal-score excluded-speaker validation

- [x] Native causal scoring primitive with seven policy tests; total Swift suite
  is 263 passing tests. The native implementation matches all 89,377 stored
  development probabilities and every derived bound/event across 179 cases.
- [x] Fixed protocol: twenty additional clean and thirteen additional other
  speakers, three transforms each, plus five reused negative controls (104 cases).
  These speakers were excluded from VAD tuning, but appeared in older ASR research.
- [x] The score retains 224 ms of extra history, which is not a bound on delay
  under continuing weak evidence. A native counterexample test and corrected
  interpretation preserve that distinction. A raw 1.424 s control accounts only
  for the fixed history span; actual coverage and delays are recorded too.
- [x] Frozen `a09b6bd` replay and 3,432 quality records across Parakeet, Whisper
  Turbo and Cohere native 8-bit. Eleven input policies separate edges, endpoint
  cuts and combined chains; equal sample ranges are reused per model. Cached
  weights and process-start Hugging Face offline mode; 2,181 actual inferences.
- [x] Independent checker verifies all 104 input hashes, 12 VAD asset files,
  35,924 exact causal scores, 312 native/reference event traces, every ASR input
  range/reuse flag and score arithmetic. Separate CI passes 263 Swift / 105 Python,
  17 profile CLI cases, lint, report/app build and clean-runner runtime imports.
- [x] Causal edges and chains introduce no new empty transcript across the 297
  speech/model pairs. All 99 speech cases finish after their source clip end;
  five reused negatives never arm. Parakeet raw edges introduce one new empty.
- [x] Preserve tradeoffs: causal edge WER original/quiet/noisy is
  4.31/6.32/5.86% Parakeet, 4.01/5.55/6.32% Whisper Turbo and
  3.24/4.47/4.47% Cohere. Full-input controls and every hypothesis are retained.
  Causal chains suppress all five Whisper negative hallucinations, but no-trim
  and endpoint-only inputs hallucinate on all five. Edge improvements are not
  universal: Parakeet has 14 worse versus 10 better transformed utterances.
- [x] Actual causal finish delay p95 original/quiet/noisy is 1.48/2.07/1.79 s
  after source clip end (maximum 2.28 s). The raw 1.424 s control does not match
  those delays. Clip end is not a last-phoneme annotation; no microphone timing.
- [ ] Experimental bounded capture integration and physical-device acceptance.
  The candidate is eligible for an explicit experiment, not default promotion.
  Delivered preview and GUI remain unchanged. See `architecture/neural-endpointing.md`.

## Bounded neural capture integration (work in progress)

- [x] Optional capture sidecar with sixteen preallocated mono buffers and a
  separate 0.5 s queued-audio ceiling, including in-flight work. Inference and
  continuous normalization run on one owning queue, outside the hardware tap.
- [x] Retractable finish candidates and an atomic capture-ingress claim: a
  candidate cannot close recording while newer accepted audio remains queued.
  Resumed activity revokes completion. Model/queue failures disable only the
  optional monitor; the complete original/recovery writer remains independent.
- [x] Partial tails probe copies of recurrent, causal-score and endpoint state.
  Successful probes do not insert padding into the continuing model stream;
  failed probes remain poisoned. Real cached-model pilot: 1,320 successful probes
  preserve every probability in a 220-frame stream exactly, including reset.
- [x] Eighteen new tests bring the local Swift suite to 281 passing tests.
  Continuous AVAudioConverter output is sample-identical across irregular packet
  boundaries at 8/16/44.1/48/96 kHz. Race, overflow, close, inference failure,
  audio-copy ownership, partial-tail resumption and original-file preservation
  controls pass. A detector failure leaves every stereo sample in the original.
- [x] Frozen `ace21b8` functional replay: all 104 prior VAD validation cases at 16 kHz
  mono / 44.1 and 48 kHz unequal-gain stereo, each with steady and irregular
  packet sizes (624 routes). This reuses known fixtures; no new quality holdout,
  model tuning, ASR or physical device acceptance is claimed. All 624 routes
  complete: 594 speech variants arm/finish after source clip end and 30 repeated
  synthetic-negative variants never arm. Maximum finish delay is 2.340 s.
- [x] Stored-evidence checker rehashes 312 source/derived WAVs and five model
  files, checks all 255,236 packet frontiers and 35,652 candidate frontiers, and
  recomputes all summaries. Raw packet traces are retained in a 4.07 MB archive.
  Serial enqueue-through-drain p95 is 0.209–0.390 ms depending on format/pattern;
  this excludes hardware callbacks, UI polling, input file reads and ASR.
- [x] Source-bound macOS CI 40043053254 passes all 281 Swift / 105 Python tests,
  17 profile CLI cases, lint, report/app build and clean-runner bundled imports.
  The cached-model replay is separate from CI and remains a functional control.
- [x] Current source constructs the optional sidecar from a Settings opt-in.
  Models adds explicit pinned 0.91 MB detector preparation; recording startup is
  cache-only. Worker/native integrity gates reject same-size corrupt data.
  Runtime/init failures display manual-finish warnings and keep original capture.
- [x] Capture preparation runs off the main actor, rechecks the destination
  before opening the microphone, and uses per-session leases for cancellation,
  timers and late cleanup. A stale operation cannot stop a newer recording.
- [x] Neural preferences encode legacy auto-stop as off and preserve the user's
  RMS choice in a separate key. Every nondefault setting round-trips through the
  custom compatibility encoder; older settings keep neural mode off.
- [x] Local contracts at initial integration: 292 Swift / 112 Python tests and
  17 profile CLI cases pass; cache repair expands Python coverage below.
  Pin parity, explicit/corrupt download contracts, visible warning callbacks,
  destination changes, manual fallback and full settings persistence are tested.
- [ ] Package and exercise native Settings/Models controls in an isolated profile.
  Physical microphone/destination acceptance remains separate. Defaults and the
  delivered preview remain unchanged. Final ASR edges need their exact final
  normalized timeline and are not changed by the auto-finish option.

## Model cache repair and native controls (work in progress)

- [x] Real isolated-cache testing exposed a Hub SDK repair gap: force-download
  still returned a corrupt snapshot. Repair now stages/hashes known files into
  unique OSpr-owned versions and atomically publishes a locator. Shared snapshots,
  immutable blobs and prior native readers remain untouched.
- [x] Python suite passes 117 tests, including absolute IPC paths for relative cache configuration. Regressions cover same-size shared/owned
  corruption, new-version publication, locator traversal and symlinked managed
  directories. No SDK/network access occurs during cache-only preparation.
- [x] The real repaired asset passes independent native size/SHA verification.
- [x] Frozen `ef50c9a` passes a fresh disposable-cache preparation/corruption/
  versioned-repair reproduction and 1,320 actual Core ML CPU probes from the
  relocated model. SDK transfer caches may be reused; network bytes are not measured.
- [x] The exact source passes macOS CI 40047540458: 292 Swift / 117 Python tests,
  17 profile CLI cases, lint, report/app build and clean-runner bundled imports.
- [x] Isolated native Settings exposes the toggle and pause selection. Choosing
  three seconds and Save preferences persisted neural=true / silence=3, legacy
  auto-stop=0 and prior RMS interval=3. A screenshot captures Preferences saved.
- [x] Normal OSpr remained running with identical settings/history hashes. QA had
  a distinct identity, disabled services, auto-paste/history off, and zero audio,
  history or recovery records. Only the disposable QA process was stopped.
- [ ] macOS locked after Settings Save. Models-screen download and native restart
  are unverified; process cleanup is not a graceful-quit acceptance claim.
  Microphone, physical hotkeys, cross-app insertion and device acceptance remain.
