# Configuration Examples

Common deployment patterns for `nginx-mcp-resource`. Complete configuration
files live under `examples/`; this document summarises the moving parts and
helps pick a pattern.

## Choosing a pattern

| Deployment | Auth mode | Recommended starting point |
|---|---|---|
| Embed into an existing nginx | JWT verification | [Bare nginx + JWT](#bare-nginx--jwt) |
| Embed into an existing nginx | RFC 7662 introspection | [Bare nginx + Introspection](#bare-nginx--introspection) |
| Run as a container | JWT verification | [Docker Compose + JWT](#docker-compose--jwt) |
| Run as a container | RFC 7662 introspection | [Docker Compose + Introspection](#docker-compose--introspection) |
| Run as a container | RFC 7662 introspection + per-subject rate limiting | [Docker Compose + Introspection + Rate limiting](#docker-compose--introspection--rate-limiting) |

Choosing between JWT and introspection depends on what the AS issues; see
[INSTALL.md](INSTALL.md#choosing-an-auth-mode).

## Bare nginx + JWT

Complete file: [`examples/nginx-jwt.conf`](../examples/nginx-jwt.conf).

### Key elements

- Load the `nginx-auth-jwt` 0.13.1+ `.so` with `load_module`.
- Use `auth_jwt_claim_set $jwt_scope scope;` to extract the `scope` claim
  into a variable.
- Declare `$mcp_canonical_uri`, `$mcp_canonical_uri_json`,
  `$mcp_metadata_uri`, `$mcp_required_scope`, etc. with `map`.
- `include` the shared snippets `conf/mcp-metadata.conf`,
  `conf/mcp-401-handler.conf`, `conf/mcp-403-handler.conf` in the `server`
  scope.
- In `location /mcp`, `include conf/mcp-resource-jwt.conf` and add
  `proxy_set_header Authorization "";` to block token passthrough.

### Minimal configuration

```nginx
load_module /usr/lib/nginx/modules/ngx_http_auth_jwt_module.so;

worker_processes 1;
events {}

http {
    map "" $mcp_canonical_uri              { default "https://mcp.example.com/mcp"; }
    map "" $mcp_canonical_uri_json         { default '"https://mcp.example.com/mcp"'; }
    map "" $mcp_metadata_uri               { default "https://mcp.example.com/.well-known/oauth-protected-resource"; }
    map "" $mcp_required_scope             { default "mcp:read"; }
    map "" $mcp_authorization_servers_json { default '["https://auth.example.com"]'; }
    map "" $mcp_scopes_supported_json      { default '["mcp:read","mcp:write"]'; }
    map "" $mcp_bearer_methods_json        { default '["header"]'; }

    auth_jwt_claim_set $jwt_scope scope;
    map $jwt_scope $mcp_has_required_scope {
        default 0;
        "~(^|\s)mcp:read(\s|$)" 1;
    }

    upstream mcp_backend { server 127.0.0.1:8080; }

    server {
        listen 443 ssl;
        http2 on;
        server_name mcp.example.com;

        ssl_certificate     /etc/nginx/certs/server.crt;
        ssl_certificate_key /etc/nginx/certs/server.key;

        auth_jwt_key_file /etc/nginx/keys/jwks.json;

        include conf/mcp-metadata.conf;
        include conf/mcp-401-handler.conf;
        include conf/mcp-403-handler.conf;

        location /mcp {
            include conf/mcp-resource-jwt.conf;
            proxy_set_header Authorization "";
            proxy_pass http://mcp_backend;
        }
    }
}
```

### Customisation points

| Field | Where to edit |
|---|---|
| Canonical URI | Both `$mcp_canonical_uri` and `$mcp_canonical_uri_json` (must include the surrounding quotes) |
| Required scope | `$mcp_required_scope` and the regular expression in `map $jwt_scope $mcp_has_required_scope` |
| JWKS | `auth_jwt_key_file` |
| Upstream backend | `upstream mcp_backend { ... }` |
| TLS certificate | `ssl_certificate` / `ssl_certificate_key` |

### When `aud` is a JSON array

Replace the trailing line of `conf/mcp-resource-jwt.conf`
(`auth_jwt_require_claim aud eq $mcp_canonical_uri_json;`) with one of:

```nginx
# match the first element
auth_jwt_require_claim .aud[0] eq $mcp_canonical_uri_json;

# or check for set intersection
auth_jwt_require_claim aud any json=["https://mcp.example.com/mcp"];
```

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md#symptom-audience-binding-does-not-seem-to-fire)
and the V2 section of the developer guide for details.

## Bare nginx + Introspection

Complete file: [`examples/nginx-introspect.conf`](../examples/nginx-introspect.conf).

### Key elements

- Load the `nginx-auth-oauth2-token` 0.4.0+ `.so` with `load_module`.
- Configure client authentication to the AS with
  `auth_oauth2_token_client_id` and `auth_oauth2_token_client_secret_file`.
- Use `auth_oauth2_token_claim_set` to lift `aud` / `scope` from the
  introspection response into variables.
- Provide an internal proxy with
  `location = /_introspect { internal; proxy_pass <AS endpoint>; }` so that
  `conf/mcp-resource-introspect.conf` can reach it.
- Turn on `auth_oauth2_token_introspect_cache` in production.

### Minimal configuration

```nginx
load_module /usr/lib/nginx/modules/ngx_http_auth_oauth2_token_module.so;

worker_processes 1;
events {}

http {
    auth_oauth2_token_client_id          mcp-rs;
    auth_oauth2_token_client_secret_file /etc/nginx/secrets/rs.secret;

    auth_oauth2_token_claim_set $oauth2_aud   aud;
    auth_oauth2_token_claim_set $oauth2_scope scope;

    map "" $mcp_canonical_uri              { default "https://mcp.example.com/mcp"; }
    map "" $mcp_metadata_uri               { default "https://mcp.example.com/.well-known/oauth-protected-resource"; }
    map "" $mcp_required_scope             { default "mcp:read"; }
    map "" $mcp_authorization_servers_json { default '["https://auth.example.com"]'; }
    map "" $mcp_scopes_supported_json      { default '["mcp:read","mcp:write"]'; }
    map "" $mcp_bearer_methods_json        { default '["header"]'; }

    map $oauth2_aud $mcp_aud_ok {
        default 0;
        "https://mcp.example.com/mcp" 1;
    }
    map $oauth2_scope $mcp_has_required_scope {
        default 0;
        "~(^|\s)mcp:read(\s|$)" 1;
    }

    auth_oauth2_token_introspect_cache zone=introspect:10m max_ttl=60s;

    upstream mcp_backend { server 127.0.0.1:8080; }

    server {
        listen 443 ssl;
        http2 on;
        server_name mcp.example.com;

        ssl_certificate     /etc/nginx/certs/server.crt;
        ssl_certificate_key /etc/nginx/certs/server.key;

        location = /_introspect {
            internal;
            proxy_pass https://auth.example.com/oauth2/introspect;
        }

        include conf/mcp-metadata.conf;
        include conf/mcp-401-handler.conf;
        include conf/mcp-403-handler.conf;

        location /mcp {
            include conf/mcp-resource-introspect.conf;
            proxy_set_header Authorization "";
            proxy_pass http://mcp_backend;
        }
    }
}
```

### Customisation points

| Field | Where to edit |
|---|---|
| Canonical URI | `$mcp_canonical_uri` and the right-hand side of `map $oauth2_aud $mcp_aud_ok` |
| Required scope | `$mcp_required_scope` and the regular expression in `map $oauth2_scope $mcp_has_required_scope` |
| AS introspection URL | `proxy_pass` inside `location = /_introspect` |
| Client authentication | `auth_oauth2_token_client_id` / `auth_oauth2_token_client_secret_file` |
| Cache lifetime | `auth_oauth2_token_introspect_cache ... max_ttl=...` |

### Avoid the "always 403" pitfall on scope checks

Implementing the scope check with `if ($var = 0) { return 403; }` runs the
test in the REWRITE phase, before the ACCESS-phase introspection populates
the variables. The map then falls through to its default and every request
is rejected. Always use `auth_oauth2_token_require`:

```nginx
auth_oauth2_token_require $mcp_aud_ok;                       # 401 on failure
auth_oauth2_token_require $mcp_has_required_scope error=403; # 403 on failure
```

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md#symptom-tokens-with-the-required-scope-still-get-403-introspection)
and the V4 section of the developer guide.

## Docker Compose + JWT

Complete file: [`examples/compose.jwt.yml`](../examples/compose.jwt.yml).

### Prerequisites

- Place the AS's JWKS at `./keys/jwks.json` (mounted read-only).
- Ensure the upstream MCP backend listens on `host.docker.internal:8080`
  (override `MCP_BACKEND` otherwise).

### Run

```sh
docker compose -f examples/compose.jwt.yml up
```

### Main environment variables

| Variable | Example | Required |
|---|---|---|
| `MCP_AUTH_MODE` | `jwt` | yes |
| `MCP_TLS` | `off` | (LB-terminated TLS assumed) |
| `MCP_SERVER_NAME` | `mcp.example.com` | yes |
| `MCP_CANONICAL_URI` | `https://mcp.example.com/mcp` | yes |
| `MCP_METADATA_URI` | `https://mcp.example.com/.well-known/oauth-protected-resource` | yes |
| `MCP_AUTHORIZATION_SERVER` | `https://auth.example.com` | yes |
| `MCP_REQUIRED_SCOPE` | `mcp:read` | yes |
| `MCP_SCOPES_SUPPORTED` | `mcp:read,mcp:write` | yes |
| `MCP_BACKEND` | `host.docker.internal:8080` | yes |
| `MCP_JWT_KEY_FILE` | `/etc/nginx/keys/jwks.json` | yes (JWT mode) |

### Terminating TLS in nginx itself

Switch `MCP_TLS=on` and mount the certificate read-only:

```yaml
environment:
  MCP_TLS: "on"
  MCP_SSL_CERT_FILE: /etc/nginx/certs/server.crt
  MCP_SSL_CERT_KEY_FILE: /etc/nginx/certs/server.key
volumes:
  - ./certs:/etc/nginx/certs:ro
```

## Docker Compose + Introspection

Complete file: [`examples/compose.introspect.yml`](../examples/compose.introspect.yml).

### Prerequisites

- Write the client secret issued by the AS into `./secrets/rs.secret` as a
  **single line with no trailing newline**.
- Confirm the upstream MCP backend is reachable (`MCP_BACKEND`).
- If the AS's introspection endpoint is an **external FQDN**, also set
  `MCP_RESOLVER` (Docker's embedded DNS is `127.0.0.11`).

### Run

```sh
docker compose -f examples/compose.introspect.yml up
```

### Introspection-specific environment variables

| Variable | Example | Required |
|---|---|---|
| `MCP_INTROSPECT_ENDPOINT` | `https://auth.example.com/oauth2/introspect` | yes |
| `MCP_CLIENT_ID` | `mcp-rs` | yes |
| `MCP_CLIENT_SECRET_FILE` | `/run/secrets/rs.secret` | yes |
| `MCP_INTROSPECT_CACHE_MAX_TTL` | `60s` | (defaults to `60s`) |
| `MCP_RESOLVER` | `127.0.0.11` | (when reaching an external FQDN) |

`MCP_CLIENT_SECRET_FILE` accepts a **file path only** — passing the secret
through an environment variable is unsupported (it would leak via
`docker inspect`). See
[SECURITY.md](SECURITY.md#8-handle-the-client-secret-carefully-introspection-mode-only).

## Docker Compose + Introspection + Rate limiting

Complete file: [`examples/compose.ratelimit.yml`](../examples/compose.ratelimit.yml).

Adds per-subject rate limiting via
[nginx-ratelimit](https://github.com/kjdev/nginx-ratelimit) on top of the
introspection setup above, keyed on the authenticated subject
(`$oauth2_token_sub`). Opt-in (`MCP_RATELIMIT_ENABLED=off` by default).
`jwt` mode is supported the same way, keyed on the `sub` claim instead
(requires `nginx-auth-jwt` >= 0.14.2 — see the bare nginx example below).

### Prerequisites

Same as [Docker Compose + Introspection](#docker-compose--introspection),
plus a reachable Redis/Valkey instance (the compose file starts one as the
`redis` service).

### Run

```sh
docker compose -f examples/compose.ratelimit.yml up --build
```

### Rate limiting environment variables

| Variable | Example | Required |
|---|---|---|
| `MCP_RATELIMIT_ENABLED` | `on` | yes (opt-in, default `off`) |
| `MCP_RATELIMIT_REDIS` | `redis:6379` | yes (when `on`) |
| `MCP_RATELIMIT_RATE` | `100r/m` | yes (when `on`) |
| `MCP_RATELIMIT_BURST` | `20` | no |
| `MCP_RATELIMIT_ALGO` | `fixed_window` | no (default `fixed_window`) |
| `MCP_RATELIMIT_ON_ERROR` | `deny` | no (default `deny`, fail-close) |
| `MCP_RATELIMIT_REDIS_PASSWORD_FILE` | `/run/secrets/redis.secret` | no |

### Bare nginx equivalent

The container's generated config follows this pattern; adapt it directly if
embedding into an existing nginx instead:

```nginx
# nginx-ratelimit must be load_module'd BEFORE the auth module: dynamic
# modules run their PREACCESS phase handler in the reverse order they are
# registered, so loading ratelimit first makes auth_oauth2_token's handler
# run first and populate $oauth2_token_sub before ratelimit reads it.
load_module /usr/lib/nginx/modules/ngx_http_ratelimit_module.so;
load_module /usr/lib/nginx/modules/ngx_http_auth_oauth2_token_module.so;

http {
    upstream mcp_ratelimit_redis {
        server redis:6379;
        keepalive 32;
    }
    ratelimit_zone mcp_peruser key=$oauth2_token_sub rate=100r/m burst=20 algo=fixed_window;

    server {
        location /mcp {
            # Move introspection into PREACCESS so $oauth2_token_sub is
            # resolved before nginx-ratelimit's PREACCESS handler runs
            # (requires nginx-auth-oauth2-token >= 0.5.0).
            auth_oauth2_token_phase preaccess;

            include conf/mcp-resource-introspect.conf;
            ratelimit zone=mcp_peruser;
            ratelimit_pass mcp_ratelimit_redis;
            ratelimit_headers on;
            ratelimit_on_error deny;

            proxy_set_header Authorization "";
            proxy_pass http://mcp_backend;
        }
    }
}
```

For `jwt` mode, key on the `sub` claim instead and move JWT validation into
PREACCESS (requires `nginx-auth-jwt` >= 0.14.2):

```nginx
load_module /usr/lib/nginx/modules/ngx_http_ratelimit_module.so;
load_module /usr/lib/nginx/modules/ngx_http_auth_jwt_module.so;

http {
    auth_jwt_claim_set $jwt_sub sub;

    upstream mcp_ratelimit_redis {
        server redis:6379;
        keepalive 32;
    }
    ratelimit_zone mcp_peruser key=$jwt_sub rate=100r/m burst=20 algo=fixed_window;

    server {
        location /mcp {
            # Move JWT validation into PREACCESS so $jwt_sub is resolved
            # before nginx-ratelimit's PREACCESS handler runs (requires
            # nginx-auth-jwt >= 0.14.2).
            auth_jwt_phase preaccess;

            include conf/mcp-resource-jwt.conf;
            ratelimit zone=mcp_peruser;
            ratelimit_pass mcp_ratelimit_redis;
            ratelimit_headers on;
            ratelimit_on_error deny;

            proxy_set_header Authorization "";
            proxy_pass http://mcp_backend;
        }
    }
}
```

See [SECURITY.md](SECURITY.md#10-rate-limiting-fail-close-behaviour-optional)
for the fail-close default and the empty-key caveat.

## Smoke testing the running RS

`curl` is the quickest way to verify the running configuration.

```sh
# health check
curl -i http://127.0.0.1:8443/healthz

# Protected Resource Metadata
curl -i http://127.0.0.1:8443/.well-known/oauth-protected-resource

# no token -> 401 + MCP-format WWW-Authenticate
curl -i http://127.0.0.1:8443/mcp

# valid token -> 200 (upstream response)
curl -i -H "Authorization: Bearer <token>" http://127.0.0.1:8443/mcp
```

Expected header format:

```
WWW-Authenticate: Bearer resource_metadata="https://.../.well-known/oauth-protected-resource", scope="mcp:read"
```

If multiple `Bearer` parts are comma-joined, see
[TROUBLESHOOTING.md](TROUBLESHOOTING.md#auth-headers-and-status-codes).

## See also

- Installation: [INSTALL.md](INSTALL.md)
- Security notes: [SECURITY.md](SECURITY.md)
- Troubleshooting: [TROUBLESHOOTING.md](TROUBLESHOOTING.md)
