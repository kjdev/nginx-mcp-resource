#!/bin/sh
# Verification helper: fetch alice's access token from Keycloak and print it.
#
# Claude Code / Inspector obtain tokens via the interactive authorization-code
# flow (+PKCE); for CLI smoke checks this uses the Direct Access Grant
# (password grant) instead.
#
# Usage:
#   TOKEN=$(./get-token.sh)
#   TOKEN=$(./get-token.sh "mcp:read")     # narrow the granted scope (to test 403)

set -eu

KC="${KC:-http://localhost:18080}"
REALM="${REALM:-mcp}"
CLIENT="${CLIENT:-mcp-client}"
USERNAME="${USERNAME:-alice}"
PASSWORD="${PASSWORD:-password}"
SCOPE="${1:-mcp:read mcp:write}"

resp=$(curl -sS \
  -d "grant_type=password" \
  -d "client_id=$CLIENT" \
  -d "username=$USERNAME" \
  -d "password=$PASSWORD" \
  --data-urlencode "scope=$SCOPE" \
  "$KC/realms/$REALM/protocol/openid-connect/token")

token=$(printf '%s' "$resp" | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')
if [ -z "$token" ]; then
  echo "failed to obtain token: $resp" >&2
  exit 1
fi
printf '%s' "$token"
