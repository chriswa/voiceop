#!/usr/bin/env bash
# Allocate the next version and record it in the committed Resources/Info.plist —
# step 1 of cutting a release (docs/RELEASING.md).
#
# Versions are MAJOR.MINOR.PATCH. PATCH comes from the build counter that local
# builds also draw from (see `allocate_version` in scripts/lib.sh), so no two
# builds — local or released — ever share a number, and numbers only go up.
#
#   ./scripts/bump-version.sh          # next patch on the current release line
#   ./scripts/bump-version.sh 0.2      # open the 0.2 line, then next patch
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
source scripts/lib.sh

if [ "$#" -gt 0 ]; then
    LINE="$1"
    [[ "$LINE" =~ ^[0-9]+\.[0-9]+$ ]] || { echo "error: release line must be MAJOR.MINOR, got '$LINE'" >&2; exit 1; }
    # allocate_version reads the line from the plist, so move it there first. The
    # patch it writes alongside is replaced a line later.
    _set_plist_string Resources/Info.plist CFBundleShortVersionString "$LINE.0"
fi

read -r VERSION BUILD_NUMBER <<<"$(allocate_version)"
record_released_version "$VERSION" "$BUILD_NUMBER"

echo "Resources/Info.plist now records v$VERSION (build $BUILD_NUMBER)."
echo "Commit it, then run ./scripts/make-release.sh:"
echo "    git add Resources/Info.plist claude-plugin/handsfree/.claude-plugin/plugin.json && git commit -m \"Bump version to $VERSION\" && git push origin main"
