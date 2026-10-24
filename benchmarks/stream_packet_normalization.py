"""Diagnose existing packet-by-packet normalization against whole-file input.

Fifteen fixed one-second synthetic waveform/rate/packet cases. This is not an
ASR accuracy, native device or latency test; mismatches are retained as evidence.
"""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import subprocess

import numpy as np
import soundfile as sf
from ospr_backend.audio import read_audio
from ospr_backend.temporary import private_audio_file

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    with path.open('rb') as file:
        return hashlib.file_digest(file, 'sha256').hexdigest()


def pcm_sha(audio):
    return hashlib.sha256(memoryview(audio.astype('<f4', copy=False))).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    assert not args.output.exists()
    assert not subprocess.check_output(['git','diff','--name-only','HEAD'],cwd=ROOT)
    rng = np.random.default_rng(20261023)
    records = []
    for rate in [16000,44100,48000]:
        audio = (0.2*np.sin(2*np.pi*440*np.arange(rate)/rate)+rng.normal(0,0.01,rate)).astype(np.float32)
        with private_audio_file() as file:
            sf.write(file.name,audio,rate,subtype='FLOAT')
            full = read_audio(file.name)
            assert len(full)==16000
            for packet in [256,512,1024,1536,8192]:
                pieces = []
                for start in range(0,len(audio),packet):
                    sf.write(file.name,audio[start:start+packet],rate,subtype='FLOAT')
                    pieces.append(read_audio(file.name))
                streamed = np.concatenate(pieces)
                records.append(dict(sample_rate=rate,input_samples=len(audio),packet_samples=packet,packets=len(pieces),
                    full_normalized_samples=len(full),packet_normalized_samples=len(streamed),
                    extra_normalized_samples=len(streamed)-len(full),
                    full_pcm_sha256=pcm_sha(full),packet_pcm_sha256=pcm_sha(streamed),
                    pcm_identical=np.array_equal(full,streamed)))
    receipt = dict(status='completed-existing-stateless-packet-normalization-diagnostic',
        timestamp=datetime.datetime.now(datetime.UTC).isoformat(),
        git_commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),tracked_changes=False,
        harness_sha256=sha(Path(__file__)),audio_source_sha256=sha(ROOT/'backend/ospr_backend/audio.py'),
        dependency_lock_sha256=sha(ROOT/'uv.lock'),cases=len(records),records=records,
        boundary=__doc__.strip()+' Uses the exact current read_audio path for whole and each packet. Per-packet rounding and filter-boundary differences can occur together; sample-count equality alone does not prove waveform equality. No production code fix or native/hardware acceptance.')
    args.output.write_text(json.dumps(receipt,indent=2)+'\n')
    print(json.dumps(records,indent=2))


if __name__ == '__main__':
    main()
