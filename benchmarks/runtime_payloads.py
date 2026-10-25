"""Compare selected Python/MLX runtime payloads on temporary unsigned copies.

Never removes signatures from the original artifacts. This checks five selected
files, not every dependency, driver/cache state, model weight or OS condition.
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

from artifact_latency import sha, write_new

FILES = ["Python/bin/python3.12", "Python/lib/libpython3.12.dylib",
         *["Engine/.venv/lib/python3.12/site-packages/mlx/" + name for name in
           ("core.cpython-312-darwin.so", "lib/libmlx.dylib", "lib/libjaccl.dylib")]]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--a", type=Path, required=True)
    parser.add_argument("--b", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    assert not args.output.exists(), "Refusing to replace runtime observations"
    apps = {key: path.resolve(strict=True) for key, path in (("A", args.a), ("B", args.b))}
    for app in apps.values():
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    rows = []
    with tempfile.TemporaryDirectory(prefix="ospr-unsigned-runtime-") as temporary:
        for index, relative in enumerate(FILES):
            row = dict(relative_path=relative, artifacts={})
            for label, app in apps.items():
                original = app / "Contents/Resources" / relative
                assert original.resolve(strict=True).is_relative_to(app)
                before = sha(original)
                copied = Path(temporary) / f"{index}-{label}"
                shutil.copyfile(original, copied)
                command = subprocess.run(["codesign", "--remove-signature", str(copied)], capture_output=True, text=True)
                assert command.returncode == 0 or "not signed at all" in command.stderr
                row["artifacts"][label] = dict(original_sha256=before, unsigned_sha256=sha(copied),
                                                signature_removed_from_copy=command.returncode == 0)
                assert sha(original) == before, "Original runtime changed"
            row["unsigned_bytes_identical"] = row["artifacts"]["A"]["unsigned_sha256"] == row["artifacts"]["B"]["unsigned_sha256"]
            rows.append(row)
    for app in apps.values():
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    result = dict(status="completed-selected-runtime-payload-comparison", records=rows,
                  builds={label: json.loads((app / "Contents/Resources/build-info.json").read_text()) for label, app in apps.items()},
                  originals_unchanged=True, original_signatures_valid_after=True,
                  harness_sha256=sha(Path(__file__)), boundary=__doc__.strip())
    write_new(args.output, result)
    print(json.dumps(dict(files=len(rows), identical=sum(row["unsigned_bytes_identical"] for row in rows))))


if __name__ == "__main__":
    main()
