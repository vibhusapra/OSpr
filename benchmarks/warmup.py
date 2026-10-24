"""Paired fresh-process first-utterance warmup diagnostic; not product latency."""
import datetime
import json
import os
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent


def child(model, primed):
    from ospr_backend.engine import Engine
    engine = Engine()
    started = time.perf_counter()
    if primed:
        warm = engine.warm(model)
    else:
        engine._load(model)
        warm = None
    prepare_ms = (time.perf_counter()-started)*1000
    item = json.loads((ROOT/'fixtures/manifest.json').read_text())['items'][0]
    started = time.perf_counter()
    result = engine.transcribe(str(ROOT/item['path']), model, language='en')
    return dict(model=model, primed=primed, prepare_ms=prepare_ms, warm=warm, first_real_ms=(time.perf_counter()-started)*1000, text=result['text'], fixture_id=item['id'])


def main():
    if len(sys.argv) == 3:
        print(json.dumps(child(sys.argv[1], sys.argv[2]=='1')))
        return
    records = []
    for model in ['parakeet-v3', 'cohere-native8', 'whisper-turbo', 'whisper-small', 'qwen3-asr', 'nemotron-streaming']:
        for repeat in range(3):
            for primed in ([False, True] if repeat % 2 == 0 else [True, False]):
                result = subprocess.run([sys.executable, __file__, model, str(int(primed))], capture_output=True, text=True, check=True, env=dict(os.environ, HF_HUB_OFFLINE='1'))
                row = dict(json.loads(result.stdout), repeat=repeat)
                records.append(row)
                print(model, repeat, primed, row['first_real_ms'], flush=True)
    output = dict(timestamp=datetime.datetime.now(datetime.UTC).isoformat(), boundary='Three paired fresh processes per model; one 5.855s public clip. Baseline loads weights only, candidate additionally runs a one-second synthetic tone and discards output. Preparation cost is shifted earlier, not removed. No microphone/IPC/insertion or general speedup claim.', records=records)
    (ROOT/'results/warmup.json').write_text(json.dumps(output, indent=2)+'\n')


if __name__ == '__main__':
    main()
