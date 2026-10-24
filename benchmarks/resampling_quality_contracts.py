"""Real native helper failure isolation and unchanged-input controls, no ASR."""

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

import numpy as np
import soundfile as sf

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    with path.open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--helper", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    assert not args.output.exists()
    helper = args.helper.resolve(strict=True)
    rows = []
    with tempfile.TemporaryDirectory(prefix="ospr-resampling-contract-") as temporary:
        directory = Path(temporary)
        source = directory / "mono.wav"
        values = (np.sin(np.arange(16000) * 0.123) * 0.2).astype("float32")
        sf.write(source, values, 16000, subtype="FLOAT")
        stereo = directory / "stereo.wav"
        sf.write(stereo, np.column_stack([values, values]), 16000, subtype="FLOAT")
        existing = directory / "existing.wav"
        existing.write_bytes(b"keep-me")
        body = dict(
            id="test",
            path=str(source),
            output=str(directory / "output.wav"),
            policy="normal-max",
            packets=[128, 1024],
            repeats=1,
        )
        requests = [
            ("{malformed", "malformed-json"),
            (dict(body, policy="unknown"), "unknown-policy"),
            (dict(body, output=str(existing)), "existing-output"),
            (dict(body, path=str(stereo)), "stereo-input"),
            (dict(body, packets=[8193]), "excess-packet"),
            (dict(body, repeats=6), "excess-repeats"),
            (body, "valid-after-six-failures"),
        ]
        process = subprocess.run(
            [str(helper)],
            input="".join(
                (value if isinstance(value, str) else json.dumps(value)) + "\n" for value, _ in requests
            ),
            text=True,
            capture_output=True,
            timeout=30,
        )
        replies = [json.loads(line) for line in process.stdout.splitlines()]
        assert process.returncode == 0 and len(replies) == len(requests)
        for (_, name), reply in zip(requests, replies, strict=True):
            if name != "valid-after-six-failures":
                assert reply["ok"] is False and reply["error"]
            else:
                assert reply["ok"] and reply["id"] == "test"
                result = reply["result"]
                assert result["exact_whole_reference"] and result["output_frames"] == 16000
                assert result["trials"][0]["converter"]["passthrough"]
                actual, rate = sf.read(directory / "output.wav", dtype="float32")
                assert rate == 16000
                np.testing.assert_array_equal(actual, values)
            rows.append(dict(case=name, response=reply))
        assert existing.read_bytes() == b"keep-me"
        assert sha(source) != sha(existing)
    receipt = dict(
        status="passed-seven-real-native-controls",
        helper_sha256=sha(helper),
        script_sha256=sha(Path(__file__)),
        controls=rows,
        existing_output_unchanged=True,
        boundary="Separate native helper process: six failed requests followed by exact 16 kHz success, no ASR, microphone, UI or default change.",
    )
    args.output.write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(dict(status=receipt["status"], cases=[row["case"] for row in rows])))


if __name__ == "__main__":
    main()
