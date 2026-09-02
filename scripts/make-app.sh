#!/usr/bin/env bash
# Build VoiceOperator.app — a menu-bar accessory bundle around the SwiftPM
# executable. Ad-hoc signed with a stable bundle id so macOS TCC remembers the
# Accessibility / Microphone grants across rebuilds.
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
source scripts/lib.sh
CONFIG="${1:-debug}"

echo "building ($CONFIG)…"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/VoiceOperator"

# Allocated after the compile, so a build that failed doesn't burn a number.
read -r VERSION BUILD_NUMBER <<<"$(allocate_version)"
echo "version: $VERSION (build $BUILD_NUMBER)"

APP="build/Voice Operator.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/VoiceOperator"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/*.svg "$APP/Contents/Resources/"
cp Resources/*.png "$APP/Contents/Resources/"
stamp_build_identity "$APP" "$VERSION" "$BUILD_NUMBER"

# Sign with a real codesigning identity if one exists (stable designated
# requirement → TCC remembers Accessibility/Microphone grants across rebuilds).
# Fall back to ad-hoc (grants must be re-approved every rebuild).
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Developer ID Application|Apple Development/{print $2; exit}')"
if [ -n "$IDENTITY" ]; then
    echo "signing as: $IDENTITY"
    codesign --force --sign "$IDENTITY" --identifier com.chriswa.voiceoperator \
        --entitlements Resources/VoiceOperator.entitlements --options runtime "$APP"
else
    echo "signing ad-hoc (no identity found — TCC grants won't persist across rebuilds)"
    codesign --force --sign - --identifier com.chriswa.voiceoperator \
        --entitlements Resources/VoiceOperator.entitlements "$APP"
fi

echo "built: $APP  (v$VERSION)"
restart_running_app "$APP" "$VERSION"
