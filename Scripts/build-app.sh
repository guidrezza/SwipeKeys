#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${VERSION:-1.1.1}"
APP_DIR="$ROOT_DIR/dist/SwipeKeys.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

cd "$ROOT_DIR"
swift build -c release
swift "$ROOT_DIR/Scripts/generate-icon.swift" "$ROOT_DIR/dist/AppIcon.iconset"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$ROOT_DIR/.build/release/swipekeys" "$MACOS_DIR/SwipeKeys"
iconutil -c icns "$ROOT_DIR/dist/AppIcon.iconset" -o "$RESOURCES_DIR/AppIcon.icns"
rm -rf "$ROOT_DIR/dist/AppIcon.iconset"

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>SwipeKeys</string>
  <key>CFBundleIdentifier</key>
  <string>com.guidrezza.SwipeKeys</string>
  <key>CFBundleName</key>
  <string>SwipeKeys</string>
  <key>CFBundleDisplayName</key>
  <string>SwipeKeys</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleShortVersionString</key>
  <string>__VERSION__</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

perl -0pi -e "s/__VERSION__/$VERSION/g" "$CONTENTS_DIR/Info.plist"

chmod +x "$MACOS_DIR/SwipeKeys"
strip -x "$MACOS_DIR/SwipeKeys"
codesign --force --deep --sign - "$APP_DIR" >/dev/null
echo "Built $APP_DIR"
