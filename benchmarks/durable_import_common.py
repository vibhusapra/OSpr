"""Bind headless batch probes to freshly built current source and test bytes."""

import hashlib
from pathlib import Path
import subprocess


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def application_fingerprint(package: Path) -> str:
    paths = sorted((package / "Sources").rglob("*.swift")) + sorted(
        path for path in (package / "backend/ospr_backend").rglob("*") if path.suffix in {".py", ".json", ".npy"}
    )
    value = hashlib.sha256()
    for path in paths:
        value.update(str(path.relative_to(package)).encode())
        value.update(path.read_bytes())
    return value.hexdigest()


def prepare_probe(package: Path, output: Path, source: str, test: str) -> dict:
    temporary = package / "Tests/OSprPlatformTests" / (test + ".swift")
    if temporary.read_bytes() != (package / "benchmarks" / source).read_bytes():
        raise ValueError("Temporary test source must match the benchmark probe exactly")
    before = application_fingerprint(package)
    with (output / "build.log").open("w") as log:
        subprocess.run(["swift", "test", "--filter", test], cwd=package, check=True, stdout=log, stderr=subprocess.STDOUT, timeout=180)
    if application_fingerprint(package) != before:
        raise RuntimeError("Application source changed while building the process probe")
    executable = package / ".build/debug/OSprPackageTests.xctest/Contents/MacOS/OSprPackageTests"
    return {"application_source_sha256": before, "source_manifest_version": 2,
            "test_executable_sha256": digest(executable), "probe_sha256": digest(temporary),
            "guardian_sha256": digest(package / ".build/debug/ospr-worker-guardian"),
            "build_log_sha256": digest(output / "build.log")}
