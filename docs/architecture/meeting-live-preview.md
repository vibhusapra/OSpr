# Live meeting drafts

Desktop recordings can opt into the existing Live preview setting. Nemotron
produces a continuous provisional transcript; other local models refresh the
most recent twelve seconds every three seconds. Drafts have no live speaker
labels. Final recognition always runs independently on the complete durable,
clock-aligned recording after stop, including audio not admitted to preview.
Draft text never replaces the final result. This costs an additional full decode.

`MeetingAudioPipeline` admits original buffers to private per-source WAV sinks
before optional preview. `MeetingPreviewMixer` owns a fixed native FIFO per
source, persistent AVAudioConverters to 16 kHz, normalized FIFOs, and a twelve
second rolling window. Gaps use bounded segment metadata instead of allocating
silence on ingress. Conversion occurs when the consumer asks for a snapshot.
A 500 ms reorder allowance accommodates different source delivery schedules.
The sources mix in fixed order with half gain each when microphone is configured;
a missing track is silence. Clipping is bounded. There is no echo cancellation.

Late packets cannot rewrite committed draft audio. Preview backlog, clock,
format or conversion failure stops only the draft and produces a visible warning;
raw tracks remain available for the complete final mix. Rate changes still stop
raw capture through its existing format guard. Capture is capped at one hour.

Stop closes audio admission and drains raw sinks first. An admitted worker packet
finishes before its temporary WAV is deleted. The app waits for stream setup or
feed completion, cancels only that generation's draft session, preserves raw
recovery, then starts final mixing/recognition. Cancellation and late callbacks
cannot alter a replacement take. Final ASR failure retains full mixed recovery.

## Verification

Eight Core tests cover exact native-rate partition equivalence, source offsets,
late sources, long sparse gaps, capacity and invalid data. Five platform tests
cover raw-track independence, private packet export and capture failure prefixes.
Eight AppModel tests use the real WorkerClient with an isolated stdlib Python
fixture worker; they check incremental/rolling modes, failed preview, missing
session IDs, in-flight stop, generation replacement and final-error recovery.
They do not request microphone or ScreenCaptureKit permissions. The complete
local suites pass 331 Swift and 248 Python tests.

`benchmarks/meeting_preview.py` and its frozen protocol replay two attributed
public LibriSpeech clips through the production Swift mixer at 44.1 and 48 kHz,
a 125 ms source offset, three packet/cadence/delivery schedules, and cached local
Nemotron/Parakeet. The producer keeps raw replies before assertions. The harness
is unpaced, and its stream flush is diagnostic: the app cancels provisional
stream state rather than promoting that text. It measures sample preservation
and file-ASR behavior, not microphone, physical stop, native latency, energy,
peak memory, overlap quality or natural meeting accuracy.

Physical desktop/system-audio/microphone capture, permission handling, route
changes, echo, preview-to-stop interaction and clean-Mac acceptance remain open.
This source change is not a checked distribution or full parity/top-three claim.

## Frozen real replay

Source `b90d92c97c95043c80b256af32803b81418bdcd3` produces three 60.125-second
mixes, each 962,000 frames. Across 187, 188 and 21 draft packets, concatenated PCM
is exactly equal to a separate whole-track AVAudioConverter path and across
partitions. All source FIFOs drain. Logical Float sample capacity is 1,681,200
(6,724,800 bytes) for the 44.1/48 kHz duplex case; this excludes AVAudioConverter,
metadata, capture sink buffers, WAV snapshots, ASR and process peak memory.

Independent checks re-read every file, verify source/lock/binary/trace hashes,
recompute conservative word edit distance, and reject wrong scores, dropped
packet events and reversed route order. Independent complete-file text is
invariant across schedules for each model: Nemotron 3/54 errors (5.56% WER),
Parakeet 4/54 (7.41%). These are two short clips, repeated once each, by one
speaker without overlapping speech. Stream final flushing is diagnostic only.

The original reference gate compared SciPy-upsampled/Apple-downsampled PCM
against the unfiltered original and failed before ASR. Maximum sample difference
is 0.1160975; relative RMS difference is 12.864%. This remains reported in every
successful replay. The revised check compares packet preservation with whole
Apple conversion, without claiming transparent resampling quality. An initial
whole-track helper incorrectly expected endOfStream in one conversion call;
it now drains explicitly. Both failed attempts are indexed publicly.

Receipts: [replay](../../benchmarks/results/meeting-preview-real-v3.json),
[raw replies](../../benchmarks/results/meeting-preview-real-v3.traces.json.gz),
[independent checks](../../benchmarks/results/meeting-preview-checks.json),
[rejected reference attempts](../../benchmarks/results/meeting-preview-reference-attempt.json),
[mutated receipt controls](../../benchmarks/results/meeting-preview-verifier-controls.json).
[Layout fixture](../assets/meeting-preview-layout.png) is a render of actual
SwiftUI source with simulated state, not native capture/recognition evidence.

## Separate test candidate

`dist/meeting-preview-v0/OSpr.app` and its ZIP freeze application source
`2ceb234`, fingerprint
`e6b9856a3641e4071bf42fde462c79faa60fb669ffa9dcb4dc371be6eabf9837`.
The Apple Development signed macOS 26.6.2 arm64 candidate passes relocated
six-engine/neural checks and exact bundled mixer/real WorkerClient final-ASR
checks. All 208 bundled help links resolve. ZIP CRC, extraction, signature,
license bytes and extracted offline CLI inventory pass. Source CI is green at
331 Swift / 248 Python tests. This does not establish native capture acceptance,
Developer ID/notarization, clean-Mac/older-OS installation or updater readiness.
The earlier checked streaming preview remains intact.

[Package manifest](../../benchmarks/results/meeting-preview-package.json),
[portable models and extras](../../benchmarks/results/meeting-preview-portable.json),
[bundled mixed-file and WorkerClient checks](../../benchmarks/results/meeting-preview-bundled-checks.json),
[source validation](../../benchmarks/results/meeting-preview-source-validation.json).
