#!/usr/bin/env bash
# Build Voice Operator's headless service (DESIGN.md "Service mode") into
# <outdir>, for another program to run as its own private instance:
#
#   scripts/make-service.sh <outdir>
#   <outdir>/voice-service --home <dir> [--kokoro-port N]
#
# <outdir>/VoiceOperatorService.app is a minimal bundle around the release
# binary: its own bundle id (com.chriswa.voiceoperator.service, so no
# UserDefaults are shared with the app), the Silero model and the Kokoro server
# files as resources. It never restarts or touches the running app, and burns
# no build number (it is stamped with the committed version).
set -euo pipefail

OUT="${1:?usage: make-service.sh <outdir>}"
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
source scripts/lib.sh

echo "building the service (release)…"
swift build -c release --product VoiceOperator
BIN="$(swift build -c release --show-bin-path)/VoiceOperator"
read -r VERSION BUILD_NUMBER <<<"$(committed_version)"

mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
APP="$OUT/VoiceOperatorService.app"
TMP="$OUT/.VoiceOperatorService.app.tmp"
rm -rf "$TMP"
mkdir -p "$TMP/Contents/MacOS" "$TMP/Contents/Resources"
cp "$BIN" "$TMP/Contents/MacOS/VoiceOperator"
cat >"$TMP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Voice Operator Service</string>
    <key>CFBundleIdentifier</key>
    <string>com.chriswa.voiceoperator.service</string>
    <key>CFBundleExecutable</key>
    <string>VoiceOperator</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0</string>
    <key>CFBundleVersion</key>
    <string>0</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST
cp Sources/COpus/COPYING "$TMP/Contents/Resources/libopus-COPYING.txt"
cp Resources/models/silero_vad_16k_op15.onnx "$TMP/Contents/Resources/"
cp Resources/models/SILERO_LICENSE "$TMP/Contents/Resources/silero-LICENSE.txt"
copy_kokoro_resources "$TMP"
stamp_build_identity "$TMP" "$VERSION" "$BUILD_NUMBER"
codesign --force --sign - --identifier com.chriswa.voiceoperator.service "$TMP" >/dev/null 2>&1
# Swapped in whole, so a service running from the old bundle keeps its files until it restarts.
rm -rf "$APP"
mv "$TMP" "$APP"

cat >"$OUT/voice-service" <<'SH'
#!/bin/sh
# Voice Operator's headless service: voice-service --home <dir> [--kokoro-port N]
exec "$(cd "$(dirname "$0")" && pwd)/VoiceOperatorService.app/Contents/MacOS/VoiceOperator" --service "$@"
SH
chmod +x "$OUT/voice-service"
echo "built: $OUT/voice-service (v$VERSION, $(/usr/libexec/PlistBuddy -c 'Print VOSourceCommit' "$APP/Contents/Info.plist"))"
