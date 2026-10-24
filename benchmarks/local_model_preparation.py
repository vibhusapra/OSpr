"""Real Swift IPC missing-9B preparation rejection with warm ASR retained."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cli', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    cli = args.cli.resolve(strict=True)
    from huggingface_hub.constants import HF_HUB_CACHE
    entry = json.loads((ROOT/'backend/ospr_backend/models.lock.json').read_text())['parakeet-v3']
    model_folder = 'models--'+entry['repo'].replace('/','--')
    existing = Path(HF_HUB_CACHE)/model_folder
    assert (existing/'snapshots'/entry['revision']).is_dir(), 'Prepare the pinned Parakeet cache first.'
    with tempfile.TemporaryDirectory(prefix='ospr-no-9b-cache-') as temp:
        cache = Path(temp)
        (cache/model_folder).symlink_to(existing, target_is_directory=True)
        environment = dict(os.environ, HF_HUB_CACHE=str(cache), HF_HUB_OFFLINE='1')
        if (cli.parent.parent/'Resources/Engine').is_dir():
            environment.pop('OSPR_ROOT', None)
        else:
            environment['OSPR_ROOT'] = str(ROOT)
        run = subprocess.run([str(cli),'_verify-local-model-preparation',str(ROOT/'benchmarks/fixtures/audio/1272-128104-0000.wav')],
                             env=environment,cwd=cache,capture_output=True,text=True,timeout=300)
        assert run.returncode == 0,run.stderr
        receipt = json.loads(run.stdout)
        assert receipt['status']=='passed' and receipt['expected_failure']=='text-model-not-prepared'
        assert receipt['same_worker_pid'] and receipt['asr_resident_after_rejection'] and receipt['warm_asr_text_unchanged']
        assert sorted(p.name for p in cache.iterdir()) == [model_folder]
    assert not cache.exists()
    metadata = cli.parent.parent/'Resources/build-info.json'
    receipt.update(build=json.loads(metadata.read_text()) if metadata.is_file() else None,
                   cli_sha256=hashlib.sha256(cli.read_bytes()).hexdigest(),isolated_cache_only_parakeet=True,
                   private_cache_removed=True,no_9b_download=True)
    args.output.write_text(json.dumps(receipt,indent=2,ensure_ascii=False)+'\n')
    print('passed-local-model-preparation-with-warm-asr')


if __name__=='__main__':
    main()
