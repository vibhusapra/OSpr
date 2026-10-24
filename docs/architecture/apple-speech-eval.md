# Apple SpeechTranscriber versus resident MLX file runtimes

This is a research helper and benchmark, not an OSpr application engine or a new
checked distribution. Parakeet/Cohere remain the preferred measured English
choices. Apple is a useful system baseline; no default change is justified here.

## Sources and API boundary

Apple's [SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer)
manages analysis and its [SpeechTranscriber](https://developer.apple.com/documentation/speech/speechtranscriber)
module supplies final or volatile text. Apple's
[WWDC introduction](https://developer.apple.com/videos/play/wwdc2025/277/)
describes on-device recognition and an out-of-process system model. The model
assets are managed and updated by the OS through
[AssetInventory](https://developer.apple.com/documentation/speech/assetinventory).
Neither exact model-weight revisions nor compute-unit selection is exposed by
this public API. App-process RSS would omit model-service memory; this study does
not compare RAM, energy, GPU or ANE use.

The helper uses the macOS 26 APIs in the installed 26.5 SDK. Current web docs also
show newer APIs; this implementation uses `AVAudioFile` and does not require
macOS 27's input-provider classes. It records supported/installed/reserved locales
and the OS build. An executable can observe an installed locale while a module's
asset status is merely `supported`; its own preparation request reached
`installed` before recognition. Asset preparation is outside measured file calls
and may download system assets. No microphone, keyboard, AX, UI or cloud API is
used. No OSpr settings/history are changed.

The ASR options are empty (no etiquette replacements, fast or volatile output),
with audio-time attributes enabled. Each file gets a fresh module/analyzer,
process-lifetime backing-model retention, concurrent result collection, and
explicit finalization through the analyzed input endpoint. Empty input endpoints
cancel cleanly. Errors cancel/close analysis and remain visible per file. The
helper uses the original text fragments without generated alignment or cleanup.
Timed attributed-string runs are recorded as runs, not asserted to be word tokens.

## Frozen study

Protocol/source commit `cb06d9b` predates the study. One initial public Quilter
trial per runtime is excluded from metrics. Then four serial routes process the
same 365 English clips (200 test-clean / 40 speakers; 165 test-other / 33 speakers)
and five existing nonspeech controls. The first five archived utterances per
speaker were selected earlier, independently of these results. These are known
read-speech inputs, including the Nelly preflight probe, not a sealed new-speaker
or spontaneous-dictation evaluation.

Rotate route order once per case across Apple, Parakeet v3, native-layout Cohere
8-bit and Whisper Turbo. Each MLX route owns a separate resident Engine. All use
full audio, no edge trimming, an English hint and no rewriting. All 1,484 requests
complete without API errors. Inputs, model/dependency locks, producing code,
compiled Swift binary and every raw output are hashed or pinned in the receipt.
The Apple model itself remains opaque and may change independently of that pin.

| Runtime | English errors / 7,765 words | Aggregate WER | Caller p50 / p95 | Nonspeech nonempty / 5 |
| --- | --- | --- | --- | --- |
| Apple SpeechTranscriber | 285 | 3.670% | 119.85 / 342.39 ms | 0 |
| Parakeet v3 / MLX | 242 | 3.117% | 66.79 / 124.65 ms | 0 |
| Cohere native-layout 8-bit / MLX | 143 | 1.842% | 92.94 / 164.20 ms | 0 |
| Whisper Turbo / MLX | 296 | 3.812% | 128.12 / 178.59 ms | 4 |

The shared conservative normalization lowercases, removes Unicode punctuation
and collapses repeated whitespace. No model-specific number expansion is used:
`10` versus `TEN` and `Mr.` versus `MISTER` can count as errors. Every reference
and hypothesis remains available for inspecting lexical versus formatting errors.

Apple caller times include a JSON pipe round trip; MLX caller times use direct
Python Engine calls. Shared desktop/OS-service/model-cache activity is not
isolated. These are different runtime file interfaces, not matched consumer-app
or physical microphone/insertion latency. Initial trials are not guaranteed cold
hardware/model loads. Median numbers describe this run; no top-three ranking,
significance, general accuracy or energy claim follows.

## Verification and failure controls

The independent checker reconstructs all input PCM hashes, checks route order and
source pins, and implements its own Unicode normalization, dynamic-programming
edit distance and linear quantiles. It confirms the reported metrics. All Apple
results are final; no result/run timing exceeds the file duration (within one
source sample), and the reported analyzed endpoint reaches the last source sample.
That checks metadata bounds/coverage, not audible alignment or omitted speech.

Five native helper subprocess controls cover inventory, usage, unsupported locale,
missing/corrupt files followed by successful same-process recognition, and
malformed protocol exit. Both valid file outputs match. These controls do not
establish hardware cancellation, live microphone, native UI or app integration.

Public receipts are `apple-speech-real.json`, its compressed raw traces,
`apple-speech-checks.json` and `apple-speech-contracts.json`. The tiny preflight
required asset preparation and is exploratory; the full source was frozen before
collecting the 370-case corpus results. A lint-only unused import is removed after
the recorded study; the native helper and inference path are unchanged.
