"""Official upstream float32 MPS diarizer control on the pinned AMI prefixes.

This tests whether poor diarization is unique to the quantized MLX conversion.
Default upstream postprocessing differs from mlx-audio; timings are not a backend
speed ranking. This research command requires the optional Torch environment.
"""
import datetime
import hashlib
import importlib.metadata
import json
from pathlib import Path
import time

import soundfile as sf
import torch
from transformers import AutoModelForAudioFrameClassification, AutoProcessor
from meetings import diarization_score

ROOT = Path(__file__).resolve().parent
REPO = 'nvidia/Nemotron-3-Diarization'
REVISION = 'f667ed73aee57d40cc39428eb768b4fd87a0a29e'


def main():
    processor = AutoProcessor.from_pretrained(REPO, revision=REVISION)
    model = AutoModelForAudioFrameClassification.from_pretrained(REPO, revision=REVISION, dtype=torch.float32).to('mps').eval()
    manifest_path = ROOT / 'fixtures/ami.json'
    manifest = json.loads(manifest_path.read_text())
    assert manifest['reference_protocol'] == 'AMI-only_words-rttm-v1'
    records = []
    for item in manifest['items']:
        path = ROOT / item['path']
        assert hashlib.sha256(path.read_bytes()).hexdigest() == item['sha256']
        waveform, rate = sf.read(path, dtype='float32')
        started = time.perf_counter()
        inputs = processor(waveform, sampling_rate=rate, return_tensors='pt').to('mps')
        with torch.inference_mode():
            result = model(**inputs)
        torch.mps.synchronize()
        turns = [dict(start=s['Start'], end=s['End'], speaker=s['Speaker']) for s in processor.extract_speaker_dict(result.logits, inputs.attention_mask)[0]]
        record = dict(id=item['id'], wall_ms=(time.perf_counter()-started)*1000, turns=turns,
                      der_0ms=diarization_score(item['turns'], turns, item['seconds'], 0),
                      der_250ms=diarization_score(item['turns'], turns, item['seconds'], .25))
        records.append(record)
        print(item['id'], record['der_0ms']['der'], record['der_250ms']['der'], flush=True)
    result = dict(timestamp=datetime.datetime.now(datetime.UTC).isoformat(), repo=REPO, revision=REVISION,
                  runtime='PyTorch MPS float32', versions={name: importlib.metadata.version(name) for name in ['torch', 'transformers']},
                  reference_protocol=manifest['reference_protocol'], manifest_sha256=hashlib.sha256(manifest_path.read_bytes()).hexdigest(),
                  scorer_sha256=hashlib.sha256((ROOT/'meetings.py').read_bytes()).hexdigest(),
                  boundary='Same four AMI only_words headset-mix prefixes; upstream default postprocessing. Not a full-corpus score or matched backend timing comparison.', records=records)
    (ROOT/'results/diarization-upstream-control.json').write_text(json.dumps(result, indent=2)+'\n')


if __name__ == '__main__':
    main()
