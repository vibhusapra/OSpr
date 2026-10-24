import hashlib
import io

import librosa
import numpy as np
import pytest

from ospr_backend import parakeet_loader


def test_packaged_filters_match_independent_upstream_reference_exactly():
    expected = librosa.filters.mel(sr=16000, n_fft=512, n_mels=128,
                                  fmin=0, fmax=8000, norm="slaney")
    actual = parakeet_loader.filterbank(16000, 512, 128)
    assert actual.dtype == expected.dtype == np.float32
    assert np.array_equal(actual, expected)


@pytest.mark.parametrize("spec", [(48000, 512, 128), (16000, 1024, 128), (16000, 512, 80)])
def test_changed_preprocessor_cannot_silently_reuse_filters(spec):
    with pytest.raises(ValueError, match="newly verified"):
        parakeet_loader.filterbank(*spec)


def test_damaged_filter_asset_is_rejected_before_parsing(tmp_path, monkeypatch):
    path = tmp_path / "damaged.npy"
    data = bytearray(parakeet_loader.FILTER_PATH.read_bytes())
    data[-1] ^= 1
    path.write_bytes(data)
    monkeypatch.setattr(parakeet_loader, "FILTER_PATH", path)
    with pytest.raises(ValueError, match="integrity"):
        parakeet_loader.filterbank(16000, 512, 128)


@pytest.mark.parametrize("filters", [np.zeros((128, 257), dtype=np.float64),
                                    np.zeros((80, 257), dtype=np.float32),
                                    np.full((128, 257), np.nan, dtype=np.float32)])
def test_filter_format_is_validated_even_with_matching_checksum(tmp_path, monkeypatch, filters):
    output = io.BytesIO()
    np.save(output, filters, allow_pickle=False)
    data = output.getvalue()
    path = tmp_path / "wrong-format.npy"
    path.write_bytes(data)
    monkeypatch.setattr(parakeet_loader, "FILTER_PATH", path)
    monkeypatch.setattr(parakeet_loader, "FILTER_SHA256", hashlib.sha256(data).hexdigest())
    with pytest.raises(ValueError, match="Invalid packaged"):
        parakeet_loader.filterbank(16000, 512, 128)
