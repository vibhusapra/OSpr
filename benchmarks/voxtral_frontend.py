"""Real MLX frontend partition parity without loading recognizer weights.

Twenty fixed synthetic source-length/packet-size combinations, with the model's
left/right padding applied identically to both paths. This verifies only the
standalone mel frontend, not the actual session's padding/encoder/decoder parity.
"""
import argparse
import datetime
import hashlib
import importlib.metadata
import json
from pathlib import Path
import subprocess

import mlx.core as mx
import numpy as np
from mlx_audio.stt.models.voxtral_realtime.audio import compute_mel_filters, compute_mel_spectrogram
from mlx_audio.stt.models.voxtral_realtime.streaming import StreamingMel
from mlx_audio.stt.models.voxtral_realtime.voxtral_realtime import _pad_audio_streaming
import mlx_audio.stt.models.voxtral_realtime as runtime

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    with path.open('rb') as file:
        return hashlib.file_digest(file, 'sha256').hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    assert not args.output.exists()
    assert importlib.metadata.version('mlx-audio') == '0.6.1'
    assert not subprocess.check_output(['git', 'diff', '--name-only', 'HEAD'], cwd=ROOT)
    filters = mx.array(compute_mel_filters(128, 400, 16000), dtype=mx.float32)
    rng = np.random.default_rng(20261023)
    records = []
    for count in [1, 160, 511, 5120, 93680]:
        source = rng.uniform(-0.1, 0.1, count).astype(np.float32)
        # Native defaults: 32 left tokens, six delay tokens + 1 + 10 right.
        padded = _pad_audio_streaming(source, 32, 17)
        expected = np.array(compute_mel_spectrogram(mx.array(padded), filters))
        for packet in [37, 159, 512, 5120]:
            frontend = StreamingMel(filters)
            chunks = []
            for start in range(0, len(padded), packet):
                value = frontend.append(padded[start:start + packet])
                if value is not None:
                    chunks.append(value)
            value = frontend.close()
            if value is not None:
                chunks.append(value)
            actual = np.array(mx.concatenate(chunks, axis=1))
            shape_equal = actual.shape == expected.shape
            error = float(np.max(np.abs(actual - expected))) if shape_equal else None
            passed = shape_equal and error <= 2e-5
            records.append(dict(source_samples=count, padded_samples=len(padded), packet_samples=packet,
                expected_shape=list(expected.shape), streamed_shape=list(actual.shape), max_abs_error=error,
                retained_raw_samples=len(frontend._buf), tolerance=2e-5, passed=passed,
                source_sha256=hashlib.sha256(memoryview(source)).hexdigest()))
            print(f'{count} samples / {packet} packets: {passed}, max error {error}', flush=True)
    runtime_path = Path(runtime.__file__).parent
    receipt = dict(status='passed' if all(row['passed'] for row in records) else 'failed-parity',
        timestamp=datetime.datetime.now(datetime.UTC).isoformat(),
        git_commit=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
        tracked_changes=False, cases=len(records), records=records, harness_sha256=sha(Path(__file__)),
        dependency_lock_sha256=sha(ROOT/'uv.lock'),
        installed_adapter_sha256={file.name:sha(file) for file in sorted(runtime_path.glob('*.py'))},
        boundary=__doc__.strip() + ' No recognizer weights, ASR, microphone, native UI or latency comparison. Both paths get the exact same already-padded waveform. Retention is observed in the standalone frontend; actual-session residency is a separate study.')
    args.output.write_text(json.dumps(receipt, indent=2) + '\n')
    assert receipt['status'] == 'passed', 'Raw failures are preserved in the receipt'


if __name__ == '__main__':
    main()
