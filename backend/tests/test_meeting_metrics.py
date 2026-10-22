"""Known activity examples verify the independently reported diagnostic DER."""

import importlib.util
from pathlib import Path
import sys
import pytest

# Benchmark scoring is an evaluation concern, outside the runtime package.
ROOT = Path(__file__).resolve().parents[2] / "benchmarks"
sys.path.insert(0, str(ROOT))
spec = importlib.util.spec_from_file_location("ospr_meeting_metrics", ROOT / "meetings.py")
metrics = importlib.util.module_from_spec(spec)
spec.loader.exec_module(metrics)


def segment(start, end, speaker):
    return dict(start=start, end=end, speaker=speaker)


def test_der_is_permutation_invariant_and_counts_overlap_misses():
    reference = [segment(0, 1, 0), segment(1, 2, 1)]
    swapped = [segment(0, 1, 3), segment(1, 2, 2)]
    assert metrics.diarization_score(reference, swapped, 2, collar=0)["der"] == 0
    reference = [segment(0, 1, 0), segment(0, 1, 1)]
    missed = [segment(0, 1, 2)]
    assert metrics.diarization_score(reference, missed, 1, collar=0)["der"] == 0.5


def test_der_counts_false_alarm_and_confusion_in_seconds():
    reference = [segment(0, 1, 0)]
    hypothesis = [segment(0, 1.5, 3)]
    result = metrics.diarization_score(reference, hypothesis, 2, collar=0)
    assert result["der"] == 0.5 and result["false_alarm_seconds"] == 0.5
    result = metrics.diarization_score([segment(0, 1, 0), segment(1, 2, 1)], [segment(0, 2, 2)], 2, collar=0)
    assert result["der"] == 0.5 and result["confusion_seconds"] == 1


def test_collar_masks_reference_boundaries_explicitly():
    result = metrics.diarization_score([segment(0, 1, 0)], [segment(0, 1, 1)], 1, collar=0.25)
    assert result["der"] == 0
    assert result["reference_speaker_seconds"] == pytest.approx(0.5)
