#!/bin/sh
# Shared library for the host-direct E2E suite (no Docker required).
#
# Launches nginx from the host using the pre-built nginx-auth-jwt and
# nginx-auth-oauth2-token .so modules, plus host-side Python servers.

set -eu

: "${E2E_LOG_DIR:=/tmp}"
: "${BACKEND_PORT:=18280}"
: "${AS_PORT:=18281}"
: "${RS_PORT:=18180}"
: "${MCP_CANONICAL_URI:=http://mcp.e2e.local/mcp}"
: "${MCP_METADATA_URI:=http://mcp.e2e.local/.well-known/oauth-protected-resource}"
: "${MCP_AUTHORIZATION_SERVER:=http://127.0.0.1:${AS_PORT}}"
: "${MCP_REQUIRED_SCOPE:=mcp:read}"

HOST_HERE=$(cd "$(dirname "$0")" && pwd)
E2E_HERE=$(cd "$HOST_HERE/.." && pwd)
PROJECT_DIR=$(cd "$E2E_HERE/../.." && pwd)
FIXTURES="$E2E_HERE/fixtures"
SERVERS="$E2E_HERE/servers"

: "${NGINX_BIN:=/usr/bin/nginx}"
: "${JWT_MODULE:=$PROJECT_DIR/../nginx-auth-jwt/build/fedora/ngx_http_auth_jwt_module.so}"
: "${OAUTH2_MODULE:=$PROJECT_DIR/../nginx-auth-oauth2-token/build/fedora/ngx_http_auth_oauth2_token_module.so}"

PASS_COUNT=0
FAIL_COUNT=0

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

count_www_authenticate() {
    printf '%s' "$1" | awk 'BEGIN{IGNORECASE=1} /^WWW-Authenticate:/ {n++} END {print n+0}'
}

# -------- subprocess management -----------------------------------------
PIDS=""
NGINX_PID=""
NGINX_PREFIX=""

cleanup() {
    if [ -n "$NGINX_PID" ] && kill -0 "$NGINX_PID" 2>/dev/null; then
        kill "$NGINX_PID" 2>/dev/null || true
        wait "$NGINX_PID" 2>/dev/null || true
    fi
    for p in $PIDS; do
        kill "$p" 2>/dev/null || true
    done
    PIDS=""
    NGINX_PID=""
}

trap cleanup INT TERM EXIT

# -------- server starters ------------------------------------------------
start_backend() {
    log=$1
    python3 "$SERVERS/backend.py" --port "$BACKEND_PORT" > "$log" 2>&1 &
    PIDS="$PIDS $!"
}

start_as_mock() {
    log=$1
    python3 "$SERVERS/as_mock.py" \
        --port "$AS_PORT" \
        --canonical-uri "$MCP_CANONICAL_URI" \
        --public-as-base "$MCP_AUTHORIZATION_SERVER" \
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

start_nginx() {
    template=$1; e2e_dir=$2; introspect_endpoint=${3:-}

    NGINX_PREFIX="$e2e_dir"
    # Pre-create temp parents that the templates redirect *_temp_path to.
    # nginx's auto-mkdir is single-level, so the grandparent must exist.
    mkdir -p "$e2e_dir/logs" "$e2e_dir/tmp"
    export E2E_DIR="$e2e_dir" \
           PROJECT_DIR="$PROJECT_DIR" \
           JWT_MODULE="$JWT_MODULE" \
           OAUTH2_MODULE="$OAUTH2_MODULE" \
           JWKS_PATH="$FIXTURES/keys/jwks.json" \
           CLIENT_SECRET_FILE="$FIXTURES/secrets/rs.secret" \
           CLIENT_ID=mcp-e2e \
           BACKEND_PORT="$BACKEND_PORT" \
           RS_PORT="$RS_PORT" \
           CANONICAL_URI="$MCP_CANONICAL_URI" \
           METADATA_URI="$MCP_METADATA_URI" \
           AUTHORIZATION_SERVER="$MCP_AUTHORIZATION_SERVER" \
           REQUIRED_SCOPE="$MCP_REQUIRED_SCOPE" \
           INTROSPECT_ENDPOINT="$introspect_endpoint"
    # Restrict envsubst to the e2e-template variables so nginx variables
    # such as $mcp_canonical_uri / $jwt_scope are passed through verbatim.
    envsubst_vars='${JWT_MODULE} ${OAUTH2_MODULE} ${E2E_DIR} ${PROJECT_DIR}
        ${JWKS_PATH} ${CLIENT_SECRET_FILE} ${CLIENT_ID}
        ${BACKEND_PORT} ${RS_PORT}
        ${CANONICAL_URI} ${METADATA_URI} ${AUTHORIZATION_SERVER}
        ${REQUIRED_SCOPE} ${INTROSPECT_ENDPOINT}'
    envsubst "$envsubst_vars" < "$template" > "$e2e_dir/nginx.conf"

    # Test config first to surface errors clearly. -e overrides nginx's
    # compile-time error log path (typically /var/log/nginx/error.log, which
    # is read-only in some sandboxes) before the in-config error_log applies.
    "$NGINX_BIN" -t \
        -p "$e2e_dir" \
        -e "$e2e_dir/early-error.log" \
        -c "$e2e_dir/nginx.conf" 2>&1 \
        | tee "$e2e_dir/nginx-t.log" \
        | sed 's|^|  nginx -t: |' >&2

    "$NGINX_BIN" \
        -p "$e2e_dir" \
        -e "$e2e_dir/early-error.log" \
        -c "$e2e_dir/nginx.conf" &
    NGINX_PID=$!
}

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

print_summary() {
    echo
    echo "==== host e2e summary: ${PASS_COUNT} passed, ${FAIL_COUNT} failed ===="
    if [ "$FAIL_COUNT" -gt 0 ]; then
        return 1
    fi
}
