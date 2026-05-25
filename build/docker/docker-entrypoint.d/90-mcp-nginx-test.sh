#!/bin/sh
# Pre-flight `nginx -t` check against the envsubst-expanded nginx.conf.
# Exit before nginx itself starts so failures surface with a clear cause.

set -eu

echo "[mcp-entrypoint] running 'nginx -t' pre-flight check"
if ! nginx -t; then
    echo "[mcp-entrypoint] ERROR: nginx -t failed" >&2
    exit 1
fi
