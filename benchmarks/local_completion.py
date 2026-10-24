"""Actual cached MLX completion acknowledgement controls; no quality ranking.

Replays the old string-only generate API and the production EOS gate against
the same prompt/budget. Also deliberately removes the EOS token from a complete
JSON answer's budget to show that valid JSON does not prove completion.
"""
import argparse
import datetime
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path

os.environ['HF_HUB_OFFLINE'] = '1'

from ospr_backend.engine import Engine, MODEL_LOCK
from ospr_backend.local_completion import LocalCompletionError, completed_text


def sha(value):
    return hashlib.sha256(value.encode()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    import mlx_lm
    engine, controls, sentinels = Engine(), [], []
    real_stream = mlx_lm.stream_generate
    for model_id in ['rewrite-quality', 'meeting-quality']:
        for task in ['transcript', 'edit-selection', 'source-selection', 'meeting-summary']:
            capture = {}

            def observed(model, tokenizer, _capture=capture, **kwargs):
                _capture.update(model=model, tokenizer=tokenizer, kwargs=kwargs, frames=[])
                for item in real_stream(model, tokenizer, **kwargs):
                    _capture['frames'].append(item)
                    yield item
            mlx_lm.stream_generate = observed
            text = 'Maya will send the draft on June 5. The budget is $250. Approval is still pending.'
            instruction = ('Return only JSON {"items":[]}.' if task in {'source-selection', 'meeting-summary'}
                           else 'Clean punctuation and preserve every fact and uncertainty.')
            try:
                result = engine.rewrite(text, instruction, model_id=model_id, task=task)
            finally:
                mlx_lm.stream_generate = real_stream
            baseline = mlx_lm.generate(capture['model'], capture['tokenizer'], **capture['kwargs'], verbose=False).strip()
            assert result['text'] == baseline
            final = capture['frames'][-1]
            assert final.token in capture['tokenizer'].eos_token_ids and result['finish_reason'] == 'stop'
            controls.append(dict(model=model_id, task=task, prompt_sha256=sha(capture['kwargs']['prompt']),
                                 max_tokens=capture['kwargs']['max_tokens'], generation_tokens=result['generation_tokens'],
                                 terminal_token=int(final.token), eos_token_ids=sorted(capture['tokenizer'].eos_token_ids),
                                 finish_reason=result['finish_reason'], text=result['text'], old_text_identical=True))
            print(model_id, task, 'EOS and identical text', flush=True)
        model, tokenizer = engine.rewriter
        prompt = tokenizer.apply_chat_template([
            dict(role='system', content='Output exactly the JSON object {"items":[]}. No explanation, Markdown or extra text.'),
            dict(role='user', content='Return the JSON now.')], tokenize=False, add_generation_prompt=True, enable_thinking=False)
        complete_frames = list(real_stream(model, tokenizer, prompt=prompt, max_tokens=64))
        complete = completed_text(complete_frames, eos_token_ids=tokenizer.eos_token_ids, max_tokens=64)
        assert json.loads(complete['text']) == {'items': []}
        budget = complete['generation_tokens'] - 1
        assert budget > 0
        limited = list(real_stream(model, tokenizer, prompt=prompt, max_tokens=budget))
        draft = ''.join(item.text for item in limited).strip()
        assert draft == complete['text'] and json.loads(draft) == {'items': []}
        baseline = mlx_lm.generate(model, tokenizer, prompt=prompt, max_tokens=budget, verbose=False).strip()
        assert baseline == draft
        try:
            completed_text(limited, eos_token_ids=tokenizer.eos_token_ids, max_tokens=budget)
        except LocalCompletionError as error:
            assert error.output_limit
        else:
            raise AssertionError('Balanced JSON limit sentinel was delivered')
        final = limited[-1]
        sentinels.append(dict(model=model_id, prompt_sha256=sha(prompt), max_tokens=budget,
                              generation_tokens=int(final.generation_tokens), terminal_token=int(final.token),
                              finish_reason=final.finish_reason, valid_json_draft=draft,
                              old_string_api_delivered_draft=True, eos_gate_rejected=True,
                              recoverable_output_limit=True))
        print(model_id, 'valid JSON without EOS rejected', flush=True)
    root = Path(__file__).resolve().parent.parent
    receipt = dict(status='passed', timestamp=datetime.datetime.now(datetime.UTC).isoformat(),
                   mlx_lm_version=importlib.metadata.version('mlx-lm'),
                   implementation_sha256={name: hashlib.sha256((root/name).read_bytes()).hexdigest() for name in
                       ['backend/ospr_backend/local_completion.py', 'backend/ospr_backend/engine.py']},
                   models={key: MODEL_LOCK[key] for key in ['rewrite-quality', 'meeting-quality']},
                   controls=controls, deliberate_limit_sentinels=sentinels,
                   boundary='Actual cached local Metal generation, greedy/nonthinking. Eight known-input same-prompt old/new controls and two deliberately chosen JSON budget sentinels. Completion acknowledgement only; no semantic fidelity, held-out accuracy, latency/energy, native insertion or product ranking claim.')
    args.output.write_text(json.dumps(receipt, ensure_ascii=False, indent=2)+'\n')


if __name__ == '__main__':
    main()
