"""Actual Core deadline schedules and real ASR packet-continuity regression.

Run with PYTHONPATH=backend and HF_HUB_OFFLINE=1. Modeled work is not measured
latency, and replay completes requests rather than canceling mid-request at stop.
"""
import argparse
import datetime
import gzip
import hashlib
import json
from pathlib import Path
import subprocess
import time

import jiwer
import numpy as np
import soundfile as sf

from ospr_backend.audio import read_audio, SAMPLE_RATE
from ospr_backend.engine import Engine
from ospr_backend.temporary import private_audio_file
from run import normalize

ROOT = Path(__file__).resolve().parents[1]
PROTOCOL = ROOT / 'benchmarks/fixtures/preview-cadence-protocol.json'


def sha(path):
    with path.open('rb') as file:
        return hashlib.file_digest(file, 'sha256').hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cli', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    assert not args.output.exists()
    assert not subprocess.check_output(['git', 'diff', '--name-only', 'HEAD'], cwd=ROOT)
    protocol = json.loads(PROTOCOL.read_text())
    assert sha(ROOT/'benchmarks/fixtures/manifest.json') == protocol['source_manifest_sha256']
    assert sha(ROOT/'backend/ospr_backend/models.lock.json') == protocol['model_lock_sha256']
    assert sha(ROOT/'uv.lock') == protocol['dependency_lock_sha256']
    source = ROOT/'benchmarks'/protocol['source']['path']
    assert sha(source) == protocol['source']['sha256']
    original = read_audio(str(source))
    block_samples = protocol['block_seconds'] * SAMPLE_RATE
    assert len(original) <= block_samples
    audio = np.tile(np.pad(original, (0, block_samples - len(original))), protocol['repetitions'])
    assert len(audio) == protocol['stop_ms'] * SAMPLE_RATE // 1000
    expected = ' '.join([protocol['source']['reference']] * protocol['repetitions'])
    full_pcm = hashlib.sha256(memoryview(audio.astype('<f4', copy=False))).hexdigest()
    cli = args.cli.resolve(strict=True)
    cli_sha = sha(cli)
    schedules = []
    for interval in protocol['intervals_ms']:
        for work in protocol['modeled_work_ms']:
            raw = subprocess.check_output([str(cli), '_benchmark-preview-cadence', str(interval), str(work), str(protocol['stop_ms'])], cwd=ROOT, timeout=30)
            schedule = json.loads(raw)
            assert schedule['interval_ms'] == interval and schedule['work_ms'] == work
            for ticks in schedule['schedules_ms'].values():
                assert ticks and ticks == sorted(set(ticks)) and ticks[-1] < protocol['stop_ms']
            schedules.append(schedule)
    engine = Engine()
    model, _ = engine._load(protocol['model'])
    context = model.default_att_context_size
    records = []
    traces = args.output.with_suffix('.traces.json.gz')
    for work, order in zip(protocol['modeled_work_ms'], protocol['policy_orders'], strict=True):
        schedule = next(row for row in schedules if row['interval_ms'] == protocol['actual_asr_interval_ms'] and row['work_ms'] == work)
        for policy in order:
            state = engine.stream_begin(protocol['language_hint'])
            assert state['sample_rate'] == SAMPLE_RATE
            session_id = state['session_id']
            digest = hashlib.sha256()
            position, events = 0, []
            began = time.perf_counter()
            with private_audio_file() as file:
                for tick in schedule['schedules_ms'][policy]:
                    end = min(len(audio), round(tick * SAMPLE_RATE / 1000))
                    assert position < end
                    chunk = audio[position:end]
                    sf.write(file.name, chunk, SAMPLE_RATE, subtype='FLOAT')
                    decoded = read_audio(file.name)
                    np.testing.assert_array_equal(decoded, chunk)
                    digest.update(memoryview(decoded.astype('<f4', copy=False)))
                    event = engine.stream_feed(file.name, session_id=session_id)
                    events.append(dict(input_ms=tick, modeled_delivery_ms=tick + work, end_sample=end,
                                       text=event['text'], actual_processing_ms=event['processing_ms']))
                    position = end
                if position < len(audio):
                    sf.write(file.name, audio[position:], SAMPLE_RATE, subtype='FLOAT')
                    decoded = read_audio(file.name)
                    np.testing.assert_array_equal(decoded, audio[position:])
                    digest.update(memoryview(decoded.astype('<f4', copy=False)))
                    engine.stream_feed(file.name, session_id=session_id)
                final = engine.stream_feed(final=True, session_id=session_id)
            assert final['done'] and digest.hexdigest() == full_pcm
            scored = jiwer.process_words(normalize(expected), normalize(final['text']))
            first = next((event for event in events if event['text']), None)
            record = dict(policy=policy, modeled_work_ms=work, input_samples=len(audio),
                supplied_pcm_sha256=digest.hexdigest(), text=final['text'], reference=expected,
                wer=scored.wer, substitutions=scored.substitutions, deletions=scored.deletions, insertions=scored.insertions,
                live_requests=len(events), events=events, actual_wall_ms=(time.perf_counter() - began) * 1000,
                actual_final_flush_ms=final['processing_ms'],
                first_partial_input_ms=first['input_ms'] if first else None,
                first_partial_modeled_delivery_ms=first['modeled_delivery_ms'] if first else None)
            records.append(record)
            traces.write_bytes(gzip.compress(json.dumps(records,ensure_ascii=False).encode(),mtime=0))
            print(json.dumps({key:record[key] for key in ['policy','modeled_work_ms','live_requests','wer','first_partial_input_ms','first_partial_modeled_delivery_ms']}),flush=True)
    pairs = []
    for work in protocol['modeled_work_ms']:
        a = next(row for row in records if row['modeled_work_ms'] == work and row['policy'] == 'legacy')
        b = next(row for row in records if row['modeled_work_ms'] == work and row['policy'] == 'deadline')
        pairs.append(dict(modeled_work_ms=work, text_identical=a['text']==b['text'], legacy_wer=a['wer'], deadline_wer=b['wer']))
    assert cli_sha == sha(cli)
    assert not subprocess.check_output(['git', 'diff', '--name-only', 'HEAD'],cwd=ROOT)
    receipt = dict(status='completed-core-schedule-and-real-packet-replay-not-native-latency',
        timestamp=datetime.datetime.now(datetime.UTC).isoformat(),
        git_commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(), tracked_changes=False,
        harness_sha256=sha(Path(__file__)), protocol_sha256=sha(PROTOCOL), cli_sha256=cli_sha,
        core_scheduler_sha256=sha(ROOT/'Sources/OSprCore/PreviewCadence.swift'),
        application_preview_sha256=sha(ROOT/'Sources/OSpr/AppModel.swift'),
        model_lock_sha256=protocol['model_lock_sha256'], dependency_lock_sha256=protocol['dependency_lock_sha256'],
        model=protocol['model'], att_context_size=context, normalized_samples=len(audio), pcm_sha256=full_pcm,
        actual_asr_sessions=len(records), summary=pairs, schedules=schedules,
        traces_file=traces.name,traces_sha256=sha(traces),boundary=protocol['boundary'])
    args.output.write_text(json.dumps(receipt,indent=2,ensure_ascii=False)+'\n')


if __name__ == '__main__':
    main()
