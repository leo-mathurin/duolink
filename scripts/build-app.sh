#!/usr/bin/env bash
# Builds dist/Duolink.app (menu bar app) and dist/duolinkctl.
#   ./scripts/build-app.sh            build only
#   ./scripts/build-app.sh --install  also copy the app to /Applications and open it
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/Duolink.app"
VERSION="$(git -C "$ROOT" describe --tags --always 2>/dev/null || echo 0.1.0)"

swift build --package-path "$ROOT/client" -c release
BIN="$(swift build --package-path "$ROOT/client" -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN/Duolink" "$APP/Contents/MacOS/Duolink"
cp "$BIN/duolinkctl" "$DIST/duolinkctl"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>io.github.leo-mathurin.duolink</string>
    <key>CFBundleName</key><string>Duolink</string>
    <key>CFBundleDisplayName</key><string>Duolink</string>
    <key>CFBundleExecutable</key><string>Duolink</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION#v}</string>
    <key>CFBundleVersion</key><string>${VERSION#v}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature: enough to run locally, not for distribution.
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Duolink 2>/dev/null && sleep 2 || true
  rm -rf /Applications/Duolink.app
  cp -R "$APP" /Applications/
  open /Applications/Duolink.app
  echo "Installed /Applications/Duolink.app"
fi
