# Recognition timing within the analyzed audio

The frozen multilingual study exposes twelve Whisper intervals beyond their
actual analyzed range. Six also extend beyond the complete source. One quiet
German input is 17.94 seconds, but neural edges select 4.608–5.408 seconds and
Whisper returns a segment ending at 34.588 seconds. The recognizer text itself
is also wrong; fixing timing does not repair recognition or the detector policy.

The common local ASR return path now bounds segment and word estimates to the
selected sample interval on the original normalized timeline. It applies after
model decoding and before JSON emission, independent of whether selection used
RMS, neural edges or complete audio. Original duration, offsets, recognition
text, model/language metadata and interior gaps remain unchanged.

An overlapping interval can be clipped to the actual range, with a visible
timing warning. A wholly out-of-range, non-finite, reversed, malformed or
unordered interval cannot support useful alignment. In that case the full text
is retained in one explicitly approximate utterance range and unreliable word
timing is omitted. Word-timed speaker attribution then rejects unavailable
alignment instead of silently assigning speakers. Native history stores the
timing warning for review before timed export. This does not establish manually
verified word alignment.

Tests include the actual 29.98-second estimate for the 0.8-second selection,
preserved payloads/gaps, clipping at both outer sides, invalid/wholly outside
word intervals, unordered estimates, absent timing and floating-point roundoff.
The frozen-response replay checks every real response from the multilingual
study without rerunning ASR or altering the original evidence. It checks 1,010
responses and corrects all twelve cases. A second harness runs both the old
signed bundle and new development CLI on the same eleven affected model/inputs:
22 paired route results, 42 actual recognitions and two detector abstentions.
All text stays identical and all twelve overruns reproduce and are corrected,
including 34.588 → 5.408 seconds in the German case. Native warning presentation
and export acceptance remain separate gates.

- [Real old/new inference](../../benchmarks/results/asr-timing-live.json)
- [Frozen-response replay](../../benchmarks/results/asr-timing-replay.json)
- [Source checks and explicit acceptance limits](../../benchmarks/results/asr-timing-source-validation.json)
- [Source CI: 304 Swift / 163 Python / 17 CLI cases](../../benchmarks/results/asr-timing-ci.json)

Neural quiet/multilingual quality remains unresolved. The UI warning now makes
partial deletion risk explicit; only an empty result is guaranteed to keep a
completed take available for retry. The shipped `neural-edges-v0` preview is the
earlier source and does not contain this timing fix. Both neural options remain
off by default while candidate selection and validation continue.

## Later native acceptance on checked source 9a51603

The isolated signed preview imports public FLEURS Japanese 005 via the native
file picker using Whisper Small/ja, with both edge filters disabled. Studio and
History show the timing-bound warning. Native save panels produce mode-0600 SRT
ending at 00:00:06,960 and JSON with duration/segment end 6.96 and the warning.
This closes the observed warning and these two timed-export interactions for
that fixture. It does not establish seeking, native VTT, broad alignment quality
or microphone-to-insertion acceptance. The attempted microphone take captures
ChatGPT rather than TextEdit and is discarded before ASR/playback. QA stops with
zero recovery files; normal app/data are visibly restored and the owned TextEdit
fixture is cleaned. See `full-audio-native-timing.json` for exact boundaries.
