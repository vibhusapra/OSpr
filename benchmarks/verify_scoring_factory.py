"""Verify research adapter injection without loading models or running inference."""
import json
from pathlib import Path
import sys
import tempfile

# The direct benchmark entry point requires its backend; scoring imports do not.
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))
from ospr_backend import engine  # noqa: E402
import run  # noqa: E402


class ConstructorReached(Exception):
    pass


def main():
    calls = []

    def candidate():
        calls.append("candidate")
        raise ConstructorReached

    def default():
        calls.append("default")
        raise ConstructorReached

    original_constructor, original_arguments = engine.Engine, sys.argv
    try:
        with tempfile.TemporaryDirectory(prefix="ospr-scoring-contract-") as directory:
            manifest = Path(directory) / "manifest.json"
            manifest.write_text(json.dumps(dict(items=[dict(id="constructor-only")])))
            sys.argv = ["run.py", "--manifest", str(manifest)]
            engine.Engine = default
            for factory in (candidate, None):
                try:
                    run.main(engine_factory=factory)
                except ConstructorReached:
                    pass
                else:
                    raise AssertionError("Expected constructor was not invoked")
        assert calls == ["candidate", "default"], calls
    finally:
        engine.Engine, sys.argv = original_constructor, original_arguments
    print("Scoring entry point: explicit candidate and default constructors passed; no inference")


if __name__ == "__main__":
    main()
