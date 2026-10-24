"""Actual compatible/Anthropic Swift CLI replay against owned loopback only."""
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
        cases = [
            ('v1', 'accepted'), ('rewrite-negation/v1', 'original-retained'),
            ('rewrite-truncated/v1', 'rejected'), ('rewrite-refused/v1', 'rejected'),
            ('rewrite-tool/v1', 'rejected'), ('rewrite-missing/v1', 'rejected'),
            ('rewrite-empty/v1', 'rejected'), ('error/v1', 'HTTP 401'),
            ('redirect/v1', 'HTTP 307'),
        ]
        scenarios = [(provider, route, expected, False)
                     for provider in ['compatible', 'anthropic'] for route, expected in cases]
        scenarios.extend((provider, 'missing-model/v1', 'model ID', False) for provider in ['compatible', 'anthropic'])
        scenarios.append(('compatible', 'anonymous-rewrite/v1', 'accepted', True))
        records = []
        with tempfile.TemporaryDirectory(prefix='ospr-rewrite-completion-') as temp:
            source = Path(temp) / 'public text.txt'
            source.write_text('test passage')
            original = source.read_bytes()
            for provider, route, expected, anonymous in scenarios:
                environment = dict(os.environ, OSPR_REWRITE_KEY='test-key', HF_HUB_OFFLINE='1')
                if anonymous:
                    environment.pop('OSPR_REWRITE_KEY')
                result = subprocess.run([str(cli), 'rewrite-' + provider, str(source),
                                         f'http://127.0.0.1:{port}/{route}', '' if route == 'missing-model/v1' else 'test-model'],
                                        env=environment, cwd=temp, capture_output=True, text=True, timeout=15)
                assert source.read_bytes() == original, 'CLI altered its input'
                if expected in ['accepted', 'original-retained']:
                    assert result.returncode == 0, result.stderr
                    reply = json.loads(result.stdout)
                    assert reply['provider'] == provider
                    assert reply['rewrite_accepted'] == (expected == 'accepted')
                    assert reply['text'] == ('Edited passage.' if expected == 'accepted' else 'test passage')
                    assert bool(reply['warning']) == (expected == 'original-retained')
                else:
                    assert result.returncode != 0 and not result.stdout.strip(), result
                    assert ('rewrit' if expected == 'rejected' else expected) in result.stderr, result.stderr
                assert 'PRIVATE' not in result.stdout + result.stderr
                assert 'test-key' not in result.stdout + result.stderr
                records.append(dict(provider=provider, case=route, anonymous=anonymous, expected=expected,
                                    exit_code=result.returncode, input_unchanged=True,
                                    partial_text_or_private_fixture_or_key_not_exposed=True))
        resources = cli.parent.parent / 'Resources/build-info.json'
        return dict(status='passed-loopback-rewrite-completion-cli-contracts',
                    cli_sha256=hashlib.sha256(cli.read_bytes()).hexdigest(),
                    build=json.loads(resources.read_text()) if resources.is_file() else None,
                    cases=records,
                    boundary='Twenty-one actual Swift CLI cases using owned loopback/public text/synthetic key. Complete and anonymous-local controls, lexical-tripwire original retention, truncation/refusal/tool/missing/empty rejection, sanitized HTTP errors, no redirect following and unchanged input. No real account call, model semantics, native app/insertion/Keychain, live latency, provider-side quota/cancellation or consumer ranking acceptance.')
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
