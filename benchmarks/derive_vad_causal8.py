"""Development-only causal aggregation of frozen VAD probabilities.

No neural or ASR inference is rerun. This is a policy selected after seeing the
development result; it must be frozen before excluded-speaker validation.
"""

import argparse
import gzip
import hashlib
import json
from pathlib import Path
import tempfile

from vad_candidate import native, summarize, bounds

ROOT = Path(__file__).resolve().parent


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--cli", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    assert not args.output.exists()
    receipt = json.loads(args.source.read_text())
    archive = args.source.parent / receipt["raw_traces"]["path"]
    assert sha(archive) == receipt["raw_traces"]["sha256"]
    assert sha(args.cli) == receipt["cli_sha256"]
    protocol_path = ROOT / "fixtures/vad-protocol.json"
    assert sha(protocol_path) == receipt["protocol_sha256"]
    rows = json.loads(gzip.decompress(archive.read_bytes()))["routes"]["coreml32-cpu"]
    for row in rows:
        probabilities = row["probabilities"]
        scores = []
        for index in range(len(probabilities)):
            product = 1.0
            for value in probabilities[max(0, index - 7) : index + 1]:
                product *= 1 - value
            scores.append(1 - product)
        row["probabilities"] = scores
        row.pop("prediction_ms", None)  # The smoothing cost has not been timed.
    with tempfile.TemporaryDirectory(prefix="ospr-causal8-public-") as tmp:
        path = Path(tmp) / "traces.json"
        path.write_text(json.dumps(rows))
        events = native(args.cli.resolve(), ["_benchmark-speech-endpoints", path])["records"]
        for row, event in zip(rows, events, strict=True):
            assert row["id"] == event["id"]
            row["events"] = event["events"]
    result = dict(
        status="derived-development-diagnostic-not-independent-validation",
        source_receipt_sha256=sha(args.source),
        source_archive_sha256=sha(archive),
        cli_sha256=sha(args.cli),
        protocol_sha256=sha(protocol_path),
        method="s[t] = 1 - product(1 - p[j]) for j=max(0,t-7)..t; trailing causal eight-frame window; no future samples",
        window_frames=8,
        input_hop_samples=512,
        sample_rate=16000,
        neural_inference_rerun=False,
        asr_evaluated=False,
        smoothing_cost_measured=False,
        summary=summarize(json.loads(protocol_path.read_text()), rows),
        records=[dict(id=row["id"], bounds=list(bounds(row)), events=row["events"]) for row in rows],
        boundary="Same development inputs and fixed raw model probabilities used to choose this follow-up. Overlapping probabilities are correlated: noisy-OR is an aggregation score, not a calibrated speech probability. Each input remains in history for seven extra hops (224ms); continuing weak evidence may sustain activity longer. A raw-threshold 1.424s silence control accounts only for that fixed history span; actual finish coverage/delay must also be measured. The GUI/defaults and delivered preview are unchanged; new speakers, actual ASR outputs, live capture and scheduling remain open.",
    )
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result["summary"], indent=2))


if __name__ == "__main__":
    main()
