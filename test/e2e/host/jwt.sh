#!/bin/sh
# Host-direct JWT-mode E2E driver. Same assertions as test/e2e/jwt.sh, but
# runs nginx on the host with the pre-built module .so files (no Docker).

set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib.sh"

E2E_DIR="$E2E_LOG_DIR/e2e-host-jwt"
mkdir -p "$E2E_DIR"
backend_log="$E2E_DIR/backend.log"

echo "[host/jwt] starting backend on :$BACKEND_PORT..."
start_backend "$backend_log"
wait_for_http "backend" "http://127.0.0.1:$BACKEND_PORT/"

echo "[host/jwt] starting nginx..."
start_nginx "$HERE/nginx-jwt.conf.template" "$E2E_DIR"

base="http://127.0.0.1:$RS_PORT"
curl="curl -sS --max-time 5"

wait_for_rs "$base"

# -------- mint tokens ----------------------------------------------------
GEN="python3 $E2E_HERE/servers/gen_jwt.py"
TOKEN_VALID=$($GEN --aud "$MCP_CANONICAL_URI" --scope "mcp:read")
TOKEN_WRONG_AUD=$($GEN --aud "https://other.example.com/mcp" --scope "mcp:read")
TOKEN_SCOPE_BAD=$($GEN --aud "$MCP_CANONICAL_URI" --scope "other:scope")
TOKEN_EXPIRED=$($GEN --aud "$MCP_CANONICAL_URI" --scope "mcp:read" --exp "-60")
TOKEN_BAD_SIG=$($GEN --aud "$MCP_CANONICAL_URI" --scope "mcp:read" --bad-sig)

# -------- PRM ------------------------------------------------------------
echo "[host/jwt] (1) /.well-known/oauth-protected-resource"
body=$($curl "$base/.well-known/oauth-protected-resource")
status=$($curl -o /dev/null -w '%{http_code}' "$base/.well-known/oauth-protected-resource")
assert_status "PRM endpoint returns 200" 200 "$status"
assert_contains "PRM has 'resource'"                  '"resource"'                  "$body"
assert_contains "PRM has 'authorization_servers'"     '"authorization_servers"'     "$body"
assert_contains "PRM has 'scopes_supported'"          '"scopes_supported"'          "$body"
assert_contains "PRM has 'bearer_methods_supported'"  '"bearer_methods_supported"'  "$body"

# -------- no token -------------------------------------------------------
echo "[host/jwt] (2) no Authorization -> 401 MCP-format"
headers=$($curl -D - -o /dev/null "$base/mcp")
status=$(printf '%s' "$headers" | awk 'NR==1{print $2; exit}')
assert_status "/mcp without token returns 401" 401 "$status"
assert_contains "401 carries resource_metadata" \
    "resource_metadata=\"$MCP_METADATA_URI\"" "$headers"
assert_contains "401 carries scope" "scope=\"$MCP_REQUIRED_SCOPE\"" "$headers"
n=$(count_www_authenticate "$headers")
assert_status "401 has exactly one WWW-Authenticate header" 1 "$n"
assert_not_contains "401 has no realm= leakage" "realm=" "$headers"

# -------- invalid (bad sig / expired) ------------------------------------
echo "[host/jwt] (3a) bad signature -> 401"
headers=$($curl -D - -o /dev/null -H "Authorization: Bearer $TOKEN_BAD_SIG" "$base/mcp")
status=$(printf '%s' "$headers" | awk 'NR==1{print $2; exit}')
assert_status "bad-sig returns 401" 401 "$status"
n=$(count_www_authenticate "$headers")
assert_status "bad-sig 401 has exactly one WWW-Authenticate header" 1 "$n"

echo "[host/jwt] (3b) expired -> 401"
headers=$($curl -D - -o /dev/null -H "Authorization: Bearer $TOKEN_EXPIRED" "$base/mcp")
status=$(printf '%s' "$headers" | awk 'NR==1{print $2; exit}')
assert_status "expired returns 401" 401 "$status"
n=$(count_www_authenticate "$headers")
assert_status "expired 401 has exactly one WWW-Authenticate header" 1 "$n"

# -------- wrong aud ------------------------------------------------------
echo "[host/jwt] (4) wrong aud -> 401"
headers=$($curl -D - -o /dev/null -H "Authorization: Bearer $TOKEN_WRONG_AUD" "$base/mcp")
status=$(printf '%s' "$headers" | awk 'NR==1{print $2; exit}')
assert_status "wrong-aud returns 401" 401 "$status"
assert_contains "wrong-aud 401 carries resource_metadata" \
    "resource_metadata=\"$MCP_METADATA_URI\"" "$headers"
n=$(count_www_authenticate "$headers")
assert_status "wrong-aud 401 has exactly one WWW-Authenticate header" 1 "$n"

# -------- insufficient scope ---------------------------------------------
echo "[host/jwt] (5) insufficient scope -> 403"
headers=$($curl -D - -o /dev/null -H "Authorization: Bearer $TOKEN_SCOPE_BAD" "$base/mcp")
status=$(printf '%s' "$headers" | awk 'NR==1{print $2; exit}')
assert_status "insufficient-scope returns 403" 403 "$status"
assert_contains "403 has error=insufficient_scope" 'error="insufficient_scope"' "$headers"
assert_contains "403 carries scope" "scope=\"$MCP_REQUIRED_SCOPE\"" "$headers"
assert_contains "403 carries resource_metadata" \
    "resource_metadata=\"$MCP_METADATA_URI\"" "$headers"
n=$(count_www_authenticate "$headers")
assert_status "403 has exactly one WWW-Authenticate header" 1 "$n"

# -------- valid token ----------------------------------------------------
echo "[host/jwt] (6) valid JWT -> 200"
body_file="$E2E_DIR/valid-body.txt"
headers=$($curl -D - -o "$body_file" -H "Authorization: Bearer $TOKEN_VALID" "$base/mcp")
status=$(printf '%s' "$headers" | awk 'NR==1{print $2; exit}')
assert_status "valid JWT returns 200" 200 "$status"
body=$(cat "$body_file")
assert_contains "200 body is from echo backend" '"backend": "e2e-echo"' "$body"

# -------- no passthrough -------------------------------------------------
echo "[host/jwt] (7) upstream sees no Authorization"
auth_value=$(printf '%s' "$headers" \
    | awk 'BEGIN{IGNORECASE=1} /^X-Echo-Authorization:/ {sub(/^[^:]*: */,""); sub(/\r$/,""); print; exit}')
if [ -z "$auth_value" ]; then
    pass "upstream Authorization value is empty"
else
    fail "upstream Authorization value should be empty, got [$auth_value]"
fi

print_summary
