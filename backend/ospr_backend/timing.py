"""Keep recognizer estimates inside the actual analyzed source interval.

Recognition text is never removed to repair timestamps. If an interval cannot
be mapped to usable source audio, retain the transcript with one explicitly
approximate utterance range and omit unreliable word timing.
"""
import math
from numbers import Real


def bound_timings(segments, words, *, start, end, text, granularity):
    if not math.isfinite(start) or not math.isfinite(end) or not 0 <= start < end:
        raise ValueError("Invalid analyzed audio interval.")
    clipped = 0

    def bounded(rows):
        nonlocal clipped
        if not isinstance(rows, (list, tuple)):
            return None
        output = []
        for row in rows:
            if not isinstance(row, dict):
                return None
            a, b = row.get("start"), row.get("end")
            if (isinstance(a, bool) or isinstance(b, bool) or not isinstance(a, Real) or not isinstance(b, Real)
                    or not math.isfinite(a) or not math.isfinite(b) or a > b):
                return None
            left, right = max(start, min(end, float(a))), max(start, min(end, float(b)))
            # A wholly out-of-range interval cannot support a word/segment
            # alignment. Do not manufacture a zero-duration interval at EOF.
            if (a != b and left == right) or (a == b and not start <= a <= end):
                return None
            if output and left < output[-1]["start"]:
                return None
            if not math.isclose(left, a, rel_tol=0, abs_tol=1e-9) or not math.isclose(right, b, rel_tol=0, abs_tol=1e-9):
                clipped += 1
            output.append(dict(row, start=left, end=right))
        return output

    bounded_segments, bounded_words = bounded(segments), bounded(words)
    fallback = bounded_segments is None or bounded_words is None or (bool(text.strip()) and not bounded_segments)
    if fallback:
        return dict(segments=[dict(start=start, end=end, text=text.strip())] if text.strip() else [], words=[],
            timestamp_granularity="utterance", timing_corrections=dict(clipped_intervals=clipped, fallback_to_utterance=True),
            timing_warning="The recognizer returned unusable timings. The transcript is kept with an approximate utterance range; word timing is unavailable.")
    result = dict(segments=bounded_segments, words=bounded_words, timestamp_granularity=granularity)
    if clipped:
        result.update(timing_corrections=dict(clipped_intervals=clipped, fallback_to_utterance=False),
                      timing_warning="Some recognizer timings extended outside the analyzed audio and were bounded. Check alignment before using timed exports.")
    return result
