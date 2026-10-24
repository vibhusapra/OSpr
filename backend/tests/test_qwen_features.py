"""Prompt accounting parity, safe fallback, private API and lifetime checks."""

import ast
import hashlib
import importlib.util
from pathlib import Path
from types import SimpleNamespace
import weakref
import inspect
import textwrap

import numpy as np
import pytest

from ospr_backend import qwen_features as qf


class Model:
    def __init__(self, dither=0):
        self._feature_extractor = SimpleNamespace(dither=dither)
        self._tokenizer = SimpleNamespace(decode=lambda tokens, **kw: str(tokens))
        self.calls = self.builds = 0
        self.feature_refs = []
        self.options = None
        self.tokens = [7, 9]
        self.omit_prompt = self.fail = self.change_dither = False

    def _preprocess_audio(self, audio):
        self.calls += 1
        features = audio.copy()
        self.feature_refs.append(weakref.ref(features))
        return features, None, int(audio.sum())

    def _build_prompt(self, count, language=None, system_prompt=None):
        self.builds += 1
        return np.ones((1, count + 4), dtype=np.int32)

    def stream_generate(self, audio, **kwargs):
        self.options = kwargs
        if not self.omit_prompt:
            features, _, count = self._preprocess_audio(audio)
            self._build_prompt(count, kwargs['language'], kwargs['system_prompt'])
            del features
        if self.change_dither:
            self._feature_extractor.dither = 0.1
        for token in self.tokens:
            if self.fail:
                raise ValueError('fixture stream failure')
            yield token, None

    def _generate_single_chunk(self, audio, **kwargs):
        tokens, prompt = [], 0
        for token, _ in self.stream_generate(audio, **kwargs):
            if prompt == 0:
                _, _, count = self._preprocess_audio(audio)
                prompt = self._build_prompt(count, kwargs['language'], kwargs['system_prompt']).shape[1]
            tokens.append(int(token))
        return self._tokenizer.decode(tokens, skip_special_tokens=True), prompt, len(tokens)

    def generate(self, audio, **kwargs):
        return self._generate_single_chunk(audio, **kwargs)


OPTIONS = dict(max_tokens=20, sampler=None, logits_processors=None, language='en',
               prefill_step_size=1024, verbose=False, system_prompt='names')


@pytest.fixture
def supported(monkeypatch):
    # The fixture emulates the supported loop; production requires its exact AST.
    monkeypatch.setattr(qf, '_supported_chunk', lambda f: f is Model._generate_single_chunk)
    monkeypatch.setenv('OSPR_QWEN_FEATURE_REUSE', '1')


def test_pinned_upstream_chunk_ast_matches_without_importing_gpu_model():
    spec = importlib.util.find_spec('mlx_audio')
    if spec is None:
        pytest.skip('optional MLX Audio is not installed')
    source = Path(spec.origin).parent / 'stt/models/qwen3_asr/qwen3_asr.py'
    text = source.read_text()
    tree = ast.parse(text)
    chunk = next(n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef) and n.name == '_generate_single_chunk')
    # inspect.getsource is dedented before hashing, including docstring whitespace.
    normalized = ast.parse(textwrap.dedent(''.join(text.splitlines(keepends=True)[chunk.lineno - 1:chunk.end_lineno])))
    assert hashlib.sha256(ast.dump(normalized.body[0], include_attributes=False).encode()).hexdigest() == qf._CHUNK_AST_SHA256


def test_unknown_private_loop_falls_back_and_signature_guard_handles_uninspectable(monkeypatch):
    monkeypatch.setenv('OSPR_QWEN_FEATURE_REUSE', '1')
    model = Model()
    result, work = qf.generate(model, np.ones(8), **OPTIONS)
    assert result == ('[7, 9]', 12, 2)
    assert not work.enabled and work.evaluations == 2 and work.hits == 0
    assert not qf._supported_chunk(len)


def test_exact_output_and_options_with_one_frontend_and_prompt_build(supported, monkeypatch):
    audio = np.ones(8)
    baseline = Model()
    monkeypatch.setenv('OSPR_QWEN_FEATURE_REUSE', '0')
    before, off = qf.generate(baseline, audio, **OPTIONS)
    model = Model()
    monkeypatch.setenv('OSPR_QWEN_FEATURE_REUSE', '1')
    after, on = qf.generate(model, audio, **OPTIONS)
    assert before == after == ('[7, 9]', 12, 2)
    assert model.options == baseline.options == OPTIONS
    assert off.evaluations == 2 and off.hits == 0 and not off.enabled
    assert on.evaluations == 1 and on.hits == 1 and on.enabled
    assert model.calls == model.builds == 1
    assert not any(name.startswith('_ospr') for name in vars(model))
    assert '_generate_single_chunk' not in vars(model) and '_build_prompt' not in vars(model)


def test_each_decode_runs_fresh_frontend_even_for_mutated_same_pcm(supported):
    model, audio = Model(), np.ones(8)
    with qf.reuse_features(model) as work:
        assert model.generate(audio, **OPTIONS)[1] == 12
        audio[0] = 9
        assert model.generate(audio, **OPTIONS)[1] == 20
        assert work.evaluations == 2 and work.hits == 2
        assert all(ref() is None for ref in model.feature_refs)
    assert all(ref() is None for ref in model.feature_refs)


def test_zero_tokens_keep_original_zero_prompt_accounting(supported):
    model = Model()
    model.tokens = []
    result, work = qf.generate(model, np.ones(8), **OPTIONS)
    assert result == ('[]', 0, 0) and work.evaluations == 1 and work.hits == 0


def test_custom_stream_without_prompt_uses_original_accounting(supported):
    model = Model()
    model.omit_prompt = True
    result, work = qf.generate(model, np.ones(8), **OPTIONS)
    assert result == ('[7, 9]', 12, 2) and work.evaluations == 1 and work.hits == 0


@pytest.mark.parametrize('initial,change', [(0.1, False), (0, True)])
def test_stochastic_frontend_and_mid_stream_change_keep_original_work(supported, initial, change):
    model = Model(initial)
    model.change_dither = change
    result, work = qf.generate(model, np.ones(8), **OPTIONS)
    assert result == ('[7, 9]', 12, 2) and work.evaluations == 2 and work.hits == 0


def test_exception_restores_every_hook_and_next_call_is_fresh(supported):
    model = Model()
    original = vars(model).copy()
    model.fail = True
    with pytest.raises(ValueError, match='fixture stream failure'):
        qf.generate(model, np.ones(8), **OPTIONS)
    for name in ['_generate_single_chunk', '_build_prompt', '_preprocess_audio', '_ospr_reusing_features']:
        assert name not in vars(model)
    model.fail = False
    assert qf.generate(model, np.ones(8), **OPTIONS)[1].hits == 1
    assert model._feature_extractor is original['_feature_extractor']


def test_existing_instance_methods_and_nested_scope_restore_exact_objects(supported):
    model = Model()
    model._build_prompt = model._build_prompt
    previous = model._build_prompt
    with qf.reuse_features(model) as outer:
        method = model._generate_single_chunk
        with qf.reuse_features(model) as inner:
            assert not inner.enabled and model._generate_single_chunk is method
            assert model.generate(np.ones(8), **OPTIONS) == ('[7, 9]', 12, 2)
        assert outer.evaluations == outer.hits == 1
    assert vars(model)['_build_prompt'] is previous


def test_bound_generation_owner_receives_hooks(supported):
    owner = Model()
    view = SimpleNamespace(generate=owner.generate)
    assert view.generate.__self__ is owner
    result, work = qf.generate(view, np.ones(8), **OPTIONS)
    assert result == ('[7, 9]', 12, 2) and work.evaluations == work.hits == 1
    assert vars(view).keys() == {'generate'}


def test_missing_frontend_passes_through_unchanged():
    model = SimpleNamespace(generate=lambda audio, **kw: (audio, kw))
    result, work = qf.generate(model, 'audio', language='en')
    assert result == ('audio', {'language': 'en'}) and not work.enabled


def test_source_guard_hashes_the_same_dedented_function_representation(monkeypatch):
    function = Model._generate_single_chunk
    tree = ast.parse(textwrap.dedent(inspect.getsource(function)))
    digest = hashlib.sha256(ast.dump(tree.body[0], include_attributes=False).encode()).hexdigest()
    qf._supported_chunk.cache_clear()
    try:
        with monkeypatch.context() as patch:
            patch.setattr(qf, '_CHUNK_AST_SHA256', digest)
            assert qf._supported_chunk(function)
    finally:
        qf._supported_chunk.cache_clear()


@pytest.mark.parametrize('mode', [None, '', 'true', '2'])
def test_default_and_unknown_modes_leave_upstream_unwrapped(monkeypatch, mode):
    if mode is None:
        monkeypatch.delenv('OSPR_QWEN_FEATURE_REUSE', raising=False)
    else:
        monkeypatch.setenv('OSPR_QWEN_FEATURE_REUSE', mode)
    monkeypatch.setattr(qf, 'reuse_features', lambda *a, **kw: pytest.fail('default must not install hooks'))
    model = Model()
    result, work = qf.generate(model, np.ones(8), **OPTIONS)
    assert result == ('[7, 9]', 12, 2) and model.calls == 2
    assert not work.enabled and work.evaluations == work.hits == 0


def test_unhashable_custom_chunk_callable_falls_back_safely(monkeypatch):
    monkeypatch.setenv('OSPR_QWEN_FEATURE_REUSE', '1')
    model = Model()

    class Chunk:
        __hash__ = None

        def __call__(self, audio, **kwargs):
            return ('custom', 5, 1)

    model._generate_single_chunk = Chunk()
    result, work = qf.generate(model, np.ones(8), **OPTIONS)
    assert result == ('custom', 5, 1) and not work.enabled
