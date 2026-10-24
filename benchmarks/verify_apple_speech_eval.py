"""Independently audit Apple/MLX PCM, ordering, edit distances and timings."""

import argparse
from collections import Counter
import gzip
import hashlib
import json
import math
from pathlib import Path
import re
import subprocess
import unicodedata

import soundfile as sf

ROOT = Path(__file__).resolve().parents[1]


def sha(data):
    return hashlib.sha256(data).hexdigest()


def tokens(text):
    # Independent implementation of the existing benchmark's conservative policy.
    text = ''.join(c for c in text.lower() if not unicodedata.category(c).startswith('P'))
    text = re.sub(r'\s\s+', ' ', text).strip()
    return [word for word in text.split(' ') if word]


def distance(reference, hypothesis):
    previous = list(range(len(hypothesis) + 1))
    for i, word in enumerate(reference, 1):
        current = [i]
        for j, other in enumerate(hypothesis, 1):
            current.append(min(previous[j] + 1, current[-1] + 1, previous[j - 1] + (word != other)))
        previous = current
    return previous[-1]


def percentile(values, fraction):
    values = sorted(values)
    position = (len(values) - 1) * fraction
    lower, upper = math.floor(position), math.ceil(position)
    return values[lower] + (values[upper] - values[lower]) * (position - lower)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--result', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    assert not args.output.exists()
    receipt = json.loads(args.result.read_text())

    def frozen(name):
        return subprocess.check_output(['git', 'show', receipt['git_commit'] + ':' + name], cwd=ROOT)

    assert not receipt['tracked_changes']
    assert sha(frozen('benchmarks/apple_speech_eval.py')) == receipt['producer_sha256']
    assert sha(frozen('benchmarks/apple_speech.swift')) == receipt['swift_source_sha256']
    protocol_bytes = frozen('benchmarks/fixtures/apple-speech-protocol.json')
    assert sha(protocol_bytes) == receipt['protocol_sha256']
    protocol = json.loads(protocol_bytes)
    assert sha(frozen('uv.lock')) == protocol['dependency_lock_sha256']
    assert sha(frozen('backend/ospr_backend/models.lock.json')) == protocol['model_lock_sha256']
    for path, digest in receipt['source_sha256'].items():
        assert sha(frozen(path)) == digest
    archive = args.result.parent / receipt['traces_file']
    assert sha(archive.read_bytes()) == receipt['traces_sha256']
    raw = json.loads(gzip.decompress(archive.read_bytes()))
    assert raw['ready']['event'] == 'ready' and raw['ready']['locale'] == protocol['locale']
    assert raw['ready']['preparation']['status_after'] == 'installed'
    cases = [protocol['initial_trial'], *protocol['cases']]
    records = [*raw['initial_trials'], *raw['records']]
    assert len(raw['initial_trials']) == 1 and len(raw['records']) == receipt['cases'] == 370
    assert len(records) * len(protocol['models']) == receipt['requests'] == 1484
    assert len({r['speaker_id'] for r in protocol['cases'] if r['reference']}) == receipt['english_speakers'] == 73
    inputs, accumulators, timing_issues, coverage_issues = [], {}, [], []
    for index, (case, row) in enumerate(zip(cases, records, strict=True)):
        path = ROOT / 'benchmarks' / case['path']
        assert sha(path.read_bytes()) == case['sha256']
        audio, rate = sf.read(path, dtype='float32')
        assert rate == 16000 and audio.ndim == 1
        inputs.append(dict(id=case['id'], samples=len(audio), pcm_sha256=sha(audio.astype('<f4').tobytes())))
        assert row['case'] == case
        models = protocol['models']
        shift = 0 if index == 0 else (index - 1) % len(models)
        assert row['order'] == models[shift:] + models[:shift]
        assert set(row['responses']) == set(models)
        for model in models:
            response = row['responses'][model]
            result = response['result']
            wall = response['caller_wall_ms']
            assert math.isfinite(wall) and wall > 0
            ok = result.get('ok', True)
            if model == 'apple-speech' and ok:
                assert result['id'] == case['id'] and result['source_frames'] == len(audio)
                assert result['source_sample_rate'] == rate and result['audio_seconds'] == len(audio) / rate
                assert all(segment['final'] for segment in result['segments'])
                assert ''.join(s['text'] for s in result['segments']).strip() == result['text']
                assert 0 < result['native_wall_ms'] <= wall + 0.1
                through = result['analyzed_through']
                if through is None or abs(through - len(audio) / rate) > 1 / rate + 1e-8:
                    coverage_issues.append(dict(id=case['id'], analyzed_through=through, duration=len(audio) / rate))
                for segment in result['segments']:
                    for kind, ranges in [('segment', [segment]), ('timed_run', segment['timed_runs'])]:
                        for item in ranges:
                            if 'start' not in item and 'end' not in item:
                                continue
                            start, end = item.get('start'), item.get('end')
                            if not (isinstance(start, (float, int)) and isinstance(end, (float, int))
                                    and math.isfinite(start) and math.isfinite(end)
                                    and -1e-8 <= start <= end <= len(audio) / rate + 1 / rate + 1e-8):
                                timing_issues.append(dict(id=case['id'], kind=kind, start=start, end=end))
            if index == 0:
                assert ok, 'Initial preparation trial failed'
                continue
            key = model, case['suite']
            acc = accumulators.setdefault(key, dict(cases=0, api_errors=0, reference_words=0,
                                                    word_errors=0, nonspeech_nonempty=0, times=[]))
            acc['cases'] += 1
            if not ok:
                acc['api_errors'] += 1
                continue
            acc['times'].append(wall)
            if case['reference']:
                reference, hypothesis = tokens(case['reference']), tokens(result['text'])
                acc['reference_words'] += len(reference)
                acc['word_errors'] += distance(reference, hypothesis)
            else:
                acc['nonspeech_nonempty'] += bool(result['text'].strip())
    assert inputs == receipt['source_inputs']
    english = {}
    for (model, suite), acc in accumulators.items():
        expected = receipt['summary'][model][suite]
        for key in ['cases', 'api_errors', 'reference_words', 'nonspeech_nonempty']:
            assert acc[key] == expected[key], (model, suite, key)
        if acc['reference_words']:
            assert acc['word_errors'] == expected['word_errors']
            assert acc['word_errors'] / acc['reference_words'] == expected['wer']
        else:
            assert expected['word_errors'] is None and expected['wer'] is None
        assert math.isclose(percentile(acc['times'], .5), expected['p50_ms'], abs_tol=1e-7)
        assert math.isclose(percentile(acc['times'], .95), expected['p95_ms'], abs_tol=1e-7)
        if acc['reference_words']:
            target = english.setdefault(model, dict(cases=0, reference_words=0, word_errors=0, times=[]))
            for key in ['cases', 'reference_words', 'word_errors']:
                target[key] += acc[key]
            target['times'] += acc['times']
    for value in english.values():
        value['wer'] = value['word_errors'] / value['reference_words']
        times = value.pop('times')
        value['p50_ms'] = percentile(times, .5)
        value['p95_ms'] = percentile(times, .95)
    nonspeech = {model: [dict(id=row['case']['id'], text=row['responses'][model]['result'].get('text'),
                             ok=row['responses'][model]['result'].get('ok', True))
                         for row in raw['records'] if not row['case']['reference']] for model in protocol['models']}
    result = dict(status='verified-frozen-source-pcm-order-levenshtein-and-quantiles-not-inference-rerun',
        source_result_sha256=sha(args.result.read_bytes()), verifier_sha256=sha(Path(__file__).read_bytes()),
        cases=370, english_speakers=73, requests=1484, english=english, nonspeech=nonspeech,
        apple_timing_issues=timing_issues, apple_audio_coverage_issues=coverage_issues,
        order_counts=dict(Counter(','.join(row['order']) for row in raw['records'])),
        boundary='Independent Unicode punctuation/whitespace normalization, dynamic-programming edit distances and linear quantiles from all raw hypotheses; source and decoded PCM hashes checked. Audits reported Apple timing bounds and consumed audio endpoint; neither proves alignment accuracy. Does not rerun ASR, verify opaque Apple weight revisions/compute units, measure system-service memory/energy, or establish consumer GUI/microphone ranking.')
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({key: result[key] for key in ['english', 'apple_timing_issues', 'apple_audio_coverage_issues']}, indent=2))


if __name__ == '__main__':
    main()
