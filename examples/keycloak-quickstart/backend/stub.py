#!/usr/bin/env python3
"""Minimal demo MCP backend (standard library only).

A stub that accepts JSON-RPC and returns MCP-shaped responses in place of a
real MCP server. Used to confirm that requests passing nginx-mcp-resource's
auth gate are proxied through to the backend (the 200 passthrough). In a real
deployment, replace this with an actual Streamable HTTP MCP server.
"""

import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LISTEN = ("0.0.0.0", 8080)


def jsonrpc_result(req_id, result):
    return {"jsonrpc": "2.0", "id": req_id, "result": result}


class Handler(BaseHTTPRequestHandler):
    def _send_json(self, status, obj):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        # Echo the header back so we can confirm nginx stripped the token.
        self.send_header("X-Echo-Authorization", self.headers.get("Authorization", ""))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self._send_json(200, {"status": "ok", "backend": "stub-mcp"})

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0") or "0")
        raw = self.rfile.read(length) if length else b""
        try:
            req = json.loads(raw or b"{}")
        except json.JSONDecodeError:
            self._send_json(400, {"error": "invalid json"})
            return

        method = req.get("method", "")

        # Notifications (no "id") get a 202 with no body (MCP / JSON-RPC rule).
        if "id" not in req:
            self.send_response(202)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        req_id = req.get("id")

        if method == "initialize":
            result = {
                "protocolVersion": "2025-06-18",
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "stub-mcp", "version": "0.0.1"},
            }
        elif method == "ping":
            result = {}
        elif method == "tools/list":
            result = {
                "tools": [
                    {
                        "name": "echo",
                        "description": "Echo back the provided text.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {"text": {"type": "string"}},
                            "required": ["text"],
                        },
                    }
                ]
            }
        elif method == "tools/call":
            params = req.get("params") or {}
            name = params.get("name")
            args = params.get("arguments") or {}
            if name == "echo":
                # An MCP tools/call result is returned as a content array.
                result = {
                    "content": [{"type": "text", "text": "Echo: " + str(args.get("text", ""))}]
                }
            else:
                result = {
                    "content": [{"type": "text", "text": "unknown tool: " + str(name)}],
                    "isError": True,
                }
        else:
            # Unsupported methods return a JSON-RPC error.
            self._send_json(200, {
                "jsonrpc": "2.0", "id": req_id,
                "error": {"code": -32601, "message": "Method not found: " + method},
            })
            return

        self._send_json(200, jsonrpc_result(req_id, result))

    def log_message(self, fmt, *args):
        print("[stub-mcp] " + (fmt % args))


if __name__ == "__main__":
    print(f"[stub-mcp] listening on {LISTEN[0]}:{LISTEN[1]}")
    ThreadingHTTPServer(LISTEN, Handler).serve_forever()
