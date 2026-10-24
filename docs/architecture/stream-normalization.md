# Continuous native-rate streaming audio

Capture snapshots contain new mono audio at the microphone's native rate. The
old backend independently called `read_audio` on each packet. At 44.1/48 kHz,
this reset FIR boundaries and rounded each packet's output length upward. One
second in 1,024-frame packets produced 16,021 / 16,031 samples instead of 16,000.
Equal counts also could hide changed waveform boundaries.

`StreamNormalizer` preserves the global rational-resampling phase and a small FIR
halo. It uses the same SciPy Kaiser filter as whole-file float32 normalization,
cached once per session. Live output waits for the filter's future input; final
flush supplies the original zero-padded end. Clipping happens after resampling.
The sixteen-kilohertz path needs neither filtering nor delayed output.

Trimming the retained buffer at multiples of the reduced `down` factor preserves
phase. The retained state depends on filter support/phase, not recording duration.
The maximum transient array also includes the current bounded packet. This is a
resampler-state claim, not a bound on the upstream recognizer's caches or process
RAM. Supported microphone rates range from 8 to 384 kHz, with fourteen explicit
standard rates; unsupported rates fail visibly rather than building huge filters.

The packet reader validates headers before decoding: at most twelve seconds,
32 channels and 32 MiB decoded float32 bytes. It downmixes without clipping, rejects
nonfinite samples and does not invoke a media subprocess. Full-file media import
keeps its existing broader decoding path. A sample-rate change within a session
raises an error; the app's preview-failure handling retains final-file fallback.
Finalization feeds the remaining normalized tail before closing the recognizer.
Cancel/replacement/final success clear normalizer state; expired IDs cannot clear
a newer session.

## Validation

- 230 Python tests, including 52 new cases: fourteen rates, fixed/random/tiny
  partitions, clipping, tail delivery, bounded retained state, limits, rejection
  without state mutation, session replacement and cancellation.
- Fifteen one-second synthetic cases: all corrected outputs are byte-identical
  to the whole normalized waveform. The ten legacy high-rate cases differ.
- Two 120-second synthetic streams plus uneven tails: full PCM hashes match,
  retaining at most 507 input samples at 44.1 kHz and 73 at 48 kHz between calls.
- Thirty-six real cached Nemotron sessions: three known public English clips,
  two rates, two native partition patterns and three routes. Corrected PCM and
  final text match all twelve whole-normalized controls; legacy differs in all
  twelve PCM hashes/counts. All routes have 8 errors / 236 repeated reference
  words, 3.39% WER. This repairs audio continuity without an observed lexical gain.
- An independent checker uses whole-array SciPy and reconstructed legacy packet
  PCM, not the candidate normalizer, and checks source hashes, final hashes,
  every live sample position and edit distances against raw traces.

Mac CI at `aec096f` also passes 310 Swift / 230 Python tests, 17 profile CLI
cases, lint, app/report build, clean-runner bundled imports and signature checks.
See [`stream-normalization-ci.json`](../../benchmarks/results/stream-normalization-ci.json).

The protocol was frozen at `9a0d1bf` before outputs; that commit contains the
production change and producer. Raw transcripts/partials and source fingerprints
are public in `benchmarks/results/stream-normalization-*`.

## Remaining acceptance

The replay is unpaced and has three reused single-speaker read-English clips.
It does not measure actual microphone/IPC/UI latency, energy, broad accuracy or
device interruptions. The unit tests reject rate changes; actual hardware route
changes and app fallback still need native acceptance. Stop cancellation while a
request is in flight also remains separate. Preview stays off by default.

The earlier full-audio-v0 ZIP at source `9a51603` predates this and the cadence
changes. A later separate streaming-v0 preview at `3feaf65` includes both and
passes exact-build artifact gates; see `streaming-package-gates.json`. It remains
a local development-signed preview, with physical native and distribution gates open.
