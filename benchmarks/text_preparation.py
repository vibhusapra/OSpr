"""Paired fresh Swift worker text preparation with actual warm-speech controls.

This is a shared-Mac first-use diagnostic. Preparation shifts work before dictation;
no microphone, provider, Settings, insertion, energy or consumer ranking claim.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cli', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--repeats', type=int, default=3)
    args = parser.parse_args()
    if args.output.exists() or not 1 <= args.repeats <= 10:
        parser.error('Choose a new receipt path and 1–10 repetitions.')
    cli = args.cli.resolve(strict=True)
    fixture = json.loads((ROOT/'benchmarks/fixtures/manifest.json').read_text())['items'][0]
    source = ROOT/'benchmarks'/fixture['path']
    assert hashlib.sha256(source.read_bytes()).hexdigest() == fixture['sha256']
    environment = dict(os.environ, HF_HUB_OFFLINE='1')
    if (cli.parent.parent/'Resources/Engine').is_dir():
        environment.pop('OSPR_ROOT', None)
    else:
        environment['OSPR_ROOT'] = str(ROOT)
    records, mismatches = [], []
    with tempfile.TemporaryDirectory(prefix='ospr-text-preparation-') as directory:
        for repeat in range(args.repeats):
            for model in ['rewrite-quality', 'meeting-quality']:
                pair = []
                for variant in (['baseline', 'prepared'] if repeat % 2 == 0 else ['prepared', 'baseline']):
                    result = subprocess.run([str(cli), '_benchmark-text-preparation', str(source), model, variant],
                                            capture_output=True, text=True, env=environment, cwd=directory, timeout=600)
                    assert result.returncode == 0, result.stderr[-2000:]
                    row = json.loads(result.stdout)
                    assert row['status'] == 'passed' and row['same_worker_pid'] and row['asr_resident'] and row['warm_asr_text_unchanged']
                    row.update(repeat=repeat, variant=variant)
                    pair.append(row)
                    records.append(row)
                    args.output.write_text(json.dumps(dict(status="running", records=records), indent=2, ensure_ascii=False)+"\n")
                    print(model, repeat, variant, round(row['preparation_wall_ms'], 2), round(row['first_real_rewrite_wall_ms'], 2), flush=True)
                if pair[0]['raw_text'] != pair[1]['raw_text'] or pair[0]['text'] != pair[1]['text']:
                    mismatches.append(dict(model=model, repeat=repeat))
    source_digest = hashlib.sha256()
    for path in sorted((ROOT/'Sources').rglob('*.swift')) + sorted(p for p in (ROOT/'backend/ospr_backend').rglob('*') if p.suffix in {'.py','.json','.npy'}):
        source_digest.update(str(path.relative_to(ROOT)).encode())
        source_digest.update(path.read_bytes())
    metadata = cli.parent.parent/'Resources/build-info.json'
    receipt = dict(status='needs-output-review' if mismatches else 'passed-paired-text-preparation-and-warm-speech-controls', paired_output_mismatches=mismatches, timestamp=datetime.datetime.now(datetime.UTC).isoformat(),
                   cli_sha256=hashlib.sha256(cli.read_bytes()).hexdigest(),
                   build=json.loads(metadata.read_text()) if metadata.is_file() else None,
                   application_source_sha256=source_digest.hexdigest(),
                   source_commit=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
                   tracked_changes=bool(subprocess.check_output(['git', 'diff', '--name-only'], cwd=ROOT, text=True).strip()),
                   source_sha256={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in [ROOT/'backend/ospr_backend/engine.py', ROOT/'backend/ospr_backend/worker.py', ROOT/'backend/ospr_backend/models.lock.json', ROOT/'Sources/OSprCLI/TextPreparationCheck.swift', Path(__file__).resolve()]},
                   fixture=fixture, records=records,
                   boundary='Fresh Swift CLI/WorkerClient for every path with Parakeet resident before text. Three alternating-order pairs per model by default, one synthetic public rewrite input and one 5.855s public speech control; every raw/delivered output retained and pairs compared. First rewrite excludes preparation; combined cost includes it. Shared Mac, cached weights; no isolated latency distribution, representative semantic grading, physical capture/insertion, energy or consumer-product ranking.')
    args.output.write_text(json.dumps(receipt, indent=2, ensure_ascii=False)+'\n')
    if mismatches:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
