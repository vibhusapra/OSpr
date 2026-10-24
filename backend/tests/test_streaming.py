"""Session fencing and packet limits without downloading model weights."""

import numpy as np
import pytest
import soundfile as sf
from ospr_backend.engine import Engine


class Session:
    def __init__(self):
        self.done = False
        self.closed = False
        self.cancelled = False
        self.samples = 0
        self.audio = []

    def feed(self, audio):
        self.samples += len(audio)
        self.audio.append(audio.copy())

    def close(self):
        self.closed = True

    def step(self, **_):
        if self.closed:
            self.done = True
            return [" complete"]
        return []

    def cancel(self):
        self.cancelled = True


def prepared():
    engine = Engine()
    engine.stream = Session()
    engine.stream_id = "current"
    return engine


def test_expired_request_cannot_feed_or_cancel_a_new_session():
    engine = prepared()
    with pytest.raises(ValueError, match="Expired"):
        engine.stream_feed(final=True, session_id="expired")
    assert engine.stream_cancel(session_id="expired") == {"cancelled": False}
    assert not engine.stream.cancelled
    result = engine.stream_feed(final=True, session_id="current")
    assert result["done"] and result["text"] == "complete"
    assert engine.stream is None


def test_packets_are_bounded_and_keep_silence(tmp_path):
    engine = prepared()
    packet = tmp_path / "packet.wav"
    sf.write(packet, np.zeros(16000), 16000)
    engine.stream_feed(str(packet), session_id="current")
    assert engine.stream.samples == 16000
    sf.write(packet, np.zeros(16000 * 13), 16000)
    with pytest.raises(ValueError, match="at most"):
        engine.stream_feed(str(packet), session_id="current")
    assert engine.stream.samples == 16000
    session = engine.stream
    assert engine.stream_cancel(session_id="current")["cancelled"]
    assert session.cancelled


def test_native_packets_flush_tail_before_close_and_reset(tmp_path):
    from ospr_backend.audio import read_audio

    engine, packet = prepared(), tmp_path / "packet.wav"
    session = engine.stream
    audio = np.random.default_rng(42).uniform(-0.4, 0.4, 44113).astype(np.float32)
    sf.write(packet, audio, 44100, subtype="FLOAT")
    expected = read_audio(packet)
    for start in range(0, len(audio), 1024):
        sf.write(packet, audio[start:start + 1024], 44100, subtype="FLOAT")
        engine.stream_feed(str(packet), session_id="current")
    assert session.samples < len(expected)  # FIR needs the final zero-padded tail.
    engine.stream_feed(final=True, session_id="current")
    np.testing.assert_array_equal(np.concatenate(session.audio), expected)
    assert session.closed and engine.stream_normalizer is None and engine.stream_id is None


def test_rate_change_is_rejected_without_advancing_and_cancel_releases_state(tmp_path):
    engine, packet = prepared(), tmp_path / "packet.wav"
    sf.write(packet, np.zeros(1024), 48000)
    engine.stream_feed(str(packet), session_id="current")
    count = engine.stream_normalizer.received
    sf.write(packet, np.zeros(1024), 44100)
    with pytest.raises(ValueError, match="sample rate changed"):
        engine.stream_feed(str(packet), session_id="current")
    assert engine.stream_normalizer.received == count
    engine.stream_cancel(session_id="current")
    assert engine.stream_normalizer is None
    engine.stream = Session()
    engine.stream_id = "next"
    engine.stream_feed(str(packet), session_id="next")
    assert engine.stream_normalizer.sample_rate == 44100


def test_replacing_session_cancels_previous_stream_and_normalizer(monkeypatch, tmp_path):
    engine, packet = prepared(), tmp_path / "packet.wav"
    sf.write(packet, np.zeros(1024), 48000)
    engine.stream_feed(str(packet), session_id="current")
    old = engine.stream
    class Model:
        prompt_dictionary = {"en-US": 0}
        def create_streaming_session(self, **_):
            return Session()
    monkeypatch.setattr(engine, "_load", lambda _: (Model(), True))
    engine.stream_begin("en")
    assert old.cancelled and engine.stream_normalizer is None and engine.stream_id != "current"
