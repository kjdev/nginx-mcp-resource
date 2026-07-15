# Troubleshooting

Common pitfalls when deploying `nginx-mcp-resource`, with their causes and
fixes. Tags in parentheses (V1–V4) reference the validation sections of the
developer guide where the underlying behaviour was confirmed.

## Auth headers and status codes

### Symptom: `WWW-Authenticate` contains `Bearer realm="..."` or is comma-joined (JWT mode)

**Cause**: `auth_jwt_www_authenticate` defaults to `on`, so the
nginx-auth-jwt module emits its own header which is **comma-joined** with the
MCP-format challenge added by `error_page` / `add_header` into one physical
header.

**Fix**: add `auth_jwt_www_authenticate off;` inside the `/mcp` location
(requires nginx-auth-jwt >= 0.13.1). This is already included in this
repository's `conf/mcp-resource-jwt.conf`. (V1)

```nginx
location /mcp {
    auth_jwt "mcp";
    auth_jwt_www_authenticate off;     # <- add this
    # ...
}
```

### Symptom: `WWW-Authenticate` contains `Bearer error="invalid_token"` or is comma-joined (introspection mode)

**Cause**: `auth_oauth2_token_www_authenticate` defaults to `on`, so the
module emits its own header on the "no Authorization header" and
`active: false` paths and it gets comma-joined with the `add_header` value.

**Fix**: add `auth_oauth2_token_www_authenticate off;` inside the `/mcp`
location (requires nginx-auth-oauth2-token >= 0.4.0). Already included in
this repository's `conf/mcp-resource-introspect.conf`. (legacy issues/001)

### Symptom: requests that should return 401 return 200

**Cause**: `auth_jwt off;` is being merged in from a parent scope, or the
location uses `return 200 "OK";` (a `return` directive runs in the REWRITE
phase, which is before the ACCESS phase where `auth_jwt` runs, so auth is
skipped).

**Fix**: declare `auth_jwt_key_file` and `auth_jwt` together on the
location. Use `proxy_pass` / `try_files` instead of `return` for content
delivery.

### Symptom: a valid JWT still produces 401

**Cause**: `auth_jwt "mcp" token=$http_authorization;` is being used; this
passes the `Bearer ` prefix as part of the token, causing base64url decoding
to fail and every request to be rejected.

**Fix**: omit `token=` so the default behaviour (strip the `Bearer ` prefix
from the `Authorization` header) is used, or pass a value with the prefix
already removed.

```nginx
auth_jwt "mcp";   # <- OK: default strips "Bearer "
# auth_jwt "mcp" token=$http_authorization;   # <- NG
```

### Symptom: requests that should return 200 return 401 / 403 (in tests)

**Cause**: a test `--- config` block serves content via `return 200 "OK";`.
Because `return` runs in REWRITE, the ACCESS-phase `auth_jwt` /
`auth_oauth2_token_introspect` is skipped, and the test setup itself is
wrong — auth never fires even for "should pass" requests.

**Fix**: use `proxy_pass http://<backend>;` so the content runs in the
CONTENT phase. All tests under `test/prove/` follow this pattern. (Discovered while
validating V1.)

### Symptom: requests that should return 403 return 401

**Cause**: the scope check is written with `auth_jwt_require_claim`, which
always returns 401.

**Fix**: implement scope checking with `auth_jwt_require` and add the
`error=403` parameter.

```nginx
auth_jwt_require $mcp_has_required_scope error=403;
```

### Symptom: tokens with the required scope still get 403 (introspection)

**Cause**: scope evaluation is written with `if ($var = 0) { return 403; }`,
which runs in the REWRITE phase. The introspection result variables
(`$oauth2_scope` etc.) are only populated in the ACCESS phase, so at the
time `if` runs they are still `not_found` and the map falls through to its
default, rejecting every request.

**Fix**: switch to `auth_oauth2_token_require $var error=403;` (requires
nginx-auth-oauth2-token >= 0.3.0). (V4)

```nginx
auth_oauth2_token_require $mcp_has_required_scope error=403;   # <- OK
# if ($mcp_has_required_scope = 0) { return 403; }             # <- NG
```

## Audience binding

### Symptom: audience binding does not seem to fire

**Cause**: the `aud` claim is a JSON array, but the configuration compares
it as a string with `eq`. (V2-3)

**Fix**: switch to an array-aware form. (V2)

```nginx
# match the first element
auth_jwt_require_claim .aud[0] eq "https://mcp.example.com/mcp";

# or check for set intersection
auth_jwt_require_claim aud any json=["https://mcp.example.com/mcp"];
```

### Symptom: JWTs with the right `aud` still return 401

**Cause**: `auth_jwt_require_claim aud eq $var` was given a variable whose
value is a plain string (`https://mcp.example.com/mcp`), which cannot be
parsed as a JSON value. `auth_jwt_require_claim` evaluates variable values
as JSON, so via a variable you need a JSON string literal (with embedded
quotes). (V2-7)

**Fix**: include the surrounding `"` in the variable value, or compare with
a literal string instead.

```nginx
map "" $mcp_canonical_uri_json {
    default '"https://mcp.example.com/mcp"';   # <- includes the quotes
}
auth_jwt_require_claim aud eq $mcp_canonical_uri_json;

# or use a literal string directly
auth_jwt_require_claim aud eq "https://mcp.example.com/mcp";
```

## Protected Resource Metadata

### Symptom: MCP Inspector cannot find `resource_metadata`

**Cause**: a syntax problem in the `WWW-Authenticate` header (missing quote,
missing comma, …).

**Fix**: inspect the raw header with `curl -i http://.../mcp`. The expected
format is:

```
WWW-Authenticate: Bearer resource_metadata="https://.../.well-known/oauth-protected-resource", scope="mcp:read"
```

### Symptom: `/.well-known/oauth-protected-resource` returns 404

**Cause**: the `server_name` does not match the host part of the canonical
URI, or `include conf/mcp-metadata.conf;` is missing.

**Fix**: keep the `MCP_SERVER_NAME` and the host in `MCP_CANONICAL_URI`
aligned. In bare nginx, line up the `server_name` directive with the
canonical URI.

### Symptom: `/.well-known/oauth-protected-resource` response is missing required fields

**Cause**: the metadata map variables (`$mcp_authorization_servers_json` /
`$mcp_scopes_supported_json` / `$mcp_bearer_methods_json`) are undefined
and expand to the empty string.

**Fix**: declare them in the `http` scope when using bare nginx:

```nginx
map "" $mcp_authorization_servers_json { default '["https://auth.example.com"]'; }
map "" $mcp_scopes_supported_json      { default '["mcp:read","mcp:write"]'; }
map "" $mcp_bearer_methods_json        { default '["header"]'; }
```

In the container image these are generated automatically from
`MCP_AUTHORIZATION_SERVER` / `MCP_SCOPES_SUPPORTED` /
`MCP_BEARER_METHODS_SUPPORTED`.

## Upstream traffic

### Symptom: `Authorization` is leaked to the upstream MCP backend

**Cause**: `proxy_set_header Authorization "";` is missing.

**Fix**: declare it explicitly inside `location /mcp { ... }`. The
`conf/mcp-resource-*.conf` snippets themselves do not include it, so the
user has to add it. `test/prove/07-no-passthrough.t` verifies the behaviour.

## Introspection-specific

### Symptom: introspection fails with `connect() failed` (502 returned)

**Cause**: the introspection endpoint is an external FQDN but no DNS
resolver is configured.

**Fix**: for the container image, set `MCP_RESOLVER=127.0.0.11` (Docker's
default embedded DNS). For bare nginx, add `resolver 127.0.0.11;` to the
`http` or `server` scope.

### Symptom: revoked tokens keep getting accepted for a while

**Cause**: the `max_ttl` on `auth_oauth2_token_introspect_cache` is too
long.

**Fix**: shorten `max_ttl` to ~60 seconds. For the container image override
the lifetime via `MCP_INTROSPECT_CACHE_MAX_TTL=30s` or similar.

## Startup and build

### Symptom: container fails with `MCP_xxx is required but not set`

**Cause**: the entrypoint env validator
(`05-mcp-validate-env.sh`) detected a missing required variable.

**Fix**: set the variable named in the error message. The full list of
required variables is in [INSTALL.md](INSTALL.md) and the project README.

### Symptom: `nginx -t` reports `unknown directive "auth_jwt_www_authenticate"` (or similar)

**Cause**: an older version of the module is being loaded.
`auth_jwt_www_authenticate` requires nginx-auth-jwt >= 0.13.1, and
`auth_oauth2_token_www_authenticate` requires nginx-auth-oauth2-token >= 0.4.0.

**Fix**: rebuild or update the dependent modules to at least the versions
above. The container image copies the required `.so` files at build time so
this should not happen there; for bare nginx, follow [INSTALL.md](INSTALL.md)
to rebuild.

## Rate limiting

### Symptom: rate limiting is silently unlimited for every subject

**Cause**: `$oauth2_token_sub` is empty when `nginx-ratelimit` reads it as the
key. nginx-ratelimit treats an empty key as unlimited rather than rejecting
the request, so requests never get throttled and no error is logged. This
happens when `auth_oauth2_token_phase preaccess;` is missing from the
location (introspection still runs in the ACCESS phase, after ratelimit's
PREACCESS handler), or the introspection response has no `sub` claim. In
`jwt` mode, the cause is the equivalent: `auth_jwt_phase preaccess;` is
missing from the `/mcp` location, `nginx-auth-jwt` is older than 0.14.2 (the
version that made a successful PREACCESS check return `NGX_DECLINED` instead
of `NGX_OK`, allowing ratelimit's handler to run afterwards), or the JWT has
no `sub` claim.

**Fix**: add the mode's PREACCESS-phase directive to the `/mcp` location —
`auth_oauth2_token_phase preaccess;` (requires nginx-auth-oauth2-token
>= 0.5.0) for `introspect`, or `auth_jwt_phase preaccess;` (requires
nginx-auth-jwt >= 0.14.2) for `jwt`. Verify with two different valid tokens
(different `sub`) that each is limited independently — if both share one
counter, or neither is ever limited, the key is empty.

For the container image, the missing-`sub`-claim case is closed
automatically: whenever `MCP_RATELIMIT_ENABLED=on`, the generated config adds
`auth_oauth2_token_require $oauth2_token_sub;` (or `auth_jwt_require
$jwt_sub;` in `jwt` mode) to the `/mcp` location, so a token/response without
`sub` gets `401` instead of silently bypassing the limit. This only covers
the missing-`sub`-claim case, not the missing-PREACCESS-phase-directive case
above. For bare nginx, add the equivalent `require` directive yourself — see
[EXAMPLES.md](EXAMPLES.md#docker-compose--introspection--rate-limiting).

### Symptom: ratelimit's PREACCESS handler doesn't seem to run, or runs before auth resolves the key

**Cause**: nginx dynamic modules run their PREACCESS-phase handlers in the
**reverse** order they are `load_module`'d. If the auth module
(`ngx_http_auth_jwt_module.so` or `ngx_http_auth_oauth2_token_module.so`) is
loaded *before* `ngx_http_ratelimit_module.so`, ratelimit's handler executes
first, before the rate-limit key variable has been resolved.

**Fix**: `load_module` nginx-ratelimit **before** the auth module, so that
the auth module's handler (loaded later) runs first and populates the key
variable before ratelimit's handler (loaded earlier) reads it. The container
image derives this order automatically; for bare nginx, follow the
`load_module` order shown in
[EXAMPLES.md](EXAMPLES.md#docker-compose--introspection--rate-limiting).

## See also

- Validation sections "V1–V4" in the developer guide
- Security notes: [SECURITY.md](SECURITY.md)
- Configuration examples: [EXAMPLES.md](EXAMPLES.md)
