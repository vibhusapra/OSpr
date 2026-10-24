"""Check omitted-trim requests against frozen full-audio multilingual controls.

Known clips, not a held-out quality study or a latency/product ranking. The
selection is fixed before execution: source 000 in each supported language,
original and 40 dB attenuation, for every model in the previous study.
"""
import argparse
import datetime
import gzip
import hashlib
import json
import os
from pathlib import Path
import select
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-work", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    assert not args.output.exists()
    assert not subprocess.check_output(["git", "diff", "--name-only", "HEAD"], cwd=ROOT)
    source_path = ROOT / "benchmarks/results/neural-edges-multilingual-v1.json"
    source = json.loads(source_path.read_text())
    archive = source_path.with_name(source["traces_file"])
    assert sha(archive) == source["traces_sha256"]
    assert sha(ROOT / "backend/ospr_backend/models.lock.json") == source["asr_lock_sha256"]
    assert sha(ROOT / "uv.lock") == source["dependency_lock_sha256"]
    raw = json.loads(gzip.decompress(archive.read_bytes()))
    items = {row["id"]: row for row in raw["items"]}
    selected = [row for row in raw["records"] if "-000-" in row["id"]]
    assert len(selected) == 52
    env = dict(os.environ, PYTHONPATH=str(ROOT / "backend"), HF_HUB_OFFLINE="1", HF_HUB_DISABLE_TELEMETRY="1")
    records = []
    with args.output.with_suffix(".log").open("x") as log:
        process = subprocess.Popen([sys.executable, "-m", "ospr_backend.worker"], cwd=ROOT,
                                   env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log, text=True)
        try:
            for index, old in enumerate(selected):
                item = items[old["id"]]
                path = (ROOT / "benchmarks" / item["original_path"] if item["variant"] == "original"
                        else args.source_work.resolve() / f"{item['id']}.wav")
                assert sha(path) == item["sha256"]
                request = dict(id=str(index), action="transcribe", path=str(path), model=old["model"], language=item["language"])
                # Deliberately omit trim: this is the default behavior under test.
                process.stdin.write(json.dumps(request) + "\n")
                process.stdin.flush()
                while True:
                    assert select.select([process.stdout], [], [], 180)[0], "Worker timed out; inspect private log."
                    line = process.stdout.readline()
                    assert line, "Worker exited; inspect private log."
                    reply = json.loads(line)
                    if "ok" in reply:
                        break
                assert reply["ok"] and reply["id"] == str(index), reply
                new = reply["result"]
                assert new["speech_seconds"] == new["audio_seconds"] == item["samples"] / 16000
                same = new["text"] == old["full"]["text"]
                records.append(dict(id=old["id"], model=old["model"], file_sha256=item["sha256"],
                                    pcm_sha256=item["pcm_sha256"], expected_text=old["full"]["text"],
                                    text_identical=same, result=new))
                print(f"{index + 1}/52 {old['model']} {old['id']}: text {'identical' if same else 'CHANGED'}", flush=True)
        finally:
            process.stdin.close()
            try:
                process.wait(timeout=30)
            except subprocess.TimeoutExpired:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
    assert process.returncode == 0
    assert not subprocess.check_output(["git", "diff", "--name-only", "HEAD"], cwd=ROOT)
    receipt = dict(status="passed" if all(row["text_identical"] for row in records) else "failed-text-identity",
        timestamp=datetime.datetime.now(datetime.UTC).isoformat(),
        git_commit=subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        tracked_changes=False, harness_sha256=sha(Path(__file__)), engine_sha256=sha(ROOT / "backend/ospr_backend/engine.py"),
        source_result_sha256=sha(source_path), asr_lock_sha256=source["asr_lock_sha256"],
        dependency_lock_sha256=sha(ROOT / "uv.lock"), requests=len(records), actual_asr=sum(not row["result"]["silence"] for row in records),
        identical_texts=sum(row["text_identical"] for row in records), records=records, boundary=__doc__.strip())
    args.output.write_text(json.dumps(receipt, indent=2, ensure_ascii=False) + "\n")
    assert receipt["status"] == "passed", "Results preserved; inspect text changes."


if __name__ == "__main__":
    main()
