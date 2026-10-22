# OSpr measurement protocol

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
.venv/bin/python benchmarks/statistics.py
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
