"""Independent sample/order/hash and conservative edit-distance checks for meeting replay."""
import argparse
import gzip
import hashlib
import json
from pathlib import Path
import re
import unicodedata

import numpy as np
import soundfile as sf

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    with path.open('rb') as handle:
        return hashlib.file_digest(handle, 'sha256').hexdigest()


def pcmsha(values):
    return hashlib.sha256(values.astype('<f4').tobytes()).hexdigest()


def words(text):
    # Independent of the producer's benchmark/jiwer normalizer.
    text = unicodedata.normalize('NFKC', text).upper()
    return re.sub(r'[^\w\s]', '', text).split()


def distance(reference, hypothesis):
    row = list(range(len(hypothesis) + 1))
    for i, expected in enumerate(reference, 1):
        next_row = [i]
        for j, actual in enumerate(hypothesis, 1):
            next_row.append(min(row[j] + 1, next_row[-1] + 1, row[j - 1] + (expected != actual)))
        row = next_row
    return row[-1]


def verify(receipt_path, work, cli):
    receipt = json.loads(receipt_path.read_text())
    protocol_path = ROOT / 'benchmarks/fixtures/meeting-preview-protocol.json'
    protocol = json.loads(protocol_path.read_text())
    assert sha(protocol_path) == receipt['protocol_sha256'] and sha(cli) == receipt['cli_sha256']
    assert sha(ROOT/'Sources/OSprCore/MeetingPreviewMixer.swift') == receipt['mixer_sha256']
    for name, digest in protocol['locks'].items():
        assert sha(ROOT/name) == digest
    for clip in protocol['clips']:
        assert sha(ROOT/'benchmarks'/clip['path']) == clip['sha256']
    trace_path = receipt_path.with_suffix('.traces.json.gz')
    assert sha(trace_path) == receipt['traces_sha256']
    traces = json.loads(gzip.decompress(trace_path.read_bytes()))
    assert [row['id'] for row in traces] == [row['id'] for row in protocol['variants']]
    assert len(traces) == len(receipt['variants']) == 3
    reference_words = words(receipt['expected_text'])
    rows = []
    for trace, summary in zip(traces, receipt['variants'], strict=True):
        assert trace['id'] == summary['id']
        native = trace['native']
        folder = work / trace['id']
        full, rate = sf.read(folder / native['full_file'], dtype='float32')
        reference, reference_rate = sf.read(folder / native['reference_file'], dtype='float32')
        assert rate == reference_rate == 16000
        assert len(full) == len(reference) == native['samples'] == summary['samples'] == receipt['expected_samples'] == 962000
        assert pcmsha(full) == trace['full_pcm_sha256'] == summary['full_pcm_sha256']
        assert pcmsha(reference) == trace['whole_track_reference_pcm_sha256'] == summary['whole_track_reference_pcm_sha256']
        assert np.max(np.abs(full - reference)) == summary['maximum_whole_track_error'] == 0
        assert native['buffered_input_samples'] == 0 and native['allocated_sample_capacity'] == 1681200
        supplied, position = [], 0
        assert len(trace['stream']) == len(native['packets'])
        for index, (packet, event) in enumerate(zip(native['packets'], trace['stream'], strict=True)):
            assert packet == event['packet'] and packet['file'] == f'packet-{index:04d}.wav'
            samples, sample_rate = sf.read(folder / packet['file'], dtype='float32')
            assert sample_rate == 16000 and 0 < len(samples) == packet['samples'] <= 192000
            position += len(samples)
            assert position == packet['end_sample']
            supplied.append(samples)
        np.testing.assert_array_equal(np.concatenate(supplied), full)
        assert native['packets'][-1]['final_drain']
        assert trace['diagnostic_draft_flush']['done']
        assert set(summary['final']) == set(trace['final']) == set(protocol['final_models'])
        scores = {}
        for model in protocol['final_models']:
            score = trace['final'][model]
            assert score == summary['final'][model]
            errors = distance(reference_words, words(score['response']['text']))
            assert errors == score['errors'] and len(reference_words) == score['words']
            assert errors / len(reference_words) == score['wer']
            assert score['response']['audio_seconds'] == len(full) / 16000
            scores[model] = dict(errors=errors, words=len(reference_words), wer=score['wer'])
        rows.append(dict(id=trace['id'], packets=len(supplied), samples=position, scores=scores))
    assert len({row['full_pcm_sha256'] for row in traces}) == 1
    for model in protocol['final_models']:
        assert len({row['final'][model]['response']['text'] for row in traces}) == 1
    return dict(status='verified-public-file-production-mix-and-asr', study_commit=receipt['git_commit'],
        receipt_sha256=sha(receipt_path), traces_sha256=sha(trace_path), verifier_sha256=sha(Path(__file__)),
        source_and_lock_checks=True, exact_whole_track_pcm=True, exact_packet_partition_pcm=True,
        complete_tail=True, independently_scored=True, variants=rows, boundary=protocol['boundary'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--receipt', type=Path, required=True)
    parser.add_argument('--work', type=Path, required=True)
    parser.add_argument('--cli', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    assert not args.output.exists()
    result = verify(args.receipt, args.work, args.cli)
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result))


if __name__ == '__main__':
    main()
