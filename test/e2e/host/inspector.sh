#!/bin/sh
# Inspector E2E driver.
#
# Spins up the same RS / backend / mock-AS stack as host/jwt.sh and
# host/introspect.sh, then runs the official MCP Inspector in `--cli`
# (headless) mode against /mcp. The point is to confirm that the Inspector's
# OAuth handshake actually walks through 401 -> WWW-Authenticate -> PRM
# discovery against our RS, not just that the headers look right under curl.
#
# Usage:
#   ./inspector.sh jwt          # JWT mode only
#   ./inspector.sh introspect   # Introspection mode only
#   ./inspector.sh all          # both, sequentially (default)
#
# Requirements:
#   - host nginx (with .so paths probed by lib.sh)
#   - npx + writable npm cache (defaults to $TMPDIR/.npm-cache when unset)
#   - network access to registry.npmjs.org for the first run

set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib.sh"

mode=${1:-all}

: "${NPM_CACHE:=${TMPDIR:-/tmp}/claude-npm-cache}"
mkdir -p "$NPM_CACHE"

# === Mint a valid JWT once so the post-auth probe can hit upstream. =====
VALID_JWT=$(python3 "$SERVERS/gen_jwt.py" \
    --aud "$MCP_CANONICAL_URI" --scope "mcp:read")

run_inspector() {
    label=$1; auth_header=$2; out=$3
    echo "[inspector] === $label ==="
    # @modelcontextprotocol/inspector --cli expects the MCP server URL as the
    # positional `target` (despite the --help blurb advertising --server-url).
    target="http://127.0.0.1:$RS_PORT/mcp"
    if [ -n "$auth_header" ]; then
        npm_config_cache="$NPM_CACHE" \
            npx -y @modelcontextprotocol/inspector \
                --cli "$target" \
                --transport http \
                --header "$auth_header" \
                --method tools/list \
                > "$out" 2>&1 \
            || true
    else
        npm_config_cache="$NPM_CACHE" \
            npx -y @modelcontextprotocol/inspector \
                --cli "$target" \
                --transport http \
                --method tools/list \
                > "$out" 2>&1 \
            || true
    fi
    echo "  inspector output -> $out"
    head -40 "$out" | sed 's|^|    |'
}

run_jwt() {
    e2e_dir="$E2E_LOG_DIR/e2e-inspector-jwt"
    mkdir -p "$e2e_dir"

    echo "[inspector/jwt] starting backend..."
    start_backend "$e2e_dir/backend.log"
    wait_for_http "backend" "http://127.0.0.1:$BACKEND_PORT/"

    echo "[inspector/jwt] starting nginx (JWT mode)..."
    start_nginx "$HERE/nginx-jwt.conf.template" "$e2e_dir"
    wait_for_rs "http://127.0.0.1:$RS_PORT"

    run_inspector "no-token (expect 401 + PRM discovery)" "" \
        "$e2e_dir/inspector-no-token.out"
    run_inspector "valid JWT (expect tools/list response from echo backend)" \
        "Authorization: Bearer $VALID_JWT" \
        "$e2e_dir/inspector-valid.out"

    cleanup
}

run_introspect() {
    e2e_dir="$E2E_LOG_DIR/e2e-inspector-introspect"
    mkdir -p "$e2e_dir"

    echo "[inspector/introspect] starting backend..."
    start_backend "$e2e_dir/backend.log"
    wait_for_http "backend" "http://127.0.0.1:$BACKEND_PORT/"

    echo "[inspector/introspect] starting mock AS..."
    start_as_mock "$e2e_dir/as.log"
    wait_for_http "as-mock" \
        "http://127.0.0.1:$AS_PORT/.well-known/oauth-authorization-server"

    echo "[inspector/introspect] starting nginx (introspect mode)..."
    start_nginx "$HERE/nginx-introspect.conf.template" "$e2e_dir" \
        "http://127.0.0.1:$AS_PORT/introspect"
    wait_for_rs "http://127.0.0.1:$RS_PORT"

    run_inspector "no-token (expect 401 + PRM discovery)" "" \
        "$e2e_dir/inspector-no-token.out"
    run_inspector "valid opaque token (expect tools/list response)" \
        "Authorization: Bearer e2e-valid" \
        "$e2e_dir/inspector-valid.out"

    cleanup
}

case "$mode" in
    jwt)        run_jwt ;;
    introspect) run_introspect ;;
    all)
        run_jwt
        run_introspect
        ;;
    *)
        echo "unknown mode: $mode" >&2
        exit 2
        ;;
esac
