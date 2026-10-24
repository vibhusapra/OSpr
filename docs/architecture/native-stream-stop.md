# Native worker stop and fallback replay

The packet-normalization regression used the Python engine directly. This later
check crosses the actual shipping Swift `WorkerClient` and its owned Python
process, with cached Metal Nemotron inference. It compiles the unchanged client
source together with a separate benchmark entry point; no app or core behavior
is modified. The frozen producer/protocol commit is `30ff45b`.

The public 12.485-second English source `1272-128104-0002` is resampled once to
44.1/48 kHz. Each case sends a twelve-second packet followed by the remaining
tail and final flush. This deliberately covers a large admitted preview packet,
not typical 320 ms pacing. Source `0000` supplies a different replacement take.

Ten scenarios complete, five per native rate:

| Scenario | Observed result |
| --- | --- |
| Normal feed, tail and flush | Complete nonempty text; worker PID stays unchanged. |
| Task already canceled before request | The packet still reaches the worker, then tail/final text matches normal. |
| Cancel caller while awaiting response | Both timed cancellations lie strictly between request start and return; final text matches normal without restart. |
| Replace session, then cancel old UUID | Old cancel returns false; replacement text matches a fresh-session control. |
| Change sample rate, then use full-file fallback | Explicit error reaches Swift, worker restarts, complete-file recognition matches its control. |

The six stop-path transcripts and both fallback transcripts have zero WER on this
one known source. Both replacement transcripts match their controls but score
1/17 word errors (5.88%) under the existing conservative normalization: `Mr.`
versus `MISTER` remains an error. No metric normalization was changed.

The first large packet takes about 184–241 ms across the six caller intervals.
These are diagnostic request times on an unpaced fixture, with model/cache/order
effects; they are not native dictation latency or a performance comparison. The
timer fires five milliseconds after task creation. The receipt verifies actual
ordering rather than assuming cancellation happened before return. It does not
claim that a GPU kernel was executing at that exact instant or that inference
was interrupted: retaining an admitted packet is the intended behavior.

All ten records retain actual partials, final text, timing and PID relationships.
An independent checker verifies pinned source inputs, reconstructed native PCM
recipes/counts, caller ordering, text controls and edit distances. Each temporary
WAV is decoded and byte-checked by the producer before use; its file hash is
bookkeeping, not a later reconstruction of ephemeral WAV bytes. The source
waveform hashes are reconstructible. The probe and its owned workers finish;
the unrelated idle QA worker remains untouched.

## Remaining native acceptance

This validates the native client/worker boundary, not microphone capture,
`Capture.snapshot`, `AppModel.stop`, actual device changes, UI failure messages,
focused-field insertion or physical Fn/PTT. The fallback is explicitly invoked
by the probe after the same protocol error; it does not claim UI fallback
acceptance. The live application and source-normalization gates remain distinct.

No production model, default or standalone package changes. Preview stays
opt-in; the checked `9a51603` ZIP predates continuous normalization and cadence.
Native QA cleanup remains pending a macOS unlock at this checkpoint.
