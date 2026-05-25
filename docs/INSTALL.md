# Installation

Two ways to deploy `nginx-mcp-resource`.

| Form | Setup cost | When to choose |
|---|---|---|
| [Container image](#a-container-image) | Low (Docker only) | Running under Compose / Kubernetes |
| [Bare nginx + snippets](#b-bare-nginx--snippets) | Medium (dependent modules built locally) | Embedding into an existing nginx / deploying directly on a VM |

Configuration walk-throughs live in [EXAMPLES.md](EXAMPLES.md). Security
prerequisites are listed in [SECURITY.md](SECURITY.md).

## Choosing an auth mode

| Mode | Token format | Module used |
|---|---|---|
| `jwt` | Self-contained JWT (RFC 7519) | `nginx-auth-jwt` 0.13.1+ |
| `introspect` | Opaque token (verified via RFC 7662 introspection) | `nginx-auth-oauth2-token` 0.4.0+ |

The choice follows the issuance format of the AS. Pick `jwt` if the AS
issues JWS-formatted JWTs, `introspect` for opaque tokens. The two modes can
coexist in one nginx, but the examples in this repository keep them separate.

## A. Container image

### A.1 Requirements

- Docker (a Buildx-capable version is recommended)
- Upstream MCP backend running and reachable
- JWT mode: `jwks.json` available on the host
- Introspection mode: AS-issued client secret as a plain-text file

### A.2 Build the image

```sh
docker build -t nginx-mcp-resource:dev .
```

Or with `task` (go-task):

```sh
task docker:build
```

What the build does:

1. Multi-stage: pull `.so` files from `ghcr.io/kjdev/nginx-auth-jwt/nginx:0.13.1`
   and `ghcr.io/kjdev/nginx-auth-oauth2-token/nginx:0.4.0`.
2. Add `jansson` (runtime dependency of auth_jwt) and `jq` (used by the
   entrypoint) to the `nginx:alpine` base.
3. Copy `conf/` to `/etc/nginx/mcp-conf/`.
4. Copy `build/docker/templates/` to `/etc/nginx/templates/`.
5. Copy `build/docker/docker-entrypoint.d/` to `/docker-entrypoint.d/`.
6. Configure the envsubst filter (`^MCP_`).

For details see [`Dockerfile`](../Dockerfile).

### A.3 Run

Minimal `docker run` (JWT mode, TLS terminated at an upstream LB):

```sh
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

For Docker Compose, see
[EXAMPLES.md](EXAMPLES.md#docker-compose--jwt) and the files under
[`examples/`](../examples/).

### A.4 Required environment variables

#### Common

| Variable | Description | Example |
|---|---|---|
| `MCP_AUTH_MODE` | `jwt` or `introspect` | `jwt` |
| `MCP_SERVER_NAME` | The `server_name` directive | `mcp.example.com` |
| `MCP_CANONICAL_URI` | RS canonical URI (RFC 8707 audience) | `https://mcp.example.com/mcp` |
| `MCP_METADATA_URI` | Absolute URI of the RFC 9728 metadata document | `https://mcp.example.com/.well-known/oauth-protected-resource` |
| `MCP_AUTHORIZATION_SERVER` | `authorization_servers[0]` in metadata | `https://auth.example.com` |
| `MCP_REQUIRED_SCOPE` | Required scope advertised in challenges | `mcp:read` |
| `MCP_SCOPES_SUPPORTED` | `scopes_supported` in metadata (comma-separated) | `mcp:read,mcp:write` |
| `MCP_BACKEND` | Upstream MCP backend | `mcp-backend:8080` |

#### TLS

| Variable | Description |
|---|---|
| `MCP_TLS` | `on` / `off` (default `off`) |
| `MCP_SSL_CERT_FILE` | Required when `MCP_TLS=on` |
| `MCP_SSL_CERT_KEY_FILE` | Required when `MCP_TLS=on` |

#### JWT mode only

| Variable | Description |
|---|---|
| `MCP_JWT_KEY_FILE` | Path to JWKS (required) |

#### Introspection mode only

| Variable | Description |
|---|---|
| `MCP_INTROSPECT_ENDPOINT` | AS's RFC 7662 introspection endpoint (required) |
| `MCP_CLIENT_ID` | Required |
| `MCP_CLIENT_SECRET_FILE` | Path to the client secret file (required). Passing the secret via an environment variable is not supported. |
| `MCP_INTROSPECT_CACHE_MAX_TTL` | Default `60s` |
| `MCP_RESOLVER` | Required when the AS endpoint is an external FQDN (e.g. `127.0.0.11`) |

#### Optional

| Variable | Default | Description |
|---|---|---|
| `MCP_LISTEN_PORT` | 443 when `MCP_TLS=on`, otherwise 80 | Listen port |
| `MCP_RESOURCE_PATH` | `/mcp` | Path of the protected MCP location |
| `MCP_BEARER_METHODS_SUPPORTED` | `header` | Metadata value |
| `MCP_WORKER_PROCESSES` | `auto` | `worker_processes` |

A missing required variable causes the entrypoint
([`build/docker/docker-entrypoint.d/05-mcp-validate-env.sh`](../build/docker/docker-entrypoint.d/05-mcp-validate-env.sh))
to exit with `MCP_xxx is required but not set`. See
[TROUBLESHOOTING.md](TROUBLESHOOTING.md) if you get stuck.

### A.5 Verify

```sh
# health
curl -i http://127.0.0.1:8080/healthz

# Protected Resource Metadata
curl -i http://127.0.0.1:8080/.well-known/oauth-protected-resource

# no token -> 401 + MCP-format WWW-Authenticate
curl -i http://127.0.0.1:8080/mcp
```

For the full curl-based smoke suite run `task docker:smoke`
(`test/smoke/run-smoke.sh` exercises both JWT and Introspection modes).

## B. Bare nginx + snippets

### B.1 Requirements

| Component | Minimum |
|---|---|
| nginx core | A regular build supporting `error_page` / `add_header` / `map` (1.18+ recommended) |
| [`nginx-auth-jwt`](https://github.com/kjdev/nginx-auth-jwt) | **0.13.1** (`auth_jwt_www_authenticate` is required) |
| [`nginx-auth-oauth2-token`](https://github.com/kjdev/nginx-auth-oauth2-token) | **0.4.0** (`auth_oauth2_token_www_authenticate` is required) |
| jansson | Runtime dependency of nginx-auth-jwt |

No additional modules (e.g. `headers-more-nginx-module`) are needed.

### B.2 Build the dependent modules

Both modules ship as dynamic modules (`.so`). See each upstream README for
the canonical build instructions. The outline is:

```sh
# nginx-auth-jwt
git clone --branch 0.13.1 https://github.com/kjdev/nginx-auth-jwt.git
cd nginx-auth-jwt
# Follow the OS-specific README (e.g. `dnf install -y jansson-devel; make build`).
# Output: build/<dist>/ngx_http_auth_jwt_module.so

# nginx-auth-oauth2-token
git clone --branch 0.4.0 https://github.com/kjdev/nginx-auth-oauth2-token.git
cd nginx-auth-oauth2-token
# Follow the OS-specific README.
# Output: build/<dist>/ngx_http_auth_oauth2_token_module.so
```

Drop the resulting `.so` files into nginx's module directory (commonly
`/usr/lib/nginx/modules/`). If you use the container image, the `Dockerfile`
copies pre-built `.so` files from `ghcr.io/kjdev/...`, so no local build is
required.

> **Note**: a dynamic module only loads when its binary matches the nginx
> core ABI. Build the modules against the same nginx version and build
> options as the packaged nginx you are running.

### B.3 Place the snippets

Place `conf/` somewhere reachable from the nginx prefix as a relative path.
For example, under `/etc/nginx/conf/`:

```
/etc/nginx/
├── nginx.conf
└── conf/
    ├── mcp-401-handler.conf
    ├── mcp-403-handler.conf
    ├── mcp-metadata.conf
    ├── mcp-resource-introspect.conf
    └── mcp-resource-jwt.conf
```

The `include conf/mcp-*.conf;` paths are resolved against the nginx prefix
(check `nginx -V` for `--prefix=`).

### B.4 Assemble `nginx.conf`

The fastest path is to copy
[EXAMPLES.md → Bare nginx + JWT](EXAMPLES.md#bare-nginx--jwt) or the files
[`examples/nginx-jwt.conf`](../examples/nginx-jwt.conf) /
[`examples/nginx-introspect.conf`](../examples/nginx-introspect.conf) and
edit them.

Main customisation points:

| Field | Where to edit |
|---|---|
| Module `.so` path | `load_module /usr/lib/nginx/modules/...;` |
| Canonical URI / metadata URI | The `default` values of the `map "" $mcp_*` declarations |
| Required scope | `$mcp_required_scope` and the regex inside `map $jwt_scope ...` / `map $oauth2_scope ...` |
| TLS certificate | `ssl_certificate` / `ssl_certificate_key` |
| Upstream backend | `upstream mcp_backend { server ...; }` |
| JWT keys (JWT mode) | `auth_jwt_key_file` |
| AS introspection endpoint (introspection mode) | `proxy_pass` inside `location = /_introspect` |

### B.5 Syntax check

Use the standard `nginx -t`:

```sh
sudo nginx -t -c /etc/nginx/nginx.conf
```

Inside the repository, `task lint` runs `nginx -t` against
`examples/nginx-*.conf` using a disposable sandbox (self-signed certificate,
dummy JWKS, dummy client secret). See
[`scripts/lint-examples.sh`](../scripts/lint-examples.sh).

### B.6 Integration tests (optional)

`Test::Nginx::Socket`-based integration tests live under `t/`. They require
Perl and the relevant CPAN modules, but are recommended when modifying the
snippets.

```sh
task test           # run prove over t/
task test file=t/02-no-token.t verbose=1   # single test
```

`Taskfile.yml` expects `TEST_NGINX_LOAD_MODULES` to point at locally built
`.so` files. The default looks under
`{PROJECT_DIR}/../nginx-auth-jwt/build/fedora/...`; adjust `Taskfile.yml` or
override via an environment variable as needed.

## Upgrades

| Target | Procedure |
|---|---|
| Container image | `docker pull` the new tag (or rebuild locally) and restart the container |
| Bare nginx modules | Overwrite the `.so` → `nginx -t` → `nginx -s reload` |
| Snippets (`conf/`) | Update the repository → re-deploy `conf/` → `nginx -t` → `nginx -s reload` |

The snippets rely on directives introduced in nginx-auth-jwt 0.13.1 and
nginx-auth-oauth2-token 0.4.0 (notably `auth_*_www_authenticate`). If you
must downgrade a dependent module, revert to an older snippet revision that
does not use those directives.

## See also

- Configuration examples: [EXAMPLES.md](EXAMPLES.md)
- Security notes: [SECURITY.md](SECURITY.md)
- Troubleshooting: [TROUBLESHOOTING.md](TROUBLESHOOTING.md)
- README: [`../README.md`](../README.md)
