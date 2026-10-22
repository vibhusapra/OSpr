#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-release}"
swift build -c "$configuration"
app="dist/OSpr.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp ".build/$configuration/OSpr" "$app/Contents/MacOS/OSpr"
cp ".build/$configuration/ospr-cli" dist/ospr-cli
cp ".build/$configuration/ospr-cli" "$app/Contents/MacOS/ospr-cli"
pwd > "$app/Contents/Resources/checkout-root.txt"
python3 - "$app/Contents/Resources/build-info.json" <<'PY'
import datetime, hashlib, json, pathlib, subprocess, sys
paths = sorted(pathlib.Path('Sources').rglob('*.swift')) + sorted(pathlib.Path('backend/ospr_backend').glob('*.py'))
digest = hashlib.sha256()
for path in paths:
    digest.update(str(path).encode()); digest.update(path.read_bytes())
info = dict(version='0.1.0', built_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),
            git_commit=subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
            tracked_changes=bool(subprocess.check_output(['git', 'diff', '--name-only'], text=True).strip()),
            application_source_sha256=digest.hexdigest(), boundary='Development build; ad-hoc signature; weights downloaded separately.')
pathlib.Path(sys.argv[1]).write_text(json.dumps(info, indent=2)+'\n')
PY
swift scripts/make-icon.swift dist/OSpr.iconset
iconutil -c icns dist/OSpr.iconset -o "$app/Contents/Resources/OSpr.icns"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>OSpr</string>
<key>CFBundleIdentifier</key><string>app.ospr.mac</string>
<key>CFBundleName</key><string>OSpr</string>
<key>CFBundleDisplayName</key><string>OSpr</string>
<key>CFBundleIconFile</key><string>OSpr</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSMicrophoneUsageDescription</key><string>OSpr records your microphone when you start dictation. Audio is processed locally unless you explicitly choose a cloud provider.</string>
<key>NSScreenCaptureUsageDescription</key><string>OSpr captures desktop sound only when you start a meeting recording. Video is not stored.</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --deep --sign - "$app"
echo "Built $app (ad-hoc signed; local development build)."
echo "Keep this checkout for the Python engine; select a new location in Settings if moved."
