# Preview cadence under processing load

The prior preview loop slept after each request completed: 320 ms for Nemotron
and three seconds for rolling preview. Snapshot/write/worker time therefore
extended every interval. With 120 ms of work, nominal 320 ms feeds started at
320, 760, 1,200 ms rather than 320, 640, 960 ms. This added avoidable waiting.

`PreviewCadence` uses `ContinuousClock` instants. Work that fits inside an
interval leaves the next tick in place. An overrun admits one immediate update
and starts a new interval rather than enqueueing every missed tick. The app
still awaits one request at a time. A generation check after wake, before the
snapshot, prevents a stale task from draining a replacement take's audio.

Missing/empty session identifiers now fail the incremental startup instead of
falling through into packet-by-packet offline transcription. Startup or live
preview failure shows a visible message while recording continues. Existing
session cleanup and final complete-recording fallback remain; cancellation and
stale generations do not show a new warning. This does not change the capture
writer, normalization, model, final-text pipeline or preview-off default.

The scheduler is constant work per tick and does not depend on wall-clock time.
Five deterministic tests cover a hundred normal ticks, decode-time accumulation,
overrun recovery, a one-hour pause, late wakeups and the three-second rolling
schedule. The CLI's `_benchmark-preview-cadence` probe invokes this exact Core
helper against modeled monotonic instants; its values are not measured latency.

The fixed regression protocol uses 40/120/600 ms modeled work costs, both policies
and 320 ms/three-second schedules. Actual inference uses six cached Nemotron
sessions for the 320 ms plans on the same sixty-second waveform: ten complete
public Quilter utterances with silence padding to six seconds each. Every WAV
packet is decoded and checked against its source slice. The whole submitted PCM
hash, final text, WER, partials and diagnostic processing times are retained.
Policy order alternates. One repeated speaker is not an accuracy benchmark.

There are no real-time sleeps or microphone/UI measurements in that replay.
Modeled work is synthetic, not the measured decoder cost. Requests complete in
this test before final draining; user-stop cancellation during an outstanding
request is a separate gate. First-partial input position and modeled delivery
are not acoustic word-relative or native end-to-end latency.

A steadier cadence can issue more requests and use more GPU time than the old
slower loop. This is not a free energy win; preview remains opt-in. Native
microphone cadence, main-actor wake jitter, source continuity under contention,
stop/cancel, fallback messages and battery behavior remain acceptance work. The
checked full-audio-v0 ZIP at 9a51603 predates this source change.
