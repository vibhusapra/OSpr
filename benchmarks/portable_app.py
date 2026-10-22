"""Verify a copied app runtime offline from a foreign working directory.

Requires all five ASR, rewrite-quality and diarization weights already cached.
This exercises the bundled worker and optional MCP, not native permissions/UI.
"""
import argparse
import asyncio
import datetime
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--app', required=True, type=Path)
    parser.add_argument('--output', type=Path, default=ROOT/'results/portable-app-smoke.json')
    args = parser.parse_args()
    app = args.app.resolve(strict=True)
    item = json.loads((ROOT/'fixtures/manifest.json').read_text())['items'][0]
    notes_text = 'Do not ship on Friday. Priya will send the review on Monday. The proposed price is $12.50.'
    models = ['parakeet-v3', 'whisper-turbo', 'whisper-small', 'qwen3-asr', 'nemotron-streaming']
    with tempfile.TemporaryDirectory(prefix='ospr-portable-') as temporary:
        directory = Path(temporary)
        copied = directory/'OSpr Relocated.app'
        shutil.copytree(app, copied, symlinks=True)
        engine = copied/'Contents/Resources/Engine'
        python = engine/'.venv/bin/python'
        audio = directory/'public sample.wav'
        shutil.copyfile(ROOT/item['path'], audio)
        environment = dict(HOME=str(Path.home()), PATH='/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin', PYTHONPATH='/nonexistent', HF_HUB_OFFLINE='1', HF_HUB_DISABLE_PROGRESS_BARS='1')
        requests = [dict(action='ping', id='ping')]
        requests += [dict(action='transcribe', model=model, path=str(audio), language='en', id=model) for model in models]
        requests += [dict(action='notes', text=notes_text, id='notes'), dict(action='meeting', path=str(audio), model='parakeet-v3', language='en', id='speakers'),
                     dict(action='mix_meeting', tracks=[dict(path=str(audio), start=0), dict(path=str(audio), start=.25)], output=str(directory/'mixed.wav'), id='mix'),
                     dict(action='ping', id='final-ping')]
        process = subprocess.run([str(python), '-u', '-m', 'ospr_backend.worker'], input=''.join(json.dumps(r)+'\n' for r in requests), capture_output=True, text=True, cwd=directory, env=environment, timeout=300)
        replies = [json.loads(line) for line in process.stdout.splitlines()]
        assert process.returncode == 0 and len(replies) == len(requests), (process.stdout, process.stderr[-3000:])
        assert all(r['ok'] for r in replies), replies
        assert all('quilter' in r['result']['text'].lower() for r in replies[1:6]), replies
        assert replies[6]['result']['excerpts'] and all(r['text'] in notes_text for r in replies[6]['result']['excerpts'])
        assert replies[7]['result']['words'] and 'quilter' in replies[7]['result']['raw_text'].lower()
        assert (directory/'mixed.wav').stat().st_size > audio.stat().st_size
        info = subprocess.check_output([str(python), '-c', 'import sys, mlx.core; print(sys.prefix); print(mlx.core.__file__)'], cwd=directory, env=environment, text=True)
        assert str(copied) in info and str(ROOT.parent/'.venv') not in info, info

        async def check_mcp():
            from mcp import Client, StdioServerParameters
            parameters = StdioServerParameters(command=str(python), args=['-m','ospr_backend.mcp_server'], env=environment)
            async with Client(parameters) as client:
                names = sorted(tool.name for tool in (await client.list_tools()).tools)
                assert names == ['list_models','rewrite_text','transcribe_file']
                result = await client.call_tool('list_models', {})
                assert 'parakeet-v3' in json.loads(result.content[0].text)
                return names
        mcp_tools = asyncio.run(check_mcp())
        receipt = dict(timestamp=datetime.datetime.now(datetime.UTC).isoformat(), status='passed',
                       boundary='Copied app path with spaces, hostile PYTHONPATH, foreign cwd, offline bundled interpreter/worker, all five ASR engines, source-excerpt notes, speaker word attribution, clocked track mix and MCP tool listing. Native microphone, permissions and UI not exercised.',
                       fixture_id=item['id'], fixture_sha256=item['sha256'],
                       executable_sha256=hashlib.sha256((app/'Contents/MacOS/OSpr').read_bytes()).hexdigest(),
                       build=json.loads((app/'Contents/Resources/build-info.json').read_text()),
                       interpreter_and_mlx_inside_bundle=True, mcp_tools=mcp_tools, results=replies[1:-1])
        args.output.write_text(json.dumps(receipt,indent=2,ensure_ascii=False)+'\n')
        print(json.dumps(dict(status='passed', models=models, extras=['notes','speakers','mix','mcp'], output=str(args.output)),indent=2))


if __name__ == '__main__':
    main()
