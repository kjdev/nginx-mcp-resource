#!/bin/sh
# Smoke test for Introspection mode.
#
# The introspect request to the AS stays pointed at a dummy (unreachable)
# endpoint. With no Authorization header, 401 is returned before introspection
# runs, so the no-token 401 / metadata / healthz assertions still hold.

set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib.sh"

prepare_fixtures

# --- HTTP (TLS off) -------------------------------------------------------
echo "[introspect/http] starting container..."
cid=$(docker run -d --rm -p "$HOST_PORT:80" \
    -e MCP_AUTH_MODE=introspect \
    -e MCP_TLS=off \
    -e MCP_SERVER_NAME=mcp.smoke.local \
    -e MCP_CANONICAL_URI=http://mcp.smoke.local/mcp \
    -e MCP_METADATA_URI=http://mcp.smoke.local/.well-known/oauth-protected-resource \
    -e MCP_AUTHORIZATION_SERVER=https://auth.smoke.local \
    -e MCP_REQUIRED_SCOPE=mcp:read \
    -e MCP_SCOPES_SUPPORTED=mcp:read,mcp:write \
    -e MCP_BACKEND=127.0.0.1:18080 \
    -e MCP_INTROSPECT_ENDPOINT=http://127.0.0.1:65532/introspect \
    -e MCP_CLIENT_ID=mcp-smoke \
    -e MCP_CLIENT_SECRET_FILE=/run/secrets/rs.secret \
    -v "$FIXTURES/secrets/rs.secret:/run/secrets/rs.secret:ro" \
    "$IMAGE")
trap 'cleanup_container "$cid"' INT TERM EXIT
wait_for_ready "$cid" http "$HOST_PORT"
run_common_assertions http "$HOST_PORT" \
    "http://mcp.smoke.local/.well-known/oauth-protected-resource" \
    "mcp:read"
cleanup_container "$cid"
trap - INT TERM EXIT

# --- HTTPS (TLS on) -------------------------------------------------------
HTTPS_PORT=$((HOST_PORT + 1))
echo "[introspect/https] starting container..."
cid=$(docker run -d --rm -p "$HTTPS_PORT:443" \
    -e MCP_AUTH_MODE=introspect \
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
    -e MCP_INTROSPECT_ENDPOINT=http://127.0.0.1:65532/introspect \
    -e MCP_CLIENT_ID=mcp-smoke \
    -e MCP_CLIENT_SECRET_FILE=/run/secrets/rs.secret \
    -v "$FIXTURES/certs:/etc/nginx/certs:ro" \
    -v "$FIXTURES/secrets/rs.secret:/run/secrets/rs.secret:ro" \
    "$IMAGE")
trap 'cleanup_container "$cid"' INT TERM EXIT
wait_for_ready "$cid" https "$HTTPS_PORT"
run_common_assertions https "$HTTPS_PORT" \
    "https://mcp.smoke.local/.well-known/oauth-protected-resource" \
    "mcp:read"
cleanup_container "$cid"
trap - INT TERM EXIT

print_summary
