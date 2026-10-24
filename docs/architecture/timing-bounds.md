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
study without rerunning ASR or altering the original evidence. New real
inference, native warning presentation and export acceptance are separate gates.

Neural quiet/multilingual quality remains unresolved. The UI warning now makes
partial deletion risk explicit; only an empty result is guaranteed to keep a
completed take available for retry. The shipped `neural-edges-v0` preview is the
earlier source and does not contain this timing fix. Both neural options remain
off by default while candidate selection and validation continue.
