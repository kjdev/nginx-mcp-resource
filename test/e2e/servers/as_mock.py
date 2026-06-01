#!/usr/bin/env python3
"""Mock Authorization Server (introspection-only) for the E2E suite.

Implements the minimum subset of RFC 7662 (POST application/x-www-form-urlencoded)
needed to drive ``auth_oauth2_token`` in introspection mode. The response is
keyed off the token value posted by the RS so a single instance can serve every
introspect-mode E2E scenario.

Recognised tokens (any other value yields ``{"active": false}``):

    e2e-valid              -> active=true,  aud=$CANONICAL, scope=mcp:read
    e2e-wrong-aud          -> active=true,  aud=other,      scope=mcp:read
    e2e-insufficient-scope -> active=true,  aud=$CANONICAL, scope=other:scope
    e2e-inactive           -> active=false  (explicit, for the inactive test)

The canonical URI is supplied via ``--canonical-uri`` so the RS-side
audience-binding map matches.

Also serves ``GET /.well-known/oauth-authorization-server`` returning a stub
RFC 8414 AS Metadata document. Inspector consults it after PRM discovery so
keeping it well-formed unblocks the auth flow even though we do not implement
DCR / authorize / token endpoints here.
"""

from __future__ import annotations

import argparse
import json
import logging
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs

LOG = logging.getLogger("e2e.as_mock")

CANONICAL_URI = ""  # populated from argv before serve_forever()
PUBLIC_AS_BASE = ""  # public URL of the AS as seen by Inspector / clients

WRONG_AUD = "https://other.example.com/mcp"


def _introspect_response(token: str) -> dict[str, object]:
    if token == "e2e-valid":
        return {
            "active": True,
            "sub": "u",
            "aud": CANONICAL_URI,
            "scope": "mcp:read",
            "exp": 4133862000,
        }
    if token == "e2e-wrong-aud":
        return {
            "active": True,
            "sub": "u",
            "aud": WRONG_AUD,
            "scope": "mcp:read",
            "exp": 4133862000,
        }
    if token == "e2e-insufficient-scope":
        return {
            "active": True,
            "sub": "u",
            "aud": CANONICAL_URI,
            "scope": "other:scope",
            "exp": 4133862000,
        }
    return {"active": False}


def _as_metadata() -> dict[str, object]:
    base = PUBLIC_AS_BASE.rstrip("/")
    return {
        "issuer": base,
        "authorization_endpoint": f"{base}/authorize",
        "token_endpoint": f"{base}/token",
        "introspection_endpoint": f"{base}/introspect",
        "registration_endpoint": f"{base}/register",
        "code_challenge_methods_supported": ["S256"],
        "grant_types_supported": ["authorization_code"],
        "response_types_supported": ["code"],
        "scopes_supported": ["mcp:read", "mcp:write"],
    }


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _write_json(self, status: int, payload: dict[str, object]) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self) -> None:
        if self.path != "/introspect":
            self._write_json(404, {"error": "not_found"})
            return
        length = int(self.headers.get("Content-Length", "0") or 0)
        raw = self.rfile.read(length).decode("utf-8") if length else ""
        params = parse_qs(raw, keep_blank_values=True)
        token = (params.get("token") or [""])[0]
        LOG.info("introspect token=%r", token)
        self._write_json(200, _introspect_response(token))

    def do_GET(self) -> None:
        if self.path in (
            "/.well-known/oauth-authorization-server",
            "/.well-known/openid-configuration",
        ):
            self._write_json(200, _as_metadata())
            return
        self._write_json(404, {"error": "not_found"})

    def log_message(self, fmt: str, *args: object) -> None:
        LOG.info("%s - %s", self.address_string(), fmt % args)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=18181)
    parser.add_argument(
        "--canonical-uri",
        required=True,
        help="Canonical resource URI used as 'aud' for e2e-valid tokens.",
    )
    parser.add_argument(
        "--public-as-base",
        required=True,
        help="Public base URL of this AS (used in AS Metadata response).",
    )
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.INFO, format="%(asctime)s %(name)s %(message)s"
    )

    global CANONICAL_URI, PUBLIC_AS_BASE
    CANONICAL_URI = args.canonical_uri
    PUBLIC_AS_BASE = args.public_as_base

    server = HTTPServer((args.host, args.port), Handler)
    LOG.info(
        "as-mock listening on %s:%s (canonical=%s, public_base=%s)",
        args.host,
        args.port,
        CANONICAL_URI,
        PUBLIC_AS_BASE,
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
