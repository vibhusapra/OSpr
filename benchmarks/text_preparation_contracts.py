"""Actual Swift CLI preparation acknowledgements and admission using owned fake workers."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile

REPOS = {'rewrite-quality':'mlx-community/Qwen3-4B-Instruct-2507-4bit', 'meeting-quality':'mlx-community/Qwen3.5-9B-4bit'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cli', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    cli = args.cli.resolve(strict=True)
    cases = []
    with tempfile.TemporaryDirectory(prefix='ospr-text-prepare-contracts-') as temp:
        root = Path(temp)
        backend = root/'backend/ospr_backend'
        backend.mkdir(parents=True)
        (backend/'__init__.py').write_text('')
        launcher = root/'.venv/bin/python'
        launcher.parent.mkdir(parents=True)
        launcher.write_text('#!/bin/sh\nexec '+shlex.quote(sys.executable)+' "$@"\n')
        launcher.chmod(0o700)
        payload = dict(model='meeting-quality', repository=REPOS['meeting-quality'], primed=True, cache_only=True,
                       already_prepared=False, finish_reason='stop', generation_tokens=8, load_ms=12, prime_ms=23, total_ms=35)
        variants = [('valid', {}), ('repeated', dict(already_prepared=True, generation_tokens=0, prime_ms=0)),
                    ('wrong-model', dict(model='rewrite-quality')), ('wrong-repository', dict(repository=REPOS['rewrite-quality'])),
                    ('not-prepared', dict(primed=False)), ('download-route', dict(cache_only=False)),
                    ('not-complete', dict(finish_reason='length')), ('bad-token-type', dict(generation_tokens=True)),
                    ('missing-completion', None)]
        for name, changes in variants:
            body = dict(payload)
            if changes is None:
                body.pop('finish_reason')
            else:
                body.update(changes)
            (backend/'worker.py').write_text('import json,sys\nfor line in sys.stdin:\n r=json.loads(line)\n'
                ' print(json.dumps(dict(id=r["id"],ok=True,result='+repr(body)+')),flush=True)\n')
            result = subprocess.run([str(cli), 'prepare-text', 'meeting-quality'], cwd=root, capture_output=True, text=True,
                                    env=dict(os.environ, OSPR_ROOT=str(root)), timeout=30)
            if name in ['valid', 'repeated']:
                assert result.returncode == 0 and json.loads(result.stdout) == body
            else:
                assert result.returncode != 0 and not result.stdout.strip()
            cases.append(dict(case=name, status='passed', exit_code=result.returncode))
        marker = backend/'started'
        (backend/'worker.py').write_text('from pathlib import Path\nPath(__file__).with_name("started").touch()\nraise RuntimeError("must not start")\n')
        for model in ['untrusted/model', 'rewrite']:
            result = subprocess.run([str(cli), 'prepare-text', model], cwd=root, capture_output=True, text=True,
                                    env=dict(os.environ, OSPR_ROOT=str(root)), timeout=30)
            assert result.returncode != 0 and not result.stdout.strip() and not marker.exists()
            cases.append(dict(case='invalid-before-worker-'+model, status='passed', exit_code=result.returncode))
    metadata = cli.parent.parent/'Resources/build-info.json'
    receipt = dict(status='passed-text-preparation-cli-contracts', cases=cases, cli_sha256=hashlib.sha256(cli.read_bytes()).hexdigest(),
                   build=json.loads(metadata.read_text()) if metadata.is_file() else None,
                   boundary='Actual Swift CLI on owned fake workers. Selected-model/repository, completed synthetic acknowledgement, typed tokens/cache-only/primed states, idempotent preparation and invalid-model pre-admission. No real model/UI/latency claim.')
    args.output.write_text(json.dumps(receipt, indent=2)+'\n')
    print(receipt['status'], len(cases))


if __name__ == '__main__':
    main()
