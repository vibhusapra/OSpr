"""Reproduce actual Whisper overruns against the previous bundle and new source.

Both CLIs run the same full/neural-edge requests. This checks text identity and
source-bound timing, not recognition accuracy or comparative latency.
"""
import argparse
import datetime
import gzip
import hashlib
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--old-app", type=Path, required=True)
    parser.add_argument("--new-app", type=Path, required=True)
    parser.add_argument("--source-work", type=Path, required=True)
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    assert not args.work.exists() and not args.output.exists()
    assert not subprocess.check_output(["git", "diff", "--name-only", "HEAD"], cwd=ROOT)
    result_path = ROOT / "benchmarks/results/neural-edges-multilingual-v1.json"
    source = json.loads(result_path.read_text())
    archive = result_path.with_name(source["traces_file"])
    assert sha(archive) == source["traces_sha256"]
    raw = json.loads(gzip.decompress(archive.read_bytes()))
    items = {item["id"]:item for item in raw["items"]}
    issue_path = ROOT / "benchmarks/results/neural-edges-multilingual-v1-checks.json"
    issues = json.loads(issue_path.read_text())["timing_issues"]
    pairs = sorted({(row["model"], row["id"]) for row in issues})
    assert len(pairs) == 11
    old_app, new_app = args.old_app.resolve(strict=True), args.new_app.resolve(strict=True)
    old_cli, new_cli = old_app / "Contents/MacOS/ospr-cli", new_app / "Contents/MacOS/ospr-cli"
    builds = {key:json.loads((app / "Contents/Resources/build-info.json").read_text()) for key,app in [("old",old_app),("new",new_app)]}
    hashes = dict(old=sha(old_cli), new=sha(new_cli))
    assert builds["old"] == source["build"] and hashes["old"] == source["cli_sha256"]
    assert not builds["new"]["tracked_changes"]
    env = dict(os.environ, HF_HUB_OFFLINE="1", HF_HUB_DISABLE_TELEMETRY="1")
    env.pop("OSPR_ROOT", None)
    args.work.mkdir(parents=True)
    records = []
    for model in sorted({model for model,_ in pairs}):
        selected = [identifier for selected_model,identifier in pairs if selected_model == model]
        entries = []
        for identifier in selected:
            item = items[identifier]
            path = ROOT / "benchmarks" / item["original_path"] if item["variant"] == "original" else args.source_work.resolve() / f"{identifier}.wav"
            assert sha(path) == item["sha256"]
            entries.append(dict(id=identifier,path=str(path),language=item["language"]))
        manifest = args.work.resolve() / f"{model}-manifest.json"
        manifest.write_text(json.dumps(entries))
        outputs = {}
        for key,cli in [("old",old_cli),("new",new_cli)]:
            with (args.work / f"{model}-{key}.json").open("x") as output, (args.work / f"{model}-{key}.log").open("x") as log:
                response = subprocess.run([str(cli), "_benchmark-neural-edges", str(manifest), model], cwd=ROOT,
                    env=env if key == "old" else dict(env, OSPR_ROOT=str(ROOT)), stdout=output, stderr=log, timeout=300)
            assert response.returncode == 0, f"Inspect {model}-{key}.log"
            outputs[key] = json.loads((args.work / f"{model}-{key}.json").read_text())["records"]
        for old,new in zip(outputs["old"],outputs["new"],strict=True):
            assert old["id"] == new["id"]
            for route in ["full", "neural_edges"]:
                before,after = old[route],new[route]
                assert before["text"] == after["text"], f"Text changed: {model}/{old['id']}/{route}"
                assert before["audio_seconds"] == after["audio_seconds"] and before["speech_seconds"] == after["speech_seconds"]
                if route == "neural_edges":
                    assert before["speech_edges"] == after["speech_edges"]
                    edge = after["speech_edges"]
                    start,end = edge["start_sample"] / 16000, edge["end_sample"] / 16000
                else:
                    start,end = 0,after["audio_seconds"]
                assert all(start <= interval["start"] <= interval["end"] <= end
                           for interval in after.get("segments", []) + after.get("words", []))
                bad = any(interval["start"] < start or interval["end"] > end + 1e-6
                          for interval in before.get("segments", []) + before.get("words", []))
                if bad:
                    assert "timing_warning" in after and "timing_corrections" in after
                records.append(dict(model=model,id=old["id"],route=route,bad_before=bad,old=before,new=after))
    assert len(records) == 22 and sum(row["bad_before"] for row in records) == 12
    german = next(row for row in records if row["model"] == "whisper-turbo" and row["id"] == "fleurs-de_de-000-quiet40db" and row["route"] == "neural_edges")
    assert german["old"]["segments"][0]["end"] == 34.588 and german["new"]["segments"][0]["end"] == 5.408
    assert hashes == dict(old=sha(old_cli),new=sha(new_cli))
    for app in [old_app,new_app]:
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)],check=True)
    assert not subprocess.check_output(["git", "diff", "--name-only", "HEAD"], cwd=ROOT)
    receipt = dict(status="passed-real-whisper-timing-reproduction",timestamp=datetime.datetime.now(datetime.UTC).isoformat(),
        git_commit=subprocess.check_output(["git", "rev-parse", "HEAD"],cwd=ROOT,text=True).strip(),tracked_changes=False,
        builds=builds,cli_sha256=hashes,harness_sha256=sha(Path(__file__)),source_result_sha256=sha(result_path),
        source_checks_sha256=sha(issue_path),timing_source_sha256=sha(ROOT / "backend/ospr_backend/timing.py"),
        model_input_pairs=len(pairs),paired_route_results=len(records),actual_asr=sum(not row[key]["silence"] for row in records for key in ["old","new"]),
        reproduced_bad_intervals=12,corrected_results=12,text_identity_results=22,records=records,
        boundary=__doc__.strip() + " The old CLI uses the delivered bundle; the new development CLI explicitly uses the frozen current checkout worker. All inputs are public known clips, language hints are explicit, requests are offline, source sample ranges/hashes are unchanged, and both app signatures remain valid. No microphone, native warning/export acceptance, new ZIP or detector-quality improvement.")
    args.output.write_text(json.dumps(receipt,indent=2,ensure_ascii=False) + "\n")
    print("Passed: 22 paired actual route results; all text identical; 12 overruns reproduced and corrected")


if __name__ == "__main__":
    main()
