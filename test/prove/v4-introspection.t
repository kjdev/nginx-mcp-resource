use Test::Nginx::Socket 'no_plan';

no_root_location();
no_shuffle();

run_tests();

__DATA__

=== V4-1: active=true + scope contains the required scope -- 200
--- http_config
    auth_oauth2_token_client_id mcp-rs;
    auth_oauth2_token_client_secret rs-secret;

    server {
        listen 18110;
        location / { return 200 "backend-ok"; }
    }

    server {
        listen 18111;
        location / {
            default_type application/json;
            return 200 '{"active":true,"sub":"user1","scope":"mcp:read mcp:write","client_id":"mcp-client","exp":4133862000}';
        }
    }
--- config
    location = /_introspect {
        internal;
        proxy_pass http://127.0.0.1:18111/;
    }

    location / {
        auth_oauth2_token_introspect on;
        auth_oauth2_token_introspect_endpoint /_introspect;
        proxy_pass http://127.0.0.1:18110;
    }
--- request
GET /
--- more_headers
Authorization: Bearer some-opaque-token
--- error_code: 200

=== V4-2: active=false -- the module returns 401 automatically
--- http_config
    auth_oauth2_token_client_id mcp-rs;
    auth_oauth2_token_client_secret rs-secret;

    server {
        listen 18112;
        location / { return 200 "backend-ok"; }
    }

    server {
        listen 18113;
        location / {
            default_type application/json;
            return 200 '{"active":false}';
        }
    }
--- config
    location = /_introspect {
        internal;
        proxy_pass http://127.0.0.1:18113/;
    }

    location / {
        auth_oauth2_token_introspect on;
        auth_oauth2_token_introspect_endpoint /_introspect;
        proxy_pass http://127.0.0.1:18112;
    }
--- request
GET /
--- more_headers
Authorization: Bearer revoked-token
--- error_code: 401
--- response_headers_like
WWW-Authenticate: Bearer error="invalid_token"

=== V4-3: auth_oauth2_token_claim_set exposes aud as a variable -- can be forwarded upstream
--- http_config
    auth_oauth2_token_client_id mcp-rs;
    auth_oauth2_token_client_secret rs-secret;
    auth_oauth2_token_claim_set $oauth2_aud aud;

    server {
        listen 18114;
        location / {
            default_type text/plain;
            return 200 "aud=$http_x_token_aud";
        }
    }

    server {
        listen 18115;
        location / {
            default_type application/json;
            return 200 '{"active":true,"sub":"u","scope":"mcp:read","aud":"https://mcp.example.com/mcp","exp":4133862000}';
        }
    }
--- config
    location = /_introspect {
        internal;
        proxy_pass http://127.0.0.1:18115/;
    }

    location / {
        auth_oauth2_token_introspect on;
        auth_oauth2_token_introspect_endpoint /_introspect;
        proxy_set_header X-Token-Aud $oauth2_aud;
        proxy_pass http://127.0.0.1:18114;
    }
--- request
GET /
--- more_headers
Authorization: Bearer some-opaque-token
--- error_code: 200
--- response_body: aud=https://mcp.example.com/mcp

=== V4-4: auth_oauth2_token_require evaluates insufficient scope in the access phase -> 403
--- http_config
    auth_oauth2_token_client_id mcp-rs;
    auth_oauth2_token_client_secret rs-secret;
    auth_oauth2_token_claim_set $oauth2_scope scope;

    map $oauth2_scope $mcp_has_required_scope {
        default 0;
        "~(^|\s)mcp:read(\s|$)" 1;
    }

    server {
        listen 18116;
        location / { return 200 "backend-ok"; }
    }

    server {
        listen 18117;
        location / {
            default_type application/json;
            return 200 '{"active":true,"sub":"u","scope":"other:scope","exp":4133862000}';
        }
    }
--- config
    location = /_introspect {
        internal;
        proxy_pass http://127.0.0.1:18117/;
    }

    location / {
        auth_oauth2_token_introspect on;
        auth_oauth2_token_introspect_endpoint /_introspect;
        auth_oauth2_token_require $mcp_has_required_scope error=403;
        proxy_pass http://127.0.0.1:18116;
    }
--- request
GET /
--- more_headers
Authorization: Bearer some-opaque-token
--- error_code: 403

=== V4-5: auth_oauth2_token_require with sufficient scope -- 200 (happy-path regression)
--- http_config
    auth_oauth2_token_client_id mcp-rs;
    auth_oauth2_token_client_secret rs-secret;
    auth_oauth2_token_claim_set $oauth2_scope scope;

    map $oauth2_scope $mcp_has_required_scope {
        default 0;
        "~(^|\s)mcp:read(\s|$)" 1;
    }

    server {
        listen 18118;
        location / { return 200 "backend-ok"; }
    }

    server {
        listen 18119;
        location / {
            default_type application/json;
            return 200 '{"active":true,"sub":"u","scope":"mcp:read mcp:write","exp":4133862000}';
        }
    }
--- config
    location = /_introspect {
        internal;
        proxy_pass http://127.0.0.1:18119/;
    }

    location / {
        auth_oauth2_token_introspect on;
        auth_oauth2_token_introspect_endpoint /_introspect;
        auth_oauth2_token_require $mcp_has_required_scope error=403;
        proxy_pass http://127.0.0.1:18118;
    }
--- request
GET /
--- more_headers
Authorization: Bearer some-opaque-token
--- error_code: 200

=== V4-6: complete MCP RS -- aud mismatch -> 401, insufficient scope -> 403 evaluated in parallel
--- http_config
    auth_oauth2_token_client_id mcp-rs;
    auth_oauth2_token_client_secret rs-secret;
    auth_oauth2_token_claim_set $oauth2_aud   aud;
    auth_oauth2_token_claim_set $oauth2_scope scope;

    map $oauth2_aud $mcp_aud_ok {
        default 0;
        "https://mcp.example.com/mcp" 1;
    }
    map $oauth2_scope $mcp_has_required_scope {
        default 0;
        "~(^|\s)mcp:read(\s|$)" 1;
    }

    server {
        listen 18120;
        location / { return 200 "backend-ok"; }
    }

    # response for the aud mismatch
    server {
        listen 18121;
        location / {
            default_type application/json;
            return 200 '{"active":true,"sub":"u","scope":"mcp:read","aud":"https://other.example.com/mcp","exp":4133862000}';
        }
    }
--- config
    location = /_introspect {
        internal;
        proxy_pass http://127.0.0.1:18121/;
    }

    location / {
        auth_oauth2_token_introspect on;
        auth_oauth2_token_introspect_endpoint /_introspect;
        auth_oauth2_token_require $mcp_aud_ok;
        auth_oauth2_token_require $mcp_has_required_scope error=403;
        proxy_pass http://127.0.0.1:18120;
    }
--- request
GET /
--- more_headers
Authorization: Bearer some-opaque-token
--- error_code: 401

=== V4-7: complete MCP RS -- aud match + insufficient scope -> 403
--- http_config
    auth_oauth2_token_client_id mcp-rs;
    auth_oauth2_token_client_secret rs-secret;
    auth_oauth2_token_claim_set $oauth2_aud   aud;
    auth_oauth2_token_claim_set $oauth2_scope scope;

    map $oauth2_aud $mcp_aud_ok {
        default 0;
        "https://mcp.example.com/mcp" 1;
    }
    map $oauth2_scope $mcp_has_required_scope {
        default 0;
        "~(^|\s)mcp:read(\s|$)" 1;
    }

    server {
        listen 18122;
        location / { return 200 "backend-ok"; }
    }

    server {
        listen 18123;
        location / {
            default_type application/json;
            return 200 '{"active":true,"sub":"u","scope":"other:scope","aud":"https://mcp.example.com/mcp","exp":4133862000}';
        }
    }
--- config
    location = /_introspect {
        internal;
        proxy_pass http://127.0.0.1:18123/;
    }

    location / {
        auth_oauth2_token_introspect on;
        auth_oauth2_token_introspect_endpoint /_introspect;
        auth_oauth2_token_require $mcp_aud_ok;
        auth_oauth2_token_require $mcp_has_required_scope error=403;
        proxy_pass http://127.0.0.1:18122;
    }
--- request
GET /
--- more_headers
Authorization: Bearer some-opaque-token
--- error_code: 403

=== V4-8: complete MCP RS -- aud match + sufficient scope -> 200 (happy path)
--- http_config
    auth_oauth2_token_client_id mcp-rs;
    auth_oauth2_token_client_secret rs-secret;
    auth_oauth2_token_claim_set $oauth2_aud   aud;
    auth_oauth2_token_claim_set $oauth2_scope scope;

    map $oauth2_aud $mcp_aud_ok {
        default 0;
        "https://mcp.example.com/mcp" 1;
    }
    map $oauth2_scope $mcp_has_required_scope {
        default 0;
        "~(^|\s)mcp:read(\s|$)" 1;
    }

    server {
        listen 18124;
        location / { return 200 "backend-ok"; }
    }

    server {
        listen 18125;
        location / {
            default_type application/json;
            return 200 '{"active":true,"sub":"u","scope":"mcp:read mcp:write","aud":"https://mcp.example.com/mcp","exp":4133862000}';
        }
    }
--- config
    location = /_introspect {
        internal;
        proxy_pass http://127.0.0.1:18125/;
    }

    location / {
        auth_oauth2_token_introspect on;
        auth_oauth2_token_introspect_endpoint /_introspect;
        auth_oauth2_token_require $mcp_aud_ok;
        auth_oauth2_token_require $mcp_has_required_scope error=403;
        proxy_pass http://127.0.0.1:18124;
    }
--- request
GET /
--- more_headers
Authorization: Bearer some-opaque-token
--- error_code: 200
