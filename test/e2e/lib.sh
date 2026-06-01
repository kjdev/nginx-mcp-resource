#!/bin/sh
# Shared library for the nginx-mcp-resource E2E suite.
#
# Each *.sh driver spins up host-side Python servers (backend, optionally
# as-mock) plus the nginx-mcp-resource container, runs assertions with curl,
# then tears everything down. Logs land in $E2E_LOG_DIR (default: /tmp).

set -eu

# -------- knobs ----------------------------------------------------------
: "${IMAGE:=nginx-mcp-resource:dev}"
: "${E2E_LOG_DIR:=/tmp}"
: "${BACKEND_PORT:=18280}"
: "${AS_PORT:=18281}"
: "${RS_PORT:=18180}"
: "${MCP_CANONICAL_URI:=http://mcp.e2e.local/mcp}"
: "${MCP_METADATA_URI:=http://mcp.e2e.local/.well-known/oauth-protected-resource}"
: "${MCP_AUTHORIZATION_SERVER:=http://127.0.0.1:${AS_PORT}}"
: "${MCP_REQUIRED_SCOPE:=mcp:read}"

HERE=$(cd "$(dirname "$0")" && pwd)
FIXTURES="$HERE/fixtures"
SERVERS="$HERE/servers"

PASS_COUNT=0
FAIL_COUNT=0

# -------- assertion helpers ---------------------------------------------
pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    printf '  ok - %s\n' "$*"
}

fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf '  NG - %s\n' "$*" >&2
}

assert_status() {
    label=$1; expected=$2; got=$3
    if [ "$got" = "$expected" ]; then
        pass "$label (status=$got)"
    else
        fail "$label (expected=$expected got=$got)"
    fi
}

assert_contains() {
    label=$1; needle=$2; haystack=$3
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        pass "$label"
    else
        fail "$label (expected to contain: $needle)"
        printf '    haystack: %s\n' "$(printf '%s' "$haystack" | head -c 400)" >&2
    fi
}

assert_not_contains() {
    label=$1; needle=$2; haystack=$3
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        fail "$label (should NOT contain: $needle)"
        printf '    haystack: %s\n' "$(printf '%s' "$haystack" | head -c 400)" >&2
    else
        pass "$label"
    fi
}

# Count physical header lines (i.e. occurrences before the body). The MCP
# requirement is that 401/403 responses emit exactly one WWW-Authenticate.
count_www_authenticate() {
    headers=$1
    printf '%s' "$headers" | awk 'BEGIN{IGNORECASE=1} /^WWW-Authenticate:/ {n++} END {print n+0}'
}

# -------- subprocess management -----------------------------------------
PIDS=""
CIDS=""

cleanup() {
    for p in $PIDS; do
        kill "$p" 2>/dev/null || true
    done
    for c in $CIDS; do
        docker rm -f "$c" >/dev/null 2>&1 || true
    done
    PIDS=""
    CIDS=""
}

trap cleanup INT TERM EXIT

# -------- server starters ------------------------------------------------
start_backend() {
    port=$1; log=$2
    python3 "$SERVERS/backend.py" --port "$port" > "$log" 2>&1 &
    PIDS="$PIDS $!"
}

start_as_mock() {
    port=$1; canonical=$2; public_base=$3; log=$4
    python3 "$SERVERS/as_mock.py" --port "$port" \
        --canonical-uri "$canonical" \
        --public-as-base "$public_base" \
        > "$log" 2>&1 &
    PIDS="$PIDS $!"
}

wait_for_http() {
    label=$1; url=$2
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        # Silence transient connection errors during the ready loop; the
        # "did not become ready" message below covers the genuine failure.
        if curl -fsS --max-time 1 -o /dev/null "$url" 2>/dev/null; then
            return 0
        fi
        sleep 0.3
    done
    echo "[e2e] $label did not become ready: $url" >&2
    return 1
}

# Wait for the nginx-mcp-resource container's healthz endpoint, since it
# never serves at /. Falls back to verifying the metadata endpoint when
# healthz is not available.
wait_for_rs() {
    base=$1
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if curl -fsS --max-time 1 -o /dev/null "$base/healthz" 2>/dev/null; then
            return 0
        fi
        sleep 0.3
    done
    echo "[e2e] RS did not become ready: $base" >&2
    return 1
}

# -------- summary --------------------------------------------------------
print_summary() {
    echo
    echo "==== e2e summary: ${PASS_COUNT} passed, ${FAIL_COUNT} failed ===="
    if [ "$FAIL_COUNT" -gt 0 ]; then
        return 1
    fi
}
