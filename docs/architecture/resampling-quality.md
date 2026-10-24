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
