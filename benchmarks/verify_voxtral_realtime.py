"""Independently recompute Voxtral study metrics and verify source/sample lineage."""
import argparse
import gzip
import hashlib
import json
from pathlib import Path
import subprocess

import jiwer
import numpy as np

from ospr_backend.audio import read_audio

ROOT = Path(__file__).resolve().parents[1]


def sha_bytes(value):
    return hashlib.sha256(value).hexdigest()


def sha(path):
    with path.open('rb') as file:
        return hashlib.file_digest(file, 'sha256').hexdigest()


def normalize(value):
    return jiwer.Compose([jiwer.ToLowerCase(), jiwer.RemovePunctuation(), jiwer.RemoveMultipleSpaces(), jiwer.Strip()])(value)


def distance(reference, hypothesis):
    previous = list(range(len(hypothesis) + 1))
    for i, expected in enumerate(reference, 1):
        current = [i]
        for j, actual in enumerate(hypothesis, 1):
            current.append(min(current[-1] + 1, previous[j] + 1, previous[j - 1] + (expected != actual)))
        previous = current
    return previous[-1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--result', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    assert not args.output.exists()
    receipt = json.loads(args.result.read_text())
    protocol_path = ROOT / 'benchmarks/fixtures/voxtral-realtime-protocol.json'
    protocol = json.loads(protocol_path.read_text())
    assert receipt['model'] == protocol['model'] and receipt['options'] == protocol['options']
    assert sha(protocol_path) == receipt['protocol_sha256']
    producer = subprocess.check_output(['git', 'show', receipt['git_commit'] + ':benchmarks/voxtral_realtime.py'])
    assert sha_bytes(producer) == receipt['harness_sha256']
    assert sha(ROOT / 'uv.lock') == receipt['dependency_lock_sha256']
    archive = args.result.with_name(receipt['traces_file'])
    assert sha(archive) == receipt['traces_sha256']
    rows = json.loads(gzip.decompress(archive.read_bytes()))
    expected = protocol['smoke'] if receipt['phase'] == 'smoke' else protocol['items']
    assert len(rows) == len(expected) * 2 == receipt['actual_routes']
    lookup = {(row['id'], row['route']): row for row in rows}
    assert len(lookup) == len(rows)
    source_checks = 0
    for item in expected:
        source = ROOT / 'benchmarks' / item['path']
        assert sha(source) == item['sha256']
        audio = read_audio(str(source))
        pcm = sha_bytes(memoryview(audio.astype('<f4', copy=False)))
        for route in ['offline', 'stream']:
            row = lookup[item['id'], route]
            for key in ['reference', 'language', 'suite', 'sha256']:
                assert row[key] == item[key]
            assert row['normalized_samples'] == len(audio) and row['pcm_sha256'] == pcm
            if route == 'stream' and 'error' not in row:
                events = row['events']
                positions = [event['audio_samples'] for event in events]
                assert positions == sorted(set(positions)) and positions[-1] == row['accepted_samples']
                assert row['source_samples'] == len(audio)
                assert row['early_completion'] == (row['accepted_samples'] != len(audio))
                first = next((event['audio_position_ms'] for event in events if event['text'].strip()), None)
                assert first == row['first_partial_audio_ms']
                for previous, current in zip(events, events[1:], strict=False):
                    assert current['text'].startswith(previous['text'])
                assert row['text'].startswith(events[-1]['text'].strip())
                for event in events:
                    assert event['audio_position_ms'] == event['audio_samples'] / 16000 * 1000
                    assert event['retained_raw_samples'] == 32 * 1280 + event['audio_samples']
            source_checks += 1
    metrics = {}
    for route in ['offline', 'stream']:
        metrics[route] = {}
        for suite in sorted({row['suite'] for row in rows}):
            selected = [row for row in rows if row['route'] == route and row['suite'] == suite and 'error' not in row]
            speech = [row for row in selected if row['reference']]
            word_errors = word_units = char_errors = char_units = 0
            for row in speech:
                ref, hyp = normalize(row['reference']), normalize(row['text'])
                word_errors += distance(ref.split(), hyp.split())
                word_units += len(ref.split())
                ref_chars, hyp_chars = ''.join(ref.split()), ''.join(hyp.split())
                char_errors += distance(ref_chars, hyp_chars)
                char_units += len(ref_chars)
            wer = word_errors / word_units if word_units else None
            cer = char_errors / char_units if char_units else None
            reported = receipt['summary'][route][suite]
            assert reported['wer'] == wer and reported['cer'] == cer
            negatives = sum(bool(row['text'].strip()) for row in selected if not row['reference'])
            assert reported['hallucinated_silence'] == negatives
            metrics[route][suite] = dict(cases=len(selected), wer=wer, cer=cer, word_errors=word_errors,
                word_units=word_units, character_errors=char_errors, character_units=char_units, nonempty_negatives=negatives)
    output = dict(status='passed-source-samples-and-recomputed-metrics-not-quality-promotion',
        source_result_sha256=sha(args.result), protocol_sha256=sha(protocol_path), source_route_checks=source_checks,
        identical_text_pairs=sum(lookup[item['id'], 'offline']['text'] == lookup[item['id'], 'stream']['text'] for item in expected),
        pairs=len(expected), metrics=metrics,
        errors=sum('error' in row for row in rows),
        spoken_empty_outputs=sum(not row['text'].strip() for row in rows if row['expected_speech']),
        boundary='Independent two-row Levenshtein distance verifies aggregate WER/CER, using the same frozen normalization convention. Source files and normalized sample/PCM hashes match on every route. Append-only partials, first-partial positions, accepted counts and raw-buffer retention are checked. A passing evidence check does not promote quality, latency or app integration.')
    args.output.write_text(json.dumps(output, indent=2, ensure_ascii=False) + '\n')
    print(json.dumps({key:output[key] for key in ['status','pairs','identical_text_pairs','errors','spoken_empty_outputs']}))


if __name__ == '__main__':
    main()
