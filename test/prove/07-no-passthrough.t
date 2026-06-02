use Test::Nginx::Socket 'no_plan';

no_root_location();
no_shuffle();

run_tests();

__DATA__

=== TEST 1: upstream sees empty Authorization header (token passthrough disabled)
--- http_config
    server {
        listen 18136;
        location / {
            default_type text/plain;
            return 200 "auth=[$http_authorization]";
        }
    }
    map "" $mcp_canonical_uri      { default "http://localhost/mcp"; }
    map "" $mcp_canonical_uri_json { default '"http://localhost/mcp"'; }
    map "" $mcp_metadata_uri       { default "http://localhost/.well-known/oauth-protected-resource"; }
    map "" $mcp_required_scope { default "mcp:read"; }
    auth_jwt_claim_set $jwt_scope scope;
    map $jwt_scope $mcp_has_required_scope {
        default 0;
        "~(^|\s)mcp:read(\s|$)" 1;
    }
--- config
    location /mcp {
        auth_jwt "mcp";
        auth_jwt_key_file $TEST_NGINX_HTML_DIR/keys.json;
        auth_jwt_www_authenticate off;
        auth_jwt_require_claim aud eq $mcp_canonical_uri_json;
        auth_jwt_require $mcp_has_required_scope error=403;
        error_page 401 = @mcp_unauthorized;
        error_page 403 = @mcp_forbidden;
        proxy_set_header Authorization "";
        proxy_pass http://127.0.0.1:18136;
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
--- user_files
>>> keys.json
{
  "keys": [
    {"kty":"oct","use":"sig","kid":"test1","k":"dGVzdDEuc2VjcmV0","alg":"HS256"}
  ]
}
--- request
GET /mcp
--- more_headers
Authorization: Bearer eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiIsImtpZCI6InRlc3QxIn0.eyJhdWQiOiJodHRwOi8vbG9jYWxob3N0L21jcCIsInNjb3BlIjoibWNwOnJlYWQiLCJleHAiOjQxMzM4NjIwMDB9.nBh1pCBeQSaSbXDVeDpGC57T_yaHfdjvnNh0eHc0FZ4
--- error_code: 200
--- response_body: auth=[]
