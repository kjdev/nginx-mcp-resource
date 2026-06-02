use Test::Nginx::Socket 'no_plan';

no_root_location();
no_shuffle();

run_tests();

__DATA__

=== V3-1: auth_jwt_require check succeeds -- 200
--- http_config
    server {
        listen 18100;
        location / { return 200 "backend-ok"; }
    }
    map $jwt_claim_scope $has_required_scope {
        default 0;
        "~(^|\s)mcp:read(\s|$)" 1;
    }
--- config
    location / {
        auth_jwt "test-realm";
        auth_jwt_key_file $TEST_NGINX_HTML_DIR/keys.json;
        auth_jwt_require $has_required_scope error=403;
        proxy_pass http://127.0.0.1:18100;
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
Authorization: Bearer eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiIsImtpZCI6InRlc3QxIn0.eyJzY29wZSI6Im1jcDpyZWFkIiwiZXhwIjo0MTMzODYyMDAwfQ.zSZuT51BTXCdYrTbjUaNYUJNd-i8xagheHWYQBmBEYk
--- error_code: 200

=== V3-2: auth_jwt_require check fails (no error= specified) -- default 401
--- http_config
    server {
        listen 18101;
        location / { return 200 "backend-ok"; }
    }
    map $jwt_claim_scope $has_required_scope {
        default 0;
        "~(^|\s)mcp:read(\s|$)" 1;
    }
--- config
    location / {
        auth_jwt "test-realm";
        auth_jwt_key_file $TEST_NGINX_HTML_DIR/keys.json;
        auth_jwt_require $has_required_scope;
        proxy_pass http://127.0.0.1:18101;
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
Authorization: Bearer eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiIsImtpZCI6InRlc3QxIn0.eyJzY29wZSI6Im90aGVyOnNjb3BlIiwiZXhwIjo0MTMzODYyMDAwfQ.HnflgHGBr1W-SQ47AyoySdQJCsS9TagALSFSk4X_pX8
--- error_code: 401

=== V3-3: auth_jwt_require check fails + error=403 -- 403 is returned
--- http_config
    server {
        listen 18102;
        location / { return 200 "backend-ok"; }
    }
    map $jwt_claim_scope $has_required_scope {
        default 0;
        "~(^|\s)mcp:read(\s|$)" 1;
    }
--- config
    location / {
        auth_jwt "test-realm";
        auth_jwt_key_file $TEST_NGINX_HTML_DIR/keys.json;
        auth_jwt_require $has_required_scope error=403;
        proxy_pass http://127.0.0.1:18102;
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
Authorization: Bearer eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiIsImtpZCI6InRlc3QxIn0.eyJzY29wZSI6Im90aGVyOnNjb3BlIiwiZXhwIjo0MTMzODYyMDAwfQ.HnflgHGBr1W-SQ47AyoySdQJCsS9TagALSFSk4X_pX8
--- error_code: 403

=== V3-4: error=403 + error_page returns an MCP-format insufficient_scope header
--- http_config
    server {
        listen 18103;
        location / { return 200 "backend-ok"; }
    }
    map $jwt_claim_scope $has_required_scope {
        default 0;
        "~(^|\s)mcp:read(\s|$)" 1;
    }
--- config
    set $mcp_metadata_uri "http://localhost/.well-known/oauth-protected-resource";
    set $mcp_required_scope "mcp:read";

    location / {
        auth_jwt "test-realm";
        auth_jwt_key_file $TEST_NGINX_HTML_DIR/keys.json;
        auth_jwt_require $has_required_scope error=403;
        error_page 403 = @mcp_forbidden;
        proxy_pass http://127.0.0.1:18103;
    }

    location @mcp_forbidden {
        internal;
        add_header WWW-Authenticate
            'Bearer error="insufficient_scope", scope="$mcp_required_scope", resource_metadata="$mcp_metadata_uri"'
            always;
        return 403;
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
Authorization: Bearer eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiIsImtpZCI6InRlc3QxIn0.eyJzY29wZSI6Im90aGVyOnNjb3BlIiwiZXhwIjo0MTMzODYyMDAwfQ.HnflgHGBr1W-SQ47AyoySdQJCsS9TagALSFSk4X_pX8
--- error_code: 403
--- response_headers_like
WWW-Authenticate: .*error="insufficient_scope".*scope="mcp:read".*resource_metadata="http://localhost/\.well-known/oauth-protected-resource"
