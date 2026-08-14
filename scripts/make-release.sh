#!/usr/bin/env bash
# Build a distributable, notarized "Voice Operator.app".
#
# Produces a UNIVERSAL binary (arm64 + x86_64) so it runs on both Apple Silicon
# and Intel Macs, targets macOS 13 (Ventura) as the floor, signs with a
# Developer ID Application certificate under a hardened runtime, notarizes with
# Apple, and staples the ticket so it launches cleanly on any Mac — offline and
# without Gatekeeper prompts.
#
# One-time setup (see docs/RELEASING.md):
#   1. A "Developer ID Application" certificate in your login Keychain.
#   2. Notarization credentials stored under a keychain profile:
#        xcrun notarytool store-credentials "$NOTARY_PROFILE" \
#          --apple-id <you@example.com> --team-id 7H2524M5TN \
#          --password <app-specific-password>
#
# Output: build/release/Voice Operator.app  and  build/VoiceOperator.zip
set -euo pipefail

cd "$(dirname "$0")/.."

NOTARY_PROFILE="${NOTARY_PROFILE:-claude-usage-notary}"
BUNDLE_ID="com.chriswa.voiceoperator"
# Release builds live under their own directory so a concurrent debug build
# (make-app.sh, which owns build/Voice Operator.app) can't clobber the bundle
# between signing and stapling — a mismatch there fails notarization stapling.
APP="build/release/Voice Operator.app"
ZIP="build/VoiceOperator.zip"

# --- Require a Developer ID Application identity (dev/ad-hoc certs won't pass
#     notarization and won't launch on other people's Macs). ---
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Developer ID Application/ && !f {print $2; f=1}')"
if [ -z "$IDENTITY" ]; then
    echo "error: no 'Developer ID Application' certificate found in the Keychain." >&2
    echo "       Create one in Xcode → Settings → Accounts → Manage Certificates → +." >&2
    exit 1
fi

echo "building universal (release, arm64 + x86_64)…"
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/VoiceOperator"

echo "assembling bundle…"
rm -rf "$APP" "$ZIP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/VoiceOperator"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/*.svg "$APP/Contents/Resources/"
cp Resources/*.png "$APP/Contents/Resources/"

echo "signing as: $IDENTITY"
# --timestamp (secure timestamp) and --options runtime (hardened runtime) are
# both required for notarization.
codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" \
    --entitlements Resources/VoiceOperator.entitlements \
    --options runtime --timestamp "$APP"

echo "verifying signature…"
codesign --verify --strict --verbose=2 "$APP"
# Record the signed code hash so we can detect the bundle drifting out from
# under us before we staple (see the check after notarization).
SIGNED_CDHASH="$(codesign -dvvv "$APP" 2>&1 | awk -F= '/^CDHash=/ && !f {print $2; f=1}')"

echo "zipping for notarization…"
# ditto preserves the bundle structure and extended attributes notarytool needs.
ditto -c -k --keepParent "$APP" "$ZIP"

echo "submitting to Apple for notarization (this can take a few minutes)…"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

NOW_CDHASH="$(codesign -dvvv "$APP" 2>&1 | awk -F= '/^CDHash=/ && !f {print $2; f=1}')"
if [ "$NOW_CDHASH" != "$SIGNED_CDHASH" ]; then
    echo "error: the bundle changed after it was submitted (cdhash $SIGNED_CDHASH" >&2
    echo "       → $NOW_CDHASH). Something rebuilt '$APP' during notarization, so" >&2
    echo "       the notary ticket won't match. Re-run this script without any" >&2
    echo "       concurrent build touching that path." >&2
    exit 1
fi

echo "stapling ticket…"
# Right after acceptance the ticket can lag behind in Apple's CDN, so stapling
# fails with "Record not found" for a few minutes. Retry until it propagates.
for attempt in $(seq 1 20); do
    if xcrun stapler staple "$APP"; then
        break
    fi
    if [ "$attempt" -eq 20 ]; then
        echo "error: stapling still failing after 20 attempts — the notary" >&2
        echo "       ticket hasn't propagated. Notarization itself succeeded;" >&2
        echo "       re-run 'xcrun stapler staple \"$APP\"' shortly." >&2
        exit 1
    fi
    echo "  ticket not ready (attempt $attempt); retrying in 60s…"
    sleep 60
done
xcrun stapler validate "$APP"

echo "re-zipping stapled app for distribution…"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo
echo "built + notarized: $APP"
echo "distributable:     $ZIP  (attach this to a GitHub Release)"
echo "arch: $(lipo -archs "$APP/Contents/MacOS/VoiceOperator")"
