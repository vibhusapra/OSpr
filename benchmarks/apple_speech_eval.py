"""Counterbalanced English file-runtime comparison, not consumer-app latency."""

import argparse
import datetime
import gzip
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import platform
import queue
import subprocess
import threading
import time

import jiwer
import numpy as np
import soundfile as sf

from ospr_backend.engine import Engine
from run import normalize

ROOT = Path(__file__).resolve().parents[1]
PROTOCOL = ROOT / 'benchmarks/fixtures/apple-speech-protocol.json'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


class Apple:
    def __init__(self, binary, locale, stderr):
        self.queue = queue.Queue()
        self.process = subprocess.Popen([str(binary), 'serve', locale], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=stderr, text=True, bufsize=1)

        def receive():
            try:
                for line in self.process.stdout:
                    self.queue.put(line)
            finally:
                self.queue.put(None)

        self.reader = threading.Thread(target=receive, daemon=True)
        self.reader.start()

    def read(self):
        line = self.queue.get(timeout=120)
        assert line is not None, f'Apple helper exited: {self.process.poll()}'
        return json.loads(line)

    def request(self, identifier, path):
        self.process.stdin.write(json.dumps(dict(id=identifier, path=str(path))) + '\n')
        self.process.stdin.flush()
        value = self.read()
        assert value['id'] == identifier
        return value

    def close(self):
        self.process.stdin.close()
        try:
            code = self.process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
            raise
        finally:
            self.process.stdout.close()
            self.reader.join(timeout=2)
        assert code == 0, f'Apple helper exit status {code}'


def summarize(records, models):
    result = {}
    for model in models:
        suites = {}
        for suite in sorted({row['case']['suite'] for row in records}):
            selected = [(row['case'], row['responses'][model]) for row in records if row['case']['suite'] == suite]
            good = [(case, response) for case, response in selected if response['result'].get('ok', True)]
            scored = [(case, response) for case, response in good if case['reference']]
            score = jiwer.process_words([normalize(case['reference']) for case, _ in scored],
                                        [normalize(response['result']['text']) for _, response in scored]) if scored else None
            times = [response['caller_wall_ms'] for _, response in good]
            suites[suite] = dict(cases=len(selected), api_errors=len(selected) - len(good),
                reference_words=sum(len(normalize(case['reference']).split()) for case, _ in scored),
                word_errors=score.substitutions + score.deletions + score.insertions if score else None,
                wer=score.wer if score else None,
                nonspeech_nonempty=sum(bool(response['result']['text'].strip()) for case, response in good if not case['reference']),
                p50_ms=float(np.percentile(times, 50)) if times else None,
                p95_ms=float(np.percentile(times, 95)) if times else None)
        result[model] = suites
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    assert not args.output.exists()
    assert not subprocess.check_output(['git', 'diff', '--name-only', 'HEAD'], cwd=ROOT)
    protocol = json.loads(PROTOCOL.read_text())
    assert sha(ROOT / 'uv.lock') == protocol['dependency_lock_sha256']
    assert sha(ROOT / 'backend/ospr_backend/models.lock.json') == protocol['model_lock_sha256']
    binary = args.binary.resolve(strict=True)
    inputs = []
    for case in [protocol['initial_trial'], *protocol['cases']]:
        path = ROOT / 'benchmarks' / case['path']
        assert sha(path) == case['sha256']
        audio, rate = sf.read(path, dtype='float32')
        assert rate == 16000 and audio.ndim == 1
        inputs.append(dict(id=case['id'], samples=len(audio), pcm_sha256=hashlib.sha256(audio.astype('<f4').tobytes()).hexdigest()))
    assert len(protocol['cases']) == 370
    models = protocol['models']
    engines = {name: Engine() for name in models if name != 'apple-speech'}
    records, initial = [], []
    archive = args.output.with_suffix('.traces.json.gz')
    ready = None

    def save():
        archive.write_bytes(gzip.compress(json.dumps(dict(ready=ready, initial_trials=initial, records=records),
                                                     ensure_ascii=False).encode(), compresslevel=1, mtime=0))

    with args.output.with_suffix('.stderr.log').open('w') as errors:
        apple = Apple(binary, protocol['locale'], errors)
        try:
            ready = apple.read()
            assert ready['event'] == 'ready' and ready['preparation']['status_after'] == 'installed'
            for index, case in enumerate([protocol['initial_trial'], *protocol['cases']]):
                shift = 0 if index == 0 else (index - 1) % len(models)
                order = models[shift:] + models[:shift]
                row = dict(case=case, order=order, responses={})
                for model in order:
                    started = time.perf_counter()
                    if model == 'apple-speech':
                        result = apple.request(case['id'], ROOT / 'benchmarks' / case['path'])
                    else:
                        try:
                            result = engines[model].transcribe(str(ROOT / 'benchmarks' / case['path']), model,
                                                              language='en', trim=False)
                        except Exception as error:
                            result = dict(ok=False, error=f'{type(error).__name__}: {error}')
                    row['responses'][model] = dict(result=result, caller_wall_ms=(time.perf_counter() - started) * 1000)
                if index == 0:
                    initial.append(row)
                else:
                    records.append(row)
                save()
                print(json.dumps(dict(completed=index, total=len(protocol['cases']), id=case['id'])), flush=True)
        finally:
            apple.close()
    receipt = dict(status='completed-counterbalanced-file-runtime-study-not-product-ranking',
        timestamp=datetime.datetime.now(datetime.UTC).isoformat(),
        git_commit=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
        tracked_changes=False, binary_sha256=sha(binary), producer_sha256=sha(Path(__file__)),
        swift_source_sha256=sha(ROOT / 'benchmarks/apple_speech.swift'), protocol_sha256=sha(PROTOCOL),
        source_sha256={str(p.relative_to(ROOT)): sha(p) for p in sorted((ROOT / 'backend/ospr_backend').glob('*.py'))},
        platform=platform.platform(), python=platform.python_version(),
        packages={name: importlib.metadata.version(name) for name in ['mlx', 'mlx-audio', 'parakeet-mlx', 'mlx-whisper', 'torch']},
        sdk=subprocess.check_output(['xcrun', '--show-sdk-version'], text=True).strip(),
        swift=subprocess.check_output(['swift', '--version'], text=True).strip(),
        cases=len(records), english_speakers=len({r['speaker_id'] for r in protocol['cases'] if r['reference']}),
        requests=len(models) * (len(records) + len(initial)), source_inputs=inputs,
        summary=summarize(records, models), traces_file=archive.name, traces_sha256=sha(archive),
        boundary=protocol['boundary'])
    assert not subprocess.check_output(['git', 'diff', '--name-only', 'HEAD'], cwd=ROOT)
    args.output.write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(receipt['summary'], indent=2))


if __name__ == '__main__':
    main()
