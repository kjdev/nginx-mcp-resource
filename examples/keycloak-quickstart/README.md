# Keycloak quickstart (introspection mode)

A near-one-command example where **Keycloak** is the authorization server and
**nginx-mcp-resource** (the RS) validates the client's token via introspection.

For the narrative walkthrough see
[`docs/GETTING_STARTED.md`](../../docs/GETTING_STARTED.md). This file only
covers the shortest path to run and verify.

## Cast

```
MCP Client ──Bearer token──> mcp-resource (RS) ──pass──> mcp-backend (stub)
(curl/Claude Code)               │ introspection
                                 ▼
                            keycloak (AS)  ← issues / validates tokens
```

| Service | Port (host) | Role |
|---|---|---|
| keycloak | 18080 | Authorization server (admin: admin/admin). Imports `realm-mcp.json` at startup |
| mcp-resource | 8080 | Resource server (this project). Protected endpoint `/mcp` |
| mcp-backend | (internal only) | Stub standing in for a real MCP server |

## Prerequisite

```sh
# Build the image at the repo root (once)
docker build -t nginx-mcp-resource:dev .
```

## Run

```sh
docker compose -f examples/keycloak-quickstart/compose.yml up -d --wait
# Keycloak's realm import takes ~15-30s
```

Confirm the realm is ready:

```sh
curl -sf http://localhost:18080/realms/mcp/.well-known/openid-configuration >/dev/null && echo ready
```

## Verify

```sh
cd examples/keycloak-quickstart

# Get alice's token (password grant, for verification)
TOKEN=$(./get-token.sh)

# (a) no token -> 401
curl -i http://localhost:8080/mcp -d '{"jsonrpc":"2.0","method":"tools/list","id":1}'

# (b) metadata (RFC 9728)
curl -s http://localhost:8080/.well-known/oauth-protected-resource

# (c) valid token -> 200 + backend response
curl -s http://localhost:8080/mcp \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"jsonrpc":"2.0","method":"tools/list","id":1}'

# (d) token without mcp:read -> 403 insufficient_scope
NOREAD=$(./get-token.sh "mcp:write")
curl -i http://localhost:8080/mcp \
  -H "Authorization: Bearer $NOREAD" \
  -d '{"jsonrpc":"2.0","method":"tools/list","id":1}'
```

> **Environment tip**: if the host's `localhost` is hard to reach over IPv6
> (`::1`), use `127.0.0.1`, or run from inside the container network:
> `docker compose exec mcp-resource curl -s http://localhost/mcp ...`

## Connecting from Claude Code

Use the pre-registered public client `mcp-client` via `--client-id`:

```sh
claude mcp add --transport http --client-id mcp-client keycloak-demo http://localhost:8080/mcp
```

Then authenticate the server in Claude Code: a browser opens the Keycloak login
page. Sign in as **alice / password** to obtain a token and call `/mcp`
(authorization code + PKCE). Confirm it works by calling the tool:

```
/mcp                                  # shows keycloak-demo connected + the echo tool
```
```
Ask Claude: use the echo tool of keycloak-demo to send "hello"
```

`Echo: hello` proves the full chain: Claude Code → RS (introspection) →
backend (echo) → result back to Claude.

> **Why pass `--client-id`**: without it, Claude Code registers itself via
> Dynamic Client Registration (DCR), but **Keycloak assigns dynamically
> registered clients only a minimal scope set** — `mcp-audience` (the `aud`)
> and `offline_access` are not attached, so the flow fails with `invalid_scope`
> or an `aud` mismatch. `realm-mcp.json` pre-registers `mcp-client` with the
> needed scopes, so using it directly is the reliable path.

## Teardown

```sh
docker compose -f examples/keycloak-quickstart/compose.yml down
```

## Design notes

- **Introspection mode**: the RS holds no JWKS file; it asks Keycloak's RFC 7662
  endpoint per request (with caching). Robust against key rotation.
- **Audience binding**: the `mcp-audience` scope (a default scope for all
  clients) always adds `aud=http://localhost:8080/mcp`. The RS requires it to
  equal `MCP_CANONICAL_URI` (RFC 8707, prevents token reuse).
- **Scope control**: `mcp:read` / `mcp:write` are optional scopes on
  `mcp-client`. Running `./get-token.sh "mcp:write"` yields a token without
  `mcp:read`, which returns 403.
- **Client is pre-registered**: `mcp-client` is defined with `mcp-audience`
  (default = always binds `aud`) plus `mcp:read`/`mcp:write`/`offline_access`
  (optional). Claude Code uses it directly via `--client-id mcp-client` (no DCR).
- **User role is `offline_access` only**: Claude Code requests `offline_access`
  for a refresh token, so alice needs that realm role (otherwise
  `Offline tokens not allowed for the user or client`). Attaching the
  `default-roles-mcp` composite would also pull in the **account** client
  audience, making `aud` an array that the RS exact-match check rejects with
  401 — so alice is given the bare `offline_access` role.
- **Pinned issuer (`KC_HOSTNAME`)**: the browser reaches Keycloak at
  `localhost:18080` while the RS reaches it at `keycloak:8080` — **different
  hosts**. Without pinning, the token `iss` varies by path and the RS
  introspection sees an issuer mismatch -> `active:false` -> 401. The compose
  sets `KC_HOSTNAME=http://localhost:18080` + `KC_HOSTNAME_BACKCHANNEL_DYNAMIC=true`
  to fix the issuer while still allowing the RS backchannel.
- **realm-mcp.json origin**: derived from a stock Keycloak realm export, keeping
  the built-in client scopes and adding `mcp-audience` / `mcp:read` / `mcp:write`
  plus `mcp-client` / `mcp-rs` / `alice`. That is why the file is large.
- **Demo shortcuts**: plaintext HTTP, `secrets/rs.secret` checked in, `admin/admin`.
  Use HTTPS and proper secret management in production (`docs/SECURITY.md`).
