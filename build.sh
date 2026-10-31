#!/bin/bash
# Build and install SpeakCast.app
# Needs: macOS 14.2+ (system-audio taps) and the Xcode Command Line Tools (xcode-select --install).
# Builds in a temp folder, ad-hoc signs, installs to ~/Applications and launches the app.
set -euo pipefail

if ! command -v swiftc >/dev/null 2>&1; then
  echo "error: swiftc not found. Install the Xcode Command Line Tools first:  xcode-select --install" >&2
  exit 1
fi

OS_VERSION="$(sw_vers -productVersion)"
IFS=. read -r OS_MAJOR OS_MINOR _ <<< "$OS_VERSION"
if [ "$OS_MAJOR" -lt 14 ] || { [ "$OS_MAJOR" -eq 14 ] && [ "${OS_MINOR:-0}" -lt 2 ]; }; then
  echo "error: SpeakCast needs macOS 14.2 or newer (this Mac has $OS_VERSION)." >&2
  exit 1
fi

SRC="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d /tmp/speakcast.XXXXXX)"
APP="$WORK/SpeakCast.app"
DEST="$HOME/Applications"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$APP/Contents/MacOS"

echo "Compiling..."
swiftc -O -parse-as-library -swift-version 5 "$SRC/SpeakCast.swift" \
  -o "$APP/Contents/MacOS/SpeakCast" \
  -target "$(uname -m)-apple-macos14.2"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>SpeakCast</string>
  <key>CFBundleIdentifier</key><string>com.matinalijani.speakcast</string>
  <key>CFBundleName</key><string>SpeakCast</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>CFBundleShortVersionString</key><string>2.0</string>
  <key>LSMinimumSystemVersion</key><string>14.2</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Play microphone audio through the selected outputs</string>
  <key>NSAudioCaptureUsageDescription</key>
  <string>Capture system audio so it can be sent to several outputs in sync</string>
</dict>
</plist>
EOF

xattr -cr "$APP"
codesign --force --sign - "$APP"

# the build succeeded: now close a running copy so the new one replaces it
if pkill -x SpeakCast 2>/dev/null; then sleep 1; fi

# remove the old build from when the app was called MultiAudio
pkill -x MultiAudio 2>/dev/null || true
rm -rf "$DEST/MultiAudio.app"

mkdir -p "$DEST"
rm -rf "$DEST/SpeakCast.app"
ditto --norsrc --noextattr "$APP" "$DEST/SpeakCast.app"

echo "Installed: $DEST/SpeakCast.app"
open "$DEST/SpeakCast.app"
