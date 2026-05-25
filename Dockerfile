# syntax=docker/dockerfile:1

FROM ghcr.io/kjdev/nginx-auth-jwt/nginx:0.14.0 AS nginx-auth-jwt
FROM ghcr.io/kjdev/nginx-auth-oauth2-token/nginx:0.4.1 AS nginx-auth-oauth2-token

FROM nginx:alpine

RUN --mount=type=cache,target=/var/cache/apk sh -ex <<'EOS'
apk add jansson
# add load module
sed -i '/events {/i load_module "/usr/lib/nginx/modules/ngx_http_auth_jwt_module.so";' /etc/nginx/nginx.conf
sed -i '/events {/i load_module "/usr/lib/nginx/modules/ngx_http_auth_oauth2_token_module.so";' /etc/nginx/nginx.conf
EOS

COPY --from=nginx-auth-jwt /usr/lib/nginx/modules/ngx_http_auth_jwt_module.so /usr/lib/nginx/modules/ngx_http_auth_jwt_module.so
COPY --from=nginx-auth-oauth2-token /usr/lib/nginx/modules/ngx_http_auth_oauth2_token_module.so /usr/lib/nginx/modules/ngx_http_auth_oauth2_token_module.so
