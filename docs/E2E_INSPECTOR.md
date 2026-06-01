# MCP Inspector E2E Verification Guide

This document walks through running `nginx-mcp-resource` (Resource Server)
end-to-end against either the official **MCP Inspector**
([modelcontextprotocol/inspector][insp]) or an equivalent tool (curl), to
confirm that the MCP Authorization spec flow works as expected.

It satisfies the following Phase A acceptance criteria:

- "Bring nginx up on a real host and manually verify with `curl -i` that the
  headers are compatible with MCP client implementations."
- "Connect from the official MCP inspector
  (https://github.com/modelcontextprotocol/inspector) or an equivalent tool
  and verify the authentication flow works as expected (both patterns)."

[insp]: https://github.com/modelcontextprotocol/inspector

## What we verify

| Aspect | Tool | Acceptance items |
|---|---|---|
| `WWW-Authenticate` on 401 / 403 is MCP-format (single header) | `curl -i` | All JWT 8 items + introspect 6 items |
| `/.well-known/oauth-protected-resource` matches RFC 9728 | `curl` | JWT (1) / introspect (PRM) |
| Upstream never sees the Authorization header (no token passthrough) | `curl` + echo backend's `X-Echo-Authorization` | JWT (7) / introspect (5) |
| Inspector can handshake with the RS over MCP Streamable HTTP | `npx @modelcontextprotocol/inspector --cli` | Inspector connectivity |
| Full OAuth 2.1 discovery (PRM → AS Metadata → DCR → Auth → token) | Inspector GUI + a real AS (Keycloak etc.) | Inspector full flow |

The simple track (curl + Inspector CLI) is automated under
`test/e2e/host/` and runs even in sandboxes without Docker. The full OAuth
flow requires GUI interaction and a real AS, so this guide documents the
procedure rather than automating it.

## Topology

```
Inspector / curl
      │
      │  HTTP
      ▼
┌─────────────────────────────┐
│ nginx-mcp-resource (RS)     │  ← system under test
│   examples/ snippets        │
│   or :dev container         │
└─────────────────────────────┘
      │ proxy_pass / introspect
      ├──────────────► echo backend (Python, port 18280)
      │                └─ returns the upstream-visible Authorization
      │                   via X-Echo-Authorization
      │
      └──────────────► mock AS (Python, port 18281)  ← introspect mode only
                       └─ /introspect: deterministic, keyed off token
                       └─ /.well-known/oauth-authorization-server:
                          RFC 8414 AS Metadata stub
```

Three Python helpers under `test/e2e/servers/`:

- `backend.py` — echo backend
- `as_mock.py` — mock AS (introspection + AS Metadata)
- `gen_jwt.py` — HS256 JWT minter matched to the test JWKS

## Prerequisites

- nginx >= 1.18 (`/usr/bin/nginx`)
- Pre-built `nginx-auth-jwt` 0.13.1+ `.so` (default path:
  `../nginx-auth-jwt/build/fedora/ngx_http_auth_jwt_module.so`)
- Pre-built `nginx-auth-oauth2-token` 0.4.0+ `.so` (same `build/fedora/`)
- Python 3.10+
- `curl`
- (Inspector CLI) `node`, `npx`, npm registry reachable
- (Docker track) `nginx-mcp-resource:dev` image and access to the Docker daemon

## 1. Host-direct nginx (recommended for the simple track)

For sandboxes / CI where the Docker daemon is not available. We load the
pre-built module `.so` files, render the config templates under
`test/e2e/host/` via envsubst, and run `nginx -p ... -c ...`.

### 1.1 curl-based assertions over the full acceptance criteria

JWT mode (all 8 acceptance items):

```bash
bash test/e2e/host/jwt.sh
```

Expected tail:

```
==== host e2e summary: 25 passed, 0 failed ====
```

Introspection mode (all 6 acceptance items):

```bash
bash test/e2e/host/introspect.sh
```

Expected tail:

```
==== host e2e summary: 23 passed, 0 failed ====
```

Logs land under `/tmp/e2e-host-jwt/` and `/tmp/e2e-host-introspect/`:

- `nginx.conf` — rendered config after envsubst
- `error.log` / `access.log` — nginx logs
- `backend.log` / `as.log` — Python server logs

### 1.2 Handshake check with Inspector CLI

`npx @modelcontextprotocol/inspector --cli` invokes `tools/list` against
`/mcp`. A wrapper boots RS / backend / mock AS first:

```bash
bash test/e2e/host/inspector.sh jwt          # JWT mode only
bash test/e2e/host/inspector.sh introspect   # introspect mode only
bash test/e2e/host/inspector.sh all          # both
```

Expected behavior:

- **No-token call**: Inspector POSTs `/mcp`, receives `401 Authorization
  Required`, and emits `Streamable HTTP error: Error POSTing to endpoint:
  ... 401 ...`. This confirms the MCP transport layer in Inspector did pick
  up our 401 + MCP-format `WWW-Authenticate` (the CLI mode does not drive
  the full PRM → OAuth discovery chain, so it terminates here).
- **Valid-token call**: Inspector POSTs with a Bearer header, the RS returns
  200, and Inspector fails JSON-RPC schema validation (`Invalid input:
  expected "2.0"`, etc.) because the echo backend is not a real MCP server.
  This is the expected outcome and demonstrates that the RS passed the
  authorization decision and proxied to the upstream.

Inspector output goes to `inspector-no-token.out` / `inspector-valid.out`
under `/tmp/e2e-inspector-jwt/` and `/tmp/e2e-inspector-introspect/`.

The npm cache is created under `$TMPDIR/claude-npm-cache` (override with
the `NPM_CACHE` environment variable). The first run downloads from npm
registry and takes 1–2 minutes.

## 2. Running against the nginx-mcp-resource:dev container

If the Docker daemon is available, the env-driven container image runs the
same suite (`test/e2e/jwt.sh`, `test/e2e/introspect.sh`):

```bash
task docker:build
bash test/e2e/run-e2e.sh jwt
bash test/e2e/run-e2e.sh introspect
bash test/e2e/run-e2e.sh all
```

The container resolves host loopback via
`--add-host=host.docker.internal:host-gateway`. Python servers still listen
on 18280 (backend) / 18281 (mock AS) on the host, same as the host-direct
track.

For each scenario the driver:

1. Starts the RS via `docker run -d --rm -p 18180:80`
2. Starts `python3 servers/backend.py --port 18280`
3. (introspect) Starts `python3 servers/as_mock.py --port 18281 ...`
4. Asserts the acceptance criteria with curl
5. Cleans up (`docker rm -f` + Python kill)

Assertion items are nearly identical to the host driver, but the docker
driver also checks "no `realm=` leakage", "no `error=\"invalid_token\"`
leakage" and that the X-Echo-Authorization header is present, so the case
count is higher (JWT 28 / introspect 25, all passing).

## 3. Full OAuth flow with the Inspector GUI and a real AS

To exercise Inspector's **automated OAuth discovery** (PRM → AS Metadata →
DCR → Auth code + PKCE → token → `/mcp` with Bearer) you need the GUI mode
and a **real Authorization Server** that supports DCR. This guide only
describes the setup; observe results by hand.

### 3.1 Launch Inspector in GUI mode

```bash
npm_config_cache=$TMPDIR/claude-npm-cache \
    npx -y @modelcontextprotocol/inspector
```

The browser opens at `http://127.0.0.1:6274`.

### 3.2 Connection settings

| Field | Value |
|---|---|
| Transport | Streamable HTTP |
| Server URL | `http://127.0.0.1:18180/mcp` |
| Authentication | (leave blank) |

Pressing **Connect** triggers Inspector to:

1. POST `/mcp` → receive 401 + `WWW-Authenticate`
2. Extract `resource_metadata` URL from `WWW-Authenticate`
3. Fetch PRM JSON, read `authorization_servers[0]`, discover AS Metadata
4. DCR against the AS Metadata `registration_endpoint`
5. Browser pop to `authorization_endpoint` (Auth code + PKCE)
6. Token exchange at `token_endpoint`
7. Retry POST `/mcp` with Bearer → 200 (response from the MCP backend)

Steps 4–6 require a real AS. `as_mock.py` only serves AS Metadata, not the
DCR / authorize / token endpoints, so Inspector errors out at that point.

### 3.3 Real-AS example (Keycloak)

Keycloak supports DCR (RFC 7591) and Auth code + PKCE, and pairs well with
Inspector.

Minimal setup:

```bash
docker run --rm -d --name kc -p 8080:8080 \
    -e KEYCLOAK_ADMIN=admin -e KEYCLOAK_ADMIN_PASSWORD=admin \
    quay.io/keycloak/keycloak:latest start-dev

# In the admin console (http://localhost:8080):
#   1. Create realm "mcp"
#   2. Add client scope "mcp:read" and register it as a default scope
#   3. Create user (alice / password)
#   4. Enable anonymous Client Registration
```

`nginx-mcp-resource` side:

```yaml
# examples/compose.jwt.yml (JWT pattern)
environment:
  MCP_AUTHORIZATION_SERVER: http://host.docker.internal:8080/realms/mcp
  MCP_JWT_KEY_FILE: /etc/nginx/keys/jwks.json
  # Fetch JWKS from
  # http://localhost:8080/realms/mcp/protocol/openid-connect/certs and
  # mount it
```

Connecting from Inspector with `http://127.0.0.1:18180/mcp` redirects to
Keycloak's login page. Sign in as alice/password and Inspector receives a
token and starts issuing MCP requests.

> **Note**: Phase A scopes the Resource Server side only; the AS is out of
> scope. This guide demonstrates that the RS works with arbitrary external
> ASs (Keycloak, Hydra, Authentik, Okta, Auth0, etc.). Refer to each AS
> documentation for the corresponding setup.

## Acceptance checklist

A clean run of `test/e2e/host/jwt.sh` + `test/e2e/host/introspect.sh`
satisfies:

### JWT pattern
- [x] `/.well-known/oauth-protected-resource` returns RFC 9728 §3.1 required fields
- [x] Missing Authorization → 401 + MCP-format `WWW-Authenticate`
- [x] Bad signature / expired JWT → 401 + MCP-format
- [x] Wrong audience → 401 + MCP-format
- [x] Insufficient scope → **403** + `error="insufficient_scope"`
- [x] Valid JWT → 200 + upstream body
- [x] Upstream Authorization stripped (`X-Echo-Authorization` empty)
- [x] `WWW-Authenticate` is single MCP-format header (no `realm=` leakage, no duplicates)

### Introspection pattern
- [x] `active: false` → 401 + MCP-format (no `error="invalid_token"` concat)
- [x] Wrong audience → 401 + MCP-format
- [x] Insufficient scope → **403** + `error="insufficient_scope"`
- [x] Audience match + sufficient scope → 200 + upstream body
- [x] Upstream Authorization stripped
- [x] Cache enabled, repeated valid requests still succeed (consecutive 200s)

### Inspector connectivity
- [x] Inspector → RS handshake succeeds over MCP Streamable HTTP transport
- [x] Inspector's transport layer recognizes the 401
- [x] Bearer-bearing call returns 200; Inspector receives the upstream
      response (schema validation fails because the backend is a stub)
- [ ] Full OAuth discovery (PRM → AS Metadata → DCR → Auth → token)
      → manual verification with the GUI + a real AS (§3 above)

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `nginx -t` reports `invalid number of arguments in "map" directive` | envsubst expanded nginx variables (`$mcp_*` etc.) to empty | Pass an explicit allowlist: `envsubst '${VAR1} ${VAR2} ...'` (see `envsubst_vars` in `test/e2e/host/lib.sh`) |
| nginx start fails with `/var/log/nginx/error.log: Read-only file system` | Compile-in error log path is not writable | Override with `nginx -e <writable-path>` |
| Python server "did not become ready" on the first curl | First `wait_for_http` retry fires before listen completes | Expected. 10 retries normally finish within 0.3–1 s |
| Inspector CLI: `missing required argument 'target'` | `--server-url` is documented but the CLI mode actually expects a positional target | `npx ... --cli <URL> --transport http --method tools/list` |
| Inspector CLI: `Streamable HTTP error: ... 401` | RS returned 401 and Inspector did not retry | Expected for CLI mode. PRM discovery only runs in GUI mode |
| Inspector CLI valid-token call: `Invalid input: expected "2.0"` | The echo backend is not a real MCP server | Expected. Confirms only that authorization passed and the upstream was proxied |
| Docker driver `permission denied while trying to connect to the docker API` | Sandbox or other env blocks docker.sock writes | Use the host driver in `test/e2e/host/` |

## File index

- `test/e2e/host/jwt.sh` — host JWT-mode driver
- `test/e2e/host/introspect.sh` — host introspect-mode driver
- `test/e2e/host/inspector.sh` — Inspector CLI wrapper
- `test/e2e/host/lib.sh` — shared (envsubst / process mgmt / assertions)
- `test/e2e/host/nginx-{jwt,introspect}.conf.template` — host nginx templates
- `test/e2e/jwt.sh` / `test/e2e/introspect.sh` — Docker-based drivers
- `test/e2e/run-e2e.sh` — Docker-based runner
- `test/e2e/servers/{backend,as_mock,gen_jwt}.py` — Python helpers
- `test/e2e/fixtures/` — JWKS / certs / secrets
