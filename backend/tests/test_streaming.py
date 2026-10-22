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

    def feed(self, audio):
        self.samples += len(audio)

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
