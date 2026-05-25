use Test::Nginx::Socket 'no_plan';

no_root_location();
no_shuffle();

run_tests();

__DATA__

=== test
--- config
location / {
}
--- request
GET /
--- error_code: 200
