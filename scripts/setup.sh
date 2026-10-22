#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -m)" != "arm64" || "$(uname -s)" != "Darwin" ]]; then
  echo "OSpr local inference requires an Apple Silicon Mac." >&2
  exit 1
fi
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
if ! command -v uv >/dev/null 2>&1; then
  echo "Install uv first: https://docs.astral.sh/uv/getting-started/installation/" >&2
  echo "Recommended: brew install uv" >&2
  exit 1
fi
if [[ "${1:-}" == "--minimal" ]]; then
  uv sync --frozen --python 3.12
else
  uv sync --frozen --python 3.12 --extra research --extra dev
fi
if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "WAV/FLAC work now. For video, MP3 and M4A, install ffmpeg: brew install ffmpeg"
fi
echo "OSpr engine installed. Model weights download on first load."
PYTHONPATH=backend .venv/bin/python -m ospr_backend.worker <<<'{"action":"ping"}'
