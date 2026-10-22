# OSpr v0 progress

Started 2026-10-22, from an empty repository. Branch: `codex/ospr-v0`.

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
  46-item acceptance ledger, model strategy, ten optimization tracks, training plan.
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
- [ ] Large-history launch loading and indexed search. WIP on
  `codex/indexed-history`: transactional SQLite, streaming verified migration,
  summary pages, on-demand detail, literal Unicode substring search and counters.
  Twenty storage regressions pass; the source suite totals 147 Swift tests.
  In six fresh storage-only processes on a deterministic 100,000-record archive,
  initial data p50 is 3.45 s for JSON versus 2.98 ms for the indexed prototype;
  median process peak RSS is 1.83 GB versus 17.6 MB. Matching IDs/counts/detail
  and every percentile pass an independent verifier. One-time migration takes
  32.34 s with 98 MiB peak after fixing retained FileHandle read buffers
  (earlier 892 MiB). Index disk size is 516 MB versus 304 MB of legacy JSON.
  An 8 KiB page control saved only 0.3% disk and had a larger observed migration
  peak, so the default remains 4 KiB. Raw results for both controls are retained.
  The current app and packaged preview continue using JSON. Serial asynchronous
  repository, paged UI/selection/search, session-only/privacy transitions and
  native acceptance remain before activation. See `architecture/indexed-history.md`.
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
