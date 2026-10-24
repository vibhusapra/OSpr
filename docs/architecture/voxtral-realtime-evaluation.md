# Voxtral Realtime candidate evaluation

This is a research branch, not an additional shipping model. The checked
full-audio-v0 ZIP and six-model app picker remain unchanged. The current
Nemotron replay exposes first partial text at a median audio position of 1.28 s
on twenty known English clips. Another native streaming architecture is worth
measuring, but its advertised decoder delay is not a Mac microphone result.

The exact candidate is MLX Community's 4-bit Voxtral Mini 4B Realtime conversion,
revision `fdebf7b2af834a1db4b8a3c99ab7480b333adf9e`, under Apache-2.0. The upstream
Mistral card documents thirteen languages and configurable transcription delay;
its MLX implementation is listed as a community contribution, not vendor-tested
Mac acceptance. The existing locked `mlx-audio==0.6.1` includes the adapter.
No remote model Python is executed. File sizes and SHA-256 hashes are pinned in
`benchmarks/fixtures/voxtral-realtime-protocol.json` and verified before/after
inference. Weights are downloaded explicitly; inference is cache-only.

The frozen selection uses twenty previously evaluated test-clean English clips,
all fifty existing FLEURS clips across Spanish, German, Hindi, Japanese and
Mandarin, and five previous synthetic nonspeech controls. Each runs full-file
and incremental recognition with the same 480 ms configuration, temperature zero
and unchanged normalized float32 waveform. No language hints or speech filter
are applied. The compatibility smoke uses the separate known Quilter clip.

The incremental path feeds 320 ms packets and takes one cooperative decoder step
per packet (budget 256 tokens), then closes input and drains to `done`. A decode
budget does not bound encoder work or wall time. The driver never feeds a
finished session; early completion preserves the unaccepted-sample count as an
explicit defect. It preserves every partial, raw text, accepted sample count,
normalized PCM hash, per-step compute time, final flush time and GPU allocation.
Every call updates a partial evidence archive. Errors remain recorded.

There are no real-time sleeps, microphone capture, IPC or native UI here. First
partial audio position is the amount of input made available when text appears;
it includes original leading silence and is not acoustic word-relative delay.
Compute and finalization are synchronized to Metal and reported separately.
Offline runs precede streaming runs, so compute timings are diagnostic rather
than a balanced performance comparison. The two modes are not assumed to return
identical text. All source samples must remain unmodified.

These are known inputs, not a new held-out model-selection set. Japanese and
Mandarin should use whitespace-normalized CER as the primary reading; WER/CER
and raw references are preserved for all speech groups. Five synthetic controls
cannot establish real-world false-positive behavior. No universal accuracy,
low-latency, streaming fidelity or top-three product claim follows from a smoke.

Run the prepared candidate with:

```sh
PYTHONPATH=backend HF_HUB_OFFLINE=1 .venv/bin/python benchmarks/voxtral_realtime.py --phase smoke --output .local/voxtral-smoke.json
PYTHONPATH=backend HF_HUB_OFFLINE=1 .venv/bin/python benchmarks/voxtral_realtime.py --phase study --output .local/voxtral-study.json
```

Before any app integration, inspect the complete study for deletions, false
positives, incomplete streams and large decoder steps. Integration also requires
bounded input admission, session ownership, explicit close/cancel behavior,
normalizer continuity, long-session residency tests and the existing capture,
recovery and actual destination-insertion gates. The upstream session's unbounded
feed queue must not run directly from an audio callback. Changing an advertised
delay or selecting the fastest row on these reused clips is not acceptance.

## Frontend diagnostic, before recognizer inference

The exact same model-padded synthetic waveform passes through full-file mel and
`StreamingMel` at twenty fixed source-length/packet-size combinations. Every
feature shape matches. Eighteen exceed the preregistered absolute tolerance
2×10⁻⁵; the maximum normalized log-mel difference is 2.0528×10⁻⁴. The threshold
was not relaxed after seeing results. This is a tight numerical parity failure,
not evidence of missing frames or an established transcription-quality failure.
Full recognizer comparison is needed to assess text effects. All twenty cases
and installed-module hashes are retained in `voxtral-frontend.json`. The raw
frontend buffer retains the entire padded input in these runs; no trim is called.

The initial diagnostic also exposed `benchmarks/statistics.py` shadowing Python's
standard-library `statistics` while Transformers imported Torch internals. The
unchanged speaker-bootstrap producer is now named `speaker_bootstrap.py`, with
its documented command updated. This fixes research imports without changing
the shipping worker or dependency lock.

## Complete known-input study

The study finishes 150 recognizer calls with no API errors or early streaming
completion. The independent checker recomputes every WER/CER from raw references
and hypotheses with a separate Levenshtein implementation and verifies all 150
source/sample/PCM routes, append-only partials and first-partial positions.
Seventy of 75 full-file/stream text pairs match exactly. Five differ in wording
or punctuation; these are preserved, rather than requiring identical text.

There is a substantive failure: the quiet original Japanese clip
`fleurs-ja_jp-005` returns empty in both modes. It contains 111,360 samples, peak
0.00937 and RMS 0.00107, with no OSpr filtering. The earlier full-audio study's
five supported shipping engines all returned nonempty text for this same source.
This does not identify quantization, frontend calibration or another model
limitation as the cause. Gain changes or threshold tuning on this reused clip
would be exploratory and would require new quiet/noise validation before use.

English WER is 2.86% for each mode on twenty clips. The streamed median first
partial input position is 1.60 s; median final flush is 370.6 ms. The previously
published Nemotron replay on those clip IDs reports 4.30% WER, 1.28 s first input
position and 14.7 ms flush, but uses a different driver and an explicit English
hint. These historical diagnostics are not a balanced head-to-head or a universal
quality/latency ranking. Voxtral's primary metrics on the five ten-clip language
groups are Spanish WER 2.13%, German WER 4.10% full / 3.69% stream, Hindi WER
23.97%, Japanese CER 10.38% and Mandarin CER 10.63%.

Both modes remain empty for all five synthetic nonspeech controls. This raw
recognizer study intentionally does not apply OSpr's exact-zero bypass. The
maximum MLX allocation is 6,024,226,688 bytes; it excludes untracked whole-process
and other-app memory. Every observed stream event retains the initial left pad
and all submitted raw samples, confirming the residency concern on these inputs.
Long-session behavior and a bounded adapter are still separate requirements.

The candidate remains research-only. Source/metric checks passing does not erase
the empty speech result, tight frontend numerical failure or open native and
long-session gates. The existing six-model full-audio-v0 preview is unchanged.
