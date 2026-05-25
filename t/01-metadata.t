use Test::Nginx::Socket 'no_plan';

no_root_location();
no_shuffle();

run_tests();

__DATA__

=== TEST 1: well-known endpoint returns 200 + application/json
--- config
    location = /.well-known/oauth-protected-resource {
        default_type application/json;
        return 200 '{"resource":"http://localhost/mcp","authorization_servers":["https://auth.example.com"],"scopes_supported":["mcp:read","mcp:write"],"bearer_methods_supported":["header"]}';
    }
--- request
GET /.well-known/oauth-protected-resource
--- error_code: 200
--- response_headers
Content-Type: application/json

=== TEST 2: metadata JSON contains RFC 9728 required fields
--- config
    location = /.well-known/oauth-protected-resource {
        default_type application/json;
        return 200 '{"resource":"http://localhost/mcp","authorization_servers":["https://auth.example.com"],"scopes_supported":["mcp:read","mcp:write"],"bearer_methods_supported":["header"]}';
    }
--- request
GET /.well-known/oauth-protected-resource
--- response_body_like eval
qr/"resource":"http:\/\/localhost\/mcp".*"authorization_servers":\["https:\/\/auth\.example\.com"\]/
