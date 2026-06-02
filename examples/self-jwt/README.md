# Self-issued JWT demo (no-AS setup)

A minimal setup that has nginx-mcp-resource (JWT mode) validate a **JWT you
signed yourself**, without standing up an authorization server (Keycloak etc.).

Intended use cases: M2M / service accounts, closed self-hosting (personal or
internal), and RS smoke testing. Not suitable for a public MCP where humans
authenticate interactively (use an AS for that).

For the AS-backed walkthrough, see
[`docs/GETTING_STARTED.md`](../../docs/GETTING_STARTED.md).

## Topology

```
MCP Client (curl) ──Bearer <self-issued JWT>──> mcp-resource (nginx, RS)
                                                    │ verify signature via JWKS
                                                    │ check aud / scope
                                                    └──pass──> mcp-backend (stub)
```

The token issuer is `tokens.py` (your own private key). There is no AS.

## Prerequisites

- Docker / Docker Compose
- Python 3 + `cryptography` (to issue JWTs)
- The image built at the repo root:
  ```sh
  docker build -t nginx-mcp-resource:dev .
  ```

## Steps

### 1. Generate a key pair and JWKS

```sh
cd examples/self-jwt
python3 -m venv .venv && . .venv/bin/activate
pip install cryptography
python tokens.py keygen          # writes keys/private.pem and keys/jwks.json
```

### 2. Start

```sh
docker compose up -d             # from examples/self-jwt/
```

### 3. Issue a JWT

```sh
TOKEN=$(python tokens.py mint)   # aud=http://localhost:8080/mcp, scope="mcp:read mcp:write"
echo "$TOKEN"
```

## Verify (a)–(d)

### (a) no token → 401 challenge

```sh
curl -i http://localhost:8080/mcp \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"tools/list","id":1}'
```
```
HTTP/1.1 401 Unauthorized
WWW-Authenticate: Bearer resource_metadata="http://localhost:8080/.well-known/oauth-protected-resource", scope="mcp:read"
```

### (b) fetch RFC 9728 metadata

```sh
curl -s http://localhost:8080/.well-known/oauth-protected-resource | jq .
```
```json
{
  "resource": "http://localhost:8080/mcp",
  "authorization_servers": ["https://self-jwt-demo.local"],
  "scopes_supported": ["mcp:read", "mcp:write"],
  "bearer_methods_supported": ["header"]
}
```

### (c) self-issued JWT passes → backend responds

```sh
curl -s http://localhost:8080/mcp \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"tools/list","id":1}' | jq .
```
```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": { "tools": [ { "name": "echo", ... } ] }
}
```

### (d) wrong-audience token → 401 (RFC 8707, prevents token reuse)

```sh
BADAUD=$(python tokens.py mint --aud https://other.example.com/mcp)
curl -i http://localhost:8080/mcp \
  -H "Authorization: Bearer $BADAUD" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"tools/list","id":1}' | head -1
# HTTP/1.1 401 Unauthorized
```

### Bonus: insufficient scope → 403 insufficient_scope

```sh
NOSCOPE=$(python tokens.py mint --scope mcp:write)   # does not include the required mcp:read
curl -i http://localhost:8080/mcp \
  -H "Authorization: Bearer $NOSCOPE" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"tools/list","id":1}' | head -1
# HTTP/1.1 403 Forbidden
```

## Connecting from a client

Supply the token as a static header (no interactive OAuth flow):

- **MCP Inspector**: set `Authorization: Bearer <TOKEN>` in the Authentication settings.
- **Claude Code**:
  ```sh
  claude mcp add --transport http self-jwt http://localhost:8080/mcp --header "Authorization: Bearer <TOKEN>"
  ```

## Teardown

```sh
docker compose down
```

## Limitations of this setup

- Long-lived tokens **cannot be revoked or rotated**; a leak is valid until `exp`.
- MCP's interactive discovery (401 → metadata → log in at the AS → auto token)
  does not work. `MCP_AUTHORIZATION_SERVER` is nominal.
- Not suited to many human users authenticating individually. For that, consider
  a lightweight AS (Ory Hydra / Logto, etc.) or Keycloak.
