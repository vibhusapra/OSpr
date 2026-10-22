"""Research-only native-layout Cohere controls using the shared benchmark.

No worker/app catalog change. Pinned public conversions, strict load, one chunk
at a time and 512-token budget. The earlier Swift-layout adapter stays separate.
"""
import argparse
import functools
import hashlib
import json
from pathlib import Path
import sys
from types import SimpleNamespace

from huggingface_hub import snapshot_download
from ospr_backend import engine
import run

CANDIDATES = {
    'fullprecision': ('littoralai/cohere-transcribe-mlx-fp16', '6a66668d9b9b26646fce93d70412ee33188b17e0'),
    'native8': ('littoralai/cohere-transcribe-mlx-8bit', 'b3f1f6b5fb5ae1bd17c9be2bcd85806339890450'),
}


def main():
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument('--variant', choices=CANDIDATES, required=True)
    args, remaining = parser.parse_known_args()
    repo, revision = CANDIDATES[args.variant]
    path = snapshot_download(repo, revision=revision, allow_patterns=['*.json','*.safetensors','*.model','*.txt'])
    model_id = 'cohere-' + args.variant
    engine.MODELS[model_id] = dict(repo=repo, engine='mlx-audio', name='Research Cohere '+args.variant, languages='14 languages; explicit language hint', license='Apache-2.0')
    original_resolve = engine.resolve_model
    engine.resolve_model = lambda key: path if key == model_id else original_resolve(key)

    class CandidateEngine(engine.Engine):
        def _load(self, key):
            model, warm = super()._load(key)
            if key == model_id and not warm:
                model = SimpleNamespace(generate=functools.partial(model.generate, max_tokens=512, batch_size=1))
                self.models[key] = model
            return model, warm

    run.Engine = CandidateEngine
    sys.argv = [str(Path(run.__file__)), '--model', model_id, *remaining]
    run.main()
    # Keep the candidate override visible alongside the common source fingerprint.
    manifest = remaining[remaining.index('--manifest')+1] if '--manifest' in remaining else 'fixtures/manifest.json'
    name = model_id + ('-notrim' if '--no-trim' in remaining else '')
    if '--suite' in remaining:
        name += '-' + remaining[remaining.index('--suite')+1]
    if manifest != 'fixtures/manifest.json':
        name += '-' + Path(manifest).stem
    output = Path(run.ROOT)/'results'/f'{name}.json'
    result = json.loads(output.read_text())
    result['research_candidate'] = dict(repo=repo, revision=revision, generation=dict(max_tokens=512, batch_size=1),
        harness_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        boundary='Pinned native-layout public conversion via strict mlx-audio. Not the earlier Swift-layout checkpoint. Not in shipping catalog.')
    output.write_text(json.dumps(result,indent=2)+'\n')


if __name__ == '__main__':
    main()
