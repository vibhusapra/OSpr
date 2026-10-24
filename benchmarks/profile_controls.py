"""Replay native-saved profile controls through the real Swift resolver.

Fixtures differ from their native settings checkpoints only in rootPath. These
commands do not initialize an engine, read AX metadata, record or call providers.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def replay(cli, fixtures):
    configs = {name: json.loads((fixtures / f"profile-controls-{name}.json").read_text()) for name in ("disabled", "enabled", "inherited")}
    for name, config in configs.items():
        profile = config["profiles"][0]
        assert len(config["profiles"]) == 1 and profile["enabled"] is False
        assert profile["contextEnabled"] is (name != "disabled")
        assert profile["site"] == "https://example.com/project" and profile["localModel"] == "qwen3-asr"
        assert profile["mode"] == "translate" and "customPrompt" not in profile
        if name == "inherited":
            assert "language" not in profile and "translationLanguage" not in profile
        else:
            assert profile["language"] == "" and profile["translationLanguage"] == "French"
    assert len({config["profiles"][0]["id"] for config in configs.values()}) == 1
    globals_only = [{key: value for key, value in c.items() if key != "profiles"} for c in configs.values()]
    assert all(config == globals_only[0] for config in globals_only)
    records = []
    environment = dict(os.environ, OSPR_ROOT="/tmp/ospr-profile-controls-no-engine", HF_HUB_OFFLINE="1")
    for state in configs:
        cases = [
            ("site", "com.apple.TextEdit", "https://example.com/project/note"),
            ("outside", "com.apple.TextEdit", "https://example.com/other"),
            ("foreign", "com.example.foreign", "https://example.com/project"),
        ]
        if state == "enabled":
            cases += [("canonical-document", "com.apple.TextEdit", "HTTPS://EXAMPLE.COM:443/project/"),
                      ("query-not-echoed", "com.apple.TextEdit", "https://example.com/project?private-query-sentinel=fixture#tab")]
        for case, bundle, url in cases:
            response = subprocess.run([str(cli), "resolve-profile", str(fixtures / f"profile-controls-{state}.json"), bundle, url],
                                      env=environment, capture_output=True, text=True, check=True, timeout=15)
            assert url not in response.stdout and "private-query-sentinel" not in response.stdout
            result = json.loads(response.stdout)
            matched = state != "disabled" and case not in {"outside", "foreign"}
            assert result["match"] == ("site" if matched else "global"), (state, case, result)
            if matched:
                target = "English" if state == "inherited" else "French"
                assert result["mode"] == "translate" and result["speech_model"] == "qwen3-asr" and result["language"] == ""
                assert result["instruction"] == f"Translate into {target}. Preserve names, numbers and meaning."
            else:
                assert result["mode"] == "verbatim" and result["speech_model"] == "parakeet-v3"
                assert result["instruction"] == "Return the transcript unchanged."
            records.append(dict(state=state, case=case, result=result))
    return records


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", type=Path, required=True)
    parser.add_argument("--fixtures", type=Path, default=ROOT / "benchmarks/fixtures")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    cli, fixtures = args.cli.resolve(strict=True), args.fixtures.resolve(strict=True)
    records = replay(cli, fixtures)
    receipt = dict(status="passed-native-profile-controls-resolver-replay", timestamp=datetime.datetime.now(datetime.UTC).isoformat(),
                   cli_sha256=sha(cli), source_sha256=sha(Path(__file__)), records=records,
                   fixture_sha256={name: sha(fixtures / f"profile-controls-{name}.json") for name in ("disabled", "enabled", "inherited")},
                   boundary="Eleven actual Swift resolver requests against native-saved configuration checkpoints. "
                   "No AX lookup, microphone, model, provider, translation quality or live dictation/insertion acceptance.")
    if args.output:
        args.output.write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(dict(status=receipt["status"], cases=len(records))))


if __name__ == "__main__":
    main()
