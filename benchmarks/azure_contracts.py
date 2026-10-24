"""Replay the actual Swift Azure CLI against owned loopback fixtures only."""
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
        cases = [
            ('resource-root', '', 'accepted'), ('v1-base', '/openai/v1/', 'accepted'),
            ('negation', '/azure-negation/openai/v1', 'original-retained'),
            ('truncated', '/azure-truncated/openai/v1', 'incomplete'),
            ('filtered', '/azure-filtered/openai/v1', 'incomplete'),
            ('refused', '/azure-refused/openai/v1', 'incomplete'),
            ('error', '/error/openai/v1', 'HTTP 401'),
            ('redirect', '/redirect/openai/v1', 'HTTP 307'),
            ('missing-key', '/openai/v1', 'key'),
            ('missing-deployment', '/openai/v1', 'deployment name'),
            ('dated-query', '/openai/v1?api-version=2024-10-21', 'HTTPS provider URL'),
            ('legacy-path', '/openai/deployments/old', 'base ending in /openai/v1'),
        ]
        with tempfile.TemporaryDirectory(prefix='ospr-azure-contracts-') as temp:
            source = Path(temp) / 'public text.txt'
            source.write_text('test passage')
            original = source.read_bytes()
            for case, path, expected in cases:
                environment = dict(os.environ, OSPR_REWRITE_KEY='test-key', HF_HUB_OFFLINE='1')
                if case == 'missing-key':
                    environment.pop('OSPR_REWRITE_KEY')
                deployment = '' if case == 'missing-deployment' else 'test-deployment'
                base = f'http://127.0.0.1:{port}{path}'
                result = subprocess.run([str(cli), 'rewrite-azure', str(source), base, deployment],
                                        env=environment, cwd=temp, capture_output=True, text=True, timeout=15)
                assert source.read_bytes() == original, 'CLI altered its input file'
                if expected in ['accepted', 'original-retained']:
                    assert result.returncode == 0, result.stderr
                    reply = json.loads(result.stdout)
                    assert reply['provider'] == 'azure'
                    assert reply['rewrite_accepted'] == (expected == 'accepted')
                    assert reply['text'] == ('Edited passage.' if expected == 'accepted' else 'test passage')
                    assert bool(reply['warning']) == (expected == 'original-retained')
                else:
                    assert result.returncode != 0 and not result.stdout.strip(), result
                    assert ('complete text rewrite' if expected == 'incomplete' else expected) in result.stderr, result.stderr
                assert 'PRIVATE' not in result.stdout + result.stderr
                assert 'test-key' not in result.stdout + result.stderr
                records.append(dict(case=case, expected=expected, exit_code=result.returncode,
                                    input_unchanged=True, stdout_text_delivered=result.returncode == 0,
                                    private_fixture_and_key_not_exposed=True))
        resources = cli.parent.parent / 'Resources/build-info.json'
        return dict(status='passed-loopback-azure-cli-contracts',
                    cli_sha256=hashlib.sha256(cli.read_bytes()).hexdigest(),
                    build=json.loads(resources.read_text()) if resources.is_file() else None,
                    cases=records,
                    boundary='Owned loopback fixture, synthetic resource key and public text only. Actual Swift CLI checks Azure v1 resource-root/base normalization, header/deployment/body contract, completion/filter/refusal errors, no redirects, input preservation, absent key/deployment/dated-path rejection and one native fidelity tripwire. No Azure account, model availability/quality, quota/provider-side cancellation, native Settings/Keychain, latency or consumer ranking acceptance.')
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
