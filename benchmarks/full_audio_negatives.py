"""Known synthetic nonspeech checks for the full-audio versus opt-in RMS routes.

Five previously used fixtures, six models, both routes. These narrow controls do
not establish a real-world false-positive rate or justify new filter thresholds.
"""
import argparse
import datetime
import gzip
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    app = args.app.resolve(strict=True)
    assert not args.output.exists()
    source_path = ROOT / "benchmarks/results/neural-final-edges.json"
    source = json.loads(source_path.read_text())
    archive = source_path.with_name(source["traces_file"])
    assert sha(archive) == source["traces_sha256"]
    raw = json.loads(gzip.decompress(archive.read_bytes()))
    items = [row for row in raw["items"] if row["suite"] == "synthetic-negative"]
    assert len(items) == 5
    models = list(source["summary"])
    assert len(models) == 6
    records = []
    requests = []
    for model in models:
        for item in items:
            path = ROOT / "benchmarks" / item["original_path"]
            assert sha(path) == item["sha256"]
            for route in ["default", "rms"]:
                request = dict(id=f"{model}/{item['id']}/{route}", action="transcribe", model=model, path=str(path), language="en")
                if route == "rms":
                    request["trim"] = True
                requests.append(request)
    environment = dict(HOME=str(Path.home()), PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", HF_HUB_OFFLINE="1")
    process = subprocess.run([str(app / "Contents/Resources/Engine/.venv/bin/python"), "-m", "ospr_backend.worker"],
        input="".join(json.dumps(row) + "\n" for row in requests), capture_output=True, text=True,
        cwd=args.output.resolve().parent, env=environment, timeout=300)
    assert process.returncode == 0, process.stderr[-1500:]
    replies = [json.loads(line) for line in process.stdout.splitlines()]
    assert len(replies) == 60 and all(row["ok"] for row in replies)
    for request, reply in zip(requests, replies, strict=True):
        assert request["id"] == reply["id"]
        model, identifier, route = request["id"].split("/")
        records.append(dict(model=model, id=identifier, route=route, result=reply["result"]))
    summary = {model: {route: dict(cases=5, nonempty=sum(bool(row["result"]["text"].strip()) for row in records
        if row["model"] == model and row["route"] == route)) for route in ["default", "rms"]} for model in models}
    receipt = dict(status="completed-nonspeech-control-not-quality-promotion", timestamp=datetime.datetime.now(datetime.UTC).isoformat(),
        build=json.loads((app / "Contents/Resources/build-info.json").read_text()), harness_sha256=sha(Path(__file__)),
        source_result_sha256=sha(source_path), requests=60, actual_asr=sum(not row["result"]["silence"] for row in records),
        fixtures=[{k: row[k] for k in ["id", "sha256", "pcm_sha256", "samples"]} for row in items],
        summary=summary, records=records, boundary=__doc__.strip() + " Offline bundled worker; no microphone, history, insertion or native UI. Any nonempty output here is a false positive; raw hypotheses are preserved.")
    args.output.write_text(json.dumps(receipt, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
