# Getting started — protecting an MCP server with Keycloak

This document is for people **new to `nginx-mcp-resource`**: it explains who the
players are, what you need, and how they connect, using a runnable example.

Where `docs/EXAMPLES.md` is a catalogue of nginx config snippets, this walks one
complete setup in the order **big picture → prerequisites → run → what each part
configures → verify**.

Runnable example included: [`examples/keycloak-quickstart/`](../examples/keycloak-quickstart/)

---

## What this project is

`nginx-mcp-resource` is **not an MCP server itself**. It sits in front of an MCP
server you expose remotely and acts as an OAuth 2.1 **Resource Server (RS)** — an
nginx auth gate that only lets through requests carrying a valid token.

OAuth has three players. Keeping them distinct is the key to understanding this.

| Player | Role | In this example |
|---|---|---|
| **Client** | Obtains a token and calls the API | Claude Code / curl |
| **Authorization Server (AS)** | Login, token issuance, validation | Keycloak |
| **Resource Server (RS)** | Validates tokens and guards the resource | **nginx-mcp-resource** |

The RS **does not issue tokens** — that is always the AS's job. So using an RS
requires a separate AS. This is not a limitation of this project; it is how OAuth
and the
[MCP authorization spec](https://modelcontextprotocol.io/specification/draft/basic/authorization)
are designed.

---

## Big picture

```
                                           ┌─────────────────────┐
                        (1) 401 if no auth │                     │
   ┌──────────┐  ────────────────────────> │  mcp-resource       │
   │  Client  │                            │   (RS = nginx)      │
   │ (Claude  │  (2) WWW-Authenticate on   │                     │
   │  Code/   │ <───────────────────────── │  - points to the AS │
   │  curl)   │      401 reveals the AS    │  - validates tokens │
   └────┬─────┘                            └────────┬────────────┘
        │                                           │ (3) introspection
        │ (4) log in -> get token                   │     (delegated validation)
        ▼                                           ▼
   ┌──────────┐                            ┌──────────────────┐
   │ keycloak │ <───────────────────────── │  keycloak (AS)   │
   │  (AS)    │                            └──────────────────┘
   └──────────┘                                     │ (5) pass if valid
        (6) retry with the obtained token →         ▼
                                            ┌───────────────────┐
                                            │  mcp-backend      │
                                            │ (the real MCP)    │
                                            └───────────────────┘
```

Key point: the RS delegates token validation to the AS introspection endpoint,
and on success proxies straight through to the MCP backend. The backend needs no
auth code at all.

---

## What you need

| Category | Requirement | In this example |
|---|---|---|
| Runtime | Docker / Docker Compose | — |
| RS | `nginx-mcp-resource` image | `docker build -t nginx-mcp-resource:dev .` |
| AS | An OAuth 2.1 authorization server | Keycloak 26.2 (realm built via import) |
| Backend | The MCP server itself | A demo JSON-RPC stub (swap in production) |
| Client | An MCP client | Claude Code / curl |

In production the two things **you provide** are the AS and the MCP backend
itself. This example bundles both in compose so it runs immediately.

---

## Quickstart

```sh
# Start the stack (keycloak + backend + RS)
docker compose -f examples/keycloak-quickstart/compose.yml up -d --wait --build
```

What gets published:
- `http://localhost:18080` — Keycloak (admin: `admin` / `admin`)
- `http://localhost:8080` — MCP resource server (protected `/mcp`)

---

## What each component configures

### Keycloak (AS) — `realm-mcp.json`

Highlights of the realm `mcp` imported at startup:

- **`mcp-audience` scope** (default for all clients): always adds
  `aud = http://localhost:8080/mcp` to the access token. This is the basis of
  RFC 8707 audience binding.
- **`mcp:read` / `mcp:write` scopes** (optional): granted only when the client
  requests them and placed in the `scope` claim. The RS checks here for `mcp:read`.
- **`mcp-client`** (public, authorization code + PKCE, direct grant enabled): the
  client used by Claude Code / Inspector / curl.
- **`mcp-rs`** (confidential, has a secret): the client the RS authenticates as
  when calling introspection.
- **User `alice` / `password`**: a demo login user.

### Resource server (RS) — compose environment variables

```yaml
MCP_AUTH_MODE: introspect                       # introspection mode
MCP_CANONICAL_URI: http://localhost:8080/mcp    # this RS's canonical URI (= aud)
MCP_AUTHORIZATION_SERVER: http://localhost:18080/realms/mcp   # AS advertised in metadata
MCP_REQUIRED_SCOPE: mcp:read                    # required scope
MCP_BACKEND: mcp-backend:8080                   # the MCP backend behind it
MCP_INTROSPECT_ENDPOINT: http://keycloak:8080/realms/mcp/protocol/openid-connect/token/introspect
MCP_CLIENT_ID: mcp-rs
MCP_CLIENT_SECRET_FILE: /run/secrets/rs.secret
```

What the RS validates (against the introspection response):
1. `active: true` (not revoked / expired)
2. `aud` equals `MCP_CANONICAL_URI` (RFC 8707, prevents token reuse)
3. `scope` contains `mcp:read`

Any failure returns 401 (or 403 when only the scope is insufficient).

### MCP backend — `backend/stub.py`

A stub that just answers JSON-RPC for `tools/list` and friends, used to show that
requests passing the RS reach the backend unchanged. **In production replace it
with a real Streamable HTTP MCP server** (just swap the `mcp-backend` service in
compose).

---

## Connecting from Claude Code

Add the server using the pre-registered public client `mcp-client` via `--client-id`:

```sh
claude mcp add --transport http --client-id mcp-client keycloak-demo http://localhost:8080/mcp
```

Then authenticate the server in Claude Code; the following OAuth 2.1
authorization-code + PKCE flow runs:

1. Claude Code hits `/mcp` unauthenticated → the RS returns **401** with
   `WWW-Authenticate: Bearer resource_metadata="…"`
2. It fetches the RS metadata from `resource_metadata` and discovers Keycloak via
   `authorization_servers`
3. A browser opens the Keycloak login → sign in as **alice / password**
4. It obtains a token and retries `/mcp` → the RS validates it and returns **200**

All you do is log in via the browser.

### Confirm the connection and call a tool

Check the connection status and tool list with `/mcp`:

```
/mcp
```

Success means `keycloak-demo` shows `connected` and the `echo` tool (exposed by
the stub) is listed. Then call the tool in natural language:

```
use the echo tool of keycloak-demo to send "hello"
```

If `Echo: hello` comes back, it proves **not just "connected" but "a tool ran via
authenticated access"**. The path is:

```
Claude Code ──Bearer token──> RS (introspection) ──> backend (echo) ──> result back to Claude
```

> The only tool is the stub's `echo`. To try meaningful tools, swap the
> `mcp-backend` service in `compose.yml` for a real Streamable HTTP MCP
> server (the RS / Keycloak stay the same).

> **Why pass `--client-id`**: without it, Claude Code registers itself via
> Dynamic Client Registration (DCR), but **Keycloak assigns dynamically
> registered clients only a minimal scope set**, so `mcp-audience` (the `aud`)
> and `offline_access` are not attached and the flow fails with `invalid_scope`
> or an `aud` mismatch. `realm-mcp.json` pre-registers `mcp-client` with the
> required scopes, so using it directly is the reliable path (to truly use DCR
> you would need extra configuration to attach an audience mapper and the needed
> scopes at registration time).

> **If you see `Offline tokens not allowed`**: Claude Code requests
> `offline_access` for a refresh token, so the logging-in user needs the
> `offline_access` realm role (alice already has it in `realm-mcp.json`). Note
> that attaching a composite role with account roles such as `default-roles-mcp`
> mixes `account` into `aud`, making it an array that the RS exact-match check
> rejects with 401 — so alice is given the bare `offline_access` role only.

> **If auth succeeds but `/mcp` returns 401 (rejected on reconnect)**: the
> token's `iss` and the Keycloak host the RS introspects against do not match.
> The browser reaches Keycloak at `localhost:18080` while the RS reaches it at
> `keycloak:8080`, so unless the issuer is pinned, introspection returns
> `active:false`. The compose solves this with
> `KC_HOSTNAME=http://localhost:18080` + `KC_HOSTNAME_BACKCHANNEL_DYNAMIC=true`.

> To smoke-test from the CLI without interactive login, use
> `examples/keycloak-quickstart/get-token.sh`, which obtains a token via the
> password grant (see the next section). (It uses the password grant, so it does
> not request `offline_access`.)

---

## Verify with curl

```sh
cd examples/keycloak-quickstart
TOKEN=$(./get-token.sh)            # alice's token (mcp:read mcp:write)
```

### (a) no token → 401

```sh
curl -i http://localhost:8080/mcp -d '{"jsonrpc":"2.0","method":"tools/list","id":1}'
```
```
HTTP/1.1 401 Unauthorized
WWW-Authenticate: Bearer resource_metadata="http://localhost:8080/.well-known/oauth-protected-resource", scope="mcp:read"
```

### (b) metadata (RFC 9728)

```sh
curl -s http://localhost:8080/.well-known/oauth-protected-resource
```
```json
{"resource":"http://localhost:8080/mcp","authorization_servers":["http://localhost:18080/realms/mcp"],"scopes_supported":["mcp:read","mcp:write"],"bearer_methods_supported":["header"]}
```

### (c) valid token → 200 + backend response

```sh
curl -s http://localhost:8080/mcp -H "Authorization: Bearer $TOKEN" \
  -d '{"jsonrpc":"2.0","method":"tools/list","id":1}'
```
```json
{"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"echo", ...}]}}
```

### (d) token without `mcp:read` → 403

```sh
NOREAD=$(./get-token.sh "mcp:write")
curl -i http://localhost:8080/mcp -H "Authorization: Bearer $NOREAD" \
  -d '{"jsonrpc":"2.0","method":"tools/list","id":1}'
```
```
HTTP/1.1 403 Forbidden
WWW-Authenticate: Bearer error="insufficient_scope", scope="mcp:read", resource_metadata="..."
```

> **Connection tip**: if the host's `localhost` is hard to reach over IPv6
> (`::1`), use `127.0.0.1`, or run from inside the container network with
> `docker compose exec mcp-resource curl http://localhost/mcp …`.

---

## The flow, end to end

```
Client                     RS (nginx)              AS (Keycloak)         Backend
  │  GET /mcp (no token)      │                        │                   │
  │ ─────────────────────────>│                        │                   │
  │  401 + WWW-Authenticate   │                        │                   │
  │ <─────────────────────────│                        │                   │
  │  fetch metadata -> find AS│                        │                   │
  │ ──────────────────────────┼───────────────────────>│                   │
  │  login + consent + PKCE   │                        │                   │
  │ <─────────────────────────┼─── token ──────────────│                   │
  │  GET /mcp (Bearer token)  │                        │                   │
  │ ─────────────────────────>│  introspection         │                   │
  │                           │ ──────────────────────>│                   │
  │                           │  active/aud/scope OK   │                   │
  │                           │ <──────────────────────│                   │
  │                           │  proxy (token stripped)│                   │
  │                           │ ───────────────────────┼──────────────────>│
  │  200 + MCP response       │ <──────────────────────┼───────────────────│
  │ <─────────────────────────│                        │                   │
```

---

## Appendix A — switching to JWT mode

Instead of introspection, the RS can **validate the token signature itself** in
JWT mode. No per-request call to the AS (faster), but you must **hand the RS
Keycloak's JWKS (public keys) as a file** (`MCP_JWT_KEY_FILE` is a file path only;
remote URLs are not supported).

```sh
# Fetch Keycloak's JWKS into the mounted file
curl -s http://localhost:18080/realms/mcp/protocol/openid-connect/certs > keys/jwks.json
```

Change the RS env to `MCP_AUTH_MODE=jwt` + `MCP_JWT_KEY_FILE=/etc/nginx/keys/jwks.json`
and mount `keys/jwks.json`. Because key rotation requires re-fetching the JWKS,
this example defaults to introspection for simpler operations.

> For a minimal setup that issues and verifies your own JWTs without an AS, see
> [`examples/self-jwt/`](../examples/self-jwt/) (for M2M / personal use).

---

## Appendix B — adding Google / GitHub login

Even if you want users to log in with Google or GitHub, **you cannot use them
directly as the AS** (no DCR, resource indicators, or custom scopes). Keep
Keycloak as the AS and federate them as the **identity provider behind it**.

```
Client → mcp-resource (RS) → mcp-backend
              ↑ token validation
        Keycloak (AS)            ← issues MCP tokens
              ↑ delegates login
        Google / GitHub (IdP)    ← authenticates the user only
```

Outline (Keycloak admin console → Identity Providers):
1. Create an OAuth app on the Google / GitHub side and get the Client ID / Secret
2. Register Keycloak's broker endpoint as the redirect URI:
   `http://localhost:18080/realms/mcp/broker/<google|github>/endpoint`
3. Add Google / GitHub under Keycloak's Identity Providers and configure the above

The RS (`nginx-mcp-resource`) configuration **does not change at all**. Who logs
in and how is the AS's internal concern; the RS only checks "is this a valid token
issued by Keycloak".

---

## Production notes

This example takes shortcuts for demo purposes. In production these are mandatory:

- **HTTPS**: plaintext HTTP is not acceptable. Terminate TLS upstream or set `MCP_TLS=on`.
- **Audience binding**: make `MCP_CANONICAL_URI` and the AS-issued `aud` match exactly.
- **Secret management**: do not use a checked-in `secrets/rs.secret` or `admin/admin`.
- **No token passthrough**: do not forward `Authorization` to the backend (already done here).
- **Client registration**: this example pre-registers the client. If you allow
  DCR, configure trusted-host restrictions, registration authentication, and
  granted-scope control appropriately.

See [`docs/SECURITY.md`](SECURITY.md) for details. The full set of config
patterns is in [`docs/EXAMPLES.md`](EXAMPLES.md), installation in
[`docs/INSTALL.md`](INSTALL.md), and pitfalls in
[`docs/TROUBLESHOOTING.md`](TROUBLESHOOTING.md).
