#!/bin/sh
# JWT-mode E2E driver.
#
# Verifies the Phase A acceptance criteria for the JWT pattern (eight items)
# against the actual nginx-mcp-resource container image, using a host-side
# Python echo backend so the upstream-visible Authorization header can be
# inspected.

set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib.sh"

backend_log="$E2E_LOG_DIR/e2e-jwt-backend.log"
rs_log="$E2E_LOG_DIR/e2e-jwt-rs.log"

echo "[jwt] starting backend on :$BACKEND_PORT..."
start_backend "$BACKEND_PORT" "$backend_log"
wait_for_http "backend" "http://127.0.0.1:$BACKEND_PORT/"

echo "[jwt] starting nginx-mcp-resource container..."
cid=$(docker run -d --rm -p "$RS_PORT:80" \
    --add-host=host.docker.internal:host-gateway \
    -e MCP_AUTH_MODE=jwt \
    -e MCP_TLS=off \
    -e MCP_SERVER_NAME=mcp.e2e.local \
    -e "MCP_CANONICAL_URI=$MCP_CANONICAL_URI" \
    -e "MCP_METADATA_URI=$MCP_METADATA_URI" \
    -e "MCP_AUTHORIZATION_SERVER=$MCP_AUTHORIZATION_SERVER" \
    -e "MCP_REQUIRED_SCOPE=$MCP_REQUIRED_SCOPE" \
    -e MCP_SCOPES_SUPPORTED=mcp:read,mcp:write \
    -e "MCP_BACKEND=host.docker.internal:$BACKEND_PORT" \
    -e MCP_JWT_KEY_FILE=/etc/nginx/keys/jwks.json \
    -v "$FIXTURES/keys:/etc/nginx/keys:ro" \
    "$IMAGE")
CIDS="$CIDS $cid"
docker logs -f "$cid" > "$rs_log" 2>&1 &
PIDS="$PIDS $!"

base="http://127.0.0.1:$RS_PORT"
curl="curl -sS --max-time 5"

wait_for_rs "$base"

# -------- mint tokens ----------------------------------------------------
GEN="python3 $HERE/servers/gen_jwt.py"
TOKEN_VALID=$($GEN --aud "$MCP_CANONICAL_URI" --scope "mcp:read")
TOKEN_WRONG_AUD=$($GEN --aud "https://other.example.com/mcp" --scope "mcp:read")
TOKEN_SCOPE_BAD=$($GEN --aud "$MCP_CANONICAL_URI" --scope "other:scope")
TOKEN_EXPIRED=$($GEN --aud "$MCP_CANONICAL_URI" --scope "mcp:read" --exp "-60")
TOKEN_BAD_SIG=$($GEN --aud "$MCP_CANONICAL_URI" --scope "mcp:read" --bad-sig)

# -------- (1) PRM endpoint -----------------------------------------------
echo "[jwt] (1) /.well-known/oauth-protected-resource"
body=$($curl "$base/.well-known/oauth-protected-resource")
status=$($curl -o /dev/null -w '%{http_code}' "$base/.well-known/oauth-protected-resource")
assert_status "PRM endpoint returns 200" 200 "$status"
assert_contains "PRM has 'resource'"              '"resource"'              "$body"
assert_contains "PRM has 'authorization_servers'" '"authorization_servers"' "$body"
assert_contains "PRM has 'scopes_supported'"      '"scopes_supported"'      "$body"
assert_contains "PRM has 'bearer_methods_supported'" '"bearer_methods_supported"' "$body"

# -------- (2) no token -> 401 + MCP-format WWW-Authenticate --------------
echo "[jwt] (2) no Authorization -> 401 with MCP WWW-Authenticate"
headers=$($curl -D - -o /dev/null "$base/mcp")
status=$(printf '%s' "$headers" | awk 'NR==1{print $2; exit}')
assert_status "/mcp without token returns 401" 401 "$status"
assert_contains "401 WWW-Authenticate carries resource_metadata" \
    "resource_metadata=\"$MCP_METADATA_URI\"" "$headers"
assert_contains "401 WWW-Authenticate carries scope" \
    "scope=\"$MCP_REQUIRED_SCOPE\"" "$headers"
# (8) header is emitted exactly once and is the MCP-format single line
n=$(count_www_authenticate "$headers")
assert_status "401 has exactly one WWW-Authenticate header" 1 "$n"
assert_not_contains "401 WWW-Authenticate has no realm= leakage" "realm=" "$headers"
assert_not_contains "401 WWW-Authenticate has no error=\"invalid_token\" leakage" \
    'error="invalid_token"' "$headers"

# -------- (3) invalid JWT (bad sig / expired) -> 401 ---------------------
echo "[jwt] (3a) invalid JWT (bad signature) -> 401"
headers=$($curl -D - -o /dev/null -H "Authorization: Bearer $TOKEN_BAD_SIG" "$base/mcp")
status=$(printf '%s' "$headers" | awk 'NR==1{print $2; exit}')
assert_status "bad signature returns 401" 401 "$status"
assert_contains "bad-sig 401 carries resource_metadata" \
    "resource_metadata=\"$MCP_METADATA_URI\"" "$headers"
n=$(count_www_authenticate "$headers")
assert_status "bad-sig 401 has exactly one WWW-Authenticate" 1 "$n"

echo "[jwt] (3b) invalid JWT (expired) -> 401"
headers=$($curl -D - -o /dev/null -H "Authorization: Bearer $TOKEN_EXPIRED" "$base/mcp")
status=$(printf '%s' "$headers" | awk 'NR==1{print $2; exit}')
assert_status "expired token returns 401" 401 "$status"
n=$(count_www_authenticate "$headers")
assert_status "expired 401 has exactly one WWW-Authenticate" 1 "$n"

# -------- (4) wrong aud -> 401 -------------------------------------------
echo "[jwt] (4) wrong-aud JWT -> 401"
headers=$($curl -D - -o /dev/null -H "Authorization: Bearer $TOKEN_WRONG_AUD" "$base/mcp")
status=$(printf '%s' "$headers" | awk 'NR==1{print $2; exit}')
assert_status "wrong-aud returns 401" 401 "$status"
assert_contains "wrong-aud 401 carries resource_metadata" \
    "resource_metadata=\"$MCP_METADATA_URI\"" "$headers"
n=$(count_www_authenticate "$headers")
assert_status "wrong-aud 401 has exactly one WWW-Authenticate" 1 "$n"

# -------- (5) insufficient scope -> 403 ----------------------------------
echo "[jwt] (5) insufficient-scope JWT -> 403"
headers=$($curl -D - -o /dev/null -H "Authorization: Bearer $TOKEN_SCOPE_BAD" "$base/mcp")
status=$(printf '%s' "$headers" | awk 'NR==1{print $2; exit}')
assert_status "insufficient-scope returns 403" 403 "$status"
assert_contains "403 WWW-Authenticate carries error=insufficient_scope" \
    'error="insufficient_scope"' "$headers"
assert_contains "403 WWW-Authenticate carries scope" \
    "scope=\"$MCP_REQUIRED_SCOPE\"" "$headers"
assert_contains "403 WWW-Authenticate carries resource_metadata" \
    "resource_metadata=\"$MCP_METADATA_URI\"" "$headers"
n=$(count_www_authenticate "$headers")
assert_status "403 has exactly one WWW-Authenticate header" 1 "$n"

# -------- (6) valid token -> 200, body from upstream ---------------------
echo "[jwt] (6) valid JWT -> 200, upstream body"
headers=$($curl -D - -o /tmp/e2e-jwt-body.txt -H "Authorization: Bearer $TOKEN_VALID" "$base/mcp")
status=$(printf '%s' "$headers" | awk 'NR==1{print $2; exit}')
assert_status "valid JWT returns 200" 200 "$status"
body=$(cat /tmp/e2e-jwt-body.txt)
assert_contains "200 body is from echo backend" '"backend": "e2e-echo"' "$body"

# -------- (7) Authorization NOT forwarded to upstream --------------------
echo "[jwt] (7) upstream sees no Authorization"
assert_contains "echo header X-Echo-Authorization is present (empty value)" \
    "X-Echo-Authorization:" "$headers"
# The echo backend emits the value of $http_authorization. nginx strips it,
# so the header value must be empty (i.e. the header line ends right after
# the colon and a space).
auth_value=$(printf '%s' "$headers" \
    | awk 'BEGIN{IGNORECASE=1} /^X-Echo-Authorization:/ {sub(/^[^:]*: */,""); sub(/\r$/,""); print; exit}')
if [ -z "$auth_value" ]; then
    pass "upstream Authorization value is empty"
else
    fail "upstream Authorization value should be empty, got [$auth_value]"
fi

print_summary
