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
    assert result["empty_reason"] == "normalized_zero"
    assert not engine.models


@pytest.mark.parametrize(
    "payload",
    [
        {"action": "unknown"},
        {"action": "transcribe", "model": "untrusted/repo"},
        {"action": "transcribe", "path": "unused", "threshold": -1},
        {"action": "transcribe", "path": "unused", "trim": "false"},
        {"action": "meeting", "path": "unused", "trim": 0},
        {"action": "meeting", "path": "unused", "trim": None},
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


def test_missing_larger_text_cache_is_classified_without_download_or_text_echo(tmp_path):
    cache = tmp_path / 'empty-cache'
    cache.mkdir()
    env = dict(os.environ, PYTHONPATH=str(Path(__file__).resolve().parents[1]), HF_HUB_CACHE=str(cache), HF_HUB_OFFLINE='1')
    request = dict(action='rewrite', model='meeting-quality', text='PRIVATE_SYNTHETIC_TEXT', id='a')
    process = subprocess.run([sys.executable, '-m', 'ospr_backend.worker'], input=json.dumps(request)+'\n'+json.dumps(dict(action='ping',id='b'))+'\n',
                             capture_output=True, text=True, timeout=30, env=env)
    rejected, ready = map(json.loads, process.stdout.splitlines())
    assert process.returncode == 0 and not rejected['ok'] and rejected['error_kind'] == 'text-model-not-prepared'
    assert ready['ok'] and 'PRIVATE_SYNTHETIC_TEXT' not in process.stdout+process.stderr
    assert not list(cache.iterdir())


@pytest.mark.parametrize('output_limit', [True, False])
def test_stdio_only_classifies_verified_text_limit_without_exposing_draft(monkeypatch, output_limit):
    import io
    from ospr_backend import worker
    from ospr_backend.local_completion import LocalCompletionError

    def reject(engine, request):
        if request['action'] == 'rewrite':
            raise LocalCompletionError('Original retained.', output_limit=output_limit)
        return {'pid': 123}
    stdin = io.TextIOWrapper(io.BytesIO(b'{"id":"a","action":"rewrite"}\n{"id":"b","action":"ping"}\n'))
    stdout = io.StringIO()
    monkeypatch.setattr(worker.sys, 'stdin', stdin)
    monkeypatch.setattr(worker.sys, 'stdout', stdout)
    monkeypatch.setattr(worker.os, 'setsid', lambda: None)
    monkeypatch.setattr(worker, 'dispatch', reject)
    worker.main()
    rejection, next_reply = map(json.loads, stdout.getvalue().splitlines())
    assert rejection == dict(id='a', ok=False, error='LocalCompletionError: Original retained.', **({'error_kind':'text-output-limit'} if output_limit else {}))
    assert next_reply == dict(id='b', ok=True, result={'pid':123})


def test_stdio_classifies_media_read_rejection_without_error_class_prefix(monkeypatch):
    import io
    from ospr_backend import worker
    from ospr_backend.audio import MediaReadError

    def reject(engine, request):
        if request['action'] == 'transcribe':
            raise MediaReadError('This file could not be read as audio. The source is unchanged.')
        return {'pid': 123}

    stdin = io.TextIOWrapper(io.BytesIO(b'{"id":"a","action":"transcribe"}\n{"id":"b","action":"ping"}\n'))
    stdout = io.StringIO()
    monkeypatch.setattr(worker.sys, 'stdin', stdin)
    monkeypatch.setattr(worker.sys, 'stdout', stdout)
    monkeypatch.setattr(worker.os, 'setsid', lambda: None)
    monkeypatch.setattr(worker, 'dispatch', reject)
    worker.main()
    rejection, next_reply = map(json.loads, stdout.getvalue().splitlines())
    assert rejection == dict(id='a', ok=False, error='This file could not be read as audio. The source is unchanged.', error_kind='media-read')
    assert next_reply == dict(id='b', ok=True, result={'pid':123})
