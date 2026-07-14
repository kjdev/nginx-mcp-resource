use Test::Nginx::Socket 'no_plan';

no_root_location();
no_shuffle();

# nginx-ratelimit persists counters in Redis across prove invocations;
# FLUSHDB keeps TEST 1's second request deterministically over the limit
# instead of depending on a previous run's TTL having already expired.
my $redis_port = $ENV{TEST_NGINX_REDIS_PORT} || 6379;
system("redis-cli -p $redis_port FLUSHDB >/dev/null 2>&1") == 0
    or system("valkey-cli -p $redis_port FLUSHDB >/dev/null 2>&1");

run_tests();

__DATA__

=== TEST 1: jwt + ratelimit -- second request from the same sub -> 429
--- http_config
    map "" $mcp_canonical_uri      { default "http://localhost/mcp"; }
    map "" $mcp_canonical_uri_json { default '"http://localhost/mcp"'; }
    map "" $mcp_metadata_uri       { default "http://localhost/.well-known/oauth-protected-resource"; }
    map "" $mcp_required_scope     { default "mcp:read"; }
    auth_jwt_claim_set $jwt_scope scope;
    auth_jwt_claim_set $jwt_sub   sub;
    map $jwt_scope $mcp_has_required_scope {
        default 0;
        "~(^|\s)mcp:read(\s|$)" 1;
    }

    upstream mcp_ratelimit_redis {
        server 127.0.0.1:6379;
        keepalive 32;
    }
    ratelimit_zone mcp_peruser_a key=$jwt_sub requests=1 period=1m;

    server {
        listen 18160;
        location / {
            default_type text/plain;
            return 200 "backend-ok";
        }
    }
--- config
    location /mcp {
        auth_jwt "mcp";
        auth_jwt_key_file $TEST_NGINX_HTML_DIR/keys.json;
        auth_jwt_www_authenticate off;
        auth_jwt_phase preaccess;
        auth_jwt_require_claim aud eq $mcp_canonical_uri_json;
        auth_jwt_require $mcp_has_required_scope error=403;

        ratelimit zone=mcp_peruser_a;
        ratelimit_pass mcp_ratelimit_redis;
        ratelimit_headers on;
        ratelimit_on_error deny;

        error_page 401 = @mcp_unauthorized;
        error_page 403 = @mcp_forbidden;
        proxy_set_header Authorization "";
        proxy_pass http://127.0.0.1:18160;
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
--- request eval
["GET /mcp", "GET /mcp"]
--- more_headers
Authorization: Bearer eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiIsImtpZCI6InRlc3QxIn0.eyJhdWQiOiJodHRwOi8vbG9jYWxob3N0L21jcCIsInNjb3BlIjoibWNwOnJlYWQiLCJzdWIiOiJ1c2VyLWp3dC1hIiwiZXhwIjo0MTMzODYyMDAwfQ._yJr_N5H14WI6WC8No4cSXhCiQlJDVnsqA-jmpXYkeI
--- error_code eval
[200, 429]
--- response_body_like eval
["backend-ok", "429 Too Many Requests"]

=== TEST 2: jwt + ratelimit -- a different sub is limited independently
--- http_config
    map "" $mcp_canonical_uri      { default "http://localhost/mcp"; }
    map "" $mcp_canonical_uri_json { default '"http://localhost/mcp"'; }
    map "" $mcp_metadata_uri       { default "http://localhost/.well-known/oauth-protected-resource"; }
    map "" $mcp_required_scope     { default "mcp:read"; }
    auth_jwt_claim_set $jwt_scope scope;
    auth_jwt_claim_set $jwt_sub   sub;
    map $jwt_scope $mcp_has_required_scope {
        default 0;
        "~(^|\s)mcp:read(\s|$)" 1;
    }

    upstream mcp_ratelimit_redis {
        server 127.0.0.1:6379;
        keepalive 32;
    }
    ratelimit_zone mcp_peruser_a key=$jwt_sub requests=1 period=1m;

    server {
        listen 18161;
        location / {
            default_type text/plain;
            return 200 "backend-ok";
        }
    }
--- config
    location /mcp {
        auth_jwt "mcp";
        auth_jwt_key_file $TEST_NGINX_HTML_DIR/keys.json;
        auth_jwt_www_authenticate off;
        auth_jwt_phase preaccess;
        auth_jwt_require_claim aud eq $mcp_canonical_uri_json;
        auth_jwt_require $mcp_has_required_scope error=403;

        ratelimit zone=mcp_peruser_a;
        ratelimit_pass mcp_ratelimit_redis;
        ratelimit_headers on;
        ratelimit_on_error deny;

        error_page 401 = @mcp_unauthorized;
        error_page 403 = @mcp_forbidden;
        proxy_set_header Authorization "";
        proxy_pass http://127.0.0.1:18161;
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
Authorization: Bearer eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiIsImtpZCI6InRlc3QxIn0.eyJhdWQiOiJodHRwOi8vbG9jYWxob3N0L21jcCIsInNjb3BlIjoibWNwOnJlYWQiLCJzdWIiOiJ1c2VyLWp3dC1iIiwiZXhwIjo0MTMzODYyMDAwfQ.bgPe9BhPIq_X7uKHQRu_1Pa1H5GAxraD57V41c4-8FA
--- error_code: 200
--- response_body: backend-ok

=== TEST 3: jwt + ratelimit -- token passthrough is still suppressed under the limit
--- http_config
    map "" $mcp_canonical_uri      { default "http://localhost/mcp"; }
    map "" $mcp_canonical_uri_json { default '"http://localhost/mcp"'; }
    map "" $mcp_metadata_uri       { default "http://localhost/.well-known/oauth-protected-resource"; }
    map "" $mcp_required_scope     { default "mcp:read"; }
    auth_jwt_claim_set $jwt_scope scope;
    auth_jwt_claim_set $jwt_sub   sub;
    map $jwt_scope $mcp_has_required_scope {
        default 0;
        "~(^|\s)mcp:read(\s|$)" 1;
    }

    upstream mcp_ratelimit_redis {
        server 127.0.0.1:6379;
        keepalive 32;
    }
    ratelimit_zone mcp_peruser_c key=$jwt_sub requests=1 period=1m;

    server {
        listen 18162;
        location / {
            default_type text/plain;
            return 200 "auth=[$http_authorization]";
        }
    }
--- config
    location /mcp {
        auth_jwt "mcp";
        auth_jwt_key_file $TEST_NGINX_HTML_DIR/keys.json;
        auth_jwt_www_authenticate off;
        auth_jwt_phase preaccess;
        auth_jwt_require_claim aud eq $mcp_canonical_uri_json;
        auth_jwt_require $mcp_has_required_scope error=403;

        ratelimit zone=mcp_peruser_c;
        ratelimit_pass mcp_ratelimit_redis;
        ratelimit_headers on;
        ratelimit_on_error deny;

        error_page 401 = @mcp_unauthorized;
        error_page 403 = @mcp_forbidden;
        proxy_set_header Authorization "";
        proxy_pass http://127.0.0.1:18162;
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
Authorization: Bearer eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiIsImtpZCI6InRlc3QxIn0.eyJhdWQiOiJodHRwOi8vbG9jYWxob3N0L21jcCIsInNjb3BlIjoibWNwOnJlYWQiLCJzdWIiOiJ1c2VyLWp3dC1jIiwiZXhwIjo0MTMzODYyMDAwfQ.7gmdfUQdp7VMEVipCsF1jq-JUeUm0HqIoWu6Uu7_8h8
--- error_code: 200
--- response_body: auth=[]
