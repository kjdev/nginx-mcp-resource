#!/bin/sh
# Validate required environment variables; fail fast on missing values.
#
# nginx:alpine's docker-entrypoint.sh runs /docker-entrypoint.d/*.sh in order.
# Exit 1 here to keep nginx itself from starting on failure.

set -eu

die() {
    echo "[mcp-entrypoint] ERROR: $*" >&2
    exit 1
}

require() {
    name=$1
    eval "val=\${$name-}"
    [ -n "$val" ] || die "$name is required but not set"
}

require_file() {
    name=$1
    eval "val=\${$name-}"
    [ -n "$val" ] || die "$name is required but not set"
    [ -r "$val" ] || die "$name=$val is not readable"
}

# === Auth mode ============================================================
case "${MCP_AUTH_MODE-}" in
    jwt|introspect) ;;
    "")
        die "MCP_AUTH_MODE is required (jwt|introspect)"
        ;;
    *)
        die "MCP_AUTH_MODE must be 'jwt' or 'introspect' (got: $MCP_AUTH_MODE)"
        ;;
esac

# === Common required vars ================================================
require MCP_SERVER_NAME
require MCP_CANONICAL_URI
require MCP_METADATA_URI
require MCP_AUTHORIZATION_SERVER
require MCP_REQUIRED_SCOPE
require MCP_SCOPES_SUPPORTED
require MCP_BACKEND

# === TLS =================================================================
case "${MCP_TLS:-off}" in
    on)
        require_file MCP_SSL_CERT_FILE
        require_file MCP_SSL_CERT_KEY_FILE
        ;;
    off) ;;
    *)
        die "MCP_TLS must be 'on' or 'off' (got: $MCP_TLS)"
        ;;
esac

# === Mode-specific =======================================================
case "$MCP_AUTH_MODE" in
    jwt)
        require_file MCP_JWT_KEY_FILE
        ;;
    introspect)
        require MCP_INTROSPECT_ENDPOINT
        require MCP_CLIENT_ID
        require_file MCP_CLIENT_SECRET_FILE
        ;;
esac

echo "[mcp-entrypoint] env validation OK (mode=$MCP_AUTH_MODE, tls=${MCP_TLS:-off})"
