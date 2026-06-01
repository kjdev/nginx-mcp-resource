#!/bin/sh
# Host-direct introspect-mode E2E driver. Same assertions as
# test/e2e/introspect.sh, but runs nginx on the host with the pre-built
# module .so files (no Docker).

set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib.sh"

E2E_DIR="$E2E_LOG_DIR/e2e-host-introspect"
mkdir -p "$E2E_DIR"
backend_log="$E2E_DIR/backend.log"
as_log="$E2E_DIR/as.log"

echo "[host/introspect] starting backend on :$BACKEND_PORT..."
start_backend "$backend_log"
wait_for_http "backend" "http://127.0.0.1:$BACKEND_PORT/"

echo "[host/introspect] starting mock AS on :$AS_PORT..."
start_as_mock "$as_log"
wait_for_http "as-mock" \
    "http://127.0.0.1:$AS_PORT/.well-known/oauth-authorization-server"

echo "[host/introspect] starting nginx..."
start_nginx "$HERE/nginx-introspect.conf.template" "$E2E_DIR" \
    "http://127.0.0.1:$AS_PORT/introspect"

base="http://127.0.0.1:$RS_PORT"
curl="curl -sS --max-time 5"

wait_for_rs "$base"

# -------- PRM ------------------------------------------------------------
echo "[host/introspect] (PRM) /.well-known/oauth-protected-resource"
body=$($curl "$base/.well-known/oauth-protected-resource")
status=$($curl -o /dev/null -w '%{http_code}' "$base/.well-known/oauth-protected-resource")
assert_status "PRM endpoint returns 200" 200 "$status"
assert_contains "PRM has 'resource'"              '"resource"'              "$body"
assert_contains "PRM has 'authorization_servers'" '"authorization_servers"' "$body"

# -------- no token -> 401 single ----------------------------------------
echo "[host/introspect] (1) no Authorization -> 401 single MCP-format"
headers=$($curl -D - -o /dev/null "$base/mcp")
status=$(printf '%s' "$headers" | awk 'NR==1{print $2; exit}')
assert_status "no-token returns 401" 401 "$status"
assert_contains "401 carries resource_metadata" \
    "resource_metadata=\"$MCP_METADATA_URI\"" "$headers"
n=$(count_www_authenticate "$headers")
assert_status "401 has exactly one WWW-Authenticate header" 1 "$n"
assert_not_contains "401 has no module-default error=invalid_token leakage" \
    'error="invalid_token"' "$headers"

# -------- inactive -> 401 single ----------------------------------------
echo "[host/introspect] (2) active=false -> 401 single MCP-format"
headers=$($curl -D - -o /dev/null -H 'Authorization: Bearer e2e-inactive' "$base/mcp")
status=$(printf '%s' "$headers" | awk 'NR==1{print $2; exit}')
assert_status "inactive returns 401" 401 "$status"
assert_contains "inactive 401 carries resource_metadata" \
    "resource_metadata=\"$MCP_METADATA_URI\"" "$headers"
n=$(count_www_authenticate "$headers")
assert_status "inactive 401 has exactly one WWW-Authenticate header" 1 "$n"
assert_not_contains "inactive 401 has no module-default error=invalid_token leakage" \
    'error="invalid_token"' "$headers"

# -------- wrong aud -> 401 ----------------------------------------------
echo "[host/introspect] (3) wrong aud -> 401"
headers=$($curl -D - -o /dev/null -H 'Authorization: Bearer e2e-wrong-aud' "$base/mcp")
status=$(printf '%s' "$headers" | awk 'NR==1{print $2; exit}')
assert_status "wrong-aud returns 401" 401 "$status"
n=$(count_www_authenticate "$headers")
assert_status "wrong-aud 401 has exactly one WWW-Authenticate header" 1 "$n"

# -------- insufficient scope -> 403 -------------------------------------
echo "[host/introspect] (4) insufficient scope -> 403"
headers=$($curl -D - -o /dev/null -H 'Authorization: Bearer e2e-insufficient-scope' "$base/mcp")
status=$(printf '%s' "$headers" | awk 'NR==1{print $2; exit}')
assert_status "insufficient-scope returns 403" 403 "$status"
assert_contains "403 has error=insufficient_scope" 'error="insufficient_scope"' "$headers"
assert_contains "403 carries scope" "scope=\"$MCP_REQUIRED_SCOPE\"" "$headers"
assert_contains "403 carries resource_metadata" \
    "resource_metadata=\"$MCP_METADATA_URI\"" "$headers"
n=$(count_www_authenticate "$headers")
assert_status "403 has exactly one WWW-Authenticate header" 1 "$n"

# -------- valid -> 200 ---------------------------------------------------
echo "[host/introspect] (5) valid -> 200, no upstream Authorization"
body_file="$E2E_DIR/valid-body.txt"
headers=$($curl -D - -o "$body_file" -H 'Authorization: Bearer e2e-valid' "$base/mcp")
status=$(printf '%s' "$headers" | awk 'NR==1{print $2; exit}')
assert_status "valid returns 200" 200 "$status"
body=$(cat "$body_file")
assert_contains "200 body is from echo backend" '"backend": "e2e-echo"' "$body"
auth_value=$(printf '%s' "$headers" \
    | awk 'BEGIN{IGNORECASE=1} /^X-Echo-Authorization:/ {sub(/^[^:]*: */,""); sub(/\r$/,""); print; exit}')
if [ -z "$auth_value" ]; then
    pass "upstream Authorization value is empty"
else
    fail "upstream Authorization value should be empty, got [$auth_value]"
fi

# -------- cache happy path -----------------------------------------------
echo "[host/introspect] (6) repeated valid request -> still 200"
s1=$($curl -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer e2e-valid' "$base/mcp")
s2=$($curl -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer e2e-valid' "$base/mcp")
assert_status "first cached hit returns 200" 200 "$s1"
assert_status "second cached hit returns 200" 200 "$s2"

print_summary
