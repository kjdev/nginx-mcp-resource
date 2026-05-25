# syntax=docker/dockerfile:1
#
# nginx-mcp-resource container image
#
# At startup, builds the full nginx config from environment variables (MCP_*)
# and templates under /etc/nginx/templates/, then runs as the MCP Resource
# Server.

FROM ghcr.io/kjdev/nginx-auth-jwt/nginx:0.14.0 AS nginx-auth-jwt
FROM ghcr.io/kjdev/nginx-auth-oauth2-token/nginx:0.4.1 AS nginx-auth-oauth2-token

FROM nginx:alpine

# Install jansson (required by nginx-auth-jwt) and jq (used by the entrypoint
# for JSON generation and regex escaping).
RUN --mount=type=cache,target=/var/cache/apk \
    apk add --no-cache jansson jq

# Copy the auth-module .so files into /usr/lib/nginx/modules/.
# Previous Dockerfiles used `sed` to inject a load_module line right before the
# `events` block of nginx.conf, but the new design declares load_module
# statically in the template (nginx.conf.template), so that step is no longer
# needed (envsubst overwrites nginx.conf at startup anyway, discarding any
# sed-based edits).
COPY --from=nginx-auth-jwt \
    /usr/lib/nginx/modules/ngx_http_auth_jwt_module.so \
    /usr/lib/nginx/modules/ngx_http_auth_jwt_module.so
COPY --from=nginx-auth-oauth2-token \
    /usr/lib/nginx/modules/ngx_http_auth_oauth2_token_module.so \
    /usr/lib/nginx/modules/ngx_http_auth_oauth2_token_module.so

# Drop the default config; our nginx.conf.template does not include
# /etc/nginx/conf.d/*.conf.
RUN rm -f /etc/nginx/conf.d/default.conf

# Pure static snippets (referencing only nginx $mcp_* variables) go under
# /etc/nginx/mcp-conf/. The bare-nginx-user-facing conf/ directory is reused
# as-is.
COPY conf/ /etc/nginx/mcp-conf/

# Templates (containing ${MCP_*}) go under /etc/nginx/templates/.
# nginx:alpine's 20-envsubst-on-templates.sh walks this directory and expands:
#   templates/nginx.conf.template          -> /etc/nginx/nginx.conf
#   templates/snippets/*.conf.template     -> /etc/nginx/snippets/*.conf
COPY build/docker/templates/ /etc/nginx/templates/

# Entrypoint scripts (env validation, derived-value generation, pre-flight nginx -t).
COPY build/docker/docker-entrypoint.d/ /docker-entrypoint.d/

# HEALTHCHECK wrapper.
COPY build/docker/healthcheck.sh /usr/local/bin/mcp-healthcheck.sh
RUN chmod +x /usr/local/bin/mcp-healthcheck.sh

# Configure envsubst's output directory (under /etc/nginx) and variable
# filter (only ${MCP_*}).
# - NGINX_ENVSUBST_OUTPUT_DIR=/etc/nginx makes templates/nginx.conf.template
#   overwrite /etc/nginx/nginx.conf.
# - NGINX_ENVSUBST_FILTER=^MCP_ guards lowercase nginx vars ($mcp_*) from
#   being touched by envsubst.
ENV NGINX_ENVSUBST_OUTPUT_DIR=/etc/nginx \
    NGINX_ENVSUBST_FILTER=^MCP_

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD ["/usr/local/bin/mcp-healthcheck.sh"]
