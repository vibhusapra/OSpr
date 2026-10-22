"""Measure the native CLI/owned-worker boundary on one public utterance."""
import datetime
import hashlib
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent


def main():
    item = json.loads((ROOT/'fixtures/manifest.json').read_text())['items'][0]
    audio = ROOT/item['path']
    assert hashlib.sha256(audio.read_bytes()).hexdigest() == item['sha256']
    executable = ROOT.parent/'.build/release/ospr-cli'
    process = subprocess.run([str(executable), 'benchmark', str(audio), 'parakeet-v3', '30'], capture_output=True, text=True, timeout=180,
                             env=dict(os.environ, OSPR_ROOT=str(ROOT.parent), HF_HUB_OFFLINE='1'))
    if process.returncode:
        raise RuntimeError(process.stderr)
    result = json.loads(process.stdout)
    result.update(timestamp=datetime.datetime.now(datetime.UTC).isoformat(), fixture_id=item['id'], fixture_sha256=item['sha256'],
                  executable_sha256=hashlib.sha256(executable.read_bytes()).hexdigest())
    (ROOT/'results/native-ipc.json').write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps({key:result[key] for key in ['cold_ms','p50_ms','p95_ms','boundary']}, indent=2))


if __name__ == '__main__':
    main()
