#!/bin/sh
# Shared smoke test library. Sourced from each *.sh via `. ./lib.sh`.

set -eu

: "${IMAGE:=nginx-mcp-resource:dev}"
: "${HOST_PORT:=18180}"
: "${FIXTURES:=$(cd "$(dirname "$0")" && pwd)/fixtures}"

# === Fixture generation ===================================================
prepare_fixtures() {
    mkdir -p "$FIXTURES/keys" "$FIXTURES/certs" "$FIXTURES/secrets"

    if [ ! -f "$FIXTURES/keys/jwks.json" ]; then
        cat > "$FIXTURES/keys/jwks.json" <<'EOF'
{"keys":[{"kty":"oct","use":"sig","kid":"smoke","k":"c21va2Utc2VjcmV0","alg":"HS256"}]}
EOF
    fi

    if [ ! -f "$FIXTURES/certs/server.crt" ]; then
        openssl req -x509 -newkey rsa:2048 -nodes \
            -keyout "$FIXTURES/certs/server.key" \
            -out    "$FIXTURES/certs/server.crt" \
            -days 1 -subj '/CN=mcp.smoke.local' >/dev/null 2>&1
    fi

    if [ ! -f "$FIXTURES/secrets/rs.secret" ]; then
        printf 'smoke-secret\n' > "$FIXTURES/secrets/rs.secret"
    fi
}

# === assertion helpers ====================================================
PASS_COUNT=0
FAIL_COUNT=0

pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  ok - $*"
}

fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo "  NG - $*" >&2
}

assert_status() {
    label=$1
    expected=$2
    got=$3
    if [ "$got" = "$expected" ]; then
        pass "$label (status=$got)"
    else
        fail "$label (expected=$expected got=$got)"
    fi
}

assert_contains() {
    label=$1
    needle=$2
    haystack=$3
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        pass "$label"
    else
        fail "$label (expected to contain: $needle)"
    fi
}

# === Container helpers ====================================================
wait_for_ready() {
    cid=$1
    proto=$2
    port=$3
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if curl -fsS -k --max-time 1 "$proto://127.0.0.1:$port/healthz" >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.5
    done
    echo "[smoke] container did not become ready" >&2
    docker logs "$cid" >&2 || true
    return 1
}

cleanup_container() {
    cid=$1
    docker rm -f "$cid" >/dev/null 2>&1 || true
}

# === Shared assertions (run regardless of mode) ===========================
# $1: proto (http / https), $2: port, $3: canonical URI exposed for this scheme
run_common_assertions() {
    proto=$1
    port=$2
    metadata_uri=$3
    required_scope=$4

    base="$proto://127.0.0.1:$port"
    curl="curl -sS -k --max-time 5"

    # healthz
    status=$($curl -o /dev/null -w '%{http_code}' "$base/healthz" || echo 000)
    assert_status "healthz returns 200" 200 "$status"

    # metadata
    body=$($curl "$base/.well-known/oauth-protected-resource" || true)
    status=$($curl -o /dev/null -w '%{http_code}' "$base/.well-known/oauth-protected-resource" || echo 000)
    assert_status "metadata returns 200" 200 "$status"
    assert_contains "metadata contains 'resource'"             '"resource"'             "$body"
    assert_contains "metadata contains 'authorization_servers'" '"authorization_servers"' "$body"
    assert_contains "metadata contains 'scopes_supported'"     '"scopes_supported"'     "$body"
    assert_contains "metadata contains 'bearer_methods_supported'" '"bearer_methods_supported"' "$body"

    # /mcp without token -> 401 + WWW-Authenticate
    headers=$($curl -o /dev/null -D - "$base/mcp" || true)
    status=$(printf '%s' "$headers" | awk 'NR==1{print $2; exit}')
    assert_status "/mcp without token returns 401" 401 "$status"
    assert_contains "/mcp 401 WWW-Authenticate has resource_metadata=$metadata_uri" \
        "resource_metadata=\"$metadata_uri\"" "$headers"
    assert_contains "/mcp 401 WWW-Authenticate has scope=$required_scope" \
        "scope=\"$required_scope\"" "$headers"

}

# === JWT-mode assertion ===================================================
# A syntactically bogus bearer is rejected locally against the JWKS, so 401 is
# returned without any AS round-trip. This does not hold in introspect mode
# (that needs a reachable introspection endpoint), so it lives here rather than
# in run_common_assertions. Introspection behaviour is covered by t/09-13.
assert_bogus_token_rejected() {
    proto=$1
    port=$2
    base="$proto://127.0.0.1:$port"
    status=$(curl -sS -k --max-time 5 -o /dev/null -w '%{http_code}' "$base/mcp" \
        -H 'Authorization: Bearer not-a-real-token' || echo 000)
    assert_status "/mcp with bogus token returns 401" 401 "$status"
}

# === Summary ==============================================================
print_summary() {
    echo
    echo "==== smoke summary: ${PASS_COUNT} passed, ${FAIL_COUNT} failed ===="
    if [ "$FAIL_COUNT" -gt 0 ]; then
        exit 1
    fi
}
