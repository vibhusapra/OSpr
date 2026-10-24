"""Partition-independent waveform, final-tail and bounded-state contracts."""

from math import gcd

import numpy as np
import pytest
import soundfile as sf
from scipy.signal import resample_poly

from ospr_backend.streaming_audio import NATIVE_RATES, StreamNormalizer, read_stream_packet


def whole(audio, rate):
    divisor = gcd(rate, 16000)
    return np.clip(resample_poly(audio, 16000 // divisor, rate // divisor), -1, 1)


@pytest.mark.parametrize("rate", sorted(NATIVE_RATES))
@pytest.mark.parametrize("packet", [37, 1024, 8192])
def test_packets_equal_whole_file_at_every_supported_rate(rate, packet):
    # Includes clipping and values near float32 zero; resample before clipping.
    rng = np.random.default_rng(rate)
    audio = rng.normal(0, 0.8, rate // 5 + 13).astype(np.float32)
    audio[:7] = np.array([0, -0.0, 1e-12, -1e-12, 2, -2, 0], dtype=np.float32)
    normalizer = StreamNormalizer(rate)
    chunks = [normalizer.feed(audio[i:i + packet]) for i in range(0, len(audio), packet)]
    chunks.append(normalizer.feed([], final=True))
    result = np.concatenate(chunks)
    np.testing.assert_array_equal(result, whole(audio, rate))
    assert result.tobytes() == whole(audio, rate).tobytes()
    assert normalizer.received == len(audio) and normalizer.emitted == len(result)
    assert normalizer.closed and not len(normalizer.buffer)
    with pytest.raises(ValueError, match="closed"):
        normalizer.feed([])


@pytest.mark.parametrize("rate", [8000, 44100, 48000, 192000])
def test_tiny_final_tail_random_partitions_and_retained_memory(rate):
    rng = np.random.default_rng(20261024)
    for length in [1, 2, 7, 29, 441, rate * 3 + 11]:
        audio = rng.uniform(-0.7, 0.7, length).astype(np.float32)
        audio[-1] = 1  # Last sample must contribute even when no live output is safe.
        normalizer, position, chunks = StreamNormalizer(rate), 0, []
        while position < len(audio):
            end = min(len(audio), position + int(rng.integers(1, 2048)))
            chunks.append(normalizer.feed(audio[position:end]))
            # This bound depends on filter/phase, never recording duration.
            assert len(normalizer.buffer) <= 2 * normalizer.halo + 2 * normalizer.down
            chunks.append(normalizer.feed([]))
            position = end
        chunks.append(normalizer.feed([], final=True))
        np.testing.assert_array_equal(np.concatenate(chunks), whole(audio, rate))


def test_empty_stream_and_final_packet_without_separate_flush():
    empty = StreamNormalizer(48000)
    assert not len(empty.feed([], final=True)) and empty.closed
    audio = np.array([0, 1, -1], dtype=np.float32)
    direct = StreamNormalizer(44100)
    np.testing.assert_array_equal(direct.feed(audio, final=True), whole(audio, 44100))


def test_invalid_packets_do_not_advance_state(tmp_path, monkeypatch):
    normalizer = StreamNormalizer(48000)
    for invalid in [[float("nan")], [float("inf")], [[0]], np.zeros(48000 * 13)]:
        with pytest.raises(ValueError):
            normalizer.feed(invalid)
        assert normalizer.received == normalizer.emitted == 0
    with pytest.raises(ValueError, match="sample rate"):
        StreamNormalizer(47999)
    packet = tmp_path / "packet.wav"
    sf.write(packet, np.zeros((13 * 48000, 2)), 48000, subtype="FLOAT")
    # Header limits must reject before allocating a decoded packet.
    monkeypatch.setattr(sf.SoundFile, "read", lambda *_a, **_k: pytest.fail("decoded oversized input"))
    with pytest.raises(ValueError, match="at most"):
        read_stream_packet(packet)
    sf.write(packet, np.zeros((48000, 32)), 48000, subtype="FLOAT")
    import ospr_backend.streaming_audio as module
    monkeypatch.setattr(module, "MAX_PACKET_BYTES", 1024)
    with pytest.raises(ValueError, match="memory"):
        read_stream_packet(packet)


def test_native_reader_preserves_unclipped_mono_and_downmix(tmp_path):
    packet = tmp_path / "packet.wav"
    stereo = np.array([[2, 0], [-3, -1], [0, 1e-9]], dtype=np.float32)
    sf.write(packet, stereo, 44100, subtype="FLOAT")
    audio, rate = read_stream_packet(packet)
    assert rate == 44100
    np.testing.assert_array_equal(audio, stereo.mean(axis=1))
    sf.write(packet, [0, float("nan")], 16000, subtype="FLOAT")
    with pytest.raises(ValueError, match="non-finite"):
        read_stream_packet(packet)
