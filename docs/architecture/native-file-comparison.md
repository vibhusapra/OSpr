# Native consumer file-import pilot

The official MacWhisper 15.8 free app and OSpr's verified v0 GUI each imported
and exported the same twenty public LibriSpeech files using Whisper Small and
automatic language. This extends the earlier Vibe **CLI** pilot with actual
consumer GUI workflows. It does not test dictation delivery or establish a
product ranking.

| Route | Clean errors / 285 words | Other errors / 200 words | All errors / 485 words | WER |
|---|---:|---:|---:|---:|
| MacWhisper 15.8 / WhisperKit Small | 9 | 8 | 17 | 3.51% |
| OSpr v0 / MLX Whisper Small, complete repeat | 10 | 6 | 16 | 3.30% |

The one-word aggregate difference is too small and the sample too narrow to
establish an accuracy winner. Both routes use the same upstream family, with
different conversions, runtimes and decoder defaults; identical weights were
not established. Neither app was tuned after inspecting its output. No rewriting
was enabled in OSpr: Verbatim, local ASR, blank language hint, empty vocabulary
and replacements, no speakers or silence trimming, session-only history.

## Frozen inputs and complete evidence

Before the first new consumer inference, the protocol retained the earlier Vibe
selection: the first utterance of the first ten distinct speakers in each fixed
clean/other manifest. All twenty staged WAV hashes match the original files.
Both apps first imported the same excluded Quilter warm-up. These are reused
development cases, not an independent holdout. References and public audio
origins follow the [existing corpus protocol](../../benchmarks/README.md).

[Frozen protocol](../../benchmarks/fixtures/native-file-comparison.json) records
the input/reference hashes and prohibited claims.
[Observations](../../benchmarks/fixtures/native-file-observations.json) retain
the exact UTF-8 native exports, their original hashes, settings, signature/build
provenance, per-file app metadata and the interrupted attempt.
[Scores](../../benchmarks/results/native-file-comparison.json) retain all forty
completed hypotheses, reference counts and substitution/deletion/insertion totals.

The OSpr private QA app was re-signed for a separate data directory and disabled
background services. Removing signatures from temporary executable copies proves
its GUI bytes match the standalone preview. It uses that package's engine.
MacWhisper came from the official CDN using Homebrew cask metadata; archive
SHA256, notarized signature, installed version and model selection were checked.
Native Open and Save dialogs performed imports/exports. No hidden app API was
used to obtain recognition output. No microphone, Accessibility or Screen
Recording permission was newly granted; no account, license, trial or purchase.

## Interrupted attempt is retained

OSpr's first batch showed all twenty cohort records plus warm-up in History.
Eighteen cohort JSON exports were saved before the app quit. Unified logs show
`performKeyEquivalent`, `sendAction`, orderly delegate-approved termination at
17:41:44 local time, and a fresh process at 17:42:07. No OSpr crash report was
found. The origin of the quit action is unestablished. Session-only history uses
an in-memory database and is intentionally discarded on quit.

The eighteen exports remain in the observations without a subset WER. Missing
outputs were not filled from another run. A separately labeled full repeat used
the unchanged twenty inputs/configuration and exported every cohort record plus
warm-up. Some Save-panel observations were transient; refreshing and completing
the pending Save required no additional inference. The normal app was restored
at eight sessions/265 words; all five normal settings/data/app hashes matched.

## VoiceInk is unmeasured

Official notarized VoiceInk 2.21 opened to onboarding with Continue disabled
pending Microphone and Accessibility access. No permission was granted and no
inference was attempted. This is a setup limitation, not a recognizer failure.
Screen context is optional, as both the
[installation docs](https://tryvoiceink.com/docs/installation) and
[pinned source](https://github.com/Beingpax/VoiceInk/blob/640b0c8c36ee74d9e76d930f40e2c04bb739b4b3/VoiceInk/Features/Onboarding/State/OnboardingPermissionModels.swift)
show. [File-import docs](https://tryvoiceink.com/docs/transcribe-audio-files)
describe batch processing without live insertion/context. The app was quit.

## Reproduction and remaining work

```sh
uv run --frozen --all-extras python benchmarks/native_file_comparison.py \
  --verify benchmarks/results/native-file-comparison.json
```

This recomputes scores offline, rehashes every retained raw export and rejects
missing, duplicate, foreign, edited or differently configured evidence. Nine
tests cover those failures, order independence and scoring an empty recognition
as deletions. It does not relaunch the apps or verify their original UI states.
New inference runs must use new attempt/output directories and preserve every
failed/interrupted attempt. Do not select a best repeat.

MacWhisper's rounded displayed times/realtime multiples and OSpr's latencyMS
have different boundaries. No inference-speed, end-to-end latency or energy
comparison is derived from them, and automation wall time is excluded.
Natural multilingual dictation, meetings, acoustic capture, shortcuts, insertion,
endpointing, refinement, accessibility and thermal/energy isolation remain open.
OSpr import source names are stored in JSON but absent from History labels;
default export filenames are generic and there is no bulk export. These gaps drove the later [import workflow implementation](file-import-workflows.md).
Persistent source-name list/search metadata and durable batch resume remain open.
