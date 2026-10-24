"""Replay the actual Swift CLI against owned loopback Gemini fixtures only.

Uses synthetic keys/public text, never a provider account. The receipt proves
protocol/error/fidelity-tripwire behavior, not model quality or paid API access.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import select
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def run(cli):
    cli = cli.resolve(strict=True)
    stub = subprocess.Popen(
        ['/usr/bin/python3', '-u', str(ROOT / 'backend/tests/provider_stub.py')],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
    )
    try:
        assert select.select([stub.stdout], [], [], 10)[0], 'Loopback fixture startup timed out'
        port = int(stub.stdout.readline().strip())
        records = []
        with tempfile.TemporaryDirectory(prefix='ospr-gemini-contracts-') as temp:
            source = Path(temp) / 'public text.txt'
            source.write_text('test passage')
            original = source.read_bytes()
            for route, expected in [
                ('v1beta', 'accepted'), ('gemini-negation', 'original-retained'),
                ('gemini-truncated', 'incomplete'), ('gemini-blocked', 'incomplete'),
                ('error', 'HTTP 401'), ('redirect', 'HTTP 307'),
                ('missing-key', 'key'), ('invalid-model', 'model ID'),
            ]:
                environment = dict(os.environ, OSPR_REWRITE_KEY='test-key', HF_HUB_OFFLINE='1')
                if route == 'missing-key':
                    environment.pop('OSPR_REWRITE_KEY')
                base = f'http://127.0.0.1:{port}/{route}'
                model = 'bad?query=secret' if route == 'invalid-model' else 'test-model'
                result = subprocess.run([str(cli), 'rewrite-gemini', str(source), base, model],
                                        env=environment, cwd=temp, capture_output=True, text=True, timeout=15)
                assert source.read_bytes() == original, 'CLI altered its input file'
                if expected in ['accepted', 'original-retained']:
                    assert result.returncode == 0, result.stderr
                    reply = json.loads(result.stdout)
                    assert reply['provider'] == 'gemini'
                    assert reply['rewrite_accepted'] == (expected == 'accepted')
                    assert reply['text'] == ('Edited passage.' if expected == 'accepted' else 'test passage')
                    assert bool(reply['warning']) == (expected == 'original-retained')
                else:
                    assert result.returncode != 0 and not result.stdout.strip(), result
                    if expected == 'incomplete':
                        assert 'complete text rewrite' in result.stderr
                    else:
                        assert expected in result.stderr, result.stderr
                assert 'PRIVATE' not in result.stdout + result.stderr
                assert 'test-key' not in result.stdout + result.stderr
                records.append(dict(case=route, expected=expected, exit_code=result.returncode,
                                    input_unchanged=True, stdout_text_delivered=result.returncode == 0,
                                    private_fixture_and_key_not_exposed=True))
        resources = cli.parent.parent / 'Resources/build-info.json'
        return dict(status='passed-loopback-gemini-cli-contracts',
                    cli_sha256=hashlib.sha256(cli.read_bytes()).hexdigest(),
                    build=json.loads(resources.read_text()) if resources.is_file() else None,
                    cases=records,
                    boundary='Owned loopback fixture, synthetic key and public text only. Actual Swift CLI checks wire headers/body, parser, explicit incomplete/blocked errors, no redirect following, missing key/model rejection, input preservation and one native fidelity tripwire. No Gemini account call, model quality, semantic fidelity, native Settings/Keychain interaction, latency or consumer ranking acceptance.')
    finally:
        stub.terminate()
        stub.wait(timeout=10)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--cli', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    result = run(args.cli)
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(dict(status=result['status'], cases=len(result['cases']))))


if __name__ == '__main__':
    main()
