"""Audit frozen Qwen pairs, counted work and native quantiles without ASR."""

import argparse
from collections import Counter
import gzip
import hashlib
import json
import math
from pathlib import Path
import subprocess

import numpy as np
import soundfile as sf

ROOT = Path(__file__).resolve().parents[1]
FIELDS = ['text', 'language', 'audio_seconds', 'speech_seconds', 'segments', 'words']


def sha(data):
    return hashlib.sha256(data).hexdigest()


def payload(row):
    return {key: row.get(key) for key in FIELDS}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--result', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    assert not args.output.exists()
    receipt = json.loads(args.result.read_text())
    commit = receipt['git_commit']

    def frozen(name):
        return subprocess.check_output(['git', 'show', f'{commit}:{name}'], cwd=ROOT)

    assert sha(frozen('benchmarks/qwen_feature_reuse.py')) == receipt['harness_sha256']
    protocol_bytes = frozen('benchmarks/fixtures/qwen-feature-reuse-protocol.json')
    assert sha(protocol_bytes) == receipt['protocol_sha256']
    protocol = json.loads(protocol_bytes)
    assert not receipt['tracked_changes']
    for name, digest in receipt['source_sha256'].items():
        assert sha(frozen(name)) == digest
    assert sha(frozen('uv.lock')) == protocol['dependency_lock_sha256']
    assert sha(frozen('backend/ospr_backend/models.lock.json')) == protocol['model_lock_sha256']
    archive = args.result.parent / receipt['traces_file']
    assert sha(archive.read_bytes()) == receipt['traces_sha256']
    traces = json.loads(gzip.decompress(archive.read_bytes()))
    inputs = []
    for case in protocol['cases']:
        source = ROOT / 'benchmarks' / case['path']
        assert sha(source.read_bytes()) == case['sha256']
        audio, rate = sf.read(source, dtype='float32')
        assert rate == 16000 and audio.ndim == 1
        audio *= np.float32(case.get('amplitude', 1))
        digest = sha(np.clip(audio, -1, 1).astype('<f4').tobytes())
        if case.get('pcm_sha256'):
            assert digest == case['pcm_sha256']
        inputs.append(dict(id=case['id'], samples=len(audio), pcm_sha256=digest))
    assert inputs == receipt['source_inputs'] and len(inputs) == receipt['cases'] == 35
    records = traces['records']
    assert len(records) == receipt['paired_runs'] == receipt['payload_pairs_identical'] == 105
    patterns = Counter()
    for index, (case, repeat) in enumerate((case, repeat) for case in protocol['cases']
                                          for repeat in range(protocol['paired_repeats'])):
        row = records[index]
        assert row['id'] == case['id'] and row['repeat'] == repeat
        expected = ['baseline', 'reuse'] if (index // protocol['paired_repeats'] + repeat) % 2 == 0 else ['reuse', 'baseline']
        assert row['order'] == expected
        before, after = [row[key]['result'] for key in ['baseline', 'reuse']]
        assert payload(before) == payload(after)
        b, r, h = before.get('frontend_evaluations', 0), after.get('frontend_evaluations', 0), after.get('frontend_cache_hits', 0)
        assert (b, r, h) in [(0, 0, 0), (1, 1, 0), (2, 1, 1)]
        assert before.get('frontend_cache_hits', 0) == 0
        patterns[b, r, h] += 1
    blocks = traces['native_blocks']
    assert len(blocks) == receipt['native_blocks'] == len(protocol['native_policy_order']) == 4
    control, times = None, {'baseline': [], 'reuse': []}
    for index, block in enumerate(blocks):
        policy, result = block['policy'], block['result']
        assert policy == protocol['native_policy_order'][index] and block['index'] == index
        assert result['warm_trials'] == protocol['native_warm_repeats'] == 30
        assert len(result['runs']) == 31
        for trial, row in enumerate(result['runs']):
            if control is None:
                control = payload(row)
            assert payload(row) == control
            assert row['cold'] == (trial == 0) and row['trial'] == trial
            assert row['frontend_evaluations'] == (2 if policy == 'baseline' else 1)
            assert row['frontend_cache_hits'] == (0 if policy == 'baseline' else 1)
            assert math.isfinite(row['native_wall_ms']) and row['native_wall_ms'] > 0
            if trial:
                times[policy].append(row['native_wall_ms'])
    summary = {policy: dict(warm_samples=len(values), p50_ms=float(np.percentile(values, 50)),
                           p95_ms=float(np.percentile(values, 95))) for policy, values in times.items()}
    assert summary == receipt['native_summary']
    assert len(times['baseline']) == len(times['reuse']) == receipt['native_warm_samples_each'] == 60
    gain = 1 - summary['reuse']['p50_ms'] / summary['baseline']['p50_ms']
    gate = gain > 0 and summary['reuse']['p95_ms'] <= summary['baseline']['p95_ms'] * 1.05
    assert gain == receipt['native_p50_reduction'] and gate == receipt['predeclared_native_performance_gate']
    result = dict(status='verified-frozen-source-pcm-pairs-work-and-native-metrics-not-model-rerun',
        source_result_sha256=sha(args.result.read_bytes()), verifier_sha256=sha(Path(__file__).read_bytes()),
        cases=35, exact_payload_pairs=105, native_payloads=124, native_warm_samples_each=60,
        work_patterns=[dict(baseline=b, reuse=r, avoided=h, pairs=count) for (b, r, h), count in sorted(patterns.items())],
        native_summary=summary, native_p50_reduction=gain, predeclared_native_performance_gate=gate,
        boundary='Independently reconstructs corpus PCM hashes, pair ordering, exact payload equality, counters and quantiles from all responses. Checks source pinned at producing commit; does not rerun inference, independently time native calls or certify microphone/UI/ranking/energy.')
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
