#!/usr/bin/env bash
# Shared helpers for the bundle-building scripts. Source from the repo root.

# Where the local build counter lives. Untracked (see .gitignore): a counter in
# the repo would make every single build dirty the working tree, and the number
# it holds is a property of this machine, not of the source.
BUILD_NUMBER_FILE=".build-number"

# Allocate the version for the build about to be made, as "<version> <build>".
#
# Every build — local or release — gets its own number, so "did my rebuild
# actually take?" is answerable by reading the version in the menu (that is the
# whole point: a running instance keeps executing the binary that was deleted out
# from under it, so identical version numbers across a restart mean nothing was
# picked up). Two builds of the *same* source therefore still differ.
#
#   MAJOR.MINOR  the release line, from the committed Info.plist. Only a human
#                changes this, when starting a new line.
#   PATCH        this counter. Releases and local builds draw from the same one,
#                so a version number is unique across both and never goes
#                backwards.
#
# The committed Info.plist's patch component doubles as the counter's floor, so a
# fresh clone (no counter file) resumes above the last released version rather
# than re-issuing numbers that are already out in the world. `record_released_version`
# is what advances that floor.
allocate_version() {
    local released base floor bundle counter next
    released="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
    base="${released%.*}"        # 0.1.12 -> 0.1
    floor="${released##*.}"      # 0.1.12 -> 12
    # CFBundleVersion counts as a floor too: it is the same counter, and past
    # releases set it, so honouring both keeps a build number from being reused
    # even if the two ever drift apart.
    bundle="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' Resources/Info.plist)"
    [ "$bundle" -gt "$floor" ] 2>/dev/null && floor="$bundle"
    counter=0
    if [ -f "$BUILD_NUMBER_FILE" ]; then
        counter="$(tr -dc '0-9' < "$BUILD_NUMBER_FILE")"
        counter="${counter:-0}"
    fi
    next=$(( (counter > floor ? counter : floor) + 1 ))
    echo "$next" > "$BUILD_NUMBER_FILE"
    echo "$base.$next $next"
}

# Stamp this build's identity into the *bundle's* copy of Info.plist — never the
# checked-in file, which stays exactly as committed. The running app logs it at
# launch and shows it in the menu (see BuildInfo.swift), so "which build is live?"
# has an answer.
stamp_build_identity() {
    local app="$1" version="$2" build="$3" plist commit
    plist="$app/Contents/Info.plist"
    commit="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
    if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
        commit="$commit+dirty"
    fi
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$plist" >/dev/null
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build" "$plist" >/dev/null
    /usr/libexec/PlistBuddy -c "Add :VOSourceCommit string $commit" "$plist" >/dev/null
}

# The version recorded in the *committed* Info.plist, as "<version> <build>".
# This is the release version: `scripts/bump-version.sh` allocates it and commits
# it, and `make-release.sh` builds exactly it, so the git tag, the committed
# plist, and the notarized bundle all agree.
committed_version() {
    echo "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)" \
         "$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' Resources/Info.plist)"
}

# Write a version into the *committed* Resources/Info.plist. That version is both
# what the next release builds and the floor every later build counts up from, so
# this is what stops a fresh clone from re-issuing a number already published.
#
# Edited as text, one line at a time. `PlistBuddy -c Set` on this file rewrites
# the whole thing: it alphabetizes the keys, converts the indentation to tabs, and
# silently deletes the XML comments.
record_released_version() {
    local version="$1" build="$2"
    _set_plist_string Resources/Info.plist CFBundleShortVersionString "$version"
    _set_plist_string Resources/Info.plist CFBundleVersion "$build"
    # The Claude Code plugin is released with the app, at the same version: a
    # changed version is what tells installed copies there is an update.
    local plugin=claude-plugin/handsfree/.claude-plugin/plugin.json
    sed -E "s/(\"version\": *\")[^\"]*\"/\\1$version\"/" "$plugin" > "$plugin.tmp" && mv "$plugin.tmp" "$plugin"
}

# Replace the <string> immediately following <key>$2</key> in the plist at $1.
_set_plist_string() {
    local file="$1" key="$2" value="$3"
    awk -v key="<key>$key</key>" -v value="$value" '
        found && /<string>.*<\/string>/ {
            sub(/<string>.*<\/string>/, "<string>" value "</string>"); found = 0
        }
        index($0, key) { found = 1 }
        { print }
    ' "$file" > "$file.tmp"
    mv "$file.tmp" "$file"
}

# Ship the local Kokoro server inside the bundle. The Text to Speech menu's
# Install/Update copies these out to Application Support (see KokoroService), so
# a release and a dev build install exactly what was built. Plain text files
# only — the venv is built on the user's Mac, never shipped.
copy_kokoro_resources() {
    local app="$1" file
    mkdir -p "$app/Contents/Resources/kokoro"
    for file in kokoro_server.py requirements.txt blocked_voices.json; do
        cp "kokoro/$file" "$app/Contents/Resources/kokoro/$file"
    done
}

# Restart the running instance so the build that was just made goes live, and
# confirm the new instance reports that build's version.
#
# The bundle has just been deleted and rewritten, but a *running* Voice Operator
# goes on executing the old binary — the process holds the deleted inode open, so
# it survives every rebuild, indefinitely, with nothing to say it is stale.
# Restarting here is what makes "built" mean "live".
#
# The restart is cooperative: the app is asked over its loopback API and finishes
# any dictation in flight first (see scripts/restart-app.sh, which this wraps).
# Set VO_NO_RESTART=1 to skip (and get a warning instead).
restart_running_app() {
    local app="$1" version="$2"
    scripts/restart-app.sh "$app" "$version"
}
