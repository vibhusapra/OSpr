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
These correlated frames do not yield a calibrated probability. The trailing
window can extend activity by up to 224 ms, so the next experiment also needs a
latency-matched raw-threshold control. Use the remaining twenty clean and thirteen
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

- Validate the causal score and actual ASR outputs on speakers excluded from the
  VAD development slice, without retuning against their results.
- Select and pin a model only after the quality/runtime tradeoff is understood.
- Feed a bounded off-callback native queue with continuous resampling and sample
  accounting; overflow, stale generation and detector failure must surface.
- Preserve the complete original recording and its recovery metadata. Evaluate
  neural edge bounds separately from auto-finish; never remove interior silence.
- Exercise microphone/device changes, actual pauses, quiet speech, background
  noise, ASR/preview contention and a sustained session before changing defaults.

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
