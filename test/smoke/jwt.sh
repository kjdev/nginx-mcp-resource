#!/bin/sh
# Smoke test for JWT mode.
#
# scenario:
#   - Start over HTTP (MCP_TLS=off) and verify healthz / metadata / no-token 401
#     / bogus-token 401.
#   - Start over HTTPS (MCP_TLS=on) and re-run the same checks.

set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib.sh"

prepare_fixtures

# --- HTTP (TLS off) -------------------------------------------------------
echo "[jwt/http] starting container..."
cid=$(docker run -d --rm -p "$HOST_PORT:80" \
    -e MCP_AUTH_MODE=jwt \
    -e MCP_TLS=off \
    -e MCP_SERVER_NAME=mcp.smoke.local \
    -e MCP_CANONICAL_URI=http://mcp.smoke.local/mcp \
    -e MCP_METADATA_URI=http://mcp.smoke.local/.well-known/oauth-protected-resource \
    -e MCP_AUTHORIZATION_SERVER=https://auth.smoke.local \
    -e MCP_REQUIRED_SCOPE=mcp:read \
    -e MCP_SCOPES_SUPPORTED=mcp:read,mcp:write \
    -e MCP_BACKEND=127.0.0.1:18080 \
    -e MCP_JWT_KEY_FILE=/etc/nginx/keys/jwks.json \
    -v "$FIXTURES/keys:/etc/nginx/keys:ro" \
    "$IMAGE")
trap 'cleanup_container "$cid"' INT TERM EXIT
wait_for_ready "$cid" http "$HOST_PORT"
run_common_assertions http "$HOST_PORT" \
    "http://mcp.smoke.local/.well-known/oauth-protected-resource" \
    "mcp:read"
assert_bogus_token_rejected http "$HOST_PORT"
cleanup_container "$cid"
trap - INT TERM EXIT

# --- HTTPS (TLS on) -------------------------------------------------------
HTTPS_PORT=$((HOST_PORT + 1))
echo "[jwt/https] starting container..."
cid=$(docker run -d --rm -p "$HTTPS_PORT:443" \
    -e MCP_AUTH_MODE=jwt \
    -e MCP_TLS=on \
    -e MCP_SSL_CERT_FILE=/etc/nginx/certs/server.crt \
    -e MCP_SSL_CERT_KEY_FILE=/etc/nginx/certs/server.key \
    -e MCP_SERVER_NAME=mcp.smoke.local \
    -e MCP_CANONICAL_URI=https://mcp.smoke.local/mcp \
    -e MCP_METADATA_URI=https://mcp.smoke.local/.well-known/oauth-protected-resource \
    -e MCP_AUTHORIZATION_SERVER=https://auth.smoke.local \
    -e MCP_REQUIRED_SCOPE=mcp:read \
    -e MCP_SCOPES_SUPPORTED=mcp:read,mcp:write \
    -e MCP_BACKEND=127.0.0.1:18080 \
    -e MCP_JWT_KEY_FILE=/etc/nginx/keys/jwks.json \
    -v "$FIXTURES/keys:/etc/nginx/keys:ro" \
    -v "$FIXTURES/certs:/etc/nginx/certs:ro" \
    "$IMAGE")
trap 'cleanup_container "$cid"' INT TERM EXIT
wait_for_ready "$cid" https "$HTTPS_PORT"
run_common_assertions https "$HTTPS_PORT" \
    "https://mcp.smoke.local/.well-known/oauth-protected-resource" \
    "mcp:read"
assert_bogus_token_rejected https "$HTTPS_PORT"
cleanup_container "$cid"
trap - INT TERM EXIT

print_summary
