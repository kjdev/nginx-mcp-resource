#!/bin/sh
# Docker HEALTHCHECK script.
#
# port / proto are read from /run/mcp.port and /run/mcp.proto, which the
# entrypoint (10-mcp-derive-vars.envsh) writes out. HEALTHCHECK cannot read
# the PID-1 environment directly, so values are passed through files.

set -eu

port=$(cat /run/mcp.port 2>/dev/null || echo 80)
proto=$(cat /run/mcp.proto 2>/dev/null || echo http)

wget --quiet --tries=1 --no-check-certificate \
    --output-document=- \
    "$proto://127.0.0.1:$port/healthz" >/dev/null
