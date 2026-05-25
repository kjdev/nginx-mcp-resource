#!/usr/bin/env bash
# Validate examples/nginx-*.conf with `nginx -t` against a disposable
# sandbox of self-signed certs, dummy JWKS, and dummy client secret.

set -euo pipefail

PROJECT_DIR=${PROJECT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}
LINT_DIR=${LINT_DIR:-"$PROJECT_DIR/build/lint"}
JWT_MODULE=${JWT_MODULE:-"$PROJECT_DIR/../nginx-auth-jwt/build/fedora/ngx_http_auth_jwt_module.so"}
OAUTH2_MODULE=${OAUTH2_MODULE:-"$PROJECT_DIR/../nginx-auth-oauth2-token/build/fedora/ngx_http_auth_oauth2_token_module.so"}
NGINX_BIN=${NGINX_BIN:-/usr/bin/nginx}

mkdir -p "$LINT_DIR"/{certs,keys,secrets,conf,logs}

if [[ ! -f "$LINT_DIR/certs/server.crt" ]]; then
    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "$LINT_DIR/certs/server.key" \
        -out "$LINT_DIR/certs/server.crt" \
        -days 1 -subj '/CN=lint.example.com' >/dev/null 2>&1
fi

cat > "$LINT_DIR/keys/jwks.json" <<'EOF'
{"keys":[{"kty":"oct","use":"sig","kid":"test1","k":"dGVzdDEuc2VjcmV0","alg":"HS256"}]}
EOF
printf 'lint-secret\n' > "$LINT_DIR/secrets/rs.secret"

rewrite() {
    local src=$1
    local dst=$2
    # The introspection example points proxy_pass at a placeholder AS host
    # (auth.example.com) which `nginx -t` tries to resolve and fails on. We
    # rewrite it to a loopback URL purely to make `-t` resolve-clean; the
    # check exercises directive grammar, not actual reachability.
    sed \
        -e "s|/etc/nginx/certs|$LINT_DIR/certs|g" \
        -e "s|/etc/nginx/keys|$LINT_DIR/keys|g" \
        -e "s|/etc/nginx/secrets|$LINT_DIR/secrets|g" \
        -e "s|/usr/lib/nginx/modules/ngx_http_auth_jwt_module.so|$JWT_MODULE|g" \
        -e "s|/usr/lib/nginx/modules/ngx_http_auth_oauth2_token_module.so|$OAUTH2_MODULE|g" \
        -e "s|include conf/|include $PROJECT_DIR/conf/|g" \
        -e "s|https://auth.example.com/oauth2/introspect|http://127.0.0.1:65532/|g" \
        -e "s|^http {|http {\n    access_log $LINT_DIR/logs/access.log;|" \
        -e 's|listen 443 ssl;|listen 8443 ssl;|' \
        "$src" > "$dst"
}

rewrite "$PROJECT_DIR/examples/nginx-jwt.conf"        "$LINT_DIR/conf/nginx-jwt.conf"
rewrite "$PROJECT_DIR/examples/nginx-introspect.conf" "$LINT_DIR/conf/nginx-introspect.conf"

status=0
for conf in nginx-jwt.conf nginx-introspect.conf; do
    echo "=== $conf ==="
    if ! "$NGINX_BIN" -t \
            -p "$PROJECT_DIR" \
            -e "$LINT_DIR/logs/error.log" \
            -g "pid $LINT_DIR/nginx.pid;" \
            -c "$LINT_DIR/conf/$conf"; then
        status=1
    fi
done

exit "$status"
