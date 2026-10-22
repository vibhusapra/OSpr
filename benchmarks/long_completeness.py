"""Summarize each long-file result with the shared WER normalization."""

import datetime
import hashlib
import json
from pathlib import Path

from ospr_backend.engine import PUBLIC_MODELS
from run import normalize, summarize

ROOT = Path(__file__).resolve().parent


def read_run(path, expected):
    raw = path.read_bytes()
    run = json.loads(raw)
    assert {r["id"] for r in run["records"]} == set(expected)
    assert len(run["records"]) == len(expected)
    cases = []
    for row in run["records"]:
        assert row["sha256"] == expected[row["id"]]["sha256"]
        assert row["reference"] == expected[row["id"]]["reference"]
        score = next(iter(summarize([row]).values()))
        cases.append(dict(id=row["id"], seconds=row["seconds"], error=row.get("error"),
                          score=score, reference_words=len(normalize(row["reference"]).split()),
                          output_words=len(normalize(row.get("text", "")).split()),
                          wall_ms=row["wall_ms"], peak_gpu_bytes=row.get("peak_gpu_bytes"),
                          decoder_chunks=row.get("decoder_chunks"),
                          max_tokens_per_chunk=row.get("max_tokens_per_chunk")))
    return dict(file=path.name, sha256=hashlib.sha256(raw).hexdigest(),
                model=run["model"], source_sha256=run["source_sha256"],
                git_commit=run["git_commit"], working_tree_dirty=run["working_tree_dirty"],
                cases=cases)


def main():
    manifest_path = ROOT / "fixtures/long-session.json"
    manifest = json.loads(manifest_path.read_text())
    expected = {r["id"]: r for r in manifest["items"]}
    models = {}
    for model in PUBLIC_MODELS:
        path = ROOT / "results" / f"{model}-notrim-long-session.json"
        if path.exists():
            models[model] = read_run(path, expected)
    before = read_run(ROOT / "results/qwen3-asr-notrim-long-session-before-chunk-fix.json", expected)
    short_checks = []
    for stem in ("qwen3-asr", "qwen3-asr-test-clean", "qwen3-asr-test-other", "qwen3-asr-fleurs"):
        old_path = ROOT / "results" / f"{stem}.json"
        new_path = ROOT / "results" / f"{stem}-after-long-fix.json"
        if not new_path.exists():
            continue
        old, new = json.loads(old_path.read_text()), json.loads(new_path.read_text())
        originals = {row["id"]: row for row in old["records"]}
        assert len(originals) == len(new["records"])
        assert {row["id"] for row in new["records"]} == set(originals)
        changed = []
        for row in new["records"]:
            original = originals[row["id"]]
            assert row["sha256"] == original["sha256"] and row["reference"] == original["reference"]
            if row.get("text") != original.get("text"):
                changed.append(dict(id=row["id"], seconds=row["seconds"], error=row.get("error")))
        short_checks.append(dict(before_file=old_path.name, after_file=new_path.name,
                                 before_sha256=hashlib.sha256(old_path.read_bytes()).hexdigest(),
                                 after_sha256=hashlib.sha256(new_path.read_bytes()).hexdigest(),
                                 cases=len(new["records"]), changed_outputs=changed,
                                 summary_before=old["summary"], summary_after=new["summary"]))
    result = dict(timestamp=datetime.datetime.now(datetime.UTC).isoformat(),
                  manifest_sha256=hashlib.sha256(manifest_path.read_bytes()).hexdigest(),
                  summary_source_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                  completed_models=list(models), expected_models=list(PUBLIC_MODELS),
                  qwen_before=before, models=models, qwen_short_checks=short_checks,
                  boundary="One warm decode per deterministic 10-minute/hour-long input per model. Complete utterance concatenation, repeated public read speech, 250ms gaps. In-process Engine, no microphone, UI or insertion.",
                  limitations=["Not natural long conversation, independent new speakers, full-corpus or production accuracy.",
                               "Fixed fixture/model order and one warm trial each, no thermal isolation; timings are exploratory.",
                               "Shared WER/CER normalization; numerals and spelling count as errors. Word count alone does not prove completeness.",
                               "Repeated source speech can make localized alignment ambiguous; do not infer exact tail coverage from aggregate alignment."])
    target = ROOT / "results/long-completeness.json"
    target.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({"completed_models": list(models), "output": str(target)}, indent=2))


if __name__ == "__main__":
    main()
