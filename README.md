# nginx-mcp-resource

A set of nginx configuration snippets — plus a ready-to-run container image
that wraps them — for serving an MCP (Model Context Protocol) endpoint as an
OAuth 2.1 Resource Server.

- Authentication switchable between **JWT verification** (`nginx-auth-jwt`)
  and **OAuth 2.0 Token Introspection** (`nginx-auth-oauth2-token`).
- Returns [RFC 9728](https://datatracker.ietf.org/doc/html/rfc9728) Protected
  Resource Metadata and a `WWW-Authenticate` challenge compliant with the
  [MCP authorization spec](https://modelcontextprotocol.io/specification/draft/basic/authorization).
- Prevents cross-service token reuse via
  [RFC 8707](https://datatracker.ietf.org/doc/html/rfc8707) audience
  binding.

## Two ways to deploy

### A. Container image + environment variables

The container builds its `nginx.conf` at startup via `envsubst` and exits
before `nginx -t` if any required variable is missing.

```sh
# Build the image.
docker build -t nginx-mcp-resource:dev .

# Run in JWT mode (TLS terminated upstream).
docker run --rm -p 8080:80 \
  -e MCP_AUTH_MODE=jwt \
  -e MCP_TLS=off \
  -e MCP_SERVER_NAME=mcp.example.com \
  -e MCP_CANONICAL_URI=https://mcp.example.com/mcp \
  -e MCP_METADATA_URI=https://mcp.example.com/.well-known/oauth-protected-resource \
  -e MCP_AUTHORIZATION_SERVER=https://auth.example.com \
  -e MCP_REQUIRED_SCOPE=mcp:read \
  -e MCP_SCOPES_SUPPORTED=mcp:read,mcp:write \
  -e MCP_BACKEND=mcp-backend:8080 \
  -e MCP_JWT_KEY_FILE=/etc/nginx/keys/jwks.json \
  -v /path/to/jwks.json:/etc/nginx/keys/jwks.json:ro \
  nginx-mcp-resource:dev
```

See [`examples/compose.jwt.yml`](examples/compose.jwt.yml) /
[`examples/compose.introspect.yml`](examples/compose.introspect.yml)
for Docker Compose recipes.

### B. Configuration snippets (bare nginx)

Include `conf/mcp-*.conf` from an existing nginx configuration. The complete
configurations are in [`examples/nginx-jwt.conf`](examples/nginx-jwt.conf) /
[`examples/nginx-introspect.conf`](examples/nginx-introspect.conf).

```nginx
http {
    map "" $mcp_canonical_uri              { default "https://mcp.example.com/mcp"; }
    map "" $mcp_canonical_uri_json         { default '"https://mcp.example.com/mcp"'; }
    map "" $mcp_metadata_uri               { default "https://mcp.example.com/.well-known/oauth-protected-resource"; }
    map "" $mcp_required_scope             { default "mcp:read"; }
    map "" $mcp_authorization_servers_json { default '["https://auth.example.com"]'; }
    map "" $mcp_scopes_supported_json      { default '["mcp:read","mcp:write"]'; }
    map "" $mcp_bearer_methods_json        { default '["header"]'; }

    # ... auth-module specific map / claim_set ...

    server {
        # ...
        include conf/mcp-metadata.conf;
        include conf/mcp-401-handler.conf;
        include conf/mcp-403-handler.conf;

        location /mcp {
            include conf/mcp-resource-jwt.conf;       # or mcp-resource-introspect.conf
            proxy_set_header Authorization "";
            proxy_pass http://mcp_backend;
        }
    }
}
```

## Environment variables (container mode)

### Common (required)

| Variable | Description | Example |
|------|------|----|
| `MCP_AUTH_MODE` | `jwt` or `introspect` | `jwt` |
| `MCP_SERVER_NAME` | `server_name` directive | `mcp.example.com` |
| `MCP_CANONICAL_URI` | RS canonical URI (RFC 8707 audience) | `https://mcp.example.com/mcp` |
| `MCP_METADATA_URI` | Absolute URI of the RFC 9728 metadata document | `https://mcp.example.com/.well-known/oauth-protected-resource` |
| `MCP_AUTHORIZATION_SERVER` | `authorization_servers[0]` in metadata | `https://auth.example.com` |
| `MCP_REQUIRED_SCOPE` | Scope advertised in challenges | `mcp:read` |
| `MCP_SCOPES_SUPPORTED` | `scopes_supported` in metadata (comma-separated) | `mcp:read,mcp:write` |
| `MCP_BACKEND` | Upstream MCP backend | `mcp-backend:8080` |

### Common (optional)

| Variable | Default | Description |
|------|--------|------|
| `MCP_LISTEN_PORT` | 443 with `MCP_TLS=on`, 80 with `off` | Listen port |
| `MCP_RESOURCE_PATH` | `/mcp` | Path of the protected location |
| `MCP_BEARER_METHODS_SUPPORTED` | `header` | Metadata value |
| `MCP_WORKER_PROCESSES` | `auto` | `worker_processes` |
| `MCP_RESOLVER` | (unset) | DNS resolver. Required when the AS is an external FQDN (e.g. `127.0.0.11`). |

### TLS

| Variable | Description |
|------|------|
| `MCP_TLS` | `on` / `off` (default `off`) |
| `MCP_SSL_CERT_FILE` | Required when `MCP_TLS=on` |
| `MCP_SSL_CERT_KEY_FILE` | Required when `MCP_TLS=on` |

### JWT mode only

| Variable | Description |
|------|------|
| `MCP_JWT_KEY_FILE` | JWKS path (required) |

### Introspection mode only

| Variable | Description |
|------|------|
| `MCP_INTROSPECT_ENDPOINT` | RFC 7662 introspection endpoint of the AS (required) |
| `MCP_CLIENT_ID` | Required |
| `MCP_CLIENT_SECRET_FILE` | Path to the client secret file (required). Passing the secret through an environment variable is unsupported. |
| `MCP_INTROSPECT_CACHE_MAX_TTL` | Default `60s` |

### Rate limiting (optional)

Per-subject rate limiting via [nginx-ratelimit](https://github.com/kjdev/nginx-ratelimit),
keyed on the authenticated subject against a Redis backend. Disabled by
default. Supported in both auth modes: `jwt` keys on the `sub` claim
(requires `nginx-auth-jwt` >= 0.14.2) and `introspect` keys on
`$oauth2_token_sub` (requires `nginx-auth-oauth2-token` >= 0.5.0).

| Variable | Default | Description |
|------|--------|------|
| `MCP_RATELIMIT_ENABLED` | `off` | `on` / `off` |
| `MCP_RATELIMIT_REDIS` | — | Required when `on`. Redis `host:port` |
| `MCP_RATELIMIT_RATE` | — | Required when `on`. `ratelimit_zone rate=` value (e.g. `100r/m`) |
| `MCP_RATELIMIT_BURST` | (unset) | `ratelimit_zone burst=` value |
| `MCP_RATELIMIT_ALGO` | `fixed_window` | `ratelimit_zone algo=` value |
| `MCP_RATELIMIT_ON_ERROR` | `deny` | `deny` (fail-close) / `allow` (fail-open) when Redis is unreachable |
| `MCP_RATELIMIT_REDIS_PASSWORD_FILE` | (unset) | Path to a file holding the Redis AUTH password. Unlike `MCP_CLIENT_SECRET_FILE`, this value is expanded into the generated `nginx.conf` at startup (root-only, not kept as a file reference) |

See [`examples/compose.ratelimit.yml`](examples/compose.ratelimit.yml) for a
runnable Docker Compose recipe.

## Documentation

End-user reference documentation lives under [`docs/`](docs/):

- [`docs/GETTING_STARTED.md`](docs/GETTING_STARTED.md) — Beginner-friendly worked example (Keycloak AS + Claude Code + a runnable Docker Compose stack).
- [`docs/INSTALL.md`](docs/INSTALL.md) — Container and bare-nginx installation, including dependent-module builds.
- [`docs/EXAMPLES.md`](docs/EXAMPLES.md) — JWT and introspection patterns for bare nginx and Docker Compose.
- [`docs/SECURITY.md`](docs/SECURITY.md) — Mandatory operational requirements (HTTPS, audience binding, token passthrough, …).
- [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) — Common pitfalls with causes and fixes.
- [`docs/E2E_INSPECTOR.md`](docs/E2E_INSPECTOR.md) — End-to-end verification with the MCP Inspector.

## Development

### Requirements

- Docker (image build, smoke and e2e tests).
- Python 3 (e2e mock servers; standard library only).
- nginx + Perl + `Test::Nginx::Socket` (for the `prove` suite against host nginx).
- Built `.so` files of [`nginx-auth-jwt`](https://github.com/kjdev/nginx-auth-jwt)
  and [`nginx-auth-oauth2-token`](https://github.com/kjdev/nginx-auth-oauth2-token),
  needed by `scripts/lint-examples.sh` and the `prove` suite when run against
  host nginx.

### Tests

```sh
# Build the image (smoke and e2e run against it).
docker build -t nginx-mcp-resource:dev .

# Validate the example configs with `nginx -t`.
scripts/lint-examples.sh

# curl-based smoke test against the image (jwt + introspect, both TLS modes).
./test/smoke/run-smoke.sh all

# End-to-end test: minted tokens + stdlib-Python mock AS/backend.
./test/e2e/run-e2e.sh all

# Test::Nginx::Socket integration suite (point it at the built modules first).
# TEST_NGINX_SERVROOT is required: Test::Nginx::Util defaults to the fixed
# relative path `t/servroot`, which predates the test/prove/ layout and would
# otherwise recreate a stray, untracked `t/` directory at the repo root.
TEST_NGINX_LOAD_MODULES="/path/to/ngx_http_auth_jwt_module.so /path/to/ngx_http_auth_oauth2_token_module.so" \
  TEST_NGINX_SERVROOT=/tmp/servroot \
  TEST_NGINX_HTML_DIR=/tmp/servroot/html \
  prove -r test/prove
```

### Continuous integration

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) runs lint + e2e + smoke
on every push and pull request, reusing the production image. The Test::Nginx
(`prove`) suite is an opt-in job triggered manually via `workflow_dispatch`.
