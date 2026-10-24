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
They do not request microphone or ScreenCaptureKit permissions.

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
