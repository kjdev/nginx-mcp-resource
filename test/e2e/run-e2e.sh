#!/bin/sh
# E2E runner for the nginx-mcp-resource container image.
#
# usage:
#   ./run-e2e.sh             # JWT + Introspection in order
#   ./run-e2e.sh jwt         # JWT mode only
#   ./run-e2e.sh introspect  # Introspection mode only

set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
mode=${1:-all}

case "$mode" in
    jwt)        "$HERE/jwt.sh" ;;
    introspect) "$HERE/introspect.sh" ;;
    all)
        "$HERE/jwt.sh"
        "$HERE/introspect.sh"
        ;;
    *)
        echo "unknown mode: $mode (expected jwt|introspect|all)" >&2
        exit 2
        ;;
esac
