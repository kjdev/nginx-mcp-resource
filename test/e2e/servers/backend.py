#!/usr/bin/env python3
"""Echo backend used by the nginx-mcp-resource E2E suite.

Returns 200 with a small JSON body and surfaces the upstream-visible
``Authorization`` header via ``X-Echo-Authorization`` so the E2E driver can
assert that nginx stripped it before proxying. Stays silent on stdout so the
driver can pipe logs to a file.

Usage:
    python3 backend.py --port 18180
"""

from __future__ import annotations

import argparse
import json
import logging
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

LOG = logging.getLogger("e2e.backend")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _respond(self) -> None:
        body = json.dumps(
            {"backend": "e2e-echo", "method": self.command, "path": self.path}
        ).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        auth = self.headers.get("Authorization", "")
        self.send_header("X-Echo-Authorization", auth)
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        self._respond()

    def do_POST(self) -> None:
        length = int(self.headers.get("Content-Length", "0") or 0)
        if length:
            self.rfile.read(length)
        self._respond()

    def log_message(self, fmt: str, *args: object) -> None:
        LOG.info("%s - %s", self.address_string(), fmt % args)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=18180)
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.INFO, format="%(asctime)s %(name)s %(message)s"
    )

    server = HTTPServer((args.host, args.port), Handler)
    LOG.info("backend listening on %s:%s", args.host, args.port)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
