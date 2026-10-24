"""Local model finish acknowledgement, independent of lexical fidelity checks."""
import sys
from types import SimpleNamespace

import pytest
from ospr_backend.engine import Engine
from ospr_backend.local_completion import LocalCompletionError, completed_text


def frame(text='', reason=None, token=3, count=1):
    return SimpleNamespace(text=text, finish_reason=reason, token=token, generation_tokens=count)


@pytest.mark.parametrize('pieces', [
    [frame(' 完了。 ', 'stop', 2)],
    [frame('完'), frame('', count=2), frame('了。', 'stop', 2, 3)],
    [frame('Done.'), frame('', 'stop', 2, 2)],
])
def test_eos_completion_preserves_unicode_and_final_flush(pieces):
    result = completed_text(iter(pieces), eos_token_ids={2, 4}, max_tokens=len(pieces))
    assert result == dict(text='完了。' if len(pieces) != 2 else 'Done.', finish_reason='stop', generation_tokens=len(pieces))


@pytest.mark.parametrize('pieces', [
    [], [frame('{"items":[]}')], [frame('draft', 'stop', 3)],
    [frame('draft', None, 2)], [frame('draft', 'length', 3)],
    [frame('draft', 'stop', 2), frame('extra', count=2)],
    [frame('draft', 'length', 3, 3)], [frame('draft', count=2)],
    [frame('draft', token=-1)], [frame('draft', token=True)],
    [frame('draft', count=True)], [frame(None, 'stop', 2)],
    [frame('', 'stop', 2)], [frame(' ', 'stop', 2)],
    [frame('draft', 'unknown', 2)],
    [frame('draft', 'length', 3), frame('extra', count=2)],
])
def test_malformed_or_unacknowledged_completion_cannot_keep_worker(pieces):
    with pytest.raises(LocalCompletionError) as caught:
        completed_text(iter(pieces), eos_token_ids={2}, max_tokens=2)
    assert not caught.value.output_limit
    assert 'draft' not in str(caught.value)


def test_only_exact_budget_stop_is_recoverable_and_never_delivers_partial_json():
    with pytest.raises(LocalCompletionError) as caught:
        completed_text(iter([frame('{"items":[]}', 'length')]), eos_token_ids={2}, max_tokens=1)
    assert caught.value.output_limit
    assert '{' not in str(caught.value)


@pytest.mark.parametrize('eos,budget', [(set(), 2), ({True}, 2), ({-1}, 2), ({'2'}, 2), ({2}, True), ({2}, 0)])
def test_invalid_completion_configuration_is_not_a_recoverable_limit(eos, budget):
    with pytest.raises(LocalCompletionError) as caught:
        completed_text(iter([]), eos_token_ids=eos, max_tokens=budget)
    assert not caught.value.output_limit


def test_early_failure_closes_mlx_generator_scope():
    closed = []
    def responses():
        try:
            yield frame('draft', 'stop', 3)
            pytest.fail('must not request more tokens after invalid terminal frame')
        finally:
            closed.append(True)
    with pytest.raises(LocalCompletionError):
        completed_text(responses(), eos_token_ids={2}, max_tokens=2)
    assert closed == [True]


def test_runtime_failure_after_partial_output_cannot_return_a_draft():
    def responses():
        yield frame('draft')
        raise RuntimeError('inference failed')
    with pytest.raises(RuntimeError, match='inference failed'):
        completed_text(responses(), eos_token_ids={2}, max_tokens=2)


def test_close_failure_cannot_be_treated_as_output_limit():
    class Responses:
        def __init__(self): self.items = iter([frame('draft', 'length')])
        def __iter__(self): return self
        def __next__(self): return next(self.items)
        def close(self): raise RuntimeError('cleanup failed')
    with pytest.raises(LocalCompletionError) as caught:
        completed_text(Responses(), eos_token_ids={2}, max_tokens=1)
    assert not caught.value.output_limit


@pytest.mark.parametrize('task', ['transcript','edit-selection','source-selection','meeting-summary'])
@pytest.mark.parametrize('reason', ['length', None])
def test_rewrite_cannot_deliver_balanced_draft_without_eos(task, reason, monkeypatch):
    from ospr_backend import engine as module
    frame = SimpleNamespace(text='{"items":[]}', finish_reason=reason, token=3, generation_tokens=1)
    tokenizer = SimpleNamespace(apply_chat_template=lambda *args, **kwargs:'prompt',encode=lambda _: [1],eos_token_ids={2})
    monkeypatch.setattr(module,'resolve_model',lambda *args:'cached-model')
    monkeypatch.setitem(sys.modules,'mlx_lm',SimpleNamespace(load=lambda _:('model',tokenizer),generate=lambda *args,**kwargs: frame.text,stream_generate=lambda *args,**kwargs: iter([frame])))
    with pytest.raises(ValueError,match='completion'):
        Engine().rewrite('Public transcript.', 'Return JSON.', task=task)
