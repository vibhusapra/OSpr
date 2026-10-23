# Native speech detection and endpointing research

The delivered context-profiles preview still uses its existing RMS trim and
optional RMS auto-finish. This work adds an offline Core ML detector and a shared
audio-time endpoint policy for evaluation. It does not yet replace microphone
endpointing, trim ASR input in the app, or bundle another model.

## Contracts

`CoreMLSpeechDetector` loads a supplied local compiled model without downloading
or compiling it. It accepts exactly the published Silero conversion interface:
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

- Complete the frozen replay and inspect raw transcript losses and false starts.
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
