use Test::Nginx::Socket 'no_plan';

no_root_location();
no_shuffle();

run_tests();

__DATA__

=== V1-1: no Authorization header (baseline) -- auth_jwt emits no WWW-Authenticate
--- http_config
    server {
        listen 18080;
        location / { return 200 "backend-ok"; }
    }
--- config
    location / {
        auth_jwt "test-realm";
        auth_jwt_key_file $TEST_NGINX_HTML_DIR/keys.json;
        proxy_pass http://127.0.0.1:18080;
    }
--- user_files
>>> keys.json
{
  "keys": [
    {"kty":"oct","use":"sig","kid":"test1","k":"dGVzdDEuc2VjcmV0","alg":"HS256"}
  ]
}
--- request
GET /
--- error_code: 401
--- response_headers
WWW-Authenticate:

=== V1-2: Authorization: Bearer <invalid> -- auth_jwt emits Bearer realm + error="invalid_token"
--- http_config
    server {
        listen 18081;
        location / { return 200 "backend-ok"; }
    }
--- config
    location / {
        auth_jwt "test-realm";
        auth_jwt_key_file $TEST_NGINX_HTML_DIR/keys.json;
        proxy_pass http://127.0.0.1:18081;
    }
--- user_files
>>> keys.json
{
  "keys": [
    {"kty":"oct","use":"sig","kid":"test1","k":"dGVzdDEuc2VjcmV0","alg":"HS256"}
  ]
}
--- request
GET /
--- more_headers
Authorization: Bearer invalid.jwt.token
--- error_code: 401
--- response_headers_like
WWW-Authenticate: Bearer realm="test-realm", error="invalid_token"

=== V1-3: no token + error_page internal redirect to a named location -- only the MCP-format header is attached
--- http_config
    server {
        listen 18082;
        location / { return 200 "backend-ok"; }
    }
--- config
    set $mcp_metadata_uri "http://localhost/.well-known/oauth-protected-resource";
    set $mcp_required_scope "mcp:read";

    location / {
        auth_jwt "test-realm";
        auth_jwt_key_file $TEST_NGINX_HTML_DIR/keys.json;
        error_page 401 = @mcp_unauthorized;
        proxy_pass http://127.0.0.1:18082;
    }

    location @mcp_unauthorized {
        internal;
        add_header WWW-Authenticate
            'Bearer resource_metadata="$mcp_metadata_uri", scope="$mcp_required_scope"'
            always;
        return 401;
    }
--- user_files
>>> keys.json
{
  "keys": [
    {"kty":"oct","use":"sig","kid":"test1","k":"dGVzdDEuc2VjcmV0","alg":"HS256"}
  ]
}
--- request
GET /
--- error_code: 401
--- response_headers_like
WWW-Authenticate: Bearer resource_metadata="http://localhost/\.well-known/oauth-protected-resource", scope="mcp:read"

=== V1-4: invalid token + error_page (no more_clear_headers) -- auth_jwt's Bearer realm remains and is concatenated
--- http_config
    server {
        listen 18083;
        location / { return 200 "backend-ok"; }
    }
--- config
    set $mcp_metadata_uri "http://localhost/.well-known/oauth-protected-resource";
    set $mcp_required_scope "mcp:read";

    location / {
        auth_jwt "test-realm";
        auth_jwt_key_file $TEST_NGINX_HTML_DIR/keys.json;
        error_page 401 = @mcp_unauthorized;
        proxy_pass http://127.0.0.1:18083;
    }

    location @mcp_unauthorized {
        internal;
        add_header WWW-Authenticate
            'Bearer resource_metadata="$mcp_metadata_uri", scope="$mcp_required_scope"'
            always;
        return 401;
    }
--- user_files
>>> keys.json
{
  "keys": [
    {"kty":"oct","use":"sig","kid":"test1","k":"dGVzdDEuc2VjcmV0","alg":"HS256"}
  ]
}
--- request
GET /
--- more_headers
Authorization: Bearer invalid.jwt.token
--- error_code: 401
--- response_headers_like
WWW-Authenticate: Bearer realm="test-realm", error="invalid_token", Bearer resource_metadata="http://localhost/\.well-known/oauth-protected-resource", scope="mcp:read"

=== V1-5: invalid token + error_page (no more_clear_headers) -- a single physical header line (comma-joined)
--- http_config
    server {
        listen 18084;
        location / { return 200 "backend-ok"; }
    }
--- config
    set $mcp_metadata_uri "http://localhost/.well-known/oauth-protected-resource";
    set $mcp_required_scope "mcp:read";

    location / {
        auth_jwt "test-realm";
        auth_jwt_key_file $TEST_NGINX_HTML_DIR/keys.json;
        error_page 401 = @mcp_unauthorized;
        proxy_pass http://127.0.0.1:18084;
    }

    location @mcp_unauthorized {
        internal;
        add_header WWW-Authenticate
            'Bearer resource_metadata="$mcp_metadata_uri", scope="$mcp_required_scope"'
            always;
        return 401;
    }
--- user_files
>>> keys.json
{
  "keys": [
    {"kty":"oct","use":"sig","kid":"test1","k":"dGVzdDEuc2VjcmV0","alg":"HS256"}
  ]
}
--- request
GET /
--- more_headers
Authorization: Bearer invalid.jwt.token
--- error_code: 401
--- raw_response_headers_unlike
WWW-Authenticate:.*\r\n.*WWW-Authenticate:

=== V1-6: invalid token + auth_jwt_www_authenticate off + error_page -- the module-origin header is cleared
--- http_config
    server {
        listen 18085;
        location / { return 200 "backend-ok"; }
    }
--- config
    set $mcp_metadata_uri "http://localhost/.well-known/oauth-protected-resource";
    set $mcp_required_scope "mcp:read";

    location / {
        auth_jwt "test-realm";
        auth_jwt_key_file $TEST_NGINX_HTML_DIR/keys.json;
        auth_jwt_www_authenticate off;
        error_page 401 = @mcp_unauthorized;
        proxy_pass http://127.0.0.1:18085;
    }

    location @mcp_unauthorized {
        internal;
        add_header WWW-Authenticate
            'Bearer resource_metadata="$mcp_metadata_uri", scope="$mcp_required_scope"'
            always;
        return 401;
    }
--- user_files
>>> keys.json
{
  "keys": [
    {"kty":"oct","use":"sig","kid":"test1","k":"dGVzdDEuc2VjcmV0","alg":"HS256"}
  ]
}
--- request
GET /
--- more_headers
Authorization: Bearer invalid.jwt.token
--- error_code: 401
--- response_headers_like
WWW-Authenticate: Bearer resource_metadata="http://localhost/\.well-known/oauth-protected-resource", scope="mcp:read"

=== V1-7: invalid token + auth_jwt_www_authenticate off -- no Bearer realm-derived string remains
--- http_config
    server {
        listen 18086;
        location / { return 200 "backend-ok"; }
    }
--- config
    set $mcp_metadata_uri "http://localhost/.well-known/oauth-protected-resource";
    set $mcp_required_scope "mcp:read";

    location / {
        auth_jwt "test-realm";
        auth_jwt_key_file $TEST_NGINX_HTML_DIR/keys.json;
        auth_jwt_www_authenticate off;
        error_page 401 = @mcp_unauthorized;
        proxy_pass http://127.0.0.1:18086;
    }

    location @mcp_unauthorized {
        internal;
        add_header WWW-Authenticate
            'Bearer resource_metadata="$mcp_metadata_uri", scope="$mcp_required_scope"'
            always;
        return 401;
    }
--- user_files
>>> keys.json
{
  "keys": [
    {"kty":"oct","use":"sig","kid":"test1","k":"dGVzdDEuc2VjcmV0","alg":"HS256"}
  ]
}
--- request
GET /
--- more_headers
Authorization: Bearer invalid.jwt.token
--- error_code: 401
--- raw_response_headers_unlike
WWW-Authenticate:.*Bearer realm

=== V1-8: auth_jwt_www_authenticate set directly to an MCP-format string -- self-contained without error_page
--- http_config
    server {
        listen 18087;
        location / { return 200 "backend-ok"; }
    }
--- config
    set $mcp_metadata_uri "http://localhost/.well-known/oauth-protected-resource";
    set $mcp_required_scope "mcp:read";

    location / {
        auth_jwt "test-realm";
        auth_jwt_key_file $TEST_NGINX_HTML_DIR/keys.json;
        auth_jwt_www_authenticate
            'Bearer resource_metadata="$mcp_metadata_uri", scope="$mcp_required_scope"';
        proxy_pass http://127.0.0.1:18087;
    }
--- user_files
>>> keys.json
{
  "keys": [
    {"kty":"oct","use":"sig","kid":"test1","k":"dGVzdDEuc2VjcmV0","alg":"HS256"}
  ]
}
--- request
GET /
--- more_headers
Authorization: Bearer invalid.jwt.token
--- error_code: 401
--- response_headers_like
WWW-Authenticate: Bearer resource_metadata="http://localhost/\.well-known/oauth-protected-resource", scope="mcp:read"
