# Shared by the plugin's hook and its `voice-mode` command: finding Voice
# Operator, and reading its answers without jq.

VO_SUPPORT="$HOME/Library/Application Support/VoiceOperator"
# Voice Operator's API generation that added /v1/voice-mode (speech-service.json `version`).
VO_API_REQUIRED=18

# http://127.0.0.1:<port>, from Voice Operator's discovery file; fails when it is not running.
vo_url() {
    local port
    port=$(plutil -extract port raw -o - "$VO_SUPPORT/speech-service.json" 2>/dev/null) || return 1
    [ -n "$port" ] || return 1
    echo "http://127.0.0.1:$port"
}

vo_api_version() {
    plutil -extract version raw -o - "$VO_SUPPORT/speech-service.json" 2>/dev/null || echo 0
}

# POST form fields (curl arguments) to /v1/voice-mode<path>; prints the body,
# fails on an HTTP error.
vo_post() {
    local path="$1"; shift
    local url
    url=$(vo_url) || return 1
    local response code
    response=$(curl -sS --max-time 10 -w '\n%{http_code}' "$@" "$url/v1/voice-mode$path") || return 1
    code=${response##*$'\n'}
    printf '%s' "${response%$'\n'*}"
    [ "${code:0:1}" = 2 ]
}

# A top-level string, number or boolean field of a flat JSON object.
json_field() {
    printf '%s' "$1" | plutil -extract "$2" raw -o - - 2>/dev/null
}

# The pid of the `claude` process this runs under: voice mode lets go when it
# is gone. 0 when it cannot be found.
claude_pid() {
    local pid=$$ name
    while [ -n "$pid" ] && [ "$pid" -gt 1 ]; do
        name=$(ps -o comm= -p "$pid" 2>/dev/null)
        case "${name##*/}" in
        claude) echo "$pid"; return ;;
        node|bun) ps -o command= -p "$pid" 2>/dev/null | grep -q 'claude' && { echo "$pid"; return; } ;;
        esac
        pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    done
    echo 0
}
