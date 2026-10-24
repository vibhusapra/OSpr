# Continuous conversion quality and processing cost

The live meeting replay found a 12.86% relative RMS difference between original
16 kHz speech and a SciPy-upsample/Apple-downsample roundtrip. Exact packet
preservation alone does not establish filter transparency. This frozen study
compares the actual Core converter's native default with explicit normal/high,
normal/maximum, mastering/maximum and minimum-phase/maximum settings.

Apple's SDK 26.5 AVAudioConverter header defines quality as an AVAudioQuality
value and algorithm as an AVSampleRateConverterAlgorithmKey. The installed
converter reports default quality 64, normal algorithm. The minimum-phase
algorithm changes its reported priming method to none. These are observed
properties on this OS, not promises for all OS versions or hardware.

The helper compiles the actual `StreamingSpeechResampler.swift` in release mode.
Internal policy injection leaves all production callers at the system default.
It records actual settings/priming information, first output input position,
initialization/flush cost, every callback cost, full frame counts and PCM. Timing
includes copying native input into scratch and collecting output; filesystem
I/O and model inference are outside that interval.

The frozen protocol selects forty known read-English clips from forty speakers,
three FLEURS clips in each of Spanish/German/Hindi/Japanese/Mandarin, each at
original and minus forty dB, plus five known nonspeech controls. Each is prepared
at 44.1 and 48 kHz with one pinned SciPy conversion. No current policy result is
used for selection. Models remain cached in separate Engine instances. Actual
streaming uses 320 ms slices of completed normalized PCM, not native arrivals.

Independent native-rate tones measure amplitude and alias rejection. Long
synthetic two-tone input separately measures callback cost across three repeats.
Uneven native partitions must preserve the same complete PCM as fixed packets;
unit tests additionally compare against independent whole-track conversion.

Promotion requires every frozen gate: signal response, substantially smaller
median speech roundtrip error, bounded callback cost and first-output position,
complete/partition-invariant PCM, no new empty speech or nonspeech text,
non-increasing word and character errors in each language/model/rate, balanced
individual regressions and non-increasing subset streaming word errors. If more
than one policy passes, choose the lowest worst-rate p95 callback cost. There is
no hidden threshold change or repeat-until-passing rule.

Scope is desktop provisional drafts. The ordinary microphone backend uses a
separate continuous SciPy normalizer. Full durable final audio stays unchanged.
Core conversion is also used by optional neural capture, which needs a separate
detector gate before any default is changed there. No new neural default is
authorized by this study. Physical capture, UI latency, energy, calibrated peak
memory, perceptual listening, broad natural-meeting quality and consumer ranking
remain outside this file replay.

Primary API references:
[quality](https://developer.apple.com/documentation/avfaudio/avaudioconverter/samplerateconverterquality),
[algorithm](https://developer.apple.com/documentation/avfaudio/avaudioconverter/samplerateconverteralgorithm).
The installed SDK headers provide the precise property types and quality values.

## Outcome at frozen source becbcc7

The completed study makes 870 native conversions, 1,500 full-file ASR requests
and fifty real streaming sessions, with no API errors. All 750 corpus conversions preserve
whole-track PCM/length; ten additional real uneven-partition controls pass. The independent checker rereads
all samples and independently recomputes hashes/order, complex tone projection,
Unicode edit distances, quantiles and all promotion gates. Four deliberately
corrupted receipts are rejected. Seven real helper failure-isolation controls
pass. Four new Core tests and the complete local 335 Swift / 248 Python suites pass.

No alternative passes every gate. Mastering/maximum reduces forty-clip median
relative RMS to 1.328% at both rates, from 2.955%/3.046%, and passes the sampled
passband/alias gates. Its first output needs two 1,024-frame buffers instead of
one: 42.67/46.44 ms input positions versus 21.33/23.22 ms. Those are input-time
proxies at this packet granularity, not actual microphone latency. Its packet
p95 is 100.7/103.9 microseconds versus 1.88/2.00. It adds English word errors in
both recognizers at both rates, and fails the first-output and language gates.

Normal/maximum costs 3.25/3.50 microseconds at p95 and reduces combined word
errors, but adds two Nemotron Japanese character errors per rate; its passband
and original-PCM fidelity gates also fail. Minimum phase improves some Whisper
counts but worsens Nemotron English/Japanese. Its direct RMS error is dominated
by phase differences, which is not a human intelligibility judgment. No policy
adds a new empty speech result or new nonempty nonspeech control.

All production callers retain the native default. No neural VAD input or checked
package is promoted. A future candidate needs a newly declared held-out study;
these known results must not become a repeat-until-passing selection process.

The first incomplete run (0fffd61) preserves 100 signal/ten cost results and zero
ASR calls. Its assumed ceil length did not match Apple's fractional rounding.
The revised native helper compares exact PCM/length with a separate whole-track
AVAudioConverter; output duration must be within one sample of the mathematical
ratio. The original 16 kHz reference can receive one zero tail frame, with no
cropping or alignment search. All original quality/cost/ASR gates remain fixed.

Files: [study](../../benchmarks/results/resampling-quality-real-v2.json),
[native timings and ASR replies](../../benchmarks/results/resampling-quality-real-v2.traces.json.gz),
[independent checks](../../benchmarks/results/resampling-quality-checks.json),
[helper controls](../../benchmarks/results/resampling-quality-contracts.json),
[corrupt receipt controls](../../benchmarks/results/resampling-quality-verifier-controls.json),
[retained attempt](../../benchmarks/results/resampling-quality-attempts.json),
[frozen protocol](../../benchmarks/fixtures/resampling-quality-protocol.json).

[Source and CI validation](../../benchmarks/results/resampling-quality-source-validation.json).
