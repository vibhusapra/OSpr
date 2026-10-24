"""Exercise the research helper's inventory and per-file failure isolation."""

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    assert not args.output.exists()
    binary = args.binary.resolve(strict=True)
    calls = []

    def call(arguments, stdin=''):
        value = subprocess.run([str(binary), *arguments], input=stdin, capture_output=True,
                               text=True, timeout=120, cwd=ROOT)
        calls.append(dict(arguments=arguments, exit_code=value.returncode,
                          stdout=value.stdout, stderr=value.stderr))
        return value

    inventory = call(['inventory'])
    assert inventory.returncode == 0 and json.loads(inventory.stdout)['available']
    usage = call([])
    assert usage.returncode == 2 and 'Usage:' in usage.stderr
    unsupported = call(['serve', 'zz_ZZ'])
    assert unsupported.returncode == 1 and 'unsupported' in unsupported.stderr
    with tempfile.TemporaryDirectory(prefix='ospr-apple-speech-contracts-') as name:
        temporary = Path(name)
        corrupt = temporary / 'corrupt.wav'
        corrupt.write_bytes(b'not an audio file')
        source = ROOT / 'benchmarks/fixtures/audio/1272-128104-0000.wav'
        requests = [dict(id='before', path=str(source)), dict(id='missing', path=str(temporary / 'missing.wav')),
                    dict(id='corrupt', path=str(corrupt)), dict(id='after', path=str(source))]
        response = call(['serve', 'en_US'], ''.join(json.dumps(row) + '\n' for row in requests))
        assert response.returncode == 0
        frames = [json.loads(line) for line in response.stdout.splitlines()]
        assert frames[0]['event'] == 'ready' and frames[0]['preparation']['status_after'] == 'installed'
        rows = frames[1:]
        assert [r['id'] for r in rows] == [r['id'] for r in requests]
        assert [r['ok'] for r in rows] == [True, False, False, True]
        assert rows[0]['text'] == rows[-1]['text'] and 'quilter' in rows[0]['text'].lower()
        assert all(segment['final'] for r in [rows[0], rows[-1]] for segment in r['segments'])
    malformed = call(['serve', 'en_US'], '{not json}\n')
    assert malformed.returncode == 1
    receipt = dict(status='passed-research-helper-inventory-arguments-and-file-failure-isolation',
        binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
        helper_sha256=hashlib.sha256((ROOT / 'benchmarks/apple_speech.swift').read_bytes()).hexdigest(),
        harness_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        subprocesses=len(calls), file_requests=4, successful_recognitions=2, file_failures_retained=2,
        calls=calls, boundary='Inventory, usage, unsupported locale, missing/corrupt file isolation, same-process subsequent recognition and malformed protocol exit. Models prepared through the OS; no UI, microphone, hardware cancellation or app-route acceptance.')
    args.output.write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps({k: v for k, v in receipt.items() if k != 'calls'}, indent=2))


if __name__ == '__main__':
    main()
