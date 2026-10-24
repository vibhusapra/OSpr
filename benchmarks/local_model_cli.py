"""Selected local-model CLI acknowledgement/fallback contracts and cached inference."""
import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
REPOSITORIES = {'rewrite-quality': 'mlx-community/Qwen3-4B-Instruct-2507-4bit',
                'meeting-quality': 'mlx-community/Qwen3.5-9B-4bit'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cli', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--contracts-only', action='store_true')
    args = parser.parse_args()
    cli = args.cli.resolve(strict=True)
    records = []
    with tempfile.TemporaryDirectory(prefix='ospr-local-choice-') as temp:
        directory = Path(temp)
        backend = directory/'backend/ospr_backend'
        backend.mkdir(parents=True)
        (backend/'__init__.py').write_text('')
        launcher = directory/'.venv/bin/python'
        launcher.parent.mkdir(parents=True)
        launcher.write_text('#!/bin/sh\nexec '+shlex.quote(sys.executable)+' "$@"\n')
        launcher.chmod(0o700)
        payload = dict(model=REPOSITORIES['meeting-quality'], text='PRIVATE_SYNTHETIC_DRAFT', finish_reason='stop', generation_tokens=3)
        variants = [('wrong-model', dict(model=REPOSITORIES['rewrite-quality'])), ('truncated', dict(finish_reason='length')),
                    ('wrong-count', dict(generation_tokens=True)), ('zero-count', dict(generation_tokens=0)),
                    ('empty', dict(text=' ')), ('missing-model', None), ('missing-completion', None),
                    ('valid', dict(text='Please ask Zoë.')), ('accent-loss-fallback', dict(text='Please ask Zoe.'))]
        for name, changes in variants:
            body = copy.deepcopy(payload)
            if name == 'missing-model':
                body.pop('model')
            elif name == 'missing-completion':
                body.pop('finish_reason')
            else:
                body.update(changes)
            (backend/'worker.py').write_text('import json,sys\nfor line in sys.stdin:\n r=json.loads(line)\n'
                ' print(json.dumps(dict(id=r["id"],ok=True,result='+repr(body)+')),flush=True)\n')
            result = subprocess.run([str(cli),'rewrite','Please ask Zoë.','meeting-quality'],
                                    env=dict(os.environ,OSPR_ROOT=str(directory),HF_HUB_OFFLINE='1'),
                                    cwd=directory,capture_output=True,text=True,timeout=30)
            if name in {'valid','accent-loss-fallback'}:
                decoded = json.loads(result.stdout)
                assert result.returncode == 0 and decoded['text'] == 'Please ask Zoë.'
                assert decoded['rewrite_accepted'] == (name == 'valid')
                assert decoded['raw_text'] == body['text']
            else:
                assert result.returncode != 0 and not result.stdout.strip()
            assert 'PRIVATE_SYNTHETIC_DRAFT' not in result.stdout+result.stderr
            records.append(dict(case=name,status='passed',exit_code=result.returncode))
        marker = backend/'worker.py.started'
        (backend/'worker.py').write_text('from pathlib import Path\nPath(__file__+".started").write_text("started")\nraise RuntimeError("worker must not start")\n')
        result = subprocess.run([str(cli),'rewrite','Public source.','untrusted/model'],
                                env=dict(os.environ,OSPR_ROOT=str(directory)),cwd=directory,capture_output=True,text=True,timeout=30)
        assert result.returncode != 0 and not result.stdout.strip() and not marker.exists()
        records.append(dict(case='unknown-model-before-worker',status='passed',exit_code=result.returncode))
        if not args.contracts_only:
            for model, repo in REPOSITORIES.items():
                environment = dict(os.environ, HF_HUB_OFFLINE='1')
                if (cli.parent.parent/'Resources/Engine').is_dir():
                    environment.pop('OSPR_ROOT',None)
                else:
                    environment['OSPR_ROOT'] = str(ROOT)
                text = 'Um, please send this to Zoë Saldaña, not the other team.'
                actual = subprocess.run([str(cli),'rewrite',text,model],env=environment,cwd=directory,
                                        capture_output=True,text=True,timeout=300)
                assert actual.returncode == 0, actual.stderr
                reply = json.loads(actual.stdout)
                assert reply['model'] == repo and reply['finish_reason'] == 'stop' and reply['generation_tokens'] > 0
                assert reply['original'] == text and 'Zoë' in reply['text'] and 'not' in reply['text']
                records.append(dict(case='actual-'+model,status='passed',result=reply))
    metadata = cli.parent.parent/'Resources/build-info.json'
    receipt = dict(status='passed-local-text-choice-cli',cases=records,cli_sha256=hashlib.sha256(cli.read_bytes()).hexdigest(),
                   build=json.loads(metadata.read_text()) if metadata.is_file() else None,
                   boundary='Actual Swift CLI with owned fake-child completion/model/type/fallback/early-admission contracts; optional two cached 4B/9B inferences. No native Settings, microphone, insertion, provider, semantic generalization or comparative latency claim.')
    args.output.write_text(json.dumps(receipt,indent=2,ensure_ascii=False)+'\n')
    print(receipt['status'],len(records))


if __name__ == '__main__':
    main()
