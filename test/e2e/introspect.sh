#!/bin/sh
# Introspect-mode E2E driver.
#
# Verifies the Phase A acceptance criteria for the introspection pattern
# (six items) against the actual nginx-mcp-resource container image, using
# a host-side Python echo backend plus a host-side mock AS that serves a
# deterministic /introspect response keyed off the posted token value.

set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib.sh"

backend_log="$E2E_LOG_DIR/e2e-introspect-backend.log"
as_log="$E2E_LOG_DIR/e2e-introspect-as.log"
rs_log="$E2E_LOG_DIR/e2e-introspect-rs.log"

# Mock AS is reachable from the RS container via host-gateway.
RS_INTROSPECT_ENDPOINT="http://host.docker.internal:${AS_PORT}/introspect"

echo "[introspect] starting backend on :$BACKEND_PORT..."
start_backend "$BACKEND_PORT" "$backend_log"
wait_for_http "backend" "http://127.0.0.1:$BACKEND_PORT/"

echo "[introspect] starting mock AS on :$AS_PORT..."
start_as_mock "$AS_PORT" "$MCP_CANONICAL_URI" \
    "$MCP_AUTHORIZATION_SERVER" "$as_log"
wait_for_http "as-mock" "http://127.0.0.1:$AS_PORT/.well-known/oauth-authorization-server"

echo "[introspect] starting nginx-mcp-resource container..."
cid=$(docker run -d --rm -p "$RS_PORT:80" \
    --add-host=host.docker.internal:host-gateway \
    -e MCP_AUTH_MODE=introspect \
    -e MCP_TLS=off \
    -e MCP_SERVER_NAME=mcp.e2e.local \
    -e "MCP_CANONICAL_URI=$MCP_CANONICAL_URI" \
    -e "MCP_METADATA_URI=$MCP_METADATA_URI" \
    -e "MCP_AUTHORIZATION_SERVER=$MCP_AUTHORIZATION_SERVER" \
    -e "MCP_REQUIRED_SCOPE=$MCP_REQUIRED_SCOPE" \
    -e MCP_SCOPES_SUPPORTED=mcp:read,mcp:write \
    -e "MCP_BACKEND=host.docker.internal:$BACKEND_PORT" \
    -e "MCP_INTROSPECT_ENDPOINT=$RS_INTROSPECT_ENDPOINT" \
    -e MCP_CLIENT_ID=mcp-e2e \
    -e MCP_CLIENT_SECRET_FILE=/run/secrets/rs.secret \
    -e MCP_RESOLVER=127.0.0.11 \
    -v "$FIXTURES/secrets/rs.secret:/run/secrets/rs.secret:ro" \
    "$IMAGE")
CIDS="$CIDS $cid"
docker logs -f "$cid" > "$rs_log" 2>&1 &
PIDS="$PIDS $!"

base="http://127.0.0.1:$RS_PORT"
curl="curl -sS --max-time 5"

wait_for_rs "$base"

# -------- (PRM) same JSON as JWT mode ------------------------------------
echo "[introspect] (PRM) /.well-known/oauth-protected-resource"
body=$($curl "$base/.well-known/oauth-protected-resource")
status=$($curl -o /dev/null -w '%{http_code}' "$base/.well-known/oauth-protected-resource")
assert_status "PRM endpoint returns 200" 200 "$status"
assert_contains "PRM has 'resource'"              '"resource"'              "$body"
assert_contains "PRM has 'authorization_servers'" '"authorization_servers"' "$body"

# -------- (1) no token -> 401 single-line MCP WWW-Authenticate -----------
echo "[introspect] (1) no Authorization -> 401, single MCP-format header"
headers=$($curl -D - -o /dev/null "$base/mcp")
status=$(printf '%s' "$headers" | awk 'NR==1{print $2; exit}')
assert_status "no-token returns 401" 401 "$status"
assert_contains "401 carries resource_metadata" \
    "resource_metadata=\"$MCP_METADATA_URI\"" "$headers"
assert_contains "401 carries scope" \
    "scope=\"$MCP_REQUIRED_SCOPE\"" "$headers"
n=$(count_www_authenticate "$headers")
assert_status "401 has exactly one WWW-Authenticate header" 1 "$n"
assert_not_contains "401 has no module-default error=\"invalid_token\" leakage" \
    'error="invalid_token"' "$headers"

# -------- (2) active=false -> 401 single-line ----------------------------
echo "[introspect] (2) active=false -> 401, single MCP-format header"
headers=$($curl -D - -o /dev/null -H 'Authorization: Bearer e2e-inactive' "$base/mcp")
status=$(printf '%s' "$headers" | awk 'NR==1{print $2; exit}')
assert_status "inactive returns 401" 401 "$status"
assert_contains "inactive 401 carries resource_metadata" \
    "resource_metadata=\"$MCP_METADATA_URI\"" "$headers"
n=$(count_www_authenticate "$headers")
assert_status "inactive 401 has exactly one WWW-Authenticate header" 1 "$n"
assert_not_contains "inactive 401 has no module-default error=\"invalid_token\" leakage" \
    'error="invalid_token"' "$headers"

# -------- (3) wrong aud -> 401 single-line -------------------------------
echo "[introspect] (3) wrong-aud -> 401"
headers=$($curl -D - -o /dev/null -H 'Authorization: Bearer e2e-wrong-aud' "$base/mcp")
status=$(printf '%s' "$headers" | awk 'NR==1{print $2; exit}')
assert_status "wrong-aud returns 401" 401 "$status"
assert_contains "wrong-aud 401 carries resource_metadata" \
    "resource_metadata=\"$MCP_METADATA_URI\"" "$headers"
n=$(count_www_authenticate "$headers")
assert_status "wrong-aud 401 has exactly one WWW-Authenticate header" 1 "$n"

# -------- (4) scope insufficient -> 403 single-line ----------------------
echo "[introspect] (4) insufficient-scope -> 403"
headers=$($curl -D - -o /dev/null -H 'Authorization: Bearer e2e-insufficient-scope' "$base/mcp")
status=$(printf '%s' "$headers" | awk 'NR==1{print $2; exit}')
assert_status "insufficient-scope returns 403" 403 "$status"
assert_contains "403 carries error=insufficient_scope" \
    'error="insufficient_scope"' "$headers"
assert_contains "403 carries scope" \
    "scope=\"$MCP_REQUIRED_SCOPE\"" "$headers"
assert_contains "403 carries resource_metadata" \
    "resource_metadata=\"$MCP_METADATA_URI\"" "$headers"
n=$(count_www_authenticate "$headers")
assert_status "403 has exactly one WWW-Authenticate header" 1 "$n"

# -------- (5) valid -> 200 + Authorization stripped ----------------------
echo "[introspect] (5) valid token -> 200, upstream sees no Authorization"
headers=$($curl -D - -o /tmp/e2e-introspect-body.txt -H 'Authorization: Bearer e2e-valid' "$base/mcp")
status=$(printf '%s' "$headers" | awk 'NR==1{print $2; exit}')
assert_status "valid token returns 200" 200 "$status"
body=$(cat /tmp/e2e-introspect-body.txt)
assert_contains "200 body is from echo backend" '"backend": "e2e-echo"' "$body"
auth_value=$(printf '%s' "$headers" \
    | awk 'BEGIN{IGNORECASE=1} /^X-Echo-Authorization:/ {sub(/^[^:]*: */,""); sub(/\r$/,""); print; exit}')
if [ -z "$auth_value" ]; then
    pass "upstream Authorization value is empty"
else
    fail "upstream Authorization value should be empty, got [$auth_value]"
fi

# -------- (6) introspect cache still works -------------------------------
# Hit the same token twice; both must succeed and the second must be served
# without errors (cache invalidation correctness is out of scope, we just
# check that the cache zone enabled in the container does not break the
# happy path).
echo "[introspect] (6) cached repeat hit -> still 200"
status1=$($curl -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer e2e-valid' "$base/mcp")
status2=$($curl -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer e2e-valid' "$base/mcp")
assert_status "first cached hit returns 200" 200 "$status1"
assert_status "second cached hit returns 200" 200 "$status2"

print_summary
