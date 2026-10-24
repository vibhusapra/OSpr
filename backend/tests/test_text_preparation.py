"""Explicit synthetic text preparation must not download, expose output or evict ASR."""
import sys
from types import SimpleNamespace

import pytest
from huggingface_hub.errors import LocalEntryNotFoundError

from ospr_backend import engine as module
from ospr_backend.engine import Engine
from ospr_backend.refinement import LocalModelNotPrepared
from ospr_backend.worker import dispatch


def fake_model(monkeypatch):
    loads, generations, conversations = [], [], []
    tokenizer = SimpleNamespace(apply_chat_template=lambda rows, **kw: conversations.append(rows) or 'prompt', eos_token_ids={2})
    monkeypatch.setitem(sys.modules, 'mlx_lm', SimpleNamespace(
        load=lambda path: loads.append(path) or ('model', tokenizer),
        stream_generate=lambda *args, **kw: generations.append(kw) or iter([SimpleNamespace(text='Discarded synthetic answer.', finish_reason='stop', token=2, generation_tokens=1)])))
    paths = []
    monkeypatch.setattr(module, 'resolve_model', lambda model, progress=None, **kw: paths.append((model, kw)) or model)
    return loads, generations, conversations, paths


def test_text_preparation_is_cache_only_idempotent_and_does_not_return_synthetic_output(monkeypatch):
    loads, generations, conversations, paths = fake_model(monkeypatch)
    engine = Engine()
    speech = object()
    engine.models['parakeet-v3'] = speech
    first = dispatch(engine, dict(action='warm_text', model='rewrite-quality', text='UNUSED_PRIVATE_SENTINEL'))
    second = dispatch(engine, dict(action='warm_text', model='rewrite-quality'))
    assert paths == [('rewrite-quality', {'cache_only': True})] and loads == ['rewrite-quality']
    assert len(generations) == 1 and len(conversations) == 1
    assert 'The model is ready.' in conversations[0][1]['content']
    assert first['primed'] and first['cache_only'] and not first['already_prepared'] and first['generation_tokens'] == 1
    assert second['already_prepared'] and second['prime_ms'] == 0 and second['generation_tokens'] == 0
    assert engine.primed_text_model == 'rewrite-quality' and engine.models['parakeet-v3'] is speech
    assert 'text' not in first and 'Discarded' not in str(first) and 'UNUSED_PRIVATE_SENTINEL' not in str(first)
    status = dispatch(engine, dict(action='model_status'))
    assert status['rewrite_primed'] == status['rewrite_resident'] == 'rewrite-quality'


@pytest.mark.parametrize('value', ['untrusted/repo', 'rewrite', None, True, [], {}])
def test_invalid_preparation_choice_stops_before_import_or_model_mutation(monkeypatch, value):
    monkeypatch.setitem(sys.modules, 'mlx_lm', None)
    engine = Engine()
    engine.rewriter = 'existing'
    engine.rewriter_id = 'rewrite-quality'
    with pytest.raises(ValueError, match='Choose'):
        dispatch(engine, dict(action='warm_text', model=value))
    assert engine.rewriter == 'existing' and engine.rewriter_id == 'rewrite-quality'


def test_missing_cache_preserves_existing_text_and_speech_models(monkeypatch):
    fake_model(monkeypatch)
    def missing(*args, **kwargs):
        assert kwargs == {'cache_only': True}
        raise LocalEntryNotFoundError('missing')
    monkeypatch.setattr(module, 'resolve_model', missing)
    engine = Engine()
    speech = object()
    engine.models['parakeet-v3'] = speech
    engine.rewriter, engine.rewriter_id, engine.primed_text_model = 'old-model', 'rewrite-quality', 'rewrite-quality'
    with pytest.raises(LocalModelNotPrepared, match='Download'):
        engine.warm_text('meeting-quality')
    assert engine.rewriter == 'old-model' and engine.primed_text_model == 'rewrite-quality'
    assert engine.models['parakeet-v3'] is speech


def test_text_switch_evicts_previous_prepared_marker_and_load_failure_cannot_report_old_resident(monkeypatch):
    loads, generations, _, _ = fake_model(monkeypatch)
    engine = Engine()
    for model in ['rewrite-quality', 'meeting-quality', 'meeting-quality', 'rewrite-quality']:
        engine.warm_text(model)
        assert engine.primed_text_model == engine.rewriter_id == model
    assert loads == ['rewrite-quality', 'meeting-quality', 'rewrite-quality'] and len(generations) == 3
    def fail(path):
        assert engine.rewriter is None and engine.rewriter_id is None and engine.primed_text_model is None
        raise RuntimeError('failed load')
    sys.modules['mlx_lm'].load = fail
    with pytest.raises(RuntimeError, match='failed load'):
        engine.warm_text('meeting-quality')
    assert engine.rewriter is None and engine.rewriter_id is None and engine.primed_text_model is None


def test_unacknowledged_synthetic_completion_never_marks_prepared_and_retry_can_succeed(monkeypatch):
    fake_model(monkeypatch)
    from ospr_backend.local_completion import LocalCompletionError
    good = sys.modules['mlx_lm'].stream_generate
    sys.modules['mlx_lm'].stream_generate = lambda *args, **kwargs: iter([SimpleNamespace(text='Unacknowledged.', finish_reason='stop', token=99, generation_tokens=1)])
    engine = Engine()
    with pytest.raises(LocalCompletionError):
        engine.warm_text('rewrite-quality')
    assert engine.rewriter is not None and engine.primed_text_model is None
    sys.modules['mlx_lm'].stream_generate = good
    assert not engine.warm_text('rewrite-quality')['already_prepared']
