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
