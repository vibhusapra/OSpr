#!/bin/bash
# Build a relocatable local .app with Python and locked runtime dependencies.
# Model weights remain first-run downloads in the user's Hugging Face cache.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
[[ "$(uname -m)" == arm64 ]] || { echo 'Apple Silicon required' >&2; exit 1; }
[[ -x .venv/bin/python ]] || scripts/setup.sh
scripts/build-app.sh
app="${OSPR_BUNDLE_OUTPUT:-dist/standalone/OSpr.app}"
signing_identity="${OSPR_SIGN_IDENTITY:--}"
[[ ! -e "$app" ]] || { echo "Move or remove the existing $app before rebuilding." >&2; exit 1; }
mkdir -p "$(dirname "$app")"
cp -R dist/OSpr.app "$app"
resources="$app/Contents/Resources"
minimum_macos="${OSPR_MACOS_TARGET:-$(sw_vers -productVersion)}"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $minimum_macos" "$app/Contents/Info.plist"
python_base="$(.venv/bin/python -c 'import sys; print(sys.base_prefix)')"
mkdir -p "$resources/Python" "$resources/Engine/backend"
rsync -a --exclude='__pycache__' "$python_base/" "$resources/Python/"
rsync -a --exclude='__pycache__' backend/ospr_backend "$resources/Engine/backend/"
cp pyproject.toml uv.lock "$resources/Engine/"
# Install with the bundled interpreter. Replace uv's absolute Python symlink with
# a relative launcher afterward; a moved .app must never use the build machine.
MACOSX_DEPLOYMENT_TARGET="$minimum_macos" uv sync --python-platform aarch64-apple-darwin --project "$resources/Engine" --frozen --python "$PWD/$resources/Python/bin/python3.12" --extra engines --extra mcp --no-dev
rm "$resources/Engine/.venv/bin/python"
cat > "$resources/Engine/.venv/bin/python" <<'LAUNCHER'
#!/bin/bash
set -euo pipefail
engine="$(cd "$(dirname "$0")/../.." && pwd)"
resources="$(dirname "$engine")"
export PYTHONHOME="$resources/Python"
export PYTHONPATH="$engine/.venv/lib/python3.12/site-packages:$engine/backend"
export PYTHONNOUSERSITE=1
export PYTHONSAFEPATH=1
export PYTHONDONTWRITEBYTECODE=1
export HF_HUB_DISABLE_TELEMETRY=1
export DO_NOT_TRACK=1
exec "$resources/Python/bin/python3.12" "$@"
LAUNCHER
chmod +x "$resources/Engine/.venv/bin/python"
# Don't leave a build-machine path in the app's resource marker or venv metadata.
rm "$resources/checkout-root.txt"
cat > "$resources/Engine/.venv/pyvenv.cfg" <<'CONFIG'
include-system-site-packages = false
version = 3.12.11
CONFIG
cp LICENSE NOTICE "$resources/"
cp -R licenses "$resources/"
mkdir -p "$resources/Engine/docs/data" "$resources/Engine/benchmarks/results"
mkdir -p "$resources/Engine/docs/architecture"
mkdir -p "$resources/Engine/docs/assets"
mkdir -p "$resources/Engine/benchmarks/fixtures"
cp docs/research.html docs/PROGRESS.md "$resources/Engine/docs/"
cp docs/architecture/*.md "$resources/Engine/docs/architecture/"
cp docs/assets/* "$resources/Engine/docs/assets/"
cp docs/data/*.json "$resources/Engine/docs/data/"
rsync -a --include='*/' --include='*.json' --include='*.json.gz' --include='*.srt' --include='*.vtt' --exclude='*' benchmarks/results/ "$resources/Engine/benchmarks/results/"
cp benchmarks/README.md "$resources/Engine/benchmarks/"
cp benchmarks/fixtures/*.json "$resources/Engine/benchmarks/fixtures/"
cp benchmarks/fixtures/insertion-target.html "$resources/Engine/benchmarks/fixtures/"
"$resources/Engine/.venv/bin/python" -c 'import importlib.metadata as m, json; print(json.dumps(sorted([{"name":d.metadata["Name"], "version":d.version, "license":d.metadata.get("License-Expression") or d.metadata.get("License"), "source":d.metadata.get("Home-page")} for d in m.distributions()], key=lambda x:x["name"].lower()), indent=2))' > "$resources/dependencies.json"

codesign --force --deep --sign "$signing_identity" "$app"
codesign --verify --deep --strict "$app"
"$resources/Engine/.venv/bin/python" -m ospr_backend.worker <<<'{"action":"ping"}'
echo "Built $app with relocatable Python. Development build; not notarized."
