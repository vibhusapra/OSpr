# OSpr measurement protocol

## Import/export and malformed-media recovery

`verify_file_import.py` rehashes retained native output/layout evidence and checks
nine complete export directories, ID preservation and edited/original boundaries.
`--native-source` additionally rehashes the historical Git source checkpoint when
that object exists locally. CI does not rerun UI/ASR or claim remaining native
drop/cancel/VoiceOver acceptance. `media_recovery.swift` exercises the
actual Swift IPC worker with cached speech before/after malformed input. Retained
Parakeet/Whisper controls preserve PID, warm state and exact text; no timing rank.
See [the implementation and reproduction](../docs/architecture/file-import-workflows.md).

## Native consumer file-import pilot

`native_file_comparison.py --verify results/native-file-comparison.json`
recomputes the official MacWhisper 15.8 GUI / OSpr v0 GUI twenty-case pilot from
retained native exports, without launching apps or running inference. Run it
from the repository root with the full path shown in
[the method](../docs/architecture/native-file-comparison.md).
The frozen manifest predates new comparator inference. All raw exports and hashes,
the first interrupted OSpr attempt and the full unchanged repeat are retained.
The shared scorer rejects incomplete/duplicate/foreign/tampered cohorts. Rounded
consumer timing and OSpr processing timing are not used for a speed ranking.
VoiceInk 2.21 is unmeasured behind required onboarding permissions.

## Local text model choice

`refinement_eval.py --model rewrite-quality|meeting-quality` replays the same 36
public synthetic cases on pinned 4B/9B models. `refinement_guard.swift` replays
saved output through the actual Swift guard. Raw model and delivered lexical
checks remain distinct from semantics. The observed 9B name-accent loss is now
rejected; canonical Unicode remains allowed. Source guards retain 36/36 lexical
sentinels with six 4B and three 9B fallbacks. No general model promotion follows.

`local_model_cli.py` checks ten fake-child/admission/fallback contracts and two
optional actual inferences; `--contracts-only` runs without weights.
`local_model_mcp.py` checks actual local tool schema and both model selections.
`local_model_preparation.py` supplies a disposable cache namespace containing only
Parakeet and verifies real Swift IPC missing-9B rejection without download or ASR
eviction. All use cached public models/text/audio, no UI/history/providers.
See [the contract and limits](../docs/architecture/local-model-choice.md).

## Local text completion controls

`local_completion.py` compares identical prompt/budget old-string/new-EOS output
on cached pinned 4B/9B models. Eight completed controls retain identical text;
two deliberately budget-limited valid-JSON answers fail the EOS gate. The
`_verify-local-completion <public-audio>` Swift CLI probes a real output limit,
then verifies the same worker PID, resident speech model and unchanged warm ASR.
These are completion/residency checks, not semantic quality or comparative timing.
See [the contract](../docs/architecture/local-completion.md) and retained JSON.
The summary harness defaults to EOS; `--completion legacy` reproduces historical
string-only runs. Earlier summary receipts remain historical and unchanged.

## Final-ASR neural edge pipeline

`neural-final-edges.json` freezes source `efe99b4`: six engines, 110 known public
inputs, 1,320 full/edge routes, 1,278 actual recognitions and 42 detector
abstentions. The original 104 cases and their causal bounds come from the prior
33-speaker VAD study. Six unequal-gain stereo transports reuse one speaker's
original/quiet audio and a tone at 44.1/48 kHz. They do not add independent speech
samples. The production app/CLI path normalizes, scans exact float samples,
checks their complete hash, slices only outer edges, and restores original
timestamps. Raw hypotheses, including regressions, are retained.

Run from the frozen source with its release CLI, cached weights and a fresh work
directory/output name:

```sh
HF_HUB_OFFLINE=1 PYTHONPATH=backend uv run --frozen --all-extras python benchmarks/neural_edge_validation.py \
  --cli .build/release/ospr-cli --work .local/new-neural-edge-run \
  --output /tmp/new-neural-edge-result.json
HF_HUB_OFFLINE=1 PYTHONPATH=backend uv run --frozen --all-extras python benchmarks/verify_neural_final_edges.py \
  --work .local/neural-edges-frozen-efe99b4 --cli .local/vad-candidates/source-efe99b4-cli \
  --output /tmp/neural-edge-checks.json
```

The verifier rehashes all 110 local waveforms and the frozen CLI, checks every
manifest, derives bounds from stored reference scores and recomputes WER/counts.
Six transport controls retain raw probabilities from the preserved earlier
`a09b6bd` CLI. Its hash/source is bound to the existing VAD study. The checks do
not rerun ASR or manually establish speech truth. The producer requires a clean
tracked checkout. See the source hashes and checker receipt before reproducing;
the preserved local binaries are not distributed model/runtime artifacts.

Every engine has per-utterance accuracy regressions; the option stays off by
default. Fixed full-then-edge ordering and diagnostic decoder timers cannot
establish native-analysis, end-to-end or comparative latency. Physical microphone,
native edge controls/recovery retry, device contention and insertion remain
separate acceptance work.

These are exploratory **engine** and native-IPC measurements on one Apple M5 Max,
40 GPU cores, 128 GB, macOS 26.6.2. They are not commercial-app rankings, full
LibriSpeech scores or proof of top-three product quality. Background desktop work
was present; energy and thermal conditions were not controlled. The final main
runs were executed sequentially to avoid competing GPU jobs.

## Reproduce

```sh
scripts/setup.sh
export PYTHONPATH=backend
.venv/bin/python benchmarks/prepare.py

# Official public archives (large; audio stays ignored by Git)
curl -fL https://www.openslr.org/resources/12/test-clean.tar.gz -o /tmp/test-clean.tar.gz
curl -fL https://www.openslr.org/resources/12/test-other.tar.gz -o /tmp/test-other.tar.gz
.venv/bin/python benchmarks/prepare_librispeech.py /tmp/test-clean.tar.gz
.venv/bin/python benchmarks/prepare_librispeech.py /tmp/test-other.tar.gz
.venv/bin/python benchmarks/prepare_fleurs.py

# First load downloads pinned model artifacts. Offline thereafter:
HF_HUB_OFFLINE=1 .venv/bin/python benchmarks/run.py --model parakeet-v3 --manifest fixtures/test-clean.json
HF_HUB_OFFLINE=1 .venv/bin/python benchmarks/run.py --model parakeet-v3 --manifest fixtures/test-other.json
HF_HUB_OFFLINE=1 .venv/bin/python benchmarks/run.py --model parakeet-v3
HF_HUB_OFFLINE=1 .venv/bin/python benchmarks/run.py --model qwen3-asr --manifest fixtures/fleurs.json

# Additional experiments
HF_HUB_OFFLINE=1 .venv/bin/python benchmarks/stream_replay.py
HF_HUB_OFFLINE=1 .venv/bin/python benchmarks/stream_replay.py --context-frames 1
HF_HUB_OFFLINE=1 .venv/bin/python benchmarks/ablations.py
HF_HUB_OFFLINE=1 .venv/bin/python benchmarks/rewrite_eval.py
.venv/bin/python benchmarks/speaker_bootstrap.py
.build/debug/ospr-cli benchmark /absolute/public-sample.wav parakeet-v3 30
python3 scripts/build-report.py
```

Preparers pin upstream revisions/digests and write fixture checksums; the English
archive preparer verifies official MD5 checksums. No Hugging Face access token is
needed for these public corpora. ASR model revisions and dependency versions are
pinned in `models.lock.json` and `uv.lock`. No weight files are checked in.

## Datasets and scoring

- `test-clean.json`: first five utterances per speaker in archive-path order,
  200 utterances / 40 speakers. `test-other.json`: same selection, 165 / 33.
  This deterministic selection is **not** random or the complete benchmark.
- `manifest.json`: 73 real LibriSpeech dev-clean recordings from the pinned HF
  dummy corpus; twelve additive 10 dB noise variants, twelve 0.1-volume variants,
  two empty-reference silence/noise cases, and one long concatenated recording.
- `fleurs.json`: first ten test rows in each of Spanish, German, Hindi, Japanese
  and Mandarin. Small multilingual smoke slices, not enough to rank languages.
- LibriSpeech and FLEURS audio are CC BY 4.0. Credit the original creators and
  use the manifest source links; don't train on a sealed evaluation set.

WER lowercases, removes punctuation and collapses whitespace with the same
normalizer for every backend. It does not expand numbers or normalize abbreviations.
CER additionally removes all whitespace consistently; character-spaced Chinese
references otherwise produce misleading scores. Japanese/Chinese whitespace WER
is not interpreted. Raw references and hypotheses are retained for inspection.
Errors remain visible and count in each suite's failure total. Silence bypass is
an **OSpr RMS gate**, not proof that an unfiltered model never hallucinates.

`statistics.py` publishes seeded 10,000-trial paired bootstrap intervals by
speaker. It resamples speaker clusters, then aggregates edit counts and reference
words. These intervals do not represent timing uncertainty, training uncertainty,
or real-world dictation generalization. A small point-estimate gap is not a win.

## Timing boundaries

- `run.py`: read/decode/downmix/resample, optional RMS edge trim and inference.
  A separate cold request includes model load and first decode/JIT, with already
  downloaded weights; warm statistics exclude it. Wall p50/p95 are across clips
  with different lengths, not repetitions of a constant workload. RTF aggregates
  wall seconds divided by input audio seconds.
- `native-ipc.json`: same 5.855-second public clip, 30 warm native CLI requests,
  owned Python worker and deterministic text rules. Excludes microphone, HUD,
  endpointing, rewriting, clipboard and target-app insertion.
- `cpp_baseline.py`: persistent Homebrew whisper.cpp 1.9.4, Metal flash attention,
  greedy decoding, four threads. Shared trim, but PCM16 encoding and HTTP are
  included; conversion and decoder differ from MLX. Supply the official
  `ggml-large-v3-turbo.bin` weights with `--weights /absolute/file.bin`. Checksum
  and command are retained. This is a runtime baseline, not a product test.
- GPU allocator peak is not RSS or total unified-memory usage. Process RSS has
  its own boundary. Do not compare these as equivalent memory quantities.

## Streaming, ablations and fidelity

`stream_replay.py` feeds 320 ms audio packets through the actual cached Nemotron
session. It does not sleep between packets. First partial is an **audio position**,
not measured wall latency; flush time is decoder work after close. Context settings
0/1 are exploratory, outside the default model configuration. Twenty clips are
insufficient for a ranking; native mic/IPC scheduling still needs device QA.

The in-memory versus FFmpeg frontend experiment alternates twenty trials on one
clip. It measures model-path overhead, not a device-wide speedup. The four RMS
thresholds are development diagnostics on a small known set; do not tune on the
held-out test slices. No lower threshold has been promoted solely for a better
small-set score.

`rewrite-fidelity.json` has twelve synthetic text cases per model. Exact substring
sentinels are a screening aid, with possible false failures for paraphrases and
false passes for added commentary. Read the raw outputs: both models have failures,
including dictated prompt injection. OSpr keeps raw text, defaults rewriting off,
and uses a native negation/number/content-loss tripwire. This is not semantic proof.
The tested Cohere converted-weight adapter has excessive deletions and is blocked
from the shipping catalog; its raw experiments are retained outside the main plot.

## Actual product comparison still required

Install the exact versions of Wispr Flow, Superwhisper, VoiceInk, Handy and other
references; record routing, model, plan, vocabulary, cleanup and language settings.
Replay identical public speech through a loopback input for dictation, and compare
file import separately. Use a fixed destination field. Timestamp hotkey, audio
start, first partial, speech end and **final insertion**. Report failure rate,
correction keystrokes, name/number/negation retention, clipboard and cursor safety,
RAM, battery/energy and sustained use. Run at least 30 warm repetitions and separate
cold trials. Published vendor latency claims cannot substitute for these runs.

Superwhisper’s [official CLI documentation](https://superwhisper.com/docs/get-started/cli)
provides `transcribe <file>` through its running app, with Pro required for file
transcription. Record the licensed plan and selected mode/model before using it.
The local CLI is not an independent inference backend; no Superwhisper timing or
score is included here without an actual app run.


## Warmup, speaker control and extractive notes

`warmup.py` alternates unprimed/primed order over three pairs of fresh processes
per model. Explicit Load now decodes a one-second synthetic tone and discards its
output. Compare both preparation cost and the first real request: work is moved
earlier, not eliminated. The single public utterance does not establish a general
speedup; all paired outputs matched.

`diarization_control.py` runs the pinned upstream NVIDIA checkpoint in float32 on
PyTorch MPS against the same four AMI `only_words` prefixes. Similar high DER
shows the problem is not unique to the MLX 8-bit conversion. Default postprocessing
and timing boundaries differ, so this is not a backend speed comparison.

`notes_eval.py` contains four synthetic transcript sentinels. A local model selects
IDs and code copies exact original spans; invalid IDs fail closed. Every required
deadline/price/negation/injection sentinel survived these four cases. Exact source
quotation prevents invented paraphrases, but selection can omit context or facts.
This is not an abstractive-summary quality benchmark or a natural-meeting relevance
study. Raw outputs are in `results/extractive-notes.json`.


## Complete sequential sweep and Cohere controls

After preparing the pinned fixtures and caching model weights, run:

```sh
OSPR_CPP_WEIGHTS=/absolute/ggml-large-v3-turbo.bin scripts/benchmark-all.sh
PYTHONPATH=backend HF_HUB_OFFLINE=1 .venv/bin/python benchmarks/native_ipc.py
```

The script runs six shipping engines on both English slices and the regression
set, then each model's selected supported-language slices. Cohere requires a
language hint and defaults to English; Hindi is not in its documented list.

`cohere_candidate.py` preserves the research procedure for the native-layout
full-precision/8-bit controls. The initial Swift-layout checkpoint lost two
utterances; both native-layout controls recovered them. The accepted 8-bit route
uses strict loading, one 35-second chunk at a time and a 512-token budget. The
full-precision control is research-only. Small point differences between the
native quantized/full-precision scores do not prove quantization improves WER.
Original upstream weights required access approval and were not downloaded; these
controls use public Apache-2.0 conversions with explicit source lineage.

## Voxtral Realtime research candidate

`voxtral_candidate.py` strictly loads the pinned public MLX 4-bit conversion in
`fixtures/voxtral-model.json` and checks large-artifact SHA-256 against upstream
LFS metadata. Pass its downloaded snapshot with `--model-path` and that manifest
with `--model-manifest`; it stays outside the shipping engine registry.

The same first twenty test-clean clips and 320 ms packets as Nemotron are replayed
at three preselected 160/480/960 ms delay settings. Raw deltas, admitted-audio
positions, per-packet compute, final flushing and hypotheses are retained. There
is no capture pacing or native UI/IPC. This harness feeds arrays directly, while
the Nemotron replay uses a temporary WAV for each packet. The first-word audio
position is not end-to-end display latency or the configured model lag. Full
English/stress/multilingual gates are required before considering app integration.

## History storage path

Run `.build/release/ospr-cli benchmark-history 10000 50` after a release build.
The deterministic synthetic archive compares the old synchronous full JSON write
on each edit with the new serial background writer, 300 ms coalescing and final
flush. Both include value mutation and 30-day retention filtering; final files
must be byte-identical. The receipt records source and executable hashes plus
the repository revision at run time. Fixed order and no filesystem/thermal
isolation; this measures storage admission, not SwiftUI frames or real typing.

## Retained audio pipeline

Run `.build/release/ospr-cli verify-audio-review <short-public-audio>` with cached
Parakeet weights. The disposable store verifies native archive leases, actual
local normalization/inference, a warm worker surviving a rejected tiny budget,
matching recognition, history/archive restart, AVFoundation audio-only tracks
and reprocessing after deletion of the original retained recording.
No sound is played and no real user history is read. The portable app harness
runs the same check through the bundled CLI from a relocated offline app.
Unit tests additionally verify sample-bit preservation, real MP4 audio extraction,
quota eviction, source immutability, ownership/path guards and stale load state.
These checks do not replace interactive playback or microphone acceptance.

## Exploratory system power

Install the official Homebrew `mactop` formula, then run
`HF_HUB_OFFLINE=1 PYTHONPATH=backend .venv/bin/python benchmarks/energy.py`.
The harness guards the inspected tool version (2.1.6), verifies the public
test-clean fixture hashes, warms each engine, and uses a fixed seeded random
model order. Each block has 20 seconds of resident-model idle, at least 30 seconds
of sustained serial inference, and 20 seconds of idle afterward. No other
benchmarks, packaging or downloads should run concurrently. Three seconds around
each transition are excluded from the sample means. Interior mean watts times
the full active duration estimates joules; subtracting the mean of the two idle
blocks produces a signed incremental estimate. Normalize by decoded input seconds.

Only an allowlist of power/temperature/thermal counters is retained. The tool's
process, port, network and device inventories are discarded before persistence.
No background service, HTTP endpoint, screen capture, fan setting, elevated
privilege or extra app permission is enabled. See the pinned
[monitor implementation](https://github.com/metaspartan/mactop/tree/1e314f047dd7b494f286b7118fea80b3006c41be)
and each receipt's tool, source and model fingerprints.

These are OS/private-API whole-system estimates, including monitoring and other
desktop activity. Sparse sampling, idle drift, thermals and shared-system noise
prevent calibrated app attribution, battery-life conclusions or a consumer-app
ranking. Maximum throughput differs from human-paced dictation. Published raw
outputs retain the decoded public speech for accuracy audit. The initial run also
includes the previously rejected Swift-layout Cohere conversion, explicitly
marked research-only; later default runs select the six shipping engines.

## Long-file completeness

Run `PYTHONPATH=backend .venv/bin/python benchmarks/long_session.py` to build
deterministic 10-minute and hour-long WAVs from the preselected test-clean clips.
It verifies source hashes, preserves whole utterances, inserts 250 ms of silence,
and records every source span and reference. Then run the existing harness with
`--manifest fixtures/long-session.json --no-trim --model <model>`.
This exercises chunk/token/resource limits with synthetic speaker joins and
repeated public speech. It is not natural-meeting or independent new-speaker
accuracy evidence. Check tail deletions and timeouts, not just aggregate WER.

## Bundled long-file regression gate

After building long-session fixtures and the standalone app, run
`PYTHONPATH=backend .venv/bin/python benchmarks/native_long.py --app dist/standalone/OSpr.app`.
It checks two separate cold Swift CLI / owned-worker / Metal requests on the
hour-long public fixture, offline from a foreign working directory. CLI defaults
use trimming and automatic language, unlike the explicit-hint/no-trim study.
The fixture-specific 5% WER regression gate rejects both former broken paths;
it is not a production accuracy SLA. Chunk metadata, sample counts, bounded
segment times and signatures are checked. Release packaging requires this
receipt to match the exact app build and CLI. These are functional checks,
with shared-system activity and cold startup; do not use their wall times as
a latency benchmark. They do not exercise native UI, permissions or sound.

## Long BYOK transport and input equivalence

Run `.venv/bin/python benchmarks/upload_parts.py --cli
dist/standalone/OSpr.app/Contents/MacOS/ospr-cli` on one line. An 80-minute public
FLOAT WAV exceeds the old 256 MiB recursive-decoding threshold. The real Swift
CLI and owned Python worker prepare private ten-minute-or-shorter PCM16 parts;
a loopback provider verifies every sample, full coverage, source immutability,
request sizes, timestamp offsets, repeated text and workspace cleanup. Responses
are deterministic sentinels, not ASR. No paid provider, UI or speed claim. Package
creation requires the bundled receipt to match its exact CLI and build metadata.

`OSPR_TRANSCRIPTION_KEY=<key> ospr-cli transcribe-cloud <audio> <base-url> <model>
[language]` uses the same multipart route. Keep real keys out of shell history;
supply them through a managed environment. Progress goes to stderr, final JSON
to stdout. Files up to four hours use serial independent calls; failure/cancel
returns no assembled partial result. Retry resends all parts and can cost again.
Speaker identity does not carry between independent provider jobs. Missing or
invalid segment times fall back to explicitly coarse part boundaries; missing
word timing is not invented.

Run `.venv/bin/python benchmarks/audio_equivalence.py` to compare all 515 fixed
short-suite inputs and default ASR cuts with the recorded pre-change baseline.
All normalized arrays and cut offsets match exactly. The receipt fingerprints
both normalizers/chunkers, manifests and each normalized array; it does not rerun
model inference or establish long-file quality.

For the native Deepgram adapter, run the same harness with `--provider deepgram`.
It uses `transcribe-deepgram`, binary WAV uploads, Token auth and the current
Listen response shape; every returned word and utterance offset is checked.
The receipt is `results/deepgram-upload-parts.json`. Release packaging requires
both provider receipts to match the exact bundled CLI and build. Both use only
loopback fixture responses and public speech; neither measures cloud ASR.

`ospr-cli transcribe-deepgram <audio> https://api.deepgram.com/v1 nova-3 [language]`
uses `OSPR_TRANSCRIPTION_KEY`. Blank language requests provider detection, which
may select another supported Deepgram model. The GUI supports comma/newline
vocabulary phrases for Nova-3; OSpr allows 100 phrases and the provider enforces
its own 500-token cap. Literal plus, ampersands and Unicode are tested. Smart
formatting and numeral conversion are disabled, fillers are requested, and cloud
speaker labels/summaries are not requested. Missing or invalid timing keeps the
text with explicitly coarse boundaries. Empty output does not fabricate a
silence verdict. See [contract and primary sources](../docs/data/deepgram-contract.json).

## Real product CLI pilot

`product_cli.py` compares actual fresh-process file commands: OSpr Parakeet,
OSpr Whisper Turbo and the official Vibe 3.2.2 desktop CLI, which forwards to
its bundled server. The first utterance from the first ten speakers in each
existing clean/other manifest gives 20 fixed cases. Three runs per case and
configuration produce 180 serial commands in seeded random order. Score only
repeat zero for quality; use all trials for timing and deterministic-text checks.

Download the official arm64 app archive and release metadata from
[Vibe v3.2.2](https://github.com/thewh1teagle/vibe/releases/tag/v3.2.2), verify its
published digest, bundle version, strict signature and notarization assessment,
and disable Vibe analytics in its documented `app_config.json` before running:

```sh
.venv/bin/python benchmarks/product_cli.py \
  --vibe-app /path/to/official/vibe.app \
  --vibe-release /path/to/vibe-release.json \
  --ospr-app dist/standalone/OSpr.app \
  --ggml-model /path/to/ggml-large-v3-turbo.bin
```

The retained pilot used the unmodified official release, with Metal confirmed
on M5 Max; its optional tensor API was unavailable, while Metal remained active.
Analytics were off. A network-denied bootstrap smoke was separate; the paired
measurements used ordinary CLI execution. Each command loads a fresh model
context, with already primed OS file/shader caches. Model download is excluded.
No GUI, microphone, endpointing, insertion, energy or fully uncached startup is
measured. Default language and trimming behavior differ; the two Turbo model
conversions/runtimes also differ. Twenty read-speech cases cannot establish a
general accuracy winner or a top-three product ranking. The first harness was
untracked when executed; its exact SHA is retained and the unchanged executed
source is committed alongside the results. See the raw `product-cli.json` and
`vibe-release-provenance.json` receipts.

`startup_imports.py --app <bundle> [--model parakeet-v3]` instruments the bundled
worker with Python import tracing, a public speech request and EOF shutdown.
It separates boot, first-request and exit observations and stores only module
timing records. The initial diagnostic attributes about 901 ms of inclusive
import time to `scipy.signal` during a roughly 1,121 ms boot. Cumulative imports
overlap; do not sum them or treat instrumentation as a latency benchmark. The
next optimization must also check real resampling inputs and first-use model
preparation, rather than shifting cost into the first microphone take.

The startup candidate uses a committed float32 Parakeet mel bank generated by
`librosa.filters.mel(sr=16000, n_fft=512, n_mels=128, fmin=0, fmax=8000,
norm="slaney")`. Its metadata records generation versions and both file/array
checksums. Unit tests compare the values against the independent upstream
reference and reject changed dimensions, damaged assets and invalid formats.
`parakeet_loader_equivalence.py` compares every parameter and all 515 public
texts/segments/word timings against upstream loading; this is an equivalence
check, not a latency measurement. `audio_equivalence.py` also exercises eight
mono/stereo controls at 8/16/44.1/48 kHz.

`frontend_startup.py --before <old-app> --after <candidate-app>` measures fresh
worker boot and public-file requests at 16/48 kHz, with and without explicit
preparation. Three trials per combination use seeded randomized serial order.
This checks where deferred resampling cost lands; it does not test a microphone
or provide a latency SLA. The portable-app check explicitly prepares all six
shipping engines at 48 kHz before release packaging.

The repeated `product-cli-after-startup.json` pilot has zero failures and all
180 texts match the original pilot. Parakeet p50 is 756.6 ms versus 1866.2 ms
before; Vibe rerun is 943.5 ms. Whisper Turbo shows no improvement (2107.9 ms
versus 1984.7 ms before). Shared-system timing changes are not isolated causal
effects. The worker controls show faster boot and more work during explicit
preparation; prepared public requests remain about 55 ms at both rates. An
unprepared native-rate request still pays the SciPy import cost. Preserve these
controls alongside the attractive 16 kHz command result.

## Indexed-history storage prototype

On `codex/indexed-history`, build the release CLI and run
`benchmark-history-index 100000 3`. It generates deterministic timing-rich
transcripts in a private, owned temporary directory. Each mode/trial uses a fresh
child process. Legacy JSON and paged SQLite must return identical top-100 IDs for
eight literal queries, aggregate counts and the selected detail hash. Migration
validates an ordered digest of every full payload. The app still uses JSON while
its asynchronous repository and paged UI integration are in progress.

`results/history-index.json` retains the 4 KiB-page result,
`history-index-4096-pages.json` an earlier same-fixture 4 KiB control, and
`history-index-8192-pages.json` the rejected page-packing experiment.
`history-migration-memory-before.json` extracts the original migration's raw
memory/time measurement before per-read autorelease pools bounded FileHandle
buffers. The initial full receipt is retained locally; the extract fingerprints
that receipt and the exact public source/fixture used.

Run `.venv/bin/python benchmarks/verify_history_index.py
benchmarks/results/history-index.json` for independent expected-ID/count/detail,
Git provenance and NumPy percentile verification. Optional `--cli <executable>`
checks the measured binary; `--baseline <receipt>` also checks the same fixture.
Three trials are exploratory. Timings exclude CLI spawn, SwiftUI rendering, app
launch, real user archives and human typing. RSS is the child's lifetime Darwin
peak; disk space and one-time migration costs are reported separately.

## SQLite compatibility control

`history_sqlite_compatibility.py --shell /absolute/path/to/sqlite-shell` accepts
multiple `--shell` arguments. The owned in-memory SQL extracts the app's actual
FTS schema/triggers and reproduces its insert, prune, edit, audio strip and delete
sequence. Schema v2 uses normal FTS DELETE before content changes. Controls also
load the pinned historical v1 schema to reproduce its stale format metadata,
exercise transactional empty/nonempty upgrades, full clearing and rollback-stable format metadata, and reject damaged current/legacy
indexes. The earlier merge-only diagnostic workaround did not cover empty
indexes; its limited receipt is retained as `history-sqlite-compatibility-v1-merge.json`. This is a correctness control, not a performance
comparison. `results/history-sqlite-compatibility.json` records all commands'
hashes, outputs, exact runtimes and source fingerprints.

The local controls were compiled from official SQLite amalgamations 3.42.0 and
3.43.2 (2023), 3.46.0 and 3.46.1 (2024), with `clang -O2 -DSQLITE_ENABLE_FTS5
shell.c sqlite3.c -o sqlite-shell -lm`. The system shell supplies 3.51.0. Inputs
are from `https://www.sqlite.org/<year>/sqlite-amalgamation-<version-number>.zip`;
downloaded C sources and compiled controls are not runtime dependencies of
OSpr and are kept under ignored `.local/sqlite-compat`; inputs are fingerprinted
in the receipt, and each test database exists only in memory. Full macOS 15 Swift CI
checks the real system-linked implementation independently.

## Session privacy / durability control

Build a fresh release CLI in the checkout and run
`ospr-cli benchmark-history-session 100000`. It creates the same deterministic
fixture as the indexed-history controls, migrates it in a separate child, then
uses another fresh child to disable and re-enable saving through the actual
asynchronous repository. Counts and ordered fingerprints of every complete
payload must match before, during and after the round trip. It also verifies
empty disk content/search while off, selected detail fidelity and file sizes.

This is one exploratory transition, with no percentile/SLA claim. Timings exclude
CLI spawn, migration, fingerprint verification, GUI and audio cleanup; lifetime
peak RSS includes the full memory snapshot and verification. A session-only
snapshot deliberately retains all currently visible records, using more RAM than
normal paged disk history. Source provenance requires the build checkout; keep
the freshly measured executable for optional hash verification.

The original control failed under its child watchdog; a sampled active stack
identified per-row FTS secure-delete work in full clearing.
`results/history-session-before-bulk-clear.json` records what was observed and
the missing exit-reason limitation, without inventing a completed timing.
`verify_history_session.py <receipt> --cli <measured-binary> --baseline
results/history-index.json` independently checks the subsequent complete receipt,
source/binary provenance, shared fixture, counts and round-trip payload hashes.

The current schema-v2 session receipt is `results/history-session.json`. The
earlier schema-v1 successful full-clear control remains in
`results/history-session-v1-bulk-clear.json`; with an earlier v2 preseed control in `results/history-session-v2-preseed.json`. These are exploratory single runs,
not a paired latency comparison. The original failed per-row control remains
separate. Every public receipt points to its exact measured source and binary.

## Indexed-history candidate artifact

`results/history-release-package.json` is the exact delivery manifest for source
`af59a186861c313ee07810cd345887adc8fcd436`, with 197 Swift/94 Python tests.
`history-portable-app-smoke.json`, `history-native-long-files.json`,
`history-compatible-upload-parts.json` and `history-deepgram-upload-parts.json`
pin checks to that artifact. This includes all six cached offline engines,
relocation/foreign Python paths, notes, speaker labels, mixing/preparation/MCP,
hour files, and every sample/time offset in both loopback 80-minute transports.
`history-native-ui.json` separately records the earlier source's generated-profile
UI acceptance. The final source adds the no-query audio-lease regression. These
are distinct boundaries; packaging does not imply microphone/shortcut/insertion
acceptance, notarization or a top-three product ranking.

## Preview cadence and native-rate packet diagnostic

The diagnostic describes the old stateless path. The later continuous normalizer
is checked separately below; cadence alone does not repair native-rate PCM.

```sh
PYTHONPATH=backend HF_HUB_OFFLINE=1 .venv/bin/python benchmarks/preview_cadence.py --cli .build/release/ospr-cli --output .local/preview-cadence-real.json
PYTHONPATH=backend .venv/bin/python benchmarks/verify_preview_cadence.py --result .local/preview-cadence-real.json --output .local/preview-cadence-checks.json
PYTHONPATH=backend .venv/bin/python benchmarks/stream_packet_normalization.py --output .local/preview-native-packet-normalization.json
```

The producer uses the actual Core schedule probe and six actual Nemotron sessions
on a repeated public input. Work costs and delivery times are modeled, not native
latency. First-partial regressions and increased request counts remain published.
The separate fifteen-case diagnostic exposes existing stateless native-rate
resampling differences; passing the 16k replay does not accept 44.1/48k continuity.
Use fresh output paths, a clean frozen checkout and cached model weights.

## Continuous native-rate streaming normalization

```sh
PYTHONPATH=backend HF_HUB_OFFLINE=1 .venv/bin/python benchmarks/stream_normalization.py --output .local/stream-normalization-real.json
PYTHONPATH=backend .venv/bin/python benchmarks/verify_stream_normalization.py --result .local/stream-normalization-real.json --output .local/stream-normalization-checks.json
```

The frozen protocol selects three known English clips, 44.1/48 kHz and two native
partition patterns before outputs. Thirty-six actual Nemotron sessions compare
continuous native packets, the old independent packet normalization and controls
normalized as a whole. All corrected PCM hashes and twelve final texts match
controls; all policies have 3.39% WER. All twelve legacy PCM hashes/counts differ.
Fifteen synthetic cases and two 120-second stress streams match exact whole-file
bytes with bounded resampler state. Every partial and final text remains public.
The independent checker reconstructs whole/legacy PCM and edit distances without
using the candidate class. This is an unpaced continuity regression, not physical
capture, end-to-end latency, energy, general accuracy or a product ranking.

## Native streaming stop and fallback boundary

```sh
PYTHONPATH=backend HF_HUB_OFFLINE=1 .venv/bin/python benchmarks/native_stream_stop.py --output .local/native-stream-stop.json
PYTHONPATH=backend .venv/bin/python benchmarks/verify_native_stream_stop.py --result .local/native-stream-stop.json --output .local/native-stream-stop-checks.json
```

Compiles the unchanged shipping `WorkerClient.swift` plus a separate benchmark
entry point, then runs a real owned worker with cached Metal Nemotron. Ten
scenarios cover normal/canceled packet admission, caller cancellation before
response, replacement/stale-cancel protection and full-file fallback after a rate
error, at 44.1/48 kHz. All text controls match; both timed cancellations are
observed between request and return. Six stop/final transcripts and both fallback
transcripts have zero WER on one known clip; replacement controls both retain
5.88% WER due to `Mr.` versus `MISTER`. No scoring normalization changes.
The independent checker verifies ordering, sources, text controls and edit
distances. This does not operate the microphone, Capture/AppModel, UI, insertion
or physical shortcuts. See `docs/architecture/native-stream-stop.md`.

The `--app <bundle>` option sends these same requests through its bundled engine
using the unchanged compiled native client source. Exact-build receipts live in
`results/streaming-native-ipc/`; temporary trace filenames are preserved there.
This does not run the app GUI or its compiled CLI entry point.

## Checked streaming preview

The separate `dist/streaming-v0` preview is frozen at `3feaf65`. Its exact-build
portable, long-file, provider, native IPC and package receipts are linked by
`results/streaming-package-gates.json`. All 168 bundled help links pass. The first
candidate omitted a linked SRT; timed exports and recursive receipt assets are
included by the bundler, and CI now checks every bundled report link. Older
previews are preserved. Apple Development signing does not provide notarization.

```sh
.venv/bin/python benchmarks/bundled_defaults.py --app dist/streaming-v0/OSpr.app --output .local/streaming-mcp.json
```

This invokes the exact bundle's real MCP server on original and -40 dB public
German speech against known full-audio text/PCM controls, plus exact-zero input.
The pinned MCP client uses `is_error`. Native UI/capture is not exercised.

## Runtime footprint and frontend sensitivity

```sh
.venv/bin/python benchmarks/runtime_footprint.py --app dist/streaming-v0/OSpr.app --output .local/runtime-footprint-smoke.json
.venv/bin/python benchmarks/runtime_footprint.py --app dist/streaming-v0/OSpr.app --protocol benchmarks/fixtures/runtime-footprint-full-protocol.json --output .local/runtime-footprint-full.json
PYTHONPATH=backend .venv/bin/python benchmarks/verify_runtime_footprint.py --result .local/runtime-footprint-full.json --protocol benchmarks/fixtures/runtime-footprint-full-protocol.json --output .local/runtime-footprint-full-checks.json
PYTHONPATH=backend HF_HUB_OFFLINE=1 .venv/bin/python benchmarks/qwen_frontend_precision.py --output .local/qwen-frontend-precision.json
PYTHONPATH=backend HF_HUB_OFFLINE=1 .venv/bin/python benchmarks/verify_qwen_frontend_precision.py --result .local/qwen-frontend-precision.json --output .local/qwen-frontend-precision-checks.json
```

These are isolated research probes, not a reduced package. Torch absence preserves
all smoke features and 203/204 broader text pairs but changes one Qwen proper name,
raising its twenty-clip English WER from 2.63% to 2.86%. All 52 multilingual and
30 nonspeech outputs match; zero API errors across 422 requests. A same-model
diagnostic reproduces the spelling change with the alternative feature backends.
The checked app/default runtime remains untouched. Every output and an independent
PCM/edit-distance checker remain public. See `docs/architecture/runtime-footprint.md`.


## Qwen duplicate frontend work (opt-in; latency gate failed)

```sh
PYTHONPATH=backend HF_HUB_OFFLINE=1 .venv/bin/python benchmarks/qwen_feature_reuse.py --cli .build/release/ospr-cli --output .local/new-qwen-reuse.json
PYTHONPATH=backend .venv/bin/python benchmarks/verify_qwen_feature_reuse.py --result .local/new-qwen-reuse.json --output .local/new-qwen-reuse-checks.json
```

The producer requires a committed clean source tree and fresh output paths.
The frozen 35-case/three-repeat paired protocol compares exact transcript/timing/
language payloads; four native ABBA blocks have thirty warm calls each after a
cold call. The gate is a strictly lower native p50 and p95 within +5%. Both the
feature cache and integer-only prompt-accounting trial fail that gate despite
removing duplicate frontend work. No speedup or checked-package promotion.
Default generation installs no hooks. Only explicit `OSPR_QWEN_FEATURE_REUSE=1`
enables the supported experimental chunk path; `0` counts original work.
The checker recomputes inputs, pair order, payload/counter equality and quantiles
without rerunning ASR. See `docs/architecture/qwen-prompt-accounting.md` and public
`qwen-feature-cache{,-checks}.json`, `qwen-prompt-accounting{,-checks}.json`, raw
traces and the incomplete-attempt index `qwen-reuse-attempts.json`.

## Apple system speech versus resident MLX (research helper, macOS 26+)

```sh
swiftc -O -parse-as-library benchmarks/apple_speech.swift -o .local/apple-speech
PYTHONPATH=backend HF_HUB_OFFLINE=1 .venv/bin/python benchmarks/apple_speech_eval.py --binary .local/apple-speech --output .local/new-apple-speech.json
.venv/bin/python benchmarks/verify_apple_speech_eval.py --result .local/new-apple-speech.json --output .local/new-apple-speech-checks.json
.venv/bin/python benchmarks/apple_speech_contracts.py --binary .local/apple-speech --output .local/new-apple-speech-contracts.json
```

Commit source before the producer and use fresh output paths. The helper's
`serve en_US` explicitly prepares system model assets, which may download; its
`inventory` command only reads capability/locale state. No microphone or UI.
The frozen 365-English/5-nonspeech comparison rotates serial route order, with
separate resident Parakeet, Cohere and Whisper Turbo Engine instances. Same
full audio/hint and conservative WER rules; no model-specific number expansion.
Apple uses its native file API over a JSON pipe; MLX uses direct Python calls.
This is not a matched consumer-app or microphone latency ranking. Opaque Apple
weights/compute units can change with OS-managed updates. No app/default/package
promotion. See `docs/architecture/apple-speech-eval.md` and public raw/check receipts.

## Explicit text-model preparation

`text_preparation.py --cli .build/release/ospr-cli --output <new.json>` runs three
alternating-order fresh Swift worker pairs/model with resident Parakeet, exact
first-rewrite timers, actual Clean receiver/fallback, same-PID/warm-ASR controls
and repeated-preparation checks. The first rewrite excludes preparation; combined
cost includes it. Every output and partial timing record is retained. One synthetic
rewrite and a 5.855s public speech control are development diagnostics, not product
latency, representative quality, battery or consumer ranking.

`text_preparation_cache.py` exposes only cached public Parakeet weights in a
disposable cache and verifies both text preparations reject without download or
speech eviction. `text_preparation_contracts.py` runs eleven actual Swift CLI
acknowledgement/admission cases with owned fake workers. `refinement_eval.py
--prepare-text` primes the current selected refiner before the development replay.
Source layouts and headless AppModel controls remain separate from native
acceptance. A separately signed isolated profile now passes Models preparation,
4B-to-9B replacement with speech retained, release/cancel and 9B Save/restart;
recording remains separate. See `results/text-preparation-native.json` and
`results/text-preparation-package.json` for exact source/package boundaries. A standalone `prepare-text` CLI invocation
releases its worker on exit; app preparation retains it for later dictation.

## Summary source fidelity and research variants

`meeting_summary_eval.py --protocol benchmarks/fixtures/summary-fidelity-protocol.json`
uses 18 new public synthetic development controls; the old 14-case protocol and
outputs remain. Select `--algorithm pre-fidelity|current`, `--decoding
unconstrained|xgrammar`, and `--encoding full|exact-references`; outputs must be new
paths. Grammar packages from `summary-research-requirements.txt` belong in a
separate research directory, not the application environment. The research-only
35B model is pinned in this protocol and absent from the application ModelLock.
`results/summary-fidelity-study.json` binds ten complete serial runs and raw calls.
Accepted-for-review is schema/source admission, not semantic quality. See
`docs/architecture/summary-fidelity.md` for timing/memory boundaries, review
observations, reproduction and open gates. No grammar/encoding/model promotion.

## Native worker lifetime

`worker_lifetime.py` builds a native owner and guardian, runs production Python
main with an injected GIL-held call and TERM-ignoring same-group decoder, then
intentionally kills only its owned owner. Two old/new ABBA observations reproduce
the leak and verify cleanup. Optional cached Parakeet controls interrupt a real
request and check fresh-process speech equality. Four separate cold/warm IPC
observations and diagnostic helper RSS snapshots disclose the added process cost;
no energy, equivalence, end-to-end dictation or product ranking follows.

See [contract/reproduction](../docs/architecture/worker-lifetime.md) and
[all retained attempts](results/worker-lifetime.json). Existing output directories
are refused. The durable batch process runner now observes production cleanup
before its own failure fallback and fails CI if the worker survives.

## Live audio privacy

`live_audio_privacy.py` runs an actual headless AppModel with cached Parakeet
using a fresh owned profile and explicit generation gate. Live revocation removes
new audio references without changing words/timing, preserves an older saved
payload/clip and survives a separate-process History restart. It checks the MLX
GPU device, selected installed library versions against the lock, all 29 backend
files and original public WAV bytes. This is one clip copied three times, not a
representative speech-quality, timing, energy or native-UI evaluation.

[Contract/reproduction](../docs/architecture/live-audio-privacy.md) ·
[All retained development/final attempts](results/live-audio-privacy.json).
Output and temporary test paths must be new. No microphone, playback, provider
API or existing profile is used.

## Saved-provider confirmation and identity

`native_provider_resume.py --stage ci --app dist/OSpr.app --output NEW_DIRECTORY`
starts an owned loopback provider with generated silence, prepares a separate
profile and runs the actual AppModel confirmation guard plus HTTP upload. Zero
requests precede confirmation or follow a model-only decline; one approved
request must preserve saved path/model/language/vocabulary/WAV hash. No model
weights, credentials, native app launch or recognition-quality claim. Server
readiness is atomic and its owned process is stopped before success. App/source/
runner/probe/compiled-test hashes are bound and existing outputs are refused.

The numeric loopback bind skips HTTPServer's reverse DNS lookup. A DNS-refusal
negative control fails before this change and passes afterward. Bounded owned
server/probe logs are printed on CI failure; no normal profile is involved.

`provider_resume_render.swift` optionally renders the actual batch component
offscreen; it does not operate a native dialog. The native warning/cancel/approve
and TextEdit gates remain open. [Protocol/reproduction](../docs/architecture/saved-provider-resume.md) ·
[Retained controls](results/saved-provider-resume.json) ·
[Layout receipt](results/saved-provider-resume-layouts.json).

## Full-meeting summary status study

`prepare_summary_status.py` freezes eighteen reused status controls and complete
AMI scenario meetings ES2004c/d, verifying exact-once manual-word coverage and
keeping human references separate from input. `meeting_summary_eval.py` exposes
the frozen `pre-status` baseline, production `current` citation feedback and
withheld `status-candidate` prompt. All six runs / 120 cases / 251 calls remain.
The status candidate is not promoted: schema admission improves on 9B while
material omissions/contradictions remain; 4B adds refusals. The production repair
feedback preserves validators but does not improve observed model outputs here.

`verify_summary_status.py` replays all raw calls through frozen implementations
without inference. Optional `--verify-prompts` checks cached pinned tokenizer
rendering and token counts, without loading weights. CI checks stored replay.
Neither mode proves semantic quality or authentic execution; all timings are
diagnostic, with early refusals doing less work. [Findings/reproduction](../docs/architecture/summary-status-fidelity.md) ·
[Run bindings](fixtures/summary-status-study.json) · [All-case review](results/summary-status-review.json).
