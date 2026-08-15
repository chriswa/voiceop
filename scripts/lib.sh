#!/usr/bin/env bash
# Shared helpers for the bundle-building scripts. Source from the repo root.

# Stamp the source commit into the *bundle's* copy of Info.plist — never the
# checked-in file, which stays exactly as committed. The running app logs this at
# launch (see BuildInfo.swift), so "which build is live?" has an answer.
stamp_source_commit() {
    local app="$1" commit
    commit="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
    if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
        commit="$commit+dirty"
    fi
    /usr/libexec/PlistBuddy -c "Add :VOSourceCommit string $commit" \
        "$app/Contents/Info.plist" >/dev/null
}

# Restart the instance running out of this bundle, if there is one.
#
# The bundle has just been deleted and rewritten, but a *running* Voice Operator
# goes on executing the old binary — the process holds the deleted inode open, so
# it survives every rebuild, indefinitely, with nothing to say it is stale.
# Restarting here is what makes "built" mean "live". Set VO_NO_RESTART=1 to skip
# (and get a warning instead).
restart_running_app() {
    local app="$1" exe pids
    exe="$PWD/$app/Contents/MacOS/VoiceOperator"
    pids="$(pgrep -f "$exe" || true)"

    if [ -z "$pids" ]; then
        echo "not currently running — start it with: open \"$app\""
        return
    fi
    if [ -n "${VO_NO_RESTART:-}" ]; then
        echo "WARNING: pid(s) $pids are still running the PREVIOUS binary."
        echo "         VO_NO_RESTART is set, so this build is not live yet."
        return
    fi

    echo "restarting the running instance (pid $pids)…"
    # shellcheck disable=SC2086  # deliberate word splitting: there may be several
    kill $pids 2>/dev/null || true
    for _ in $(seq 1 50); do
        pgrep -f "$exe" >/dev/null || break
        sleep 0.1
    done
    open "$app"
    echo "restarted — confirm with: grep launching ~/Library/Logs/VoiceOperator.log | tail -1"
}
