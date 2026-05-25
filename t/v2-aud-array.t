use Test::Nginx::Socket 'no_plan';

no_root_location();
no_shuffle();

run_tests();

__DATA__

=== V2-1: aud matches as a string (plain string literal) -- passes (200)
--- http_config
    server {
        listen 18090;
        location / { return 200 "backend-ok"; }
    }
--- config
    location / {
        auth_jwt "test-realm";
        auth_jwt_key_file $TEST_NGINX_HTML_DIR/keys.json;
        auth_jwt_require_claim aud eq "https://mcp.example.com/mcp";
        proxy_pass http://127.0.0.1:18090;
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
Authorization: Bearer eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiIsImtpZCI6InRlc3QxIn0.eyJhdWQiOiJodHRwczovL21jcC5leGFtcGxlLmNvbS9tY3AiLCJleHAiOjQxMzM4NjIwMDB9.MtiVJaFhiWQ54_mWukUgzJxU0K_jJNe2lQQxcHT9zIE
--- error_code: 200

=== V2-2: aud mismatches as a string -- 401
--- http_config
    server {
        listen 18091;
        location / { return 200 "backend-ok"; }
    }
--- config
    location / {
        auth_jwt "test-realm";
        auth_jwt_key_file $TEST_NGINX_HTML_DIR/keys.json;
        auth_jwt_require_claim aud eq "https://mcp.example.com/mcp";
        proxy_pass http://127.0.0.1:18091;
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
Authorization: Bearer eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiIsImtpZCI6InRlc3QxIn0.eyJhdWQiOiJodHRwczovL290aGVyLmV4YW1wbGUuY29tIiwiZXhwIjo0MTMzODYyMDAwfQ.RPN6Qp6d1v_R0F6VYL5j4znYGmVdfCPJAnqBlMKQODQ
--- error_code: 401

=== V2-3: aud is an array with the eq operator -- JSON array vs string mismatch (401)
--- http_config
    server {
        listen 18092;
        location / { return 200 "backend-ok"; }
    }
--- config
    location / {
        auth_jwt "test-realm";
        auth_jwt_key_file $TEST_NGINX_HTML_DIR/keys.json;
        auth_jwt_require_claim aud eq "https://mcp.example.com/mcp";
        proxy_pass http://127.0.0.1:18092;
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
Authorization: Bearer eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiIsImtpZCI6InRlc3QxIn0.eyJhdWQiOlsiaHR0cHM6Ly9tY3AuZXhhbXBsZS5jb20vbWNwIiwiaHR0cHM6Ly9vdGhlci5leGFtcGxlLmNvbSJdLCJleHAiOjQxMzM4NjIwMDB9.pef7MFnIcgX5ip9mt59tpgjV1MKdZVEWNlkMKz4o_Yg
--- error_code: 401

=== V2-4: aud is an array with JQ-like .aud[0] eq -- 200 when the first array element matches
--- http_config
    server {
        listen 18093;
        location / { return 200 "backend-ok"; }
    }
--- config
    location / {
        auth_jwt "test-realm";
        auth_jwt_key_file $TEST_NGINX_HTML_DIR/keys.json;
        auth_jwt_require_claim .aud[0] eq "https://mcp.example.com/mcp";
        proxy_pass http://127.0.0.1:18093;
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
Authorization: Bearer eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiIsImtpZCI6InRlc3QxIn0.eyJhdWQiOlsiaHR0cHM6Ly9tY3AuZXhhbXBsZS5jb20vbWNwIiwiaHR0cHM6Ly9vdGhlci5leGFtcGxlLmNvbSJdLCJleHAiOjQxMzM4NjIwMDB9.pef7MFnIcgX5ip9mt59tpgjV1MKdZVEWNlkMKz4o_Yg
--- error_code: 200

=== V2-5: aud is an array with the any operator (array intersection) -- 200 when they intersect
--- http_config
    server {
        listen 18094;
        location / { return 200 "backend-ok"; }
    }
--- config
    location / {
        auth_jwt "test-realm";
        auth_jwt_key_file $TEST_NGINX_HTML_DIR/keys.json;
        auth_jwt_require_claim aud any json=["https://mcp.example.com/mcp"];
        proxy_pass http://127.0.0.1:18094;
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
Authorization: Bearer eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiIsImtpZCI6InRlc3QxIn0.eyJhdWQiOlsiaHR0cHM6Ly9vdGhlci5leGFtcGxlLmNvbSIsImh0dHBzOi8vbWNwLmV4YW1wbGUuY29tL21jcCJdLCJleHAiOjQxMzM4NjIwMDB9._QvgjrN6Cc1HfxmMDPovnkDuY_pigN5W4CIAdCvfN4o
--- error_code: 200

=== V2-6: aud is an array with the any operator -- 401 when there is no common element
--- http_config
    server {
        listen 18095;
        location / { return 200 "backend-ok"; }
    }
--- config
    location / {
        auth_jwt "test-realm";
        auth_jwt_key_file $TEST_NGINX_HTML_DIR/keys.json;
        auth_jwt_require_claim aud any json=["https://not-included.example.com/mcp"];
        proxy_pass http://127.0.0.1:18095;
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
Authorization: Bearer eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiIsImtpZCI6InRlc3QxIn0.eyJhdWQiOlsiaHR0cHM6Ly9vdGhlci5leGFtcGxlLmNvbSIsImh0dHBzOi8vbWNwLmV4YW1wbGUuY29tL21jcCJdLCJleHAiOjQxMzM4NjIwMDB9._QvgjrN6Cc1HfxmMDPovnkDuY_pigN5W4CIAdCvfN4o
--- error_code: 401

=== V2-7: via a variable -- 200 when the value is a JSON-encoded string
--- http_config
    server {
        listen 18096;
        location / { return 200 "backend-ok"; }
    }
--- config
    set $mcp_canonical_uri_json '"https://mcp.example.com/mcp"';

    location / {
        auth_jwt "test-realm";
        auth_jwt_key_file $TEST_NGINX_HTML_DIR/keys.json;
        auth_jwt_require_claim aud eq $mcp_canonical_uri_json;
        proxy_pass http://127.0.0.1:18096;
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
Authorization: Bearer eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiIsImtpZCI6InRlc3QxIn0.eyJhdWQiOiJodHRwczovL21jcC5leGFtcGxlLmNvbS9tY3AiLCJleHAiOjQxMzM4NjIwMDB9.MtiVJaFhiWQ54_mWukUgzJxU0K_jJNe2lQQxcHT9zIE
--- error_code: 200
