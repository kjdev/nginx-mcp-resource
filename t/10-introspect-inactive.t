use Test::Nginx::Socket 'no_plan';

no_root_location();
no_shuffle();

run_tests();

__DATA__

=== TEST 1: introspection returns active:false -> 401 + MCP-format WWW-Authenticate (module's invalid_token is overwritten)
--- http_config
    auth_oauth2_token_client_id mcp-rs;
    auth_oauth2_token_client_secret rs-secret;
    auth_oauth2_token_claim_set $oauth2_aud   aud;
    auth_oauth2_token_claim_set $oauth2_scope scope;

    map "" $mcp_canonical_uri  { default "http://localhost/mcp"; }
    map "" $mcp_metadata_uri   { default "http://localhost/.well-known/oauth-protected-resource"; }
    map "" $mcp_required_scope { default "mcp:read"; }

    map $oauth2_aud $mcp_aud_ok {
        default 0;
        "http://localhost/mcp" 1;
    }
    map $oauth2_scope $mcp_has_required_scope {
        default 0;
        "~(^|\s)mcp:read(\s|$)" 1;
    }

    server {
        listen 18142;
        location / { return 200 "backend-ok"; }
    }
    server {
        listen 18143;
        location / {
            default_type application/json;
            return 200 '{"active":false}';
        }
    }
--- config
    location = /_introspect {
        internal;
        proxy_pass http://127.0.0.1:18143/;
    }
    location /mcp {
        auth_oauth2_token_introspect          on;
        auth_oauth2_token_introspect_endpoint /_introspect;
        auth_oauth2_token_www_authenticate    off;
        auth_oauth2_token_require $mcp_aud_ok;
        auth_oauth2_token_require $mcp_has_required_scope error=403;
        error_page 401 = @mcp_unauthorized;
        error_page 403 = @mcp_forbidden;
        proxy_pass http://127.0.0.1:18142;
    }
    location @mcp_unauthorized {
        internal;
        add_header WWW-Authenticate
            'Bearer resource_metadata="$mcp_metadata_uri", scope="$mcp_required_scope"'
            always;
        return 401;
    }
    location @mcp_forbidden {
        internal;
        add_header WWW-Authenticate
            'Bearer error="insufficient_scope", scope="$mcp_required_scope", resource_metadata="$mcp_metadata_uri"'
            always;
        return 403;
    }
--- request
GET /mcp
--- more_headers
Authorization: Bearer revoked-token
--- error_code: 401
--- response_headers_like
WWW-Authenticate: Bearer resource_metadata="http://localhost/\.well-known/oauth-protected-resource", scope="mcp:read"
