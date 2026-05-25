#!/bin/sh
# Smoke test runner for the Docker image.
#
# usage:
#   ./run-smoke.sh             # run JWT + Introspection in order
#   ./run-smoke.sh jwt         # JWT mode only
#   ./run-smoke.sh introspect  # Introspection mode only
#
# Prerequisites: access to the Docker daemon and the `nginx-mcp-resource:dev`
# image (built via `task docker:build` or `docker build -t nginx-mcp-resource:dev .`).
# Override the tag with the IMAGE environment variable.

set -eu

HERE=$(cd "$(dirname "$0")" && pwd)

mode=${1:-all}

case "$mode" in
    jwt)
        "$HERE/jwt.sh"
        ;;
    introspect)
        "$HERE/introspect.sh"
        ;;
    all)
        "$HERE/jwt.sh"
        "$HERE/introspect.sh"
        ;;
    *)
        echo "unknown mode: $mode (expected jwt|introspect|all)" >&2
        exit 2
        ;;
esac
