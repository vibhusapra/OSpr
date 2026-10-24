"""Public-file production meeting mix replay and cached local ASR regression.

Unpaced, simulated capture arrivals. Native UI/capture and latency remain separate.
"""
import argparse
import datetime
import gzip
import hashlib
import json
from pathlib import Path
import subprocess

import jiwer
import numpy as np
from scipy.signal import resample_poly
import soundfile as sf

from ospr_backend.engine import Engine
from run import normalize

ROOT = Path(__file__).resolve().parents[1]
PROTOCOL = ROOT / 'benchmarks/fixtures/meeting-preview-protocol.json'


def sha(path):
    with path.open('rb') as handle:
        return hashlib.file_digest(handle, 'sha256').hexdigest()


def pcmsha(values):
    return hashlib.sha256(values.astype('<f4').tobytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cli', type=Path, required=True)
    parser.add_argument('--work', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    assert not args.work.exists() and not args.output.exists()
    assert not subprocess.check_output(['git', 'diff', '--name-only', 'HEAD'], cwd=ROOT)
    commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    protocol = json.loads(PROTOCOL.read_text())
    for name, digest in protocol['locks'].items():
        assert sha(ROOT / name) == digest
    cli = args.cli.resolve(strict=True)
    cli_sha = sha(cli)
    args.work.mkdir(parents=True, mode=0o700)
    sources = {}
    for item in protocol['clips']:
        path = ROOT / 'benchmarks' / item['path']
        assert sha(path) == item['sha256']
        values, rate = sf.read(path, dtype='float32')
        assert rate == 16000 and values.ndim == 1
        sources[item['id']] = values
    expected = np.zeros(round((protocol['seconds'] + protocol['microphone_offset']) * 16000), dtype=np.float32)
    source_paths = []
    for source in protocol['sources']:
        values = np.zeros(protocol['seconds'] * 16000, dtype=np.float32)
        offset = protocol['microphone_offset'] if source['name'] == 'microphone' else 0
        for placement in protocol['placements']:
            if placement['source'] != source['name']:
                continue
            clip = sources[placement['id']]
            start = round(placement['at'] * 16000)
            values[start:start + len(clip)] += clip
        start = round(offset * 16000)
        expected[start:start + len(values)] += values * np.float32(0.5)
        # Independent source preparation, not the production AVAudioConverter.
        divisor = int(np.gcd(source['rate'], 16000))
        native = resample_poly(values, source['rate'] // divisor, 16000 // divisor).astype('float32')
        path = args.work / (source['name'] + '.wav')
        sf.write(path, native, source['rate'], subtype='FLOAT')
        source_paths.append(dict(source=source['name'], path=str(path.resolve()), offset=offset))
    expected_text = ' '.join(next(clip['reference'] for clip in protocol['clips'] if clip['id'] == place['id'])
                             for place in sorted(protocol['placements'], key=lambda row: row['at']))
    records = []
    traces = args.output.with_suffix('.traces.json.gz')

    def save():
        traces.write_bytes(gzip.compress(json.dumps(records, ensure_ascii=False).encode(), mtime=0))

    engine = Engine()
    try:
        for variant in protocol['variants']:
            folder = args.work / variant['id']
            manifest = args.work / (variant['id'] + '.json')
            manifest.write_text(json.dumps(dict(sources=source_paths, packets=variant['packets'], interval=variant['interval'], jitter=variant['jitter'])))
            raw = subprocess.check_output([str(cli), '_benchmark-meeting-preview', str(manifest), str(folder)], cwd=ROOT, timeout=60)
            replay = json.loads(raw)
            (args.work / (variant['id'] + '-native.json')).write_bytes(raw)
            full, rate = sf.read(folder / replay['full_file'], dtype='float32')
            record = dict(id=variant['id'], native=replay, samples=len(full), full_pcm_sha256=pcmsha(full), stream=[])
            records.append(record)
            save()  # Preserve native receipt before contract checks / inference.
            assert rate == 16000 and len(full) == len(expected) and replay['samples'] == len(expected)
            assert replay['buffered_input_samples'] == 0
            record['maximum_roundtrip_error'] = float(np.max(np.abs(full - expected)))
            record['relative_rms_roundtrip_error'] = float(np.linalg.norm(full - expected) / np.linalg.norm(expected))
            assert record['maximum_roundtrip_error'] <= protocol['max_sample_error']
            assert record['relative_rms_roundtrip_error'] <= protocol['max_relative_rms_error']
            # Every packet, including the independently flushed converter tail.
            state = engine.stream_begin('en')
            supplied = []
            for packet in replay['packets']:
                path = folder / packet['file']
                values, packet_rate = sf.read(path, dtype='float32')
                assert packet_rate == 16000 and len(values) == packet['samples'] <= 12 * 16000
                supplied.append(values)
                response = engine.stream_feed(str(path), session_id=state['session_id'])
                record['stream'].append(dict(packet=packet, response=response))
                save()
            np.testing.assert_array_equal(np.concatenate(supplied), full)
            # Diagnostic only: the app cancels draft state and runs full final ASR.
            record['diagnostic_draft_flush'] = engine.stream_feed(final=True, session_id=state['session_id'])
            for model in protocol['final_models']:
                response = engine.transcribe(str(folder / replay['full_file']), model_id=model, language='en', trim=False)
                score = jiwer.process_words(normalize(expected_text), normalize(response['text']))
                record.setdefault('final', {})[model] = dict(response=response, errors=score.substitutions + score.deletions + score.insertions,
                    substitutions=score.substitutions, deletions=score.deletions, insertions=score.insertions, words=len(normalize(expected_text).split()), wer=score.wer)
                save()
            print(json.dumps(dict(id=variant['id'], packets=len(replay['packets']), samples=len(full), final_wer={key: row['wer'] for key, row in record['final'].items()})), flush=True)
    finally:
        save()
    assert len({row['full_pcm_sha256'] for row in records}) == 1
    for model in protocol['final_models']:
        assert len({row['final'][model]['response']['text'] for row in records}) == 1
    assert cli_sha == sha(cli)
    assert not subprocess.check_output(['git', 'diff', '--name-only', 'HEAD'], cwd=ROOT)
    receipt = dict(status='completed-public-file-mixer-and-real-asr-not-native-capture', timestamp=datetime.datetime.now(datetime.UTC).isoformat(),
        git_commit=commit, cli_sha256=cli_sha, protocol_sha256=sha(PROTOCOL), harness_sha256=sha(Path(__file__)),
        mixer_sha256=sha(ROOT/'Sources/OSprCore/MeetingPreviewMixer.swift'), expected_text=expected_text,
        expected_samples=len(expected), expected_pcm_sha256=pcmsha(expected),
        variants=[{key: row[key] for key in ['id', 'samples', 'full_pcm_sha256', 'maximum_roundtrip_error', 'relative_rms_roundtrip_error', 'final']} for row in records],
        full_pcm_partition_invariant=True, full_final_text_partition_invariant=True,
        traces_file=traces.name, traces_sha256=sha(traces), boundary=protocol['boundary'])
    args.output.write_text(json.dumps(receipt, indent=2, ensure_ascii=False) + '\n')


if __name__ == '__main__':
    main()
