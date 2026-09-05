#!/usr/bin/env bash
# Restart the running Voice Operator without cutting off a dictation.
#
#   scripts/restart-app.sh <app-bundle> [expected-version] [--force] [--timeout SECONDS]
#
# The running app is *asked* to restart over its loopback API (POST /v1/restart).
# The app finishes any dictation in flight — through paste — before it plays its
# restart cue and relaunches. This script waits with it, then confirms the new
# instance is up and, when an expected version is given, that it is the version
# just built. That last check is the whole point of the per-build version number:
# a process keeps executing a binary that was deleted out from under it, so "the
# pid changed" alone does not prove the new build is what is running.
#
# Exit status: 0 restarted (or nothing was running and it was started); 1 the
# app did not come back, or came back as the wrong version; 2 the running app
# would not take the request (unresponsive, or too old to have the endpoint) and
# --force was not given; 3 timed out waiting for the app to become idle.
#
# --force falls back to SIGTERM when the request cannot be delivered. The app
# treats SIGTERM as an ordinary quit (system audio restored, discovery file
# removed) but does NOT wait for a dictation: a force restart mid-dictation loses
# it. Never use --force just because the wait is inconvenient.
#
# VO_NO_RESTART=1 skips the restart entirely (with a warning), for builds you do
# not want to go live yet.
set -euo pipefail

DISCOVERY="$HOME/Library/Application Support/VoiceOperator/speech-service.json"
TIMEOUT=600          # how long a dictation or a read-aloud may keep us waiting
RELAUNCH_WAIT=30     # how long the new instance gets to come up
FORCE=

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

APP=
EXPECTED=
while [ $# -gt 0 ]; do
    case "$1" in
        --force) FORCE=1 ;;
        --timeout) TIMEOUT="$2"; shift ;;
        -h|--help) usage ;;
        -*) echo "unknown option: $1" >&2; usage 2 ;;
        *) if [ -z "$APP" ]; then APP="$1"; elif [ -z "$EXPECTED" ]; then EXPECTED="$1"; else usage 2; fi ;;
    esac
    shift
done
[ -n "$APP" ] || usage 2
[ -d "$APP" ] || { echo "no such bundle: $APP" >&2; exit 2; }
EXE="$(cd "$APP" && pwd)/Contents/MacOS/VoiceOperator"

# --- helpers ---------------------------------------------------------------

# Read one top-level key out of a JSON file (or stdin with "-").
json_field() { plutil -extract "$1" raw -o - "$2" 2>/dev/null; }

# The pid and port the live instance advertises, or nothing if there is no
# discovery file or its pid is dead.
discover() {
    [ -f "$DISCOVERY" ] || return 1
    local pid port
    pid="$(json_field pid "$DISCOVERY")" || return 1
    port="$(json_field port "$DISCOVERY")" || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    echo "$pid $port"
}

# GET/POST against the live instance. Leaves the body in HTTP_BODY and the
# status in HTTP_CODE (globals, so callers must not wrap this in `$(...)`).
# Returns non-zero only when the connection itself fails.
HTTP_CODE=
HTTP_BODY=
http() {
    local method="$1" port="$2" path="$3" out
    out="$(curl -s -m 5 -X "$method" -w $'\n%{http_code}' "http://127.0.0.1:$port$path")" || return 1
    HTTP_CODE="${out##*$'\n'}"
    HTTP_BODY="${out%$'\n'*}"
}

wait_for_exit() {   # $1 pid, $2 seconds
    local i
    for (( i = 0; i < $2 * 10; i++ )); do
        kill -0 "$1" 2>/dev/null || return 0
        sleep 0.1
    done
    return 1
}

# Wait for an instance other than $1 to publish itself; print "pid port".
wait_for_new_instance() {   # $1 old pid (may be empty), $2 seconds
    local i found
    for (( i = 0; i < $2 * 10; i++ )); do
        if found="$(discover)" && [ "${found%% *}" != "$1" ]; then echo "$found"; return 0; fi
        sleep 0.1
    done
    return 1
}

start_and_verify() {   # $1 old pid (may be empty)
    local new pid port version
    if ! new="$(wait_for_new_instance "$1" "$RELAUNCH_WAIT")"; then
        echo "ERROR: no new Voice Operator instance appeared within ${RELAUNCH_WAIT}s" >&2
        echo "       check: tail ~/Library/Logs/VoiceOperator.log" >&2
        return 1
    fi
    pid="${new%% *}"; port="${new##* }"
    # The listener publishes its port before the status closure is wired, in
    # rare orderings, so allow a beat for /v1/status to answer.
    local i
    for (( i = 0; i < 50; i++ )); do
        if http GET "$port" /v1/status && [ "$HTTP_CODE" = 200 ]; then break; fi
        sleep 0.1
    done
    version="$(printf '%s' "$HTTP_BODY" | json_field version -)" || version="unknown"
    if [ -n "$EXPECTED" ] && [ "$version" != "$EXPECTED" ]; then
        echo "ERROR: restarted, but the running version is v$version — expected v$EXPECTED" >&2
        echo "       (pid $pid, running from $(ps -o comm= -p "$pid" 2>/dev/null || echo '?'))" >&2
        return 1
    fi
    echo "restarted: v$version (pid $pid)"
    # The app checks for Wispr's Baseten key at launch and reports the path
    # dictation will take. Without the key every dictation uploads *after* key-up
    # to raw /llm/asr — 5–10 s and unformatted — and nothing else in the build
    # flow would say so (see StreamHealth.swift and CLAUDE.md).
    local stream reason
    stream="$(printf '%s' "$HTTP_BODY" | json_field stream -)" || stream=""
    if [ "$stream" = "degraded" ]; then
        reason="$(printf '%s' "$HTTP_BODY" | json_field stream_reason -)" || reason="unknown reason"
        echo "WARNING: dictation is on the SLOW path — live stream unavailable ($reason)" >&2
        echo "         see CLAUDE.md 'Dictation transcription paths' for the baseten-key file" >&2
    fi
}

force_restart() {   # $1 pids (space separated)
    echo "forcing: SIGTERM to pid(s) $1 — any dictation in flight is lost"
    # shellcheck disable=SC2086  # deliberate word splitting
    kill $1 2>/dev/null || true
    local p
    for p in $1; do wait_for_exit "$p" 10 || { echo "ERROR: pid $p did not exit" >&2; return 1; }; done
    open "$APP"
    start_and_verify "${1%% *}"
}

# --- main ------------------------------------------------------------------

if live="$(discover)"; then
    OLD_PID="${live%% *}"; PORT="${live##* }"
else
    OLD_PID=""; PORT=""
fi
# Processes running out of this bundle that the discovery file does not know
# about (a hung instance, or one older than the loopback service).
STRAY_PIDS="$(pgrep -f "$EXE" | grep -vx "${OLD_PID:-NONE}" || true)"

if [ -z "$OLD_PID" ] && [ -z "$STRAY_PIDS" ]; then
    echo "not currently running — starting it"
    open "$APP"
    start_and_verify ""
    exit
fi
if [ -n "${VO_NO_RESTART:-}" ]; then
    echo "WARNING: pid(s) ${OLD_PID:-} ${STRAY_PIDS} are still running the PREVIOUS binary."
    echo "         VO_NO_RESTART is set, so this build is not live yet."
    exit 0
fi

if [ -z "$OLD_PID" ]; then
    echo "Voice Operator is running (pid $STRAY_PIDS) but is not reachable over its loopback API."
    [ -n "$FORCE" ] || { echo "Re-run with --force to SIGTERM it (loses any dictation in flight)." >&2; exit 2; }
    force_restart "$STRAY_PIDS"
    exit
fi

if ! http POST "$PORT" /v1/restart; then
    echo "Voice Operator (pid $OLD_PID) did not answer on port $PORT."
    [ -n "$FORCE" ] || { echo "Re-run with --force to SIGTERM it (loses any dictation in flight)." >&2; exit 2; }
    force_restart "$OLD_PID ${STRAY_PIDS}"
    exit
fi
case "$HTTP_CODE" in
    200) echo "restarting pid $OLD_PID (idle)" ;;
    202)
        # The app says which of the two it is holding for; say the right one
        # rather than telling the user they are dictating when they are listening.
        case "$(printf '%s' "$HTTP_BODY" | json_field reason -)" in
            speaking) echo "waiting: the user is listening to speech — the restart will follow it (up to ${TIMEOUT}s)…" ;;
            *)        echo "waiting: the user is dictating — the restart will follow the paste (up to ${TIMEOUT}s)…" ;;
        esac
        start=$SECONDS
        while :; do
            sleep 1
            # Connection refused means the old process is on its way out: done waiting.
            http GET "$PORT" /v1/status || break
            [ "$(printf '%s' "$HTTP_BODY" | json_field restart -)" = "restarting" ] && break
            if (( SECONDS - start >= TIMEOUT )); then
                echo "ERROR: still busy after ${TIMEOUT}s; the restart request is left pending in the app." >&2
                echo "       It will restart itself when the dictation or speech ends. Do not kill it." >&2
                exit 3
            fi
            (( (SECONDS - start) % 15 == 0 )) && echo "  still waiting ($((SECONDS - start))s)…"
        done
        echo "app is idle — restarting pid $OLD_PID"
        ;;
    404)
        echo "Voice Operator (pid $OLD_PID) predates the /v1/restart endpoint."
        [ -n "$FORCE" ] || { echo "Re-run with --force to SIGTERM it (loses any dictation in flight)." >&2; exit 2; }
        force_restart "$OLD_PID ${STRAY_PIDS}"
        exit
        ;;
    *)  echo "ERROR: unexpected response to /v1/restart: HTTP $HTTP_CODE $HTTP_BODY" >&2; exit 1 ;;
esac

if [ -n "$STRAY_PIDS" ]; then
    echo "WARNING: also running from this bundle but not advertised: pid(s) $STRAY_PIDS (left alone; use --force to kill)"
fi
# The relaunch is the app's own doing (Relauncher); we only confirm it happened.
wait_for_exit "$OLD_PID" 20 || { echo "ERROR: pid $OLD_PID has not exited 20s after agreeing to restart" >&2; exit 1; }
start_and_verify "$OLD_PID"
