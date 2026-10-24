# Native speech detection and endpointing research

The delivered context-profiles preview still uses its existing RMS trim and
optional RMS auto-finish. This work adds an offline Core ML detector and a shared
audio-time endpoint policy for evaluation. It does not yet replace microphone
endpointing, trim ASR input in the app, or bundle another model.

## Contracts

`CoreMLSpeechDetector` loads a supplied local compiled model. OSpr performs no
model download or conversion in this call; first-use preparation remains part of
the measured Core ML load/prediction costs. It accepts the conversion interface:
Float32 `audio_input` shaped `[1,576]` or `[1,4160]`, plus `[1,128]` hidden/cell
inputs. Outputs must be a scalar probability and two matching recurrent states.
The 64-sample context and both recurrent states reset independently for each
file/session. Input/state/probability finiteness and shapes are checked. An error
poisons prediction until explicit reset. The object is serial and must run off
the main actor and audio callback. Input arrays are reused; outputs are copied
before their prediction's autorelease pool closes.

`SpeechAudioInput` reads bounded 16 kHz mono audio, with no implicit resampling.
AVFoundation can return a short read before EOF: one real FLOAT-WAV control
declared 230,913 frames but returned 230,380 on the first read and 533 on the next.
The reader drains the complete declared timeline and rejects an early EOF,
non-finite samples, wrong rate, stereo, empty input and files over five minutes.
A native regression checks every float sample in an uneven 230,913-frame file.

`SpeechEndpoint` is a one-shot state machine. The fixed development policy needs
96 ms of consecutive probability >=0.5 to arm. After arming, >=0.35 refreshes the
speech boundary; 1.2 s of examined sub-threshold audio emits finish. These values
are preselected evaluation parameters, not a calibrated default. Initial silence
cannot finish a take. A missing/duplicate frame or invalid value fails closed
until reset. Timestamps count only actual examined samples; padded final input
and delayed inference cannot create unexamined silence. After finish, further
valid frames cannot emit another finish. Twelve native tests cover this policy
and input integrity; live capture integration has its own remaining gates.

## Reproduction

```sh
swift build -c release
.build/release/ospr-cli analyze-speech public-16k-mono.wav /path/to/model.mlmodelc cpu 1.2
uv run --frozen --all-extras python benchmarks/prepare_vad.py
PYTHONPATH=backend uv run --frozen --all-extras python benchmarks/vad_candidate.py \
  --output benchmarks/results/vad-candidate-v1.json
```

The evaluation downloads only pinned, hashed model data using the installed
libraries; it executes no repository-supplied Python. The prepared corpus has
179 cases: three variants of forty English utterances from forty speakers, five
synthetic negatives, four existing AMI prefixes and fifty FLEURS clips. Model
files and source/derived audio hashes are explicit. The full trace archive keeps
every probability, prediction timing and native event, compressed separately from
the readable receipt.

## First frozen result

Source `5fc2bc8` completed all 179 cases on an M5 Max with 128 GiB RAM, macOS
26.6.2. Local validation passes 256 Swift/105 Python tests. The independent stored
evidence check rehashes all 179 inputs and twelve model files, replays 537 native
event traces and recomputes all 750 ASR quality records. The records contain
520 distinct model inferences; equal sample ranges reuse a measured hypothesis,
and 42 unique empty ranges bypass inference.

| Detector | Input hop | Prediction p95 | −40 dB cases with an empty edge | Synthetic negatives arming | AMI only_words timing-proxy F1 |
|---|---:|---:|---:|---:|---:|
| Core ML v6.0 / CPU | 32 ms | 0.0759 ms | 2/40 | 0/5 | 0.793 |
| Core ML v6.2.1 / CPU | 256 ms | 0.1957 ms | 0/40 | 1/5 | 0.912 |
| MLX v6.2.1 / CPU | 32 ms | 0.1104 ms | 2/40 | 0/5 | 0.840 |
| RMS 0.003 reference | 20 ms | not measured | 37/40 | 4/5 | 0.616 |
| RMS 0.0005 reference | 20 ms | not measured | 1/40 | 4/5 | 0.773 |

These AMI masks label 70.6% of frames as speech; an always-speech predictor would
score F1 0.828 while also arming on every negative and never finding silence.
The unsmoothed 32 ms candidate's high precision trades away recall. F1 alone is
insufficient for choosing a writing-tool gate; complete utterances and false
finishes remain explicit checks.

The native 32 ms edge candidate improves observed Parakeet WER, but still loses
two complete attenuated utterances. It is **not promoted to an app default**.
The endpoint and edge experiments are distinct: the 1.2 s auto-finish replay can
still stop inside a read utterance; it does not understand semantic completion.

| Parakeet input policy | Original WER | −40 dB WER | Nominal 10 dB noise WER |
|---|---:|---:|---:|
| Full / no trim | 3.66% | 4.80% | 4.46% |
| RMS 0.003 edge | 3.43% | 95.09% | 4.46% |
| RMS 0.0005 edge | 3.31% | 8.00% | 4.46% |
| Native 32 ms edge | 2.06% | 4.34% | 2.97% |
| Native 32 ms endpoint cut | 5.37% | 6.17% | 4.46% |
| RMS 0.003 endpoint cut | 5.37% | 9.71% | 4.46% |

Every column is the same forty utterances with a defined transform. The gain
variant is electrical attenuation, not real whispering; noise is seeded Gaussian
at nominal SNR before clipping. Prediction timings exclude model load, three
prime frames, file I/O, resampling, scheduling and ASR. Requested GPU/ANE/all
eligibility probes are retained without claiming their actual device placement.
Native 32 ms and MLX versions differ, and the 256 ms model uses aggregation;
these measurements do not isolate a pure runtime or version effect.

- [Full result and every ASR hypothesis](../../benchmarks/results/vad-candidate-v1.json)
- [Compressed raw probabilities, prediction times and events](../../benchmarks/results/vad-candidate-v1.traces.json.gz)
- [Independent stored-evidence checks and hardware](../../benchmarks/results/vad-candidate-v1-validation.json)

A development-only follow-up applies an eight-frame causal noisy-OR score to
the stored native 32 ms probabilities. It removes both empty edges on this
development slice and still leaves all five synthetic negatives below threshold.
That is not a new ASR result or independent validation. Freeze the policy before
testing additional speakers, and preserve the original unsmoothed result.

The exact score is `s[t] = 1 - product(1 - p[j])`, over `j=max(0,t-7)..t`.
These correlated frames do not yield a calibrated probability. Each input stays
in history for seven extra hops (224 ms), while continued weak evidence may keep
the score active longer. A raw 1.424 s silence control accounts for the history
span but is not a fully latency-matched operating point; actual finish coverage
and delay must also be measured. Use the remaining twenty clean and thirteen
other speakers excluded from this VAD development slice; do not retune against
their outcomes. They are not a sealed ASR holdout, because the existing broader
ASR research already used their source manifests.

[Reproducible development derivation](../../benchmarks/results/vad-causal8-development.json):

```sh
PYTHONPATH=backend uv run --frozen --all-extras python benchmarks/derive_vad_causal8.py \
  --source benchmarks/results/vad-candidate-v1.json \
  --cli .local/vad-candidates/source-5fc2bc8-cli \
  --output /tmp/vad-causal8-development.json
```

The CLI must match the source receipt hash. The preserved local binary is for
rechecking this frozen run; rebuild source `5fc2bc8` for a separate reproduction
and regenerate both source and derived receipts with that binary's own hash.

The matrix requests CPU, CPU/GPU, CPU/ANE and all compute eligibility for the two
Core ML conversions. Three seeded serial probes per choice separate model load,
prediction and command-wall time. Full corpus runs compare native 32/256 ms, MLX
32 ms on an explicit CPU stream, and two RMS thresholds. MLX compilation is
checked against its eager implementation on the first complete input. Both
native models receive actual reset/padding and invalid-audio controls.

The downstream quality check uses actual pinned Parakeet inference for full
audio, two RMS edges, the primary native edge candidate and both default-RMS and
native endpoint cuts. Identical sample ranges reuse one measured hypothesis;
these are quality checks, not ASR latency measurements. Native and model-version
effects are confounded: the native 32 ms artifact is v6.0, while the other two are
v6.2.1. No winner is assumed before these checks.

## Remaining integration gates

- Preserve the completed excluded-speaker results below without retuning against
  their outcomes; separately test any changed policy on fresh evaluation data.
- Select and pin a model only after the quality/runtime tradeoff is understood.
- Feed a bounded off-callback native queue with continuous resampling and sample
  accounting; overflow, stale generation and detector failure must surface.
- Preserve the complete original recording and its recovery metadata. Evaluate
  neural edge bounds separately from auto-finish; never remove interior silence.
- Exercise microphone/device changes, actual pauses, quiet speech, background
  noise, ASR/preview contention and a sustained session before changing defaults.

## Excluded-speaker protocol

The [second protocol](../../benchmarks/fixtures/vad-causal8-validation-protocol.json)
fixes 104 cases, the causal score, raw 1.2/1.424 s controls and eleven ASR input
policies before their outcomes are inspected. It includes both endpoint-only and
endpoint-plus-edge chains. Parakeet, Whisper Turbo and Cohere native 8-bit each
evaluate the same sample ranges/settings; equal inputs may reuse a hypothesis
within that model. Source audio and the complete original recordings stay intact.

```sh
uv run --frozen --all-extras python benchmarks/prepare_vad_validation.py
HF_HUB_OFFLINE=1 HF_HUB_DISABLE_TELEMETRY=1 PYTHONPATH=backend \
  uv run --frozen --all-extras python benchmarks/vad_causal_validation.py \
  --cli .build/release/ospr-cli --output benchmarks/results/vad-causal8-validation.json
```

Prepare pinned models separately first. The harness checks the imported offline
constant, rather than setting an environment variable too late after the Hub
library is imported. This controls Hub access; it is not an OS network sandbox.
The seven native score tests include a sustained weak-evidence counterexample.
The full suite currently passes 263 Swift tests. No GUI/default promotion follows
from this protocol alone.

## Excluded-speaker results and decision

Frozen source `a09b6bda1648cff96cf68bdaf5553b3009440156` completed all
3,432 records: 2,181 actual ASR inferences, 105 unique short/empty bypasses and
1,146 within-model equal-input reuses. The native causal score matches the
reference on all 35,924 frames. Independent checks replay all 312 native and
Python reference event traces, every ASR input range and all score arithmetic.
CI at that source passes 263 Swift / 105 Python tests, 17 profile CLI cases,
lint, report/app build and bundled-runtime imports. CI does not execute this
separately cached model study.

| ASR / input | Original WER | −40 dB WER | Noise WER |
|---|---:|---:|---:|
| Parakeet / full | 3.85% | 6.16% | 6.32% |
| Parakeet / RMS default edge | 3.54% | 99.69% | 6.32% |
| Parakeet / causal edge or chain | 4.31% | 6.32% | 5.86% |
| Parakeet / causal endpoint only | 4.62% | 5.55% | 6.93% |
| Whisper Turbo / full | 4.62% | 6.01% | 6.16% |
| Whisper Turbo / RMS default edge | 4.01% | 99.69% | 6.16% |
| Whisper Turbo / causal edge or chain | 4.01% | 5.55% | 6.32% |
| Whisper Turbo / causal endpoint only | 4.78% | 6.47% | 6.32% |
| Cohere native8 / full | 3.54% | 4.78% | 5.08% |
| Cohere native8 / RMS default edge | 2.93% | 99.69% | 5.08% |
| Cohere native8 / causal edge or chain | 3.24% | 4.47% | 4.47% |
| Cohere native8 / causal endpoint only | 4.01% | 4.78% | 5.24% |

Each speech column uses the same 33 utterances (649 normalized reference words)
under a different transform. The three transforms are not independent samples.
The edge/chain bounds happen to be identical on this slice; that is not a
general equivalence of those policies. WER normalization retains number-format
differences, so a correct written "13th" can count differently from "thirteenth."

Causal edges and chains introduce zero new empty transcripts across 297
speech/model pairs. Unsmooth raw edges introduce one Parakeet empty on quiet
`test-clean-6930-75918-0000`. RMS default edges empty 30/33 quiet inputs for each
ASR model. The five reused synthetic negatives never arm any neural policy.
Whisper returns text on all five full/endpoint-only negatives; causal edges and
chains bypass them all, while RMS edges still hallucinate on four. Parakeet and
Cohere return no text for these controls even without edge trimming.

This is not universal quality improvement. Causal edges improve/equal/worsen
10/75/14 transformed utterances for Parakeet, 8/84/7 for Whisper and 14/77/8 for
Cohere relative to each model's full input. Parakeet changes correctly recognized
"Captain Lake" to "Captain Leake"; Cohere changes "Captain Murdoch" to
"Captain Murdock." These lexical regressions remain in the receipt.

| Policy | Original finish p95 | −40 dB finish p95 | Noise finish p95 |
|---|---:|---:|---:|
| Raw / 1.2 s silence | 1.237 s | 1.164 s | 1.200 s |
| Raw / 1.424 s history control | 1.461 s | 1.388 s | 1.424 s |
| Causal8 / 1.2 s silence | 1.477 s | 2.074 s | 1.793 s |

These are observed-through sample positions minus source clip end, not measured
last-phoneme-to-UI latency. All 99 speech cases finish and none finish before the
source clip end; initial/trailing padding is fixed by the protocol. Causal maximum
delay is 2.279 s. Default RMS finishes none of the 33 noisy cases and prematurely
finishes the three quiet cases it arms. Low RMS arms all quiet cases but finishes
five before clip end. The RMS replay approximates polling; it does not execute
the hardware capture pipeline. Native prediction p95 is 0.075 ms, excluding
scoring, loading, priming, resampling, queues and ASR.

**Decision:** retain the frozen policy for an explicit experimental integration.
Do not change default edge trimming or auto-finish based on aggregate WER.
Preserve the complete recording, fail visibly to manual finish on backlog/error,
and reject stale endpoint decisions when newer audio remains unexamined. Final
edge bounds must refer to the exact normalized ASR input timeline. Remaining
models, multilingual quiet speech, real environmental noise, paused spontaneous
speech, devices and contention need separate evidence.

- [Every quality hypothesis, policy and delay summary](../../benchmarks/results/vad-causal8-validation.json)
- [Raw probabilities, activity scores, timings and events](../../benchmarks/results/vad-causal8-validation.traces.json.gz)
- [Independent checks](../../benchmarks/results/vad-causal8-validation-checks.json)
- [Source-bound CI](../../benchmarks/results/vad-causal8-ci.json)

After the run, recheck the stored evidence without neural/ASR inference:

```sh
HF_HUB_OFFLINE=1 PYTHONPATH=backend uv run --frozen --all-extras python \
  benchmarks/verify_vad_causal_validation.py \
  --receipt benchmarks/results/vad-causal8-validation.json \
  --cli .local/vad-candidates/source-a09b6bd-cli --output /tmp/causal8-checks.json
```

The verifier requires the source receipt's exact CLI hash. Rebuilding on another
host requires a new replay receipt, rather than changing the archived hash.

## Native capture sidecar under implementation

`NeuralCaptureMonitor` owns sixteen preallocated 8192-float mono buffers and a
separate half-second audio backlog ceiling, counting the in-flight packet. The
capture callback copies an already downmixed block; one serial queue owns model,
continuous AVAudioConverter, frame assembly, causal score and live endpoint.
No inference, resampling, disk reads or SwiftUI closure runs on the audio tap.
This still uses short locks and a bounded dispatch closure per admitted packet;
it is not a claim of lock-free or allocation-free real-time execution.

`LiveSpeechEndpoint` preserves the first one-shot policy decision while allowing
later >=0.35 activity to revoke a candidate. Its candidate refers to the latest
examined normalized frontier, not an old completed silence interval. At each
packet boundary, an incomplete 512-sample frame probes copies of model context,
recurrent state, causal score and endpoint state. Successful probes restore model
state; bad probes poison it. The next complete frame commits its actual samples
exactly once. There is no inserted padding at intermediate packet seams.

`CapturePipeline.claimNeuralFinish` holds the same ingress lock as capture,
requires the monitor's processed and received input positions to equal the
writer's accepted frontier, and atomically closes both admissions on success.
There can be no received-but-unexamined queue or a read-then-stop race. Activity
within a partial normalized tail can revoke completion. Converter filter latency
is still real, as is imperfect model classification; frontier consistency does
not guarantee that every phoneme is detected or that semantic intent is complete.

An overflow, input inconsistency or inference error disables the optional monitor
and exposes a manual-finish warning. It never switches silently to RMS. The
independent original recording writer continues unchanged. Close prevents stale
in-flight work from publishing, and every new monitor owns fresh per-take state.
The UI must actually display that warning and use the atomic claim before it can
enable this experiment. **No current GUI constructs the optional sidecar yet.**

Eighteen new controls bring the local suite to 281 passing Swift tests. These
include sample-identical continuous resampling across partitions at five device
rates, backlog/slot overflow, newer audio arriving after an old candidate,
in-flight close/failure, one-sample speech resumption in a partial frame, and
every original stereo sample surviving detector failure. A real Core ML pilot
preserves a 220-frame probability stream exactly across 1,320 partial probes.

The private `_benchmark-speech-capture` CLI replays file samples through this
actual sidecar. It drains every packet before admitting the next, which tests
function and frontiers without claiming real-time contention or microphone
acceptance. The pending batch uses all 104 existing validation cases at three
formats and two packet patterns (624 routes). Stereo gains 0.5/1.5 exercise
downmix; SciPy creates rate variants, while the live sidecar uses AVAudioConverter.
Those paths need not produce identical waveform values. Final ASR edge selection
must use its own exact normalized timeline, rather than reusing live bounds.

```sh
PYTHONPATH=backend uv run --frozen --all-extras python benchmarks/native_speech_capture.py \
  --cli .build/release/ospr-cli --output benchmarks/results/native-speech-capture.json
```

The harness uses only already cached pinned model data and public fixtures. It
retains every failed route and all packet/candidate traces. Preparation, packet
enqueue-through-drain cost and sample-position finish delay are separate; none
is a measured hardware callback, UI or ASR latency distribution.

## Primary sources and provenance

- [Silero upstream and MIT license](https://github.com/snakers4/silero-vad)
- [FluidInference Core ML conversion](https://huggingface.co/FluidInference/silero-vad-coreml)
- [FluidAudio VAD contracts](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/VAD/GettingStarted.md)
- [MLX v6 conversion](https://huggingface.co/mlx-community/silero-vad-v6)
- [Pinned model files](../../benchmarks/fixtures/vad-models.json)
- [Preselected public protocol](../../benchmarks/fixtures/vad-protocol.json)

Vendor/model-card speed and parity statements are not OSpr measurements. The
four AMI annotations are coarse speech-timing proxies, not a standard VAD frame
test set. Synthetic noise/gain variants are development controls. There is no
physical microphone, power attribution or product-quality ranking in this replay.
