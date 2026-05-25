# Security Notes

Mandatory items to observe when operating `nginx-mcp-resource`. The normative
sources are the MCP Authorization specification (2025-11-25), OAuth 2.1,
RFC 8707, and RFC 9728.

## 1. HTTPS is required

OAuth 2.1 §1.5 mandates that all protected-resource traffic between the AS
and the RS run over HTTPS.

- Every `examples/nginx-*.conf` in this repository declares `listen 443 ssl`.
- For the container image set `MCP_TLS=on` together with `MCP_SSL_CERT_FILE`
  and `MCP_SSL_CERT_KEY_FILE`. When TLS is terminated at a load balancer and
  the container receives plaintext (`MCP_TLS=off`), make sure that the
  LB-to-RS hop stays inside a single trust boundary.
- Never expose a plaintext endpoint to the public internet.

## 2. Audience binding is mandatory

Do **not** omit `auth_jwt_require_claim aud eq ...` (JWT mode) or
`auth_oauth2_token_require $mcp_aud_ok;` (introspection mode).

- Without the check, a Bearer token issued for a different service can be
  replayed against this RS, violating MCP §Access Token Privilege Restriction.
- The canonical URI is also consumed by the AS as the RFC 8707 audience.
  Keep `MCP_CANONICAL_URI` / `$mcp_canonical_uri` in sync with the AS issuance
  policy.
- If the AS issues `aud` as a JSON array, switch to
  `auth_jwt_require_claim .aud[0] eq "<URI>"` or
  `auth_jwt_require_claim aud any json=["<URI>"]`. See
  [TROUBLESHOOTING.md](TROUBLESHOOTING.md) and the V2 section of the
  developer guide for details.

## 3. Token passthrough is forbidden

Always include `proxy_set_header Authorization "";` inside the `/mcp`
location. MCP §Token Passthrough prohibits forwarding the Bearer token to
the upstream MCP backend verbatim.

- The snippets `conf/mcp-resource-jwt.conf` / `conf/mcp-resource-introspect.conf`
  themselves do not contain `proxy_set_header`; the user must add it in
  the surrounding `location /mcp { ... }` block.
- The container image applies it automatically via
  `build/docker/templates/snippets/mcp-server-{jwt,introspect}.conf.template`.
- The behaviour is exercised by `t/07-no-passthrough.t`.

## 4. Verify the `aud` issuance policy in advance

The snippets assume a **single-string `aud`** claim. Coordinate with the AS
operator before deployment when any of the following may occur:

- An array (`aud: ["https://mcp.example.com/mcp", "https://other.example.com"]`).
- A value that differs subtly from the canonical URI (trailing slash, scheme
  mismatch, explicit port).

## 5. Keep Bearer tokens out of logs

Design `log_format` so that the contents of the `Authorization` header never
appear in the nginx `access_log` or `error_log`.

- Do not include `$http_authorization` in `log_format`.
- The `debug` level of `error_log` can leak token bytes from inside the
  modules; in production pin the level to `info` or higher.
- Do not log introspection response claims (active=true bodies) either.

## 6. Keep `scopes_supported` and the 401 challenge in sync

The `scopes_supported` array returned at
`/.well-known/oauth-protected-resource` must agree with the `scope`
parameter advertised in the `WWW-Authenticate` challenge.

- MCP §Scope Selection Strategy expects the client to pick scopes from the
  metadata document.
- The configuration uses two distinct knobs — `MCP_REQUIRED_SCOPE` (used in
  the challenge) and `MCP_SCOPES_SUPPORTED` (used in the metadata). It is
  easy to update only one and end up with a mismatch. For bare nginx, keep
  `$mcp_required_scope` and `$mcp_scopes_supported_json` consistent.

## 7. PKCE is the AS's responsibility

PKCE verification is performed at the Authorization Server. The RS does not
need to do anything about PKCE.

- Capability discovery (PKCE methods etc.) belongs in AS Metadata
  (`.well-known/oauth-authorization-server`), not in the Protected Resource
  Metadata document.

## 8. Handle the client secret carefully (introspection mode only)

Provide the client secret **only via a file** (`MCP_CLIENT_SECRET_FILE`).

- Passing the secret through an environment variable is not supported —
  `docker inspect` would expose it.
- Mount the file read-only from outside the container
  (`./secrets/rs.secret:/run/secrets/rs.secret:ro`).
- A host-side file permission of 600 is recommended.

## 9. Tune the introspection cache lifetime

Enable `auth_oauth2_token_introspect_cache zone=introspect:10m max_ttl=60s;`
in production deployments.

- An overly long `max_ttl` delays revocation. The MCP guidance is on the
  order of tens of seconds.
- For the container image, adjust the lifetime with
  `MCP_INTROSPECT_CACHE_MAX_TTL` (default `60s`).

## 10. References

- MCP Authorization specification: <https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization>
- RFC 8707 (Resource Indicators): <https://datatracker.ietf.org/doc/html/rfc8707>
- RFC 9728 (Protected Resource Metadata): <https://datatracker.ietf.org/doc/html/rfc9728>
- OAuth 2.1: <https://datatracker.ietf.org/doc/html/draft-ietf-oauth-v2-1>
- RFC 7662 (Token Introspection): <https://datatracker.ietf.org/doc/html/rfc7662>
- RFC 6750 §2.1 (Bearer Token Usage): <https://datatracker.ietf.org/doc/html/rfc6750>
