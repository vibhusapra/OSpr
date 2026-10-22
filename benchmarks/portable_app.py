"""Verify a copied app runtime offline from a foreign working directory.

Requires all six ASR, rewrite-quality and diarization weights already cached.
This exercises the bundled worker and optional MCP, not native permissions/UI.
"""
import argparse
import asyncio
import datetime
import hashlib
from html.parser import HTMLParser
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parent


def verify_help_links(app):
    class Links(HTMLParser):
        def __init__(self):
            super().__init__()
            self.paths = []

        def handle_starttag(self, tag, attrs):
            for key, value in attrs:
                if key in ('href', 'src') and value and not value.startswith('#') and not urlsplit(value).scheme:
                    self.paths.append(unquote(urlsplit(value).path))

    report = app/'Contents/Resources/Engine/docs/research.html'
    parser = Links()
    parser.feed(report.read_text())
    for path in parser.paths:
        target = (report.parent/path).resolve()
        assert target.is_relative_to(app) and target.is_file(), f'Broken bundled help link: {path}'
    return len(parser.paths)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--app', required=True, type=Path)
    parser.add_argument('--output', type=Path, default=ROOT/'results/portable-app-smoke.json')
    args = parser.parse_args()
    app = args.app.resolve(strict=True)
    item = json.loads((ROOT/'fixtures/manifest.json').read_text())['items'][0]
    notes_text = 'Do not ship on Friday. Priya will send the review on Monday. The proposed price is $12.50.'
    models = ['parakeet-v3', 'whisper-turbo', 'whisper-small', 'qwen3-asr', 'nemotron-streaming','cohere-native8']
    with tempfile.TemporaryDirectory(prefix='ospr-portable-') as temporary:
        directory = Path(temporary)
        copied = directory/'OSpr Relocated.app'
        shutil.copytree(app, copied, symlinks=True)
        engine = copied/'Contents/Resources/Engine'
        help_links = verify_help_links(copied)
        python = engine/'.venv/bin/python'
        audio = directory/'public sample.wav'
        shutil.copyfile(ROOT/item['path'], audio)
        poisoned = directory/'untrusted-pythonpath'
        poisoned.mkdir()
        (poisoned/'json.py').write_text('raise RuntimeError("external PYTHONPATH was used")\n')
        (directory/'json.py').write_text('raise RuntimeError("foreign working directory was imported")\n')
        environment = dict(HOME=str(Path.home()), PATH='/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin', PYTHONPATH=str(poisoned), HF_HUB_OFFLINE='1', HF_HUB_DISABLE_PROGRESS_BARS='1')
        requests = [dict(action='ping', id='ping')]
        requests += [dict(action='transcribe', model=model, path=str(audio), language='en', id=model) for model in models]
        requests += [dict(action='notes', text=notes_text, id='notes'), dict(action='meeting', path=str(audio), model='parakeet-v3', language='en', id='speakers'),
                     dict(action='mix_meeting', tracks=[dict(path=str(audio), start=0), dict(path=str(audio), start=.25)], output=str(directory/'mixed.wav'), id='mix'),
                     dict(action='prepare_upload', path=str(audio), output=str(directory/'upload.wav'), id='prepare-upload'),
                     dict(action='model_status', id='status-before'),
                     dict(action='download_model', model='whisper-small', id='download-cached'),
                     dict(action='model_status', id='status-after'),
                     dict(action='warm', model='parakeet-v3', id='warm-progress'),
                     dict(action='prepare_review', path=str(audio), output=str(directory/'review.wav'), limit_bytes=1024**2, id='prepare-review'),
                     dict(action='ping', id='final-ping')]
        process = subprocess.run([str(python), '-u', '-m', 'ospr_backend.worker'], input=''.join(json.dumps(r)+'\n' for r in requests), capture_output=True, text=True, cwd=directory, env=environment, timeout=300)
        frames = [json.loads(line) for line in process.stdout.splitlines()]
        events = [frame for frame in frames if frame.get('event') == 'progress']
        replies = [frame for frame in frames if frame.get('event') != 'progress']
        assert process.returncode == 0 and len(replies) == len(requests), (process.stdout, process.stderr[-3000:])
        assert all(r['ok'] for r in replies), replies
        assert all('quilter' in r['result']['text'].lower() for r in replies[1:7]), replies
        assert replies[7]['result']['excerpts'] and all(r['text'] in notes_text for r in replies[7]['result']['excerpts'])
        assert replies[8]['result']['words'] and 'quilter' in replies[8]['result']['raw_text'].lower()
        assert (directory/'mixed.wav').stat().st_size > audio.stat().st_size
        assert replies[10]['result']['source_unchanged'] and (directory/'upload.wav').is_file()
        before, after = replies[11]['result'], replies[13]['result']
        assert len(before['models']) == 8 and all(row['complete'] for row in before['models'])
        assert before['resident'] == after['resident'] and before['rewrite_resident'] == after['rewrite_resident']
        assert replies[12]['result']['complete'] and replies[14]['ok']
        assert all(event['id'] in {'download-cached', 'warm-progress'} for event in events)
        assert any(event['id'] == 'warm-progress' and event['progress']['phase'] == 'priming' for event in events)
        assert replies[15]['result']['source_unchanged'] and (directory/'review.wav').is_file()
        info = subprocess.check_output([str(python), '-c', 'import sys, mlx.core; print(sys.prefix); print(mlx.core.__file__)'], cwd=directory, env=environment, text=True)
        assert str(copied) in info and str(ROOT.parent/'.venv') not in info, info
        cli = copied/'Contents/MacOS/ospr-cli'
        native = subprocess.run([str(cli), 'doctor'], capture_output=True, text=True, cwd=directory, env=environment, timeout=30)
        assert native.returncode == 0 and 'parakeet-v3' in json.loads(native.stdout)['models'], native.stderr
        linked = directory/'ospr-cli'
        linked.symlink_to(cli)
        symlinked = subprocess.run([str(linked), 'doctor'], capture_output=True, text=True, cwd=directory, env=environment, timeout=30)
        assert symlinked.returncode == 0 and 'parakeet-v3' in json.loads(symlinked.stdout)['models'], symlinked.stderr
        review = subprocess.run([str(cli), 'verify-audio-review', str(audio)], capture_output=True, text=True, cwd=directory, env=environment, timeout=60)
        assert review.returncode == 0, review.stderr
        review_result = json.loads(review.stdout)
        assert review_result['status'] == 'passed' and review_result['history_and_archive_restart']

        async def check_mcp():
            from mcp import Client, StdioServerParameters
            parameters = StdioServerParameters(command=str(python), args=['-m','ospr_backend.mcp_server'], env=environment, cwd=str(directory))
            async with Client(parameters) as client:
                names = sorted(tool.name for tool in (await client.list_tools()).tools)
                assert names == ['list_models','rewrite_text','transcribe_file']
                result = await client.call_tool('list_models', {})
                assert 'parakeet-v3' in json.loads(result.content[0].text)
                return names
        mcp_tools = asyncio.run(check_mcp())
        signature = subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict',str(copied)], capture_output=True, text=True)
        assert signature.returncode == 0, signature.stderr
        receipt = dict(timestamp=datetime.datetime.now(datetime.UTC).isoformat(), status='passed',
                       bundled_help_relative_links=help_links,
                       boundary='Copied app path with spaces, hostile PYTHONPATH, foreign cwd, offline bundled interpreter/worker, all six ASR engines, source-excerpt notes, speaker word attribution, clocked track mix, local upload preparation, pinned model inventory/download-only/warm progress and MCP tool listing. Native microphone, permissions and UI not exercised.',
                       fixture_id=item['id'], fixture_sha256=item['sha256'],
                       executable_sha256=hashlib.sha256((app/'Contents/MacOS/OSpr').read_bytes()).hexdigest(),
                       build=json.loads((app/'Contents/Resources/build-info.json').read_text()),
                       interpreter_and_mlx_inside_bundle=True, bundled_cli_foreign_cwd=True, signature_valid_after_inference=True,
                       poisoned_pythonpath_and_cwd_ignored=True, mcp_tools=mcp_tools, model_progress_events=events, native_audio_review=review_result, results=replies[1:-1])
        args.output.write_text(json.dumps(receipt,indent=2,ensure_ascii=False)+'\n')
        print(json.dumps(dict(status='passed', models=models, extras=['notes','speakers','mix','prepare-upload','mcp'], output=str(args.output)),indent=2))


if __name__ == '__main__':
    main()
