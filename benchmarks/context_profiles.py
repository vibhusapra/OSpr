"""Black-box the real Swift profile resolver with public synthetic settings.

No model runtime is available to the tested commands. The optional receipt keeps
only case IDs and resolved values, not the supplied document URL.
"""
import argparse
import copy
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
    parser.add_argument("--cli", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    cli = args.cli.resolve(strict=True)
    profiles = [
        dict(id="00000000-0000-0000-0000-000000000001", bundleID="com.test.browser", mode="email", enabled=True,
             localModel="whisper-turbo", language="en-GB"),
        dict(id="00000000-0000-0000-0000-000000000002", bundleID="com.test.browser", mode="custom", enabled=True,
             name="Code", site="https://example.org/team", localModel="cohere-native8", language="", customPrompt="Keep identifiers exactly."),
        dict(id="00000000-0000-0000-0000-000000000003", bundleID="com.test.browser", mode="translate", enabled=True,
             name="French", site="https://example.org/team/admin", translationLanguage="French"),
        dict(id="00000000-0000-0000-0000-000000000004", bundleID="com.test.disabled", mode="code", enabled=False),
    ]
    settings = dict(model="parakeet-v3", language="en", mode="clean", rewriteProvider="none", profiles=profiles)
    cases = [
        ("app-fallback", "com.test.browser", None, dict(match="app", mode="email", speech_model="whisper-turbo", language="en-GB")),
        ("site-custom", "com.test.browser", "https://example.org/team/code?auth=public-query-sentinel#tab", dict(match="site", mode="custom", speech_model="cohere-native8", language="", instruction="Keep identifiers exactly.")),
        ("longest-path", "com.test.browser", "https://example.org/team/admin/edit", dict(match="site", mode="translate", speech_model="parakeet-v3", language="en", instruction="Translate into French. Preserve names, numbers and meaning.")),
        ("segment-boundary", "com.test.browser", "https://example.org/teammate", dict(match="app", mode="email")),
        ("scheme-boundary", "com.test.browser", "http://example.org/team", dict(match="app", mode="email")),
        ("host-boundary", "com.test.browser", "https://example.org.evil/team", dict(match="app", mode="email")),
        ("port-boundary", "com.test.browser", "https://example.org:444/team", dict(match="app", mode="email")),
        ("foreign-app", "com.test.other", "https://example.org/team", dict(match="global", mode="clean", speech_model="parakeet-v3", document_available=False)),
        ("disabled-app", "com.test.disabled", None, dict(match="global", mode="clean")),
        ("invalid-document", "com.test.browser", "file:///team", dict(match="app", mode="email", document_available=False)),
        ("default-port", "com.test.browser", "HTTPS://EXAMPLE.ORG:443/team", dict(match="site", mode="custom")),
    ]
    records = []
    with tempfile.TemporaryDirectory(prefix="ospr-profile-resolution-") as temporary:
        directory = Path(temporary)
        path = directory / "public-settings.json"
        environment = dict(os.environ, OSPR_ROOT=str(directory / "no-engine"), HF_HUB_OFFLINE="1")

        def resolve(case_id, config, bundle, document, expected):
            path.write_text(json.dumps(config))
            command = [str(cli), "resolve-profile", str(path), bundle]
            if document is not None:
                command.append(document)
            process = subprocess.run(command, capture_output=True, text=True, cwd=directory, env=environment, timeout=15)
            assert process.returncode == 0, (case_id, process.stderr)
            value = json.loads(process.stdout)
            assert all(value[key] == expected_value for key, expected_value in expected.items()), (case_id, expected, value)
            assert "public-query-sentinel" not in process.stdout
            assert document is None or document not in process.stdout
            records.append(dict(id=case_id, status="passed", result=value))

        for case_id, bundle, document, expected in cases:
            resolve(case_id, settings, bundle, document, expected)
        cloud = copy.deepcopy(settings)
        cloud.update(transcriptionProvider="soniox", transcriptionModel="stt-async-v5")
        resolve("cloud-model-retained", cloud, "com.test.browser", "https://example.org/team", dict(match="site", speech_provider="soniox", speech_model="stt-async-v5", mode="custom"))
        invalid = copy.deepcopy(settings)
        invalid["profiles"][1]["localModel"] = "untrusted/model"
        resolve("invalid-profile-fallback", invalid, "com.test.browser", "https://example.org/team", dict(match="app", mode="email"))
        persisted = copy.deepcopy(settings)
        persisted["profiles"][1].update(enabled=False, contextEnabled=True)
        resolve("persisted-modern-profile", persisted, "com.test.browser", "https://example.org/team", dict(match="site", mode="custom"))
        persisted["profiles"][1]["contextEnabled"] = False
        resolve("persisted-disabled-profile", persisted, "com.test.browser", "https://example.org/team", dict(match="app", mode="email"))
        for case_id, data in [("oversized-file", b" " * (4 * 1024 * 1024 + 1)), ("malformed-settings", b'{"profiles":true}')]:
            path.write_bytes(data)
            process = subprocess.run([str(cli), "resolve-profile", str(path), "com.test.browser"], capture_output=True, text=True, cwd=directory, env=environment, timeout=15)
            assert process.returncode != 0 and not process.stdout, case_id
            if case_id == "oversized-file":
                assert "4 MiB" in process.stderr
            records.append(dict(id=case_id, status="rejected-as-expected"))
    receipt = dict(status="passed", verified_at=datetime.datetime.now(datetime.UTC).isoformat(),
                   git_commit=subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
                   tracked_changes=bool(subprocess.check_output(["git", "diff", "--name-only", "HEAD"], cwd=ROOT)),
                   cli_sha256=hashlib.sha256(cli.read_bytes()).hexdigest(),
                   harness_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                   engine_root_unavailable=True, records=records,
                   boundary=f"{len(records)} public synthetic black-box Swift CLI profile cases, including two negative controls. No AX, microphone, model inference, provider call or native editor interaction. Not a latency benchmark.")
    if args.output:
        if args.output.exists():
            parser.error("Receipt already exists; choose a fresh path.")
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(dict(status="passed", cases=len(records), cli_sha256=receipt["cli_sha256"])))


if __name__ == "__main__":
    main()
