import json
import os
from pathlib import Path
import subprocess
import sys

import numpy as np
import pytest
import soundfile as sf

from ospr_backend.engine import Engine
from ospr_backend.worker import dispatch


def test_silence_never_loads_a_model(tmp_path):
    path = tmp_path / "silence.wav"
    sf.write(path, np.zeros(16000), 16000)
    engine = Engine()
    result = engine.transcribe(str(path))
    assert result["silence"]
    assert result["text"] == ""
    assert not engine.models


@pytest.mark.parametrize(
    "payload",
    [
        {"action": "unknown"},
        {"action": "transcribe", "model": "untrusted/repo"},
        {"action": "transcribe", "path": "unused", "threshold": -1},
        {"action": "rewrite", "text": "a" * 100001},
    ],
)
def test_invalid_requests_fail_before_loading(payload):
    with pytest.raises(ValueError):
        dispatch(Engine(), payload)


def test_stdio_protocol_recovers_after_bad_request():
    env = dict(os.environ, PYTHONPATH=str(Path(__file__).resolve().parents[1]))
    process = subprocess.run(
        [sys.executable, "-m", "ospr_backend.worker"],
        input='invalid json\n{"action":"ping","id":"a"}\n{"action":"bad","id":"b"}\n{"action":"ping","id":"c"}\n',
        capture_output=True,
        text=True,
        timeout=30,
        env=env,
    )
    replies = [json.loads(line) for line in process.stdout.splitlines()]
    assert process.returncode == 0
    assert len(replies) == 4
    assert not replies[0]["ok"]
    assert replies[1]["id"] == "a" and replies[1]["ok"]
    assert replies[2]["id"] == "b" and not replies[2]["ok"]
    assert replies[3]["id"] == "c" and replies[3]["ok"]


def test_non_object_json_is_not_a_protocol_crash():
    env = dict(os.environ, PYTHONPATH=str(Path(__file__).resolve().parents[1]))
    process = subprocess.run(
        [sys.executable, "-m", "ospr_backend.worker"],
        input='[]\n{"action":"ping"}\n',
        capture_output=True,
        text=True,
        timeout=30,
        env=env,
    )
    assert len(process.stdout.splitlines()) == 2
    assert not json.loads(process.stdout.splitlines()[0])["ok"]
    assert json.loads(process.stdout.splitlines()[1])["ok"]
