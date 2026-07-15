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

=== TEST 1: introspect + ratelimit -- second request from the same sub -> 429
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

    upstream mcp_ratelimit_redis {
        server 127.0.0.1:6379;
        keepalive 32;
    }
    ratelimit_zone mcp_peruser_a key=$oauth2_token_sub requests=1 period=1m;

    server {
        listen 18150;
        location / {
            default_type text/plain;
            return 200 "backend-ok";
        }
    }
    server {
        listen 18151;
        location / {
            default_type application/json;
            return 200 '{"active":true,"sub":"user-a","scope":"mcp:read","aud":"http://localhost/mcp","exp":4133862000}';
        }
    }
--- config
    location = /_introspect {
        internal;
        proxy_pass http://127.0.0.1:18151/;
    }
    location /mcp {
        auth_oauth2_token_introspect          on;
        auth_oauth2_token_introspect_endpoint /_introspect;
        auth_oauth2_token_www_authenticate    off;
        auth_oauth2_token_phase               preaccess;
        auth_oauth2_token_require $mcp_aud_ok;
        auth_oauth2_token_require $mcp_has_required_scope error=403;
        auth_oauth2_token_require $oauth2_token_sub;

        ratelimit zone=mcp_peruser_a;
        ratelimit_pass mcp_ratelimit_redis;
        ratelimit_headers on;
        ratelimit_on_error deny;

        error_page 401 = @mcp_unauthorized;
        error_page 403 = @mcp_forbidden;
        proxy_set_header Authorization "";
        proxy_pass http://127.0.0.1:18150;
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
--- request eval
["GET /mcp", "GET /mcp"]
--- more_headers
Authorization: Bearer some-opaque-token
--- error_code eval
[200, 429]
--- response_body_like eval
["backend-ok", "429 Too Many Requests"]

=== TEST 2: introspect + ratelimit -- a different sub is limited independently
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

    upstream mcp_ratelimit_redis {
        server 127.0.0.1:6379;
        keepalive 32;
    }
    ratelimit_zone mcp_peruser_a key=$oauth2_token_sub requests=1 period=1m;

    server {
        listen 18152;
        location / {
            default_type text/plain;
            return 200 "backend-ok";
        }
    }
    server {
        listen 18153;
        location / {
            default_type application/json;
            return 200 '{"active":true,"sub":"user-b","scope":"mcp:read","aud":"http://localhost/mcp","exp":4133862000}';
        }
    }
--- config
    location = /_introspect {
        internal;
        proxy_pass http://127.0.0.1:18153/;
    }
    location /mcp {
        auth_oauth2_token_introspect          on;
        auth_oauth2_token_introspect_endpoint /_introspect;
        auth_oauth2_token_www_authenticate    off;
        auth_oauth2_token_phase               preaccess;
        auth_oauth2_token_require $mcp_aud_ok;
        auth_oauth2_token_require $mcp_has_required_scope error=403;
        auth_oauth2_token_require $oauth2_token_sub;

        ratelimit zone=mcp_peruser_a;
        ratelimit_pass mcp_ratelimit_redis;
        ratelimit_headers on;
        ratelimit_on_error deny;

        error_page 401 = @mcp_unauthorized;
        error_page 403 = @mcp_forbidden;
        proxy_set_header Authorization "";
        proxy_pass http://127.0.0.1:18152;
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
Authorization: Bearer some-opaque-token
--- error_code: 200
--- response_body: backend-ok

=== TEST 3: introspect + ratelimit -- token passthrough is still suppressed under the limit
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

    upstream mcp_ratelimit_redis {
        server 127.0.0.1:6379;
        keepalive 32;
    }
    ratelimit_zone mcp_peruser_c key=$oauth2_token_sub requests=1 period=1m;

    server {
        listen 18154;
        location / {
            default_type text/plain;
            return 200 "auth=[$http_authorization]";
        }
    }
    server {
        listen 18155;
        location / {
            default_type application/json;
            return 200 '{"active":true,"sub":"user-c","scope":"mcp:read","aud":"http://localhost/mcp","exp":4133862000}';
        }
    }
--- config
    location = /_introspect {
        internal;
        proxy_pass http://127.0.0.1:18155/;
    }
    location /mcp {
        auth_oauth2_token_introspect          on;
        auth_oauth2_token_introspect_endpoint /_introspect;
        auth_oauth2_token_www_authenticate    off;
        auth_oauth2_token_phase               preaccess;
        auth_oauth2_token_require $mcp_aud_ok;
        auth_oauth2_token_require $mcp_has_required_scope error=403;
        auth_oauth2_token_require $oauth2_token_sub;

        ratelimit zone=mcp_peruser_c;
        ratelimit_pass mcp_ratelimit_redis;
        ratelimit_headers on;
        ratelimit_on_error deny;

        error_page 401 = @mcp_unauthorized;
        error_page 403 = @mcp_forbidden;
        proxy_set_header Authorization "";
        proxy_pass http://127.0.0.1:18154;
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
Authorization: Bearer some-opaque-token
--- error_code: 200
--- response_body: auth=[]

=== TEST 4: introspect + ratelimit -- an introspection response without a sub is rejected, not rate-limited as unlimited
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

    upstream mcp_ratelimit_redis {
        server 127.0.0.1:6379;
        keepalive 32;
    }
    ratelimit_zone mcp_peruser_d key=$oauth2_token_sub requests=1 period=1m;

    server {
        listen 18156;
        location / {
            default_type text/plain;
            return 200 "backend-ok";
        }
    }
    server {
        listen 18157;
        location / {
            default_type application/json;
            return 200 '{"active":true,"scope":"mcp:read","aud":"http://localhost/mcp","exp":4133862000}';
        }
    }
--- config
    location = /_introspect {
        internal;
        proxy_pass http://127.0.0.1:18157/;
    }
    location /mcp {
        auth_oauth2_token_introspect          on;
        auth_oauth2_token_introspect_endpoint /_introspect;
        auth_oauth2_token_www_authenticate    off;
        auth_oauth2_token_phase               preaccess;
        auth_oauth2_token_require $mcp_aud_ok;
        auth_oauth2_token_require $mcp_has_required_scope error=403;
        auth_oauth2_token_require $oauth2_token_sub;

        ratelimit zone=mcp_peruser_d;
        ratelimit_pass mcp_ratelimit_redis;
        ratelimit_headers on;
        ratelimit_on_error deny;

        error_page 401 = @mcp_unauthorized;
        error_page 403 = @mcp_forbidden;
        proxy_set_header Authorization "";
        proxy_pass http://127.0.0.1:18156;
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
--- request eval
["GET /mcp", "GET /mcp"]
--- more_headers
Authorization: Bearer some-opaque-token
--- error_code eval
[401, 401]
--- response_headers_like eval
[
    "WWW-Authenticate: Bearer resource_metadata=\"http://localhost/\\.well-known/oauth-protected-resource\", scope=\"mcp:read\"",
    "WWW-Authenticate: Bearer resource_metadata=\"http://localhost/\\.well-known/oauth-protected-resource\", scope=\"mcp:read\"",
]
