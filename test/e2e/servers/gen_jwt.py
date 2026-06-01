#!/usr/bin/env python3
"""HS256 JWT mint helper used by the E2E suite.

Generates a signed JWT compatible with the JWKS bundled under
``test/e2e/fixtures/keys/jwks.json``:

    kid=smoke, kty=oct, alg=HS256, k=c21va2Utc2VjcmV0  (== "smoke-secret")

Usage:
    python3 gen_jwt.py --aud <uri> [--scope mcp:read] [--exp +3600]
                      [--iss <iss>] [--sub <sub>]
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import json
import sys
import time

# Must match test/e2e/fixtures/keys/jwks.json
HS256_SECRET = b"smoke-secret"
KID = "smoke"


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def sign(header: dict[str, object], payload: dict[str, object]) -> str:
    h = b64url(json.dumps(header, separators=(",", ":"), sort_keys=True).encode())
    p = b64url(json.dumps(payload, separators=(",", ":"), sort_keys=True).encode())
    signing_input = f"{h}.{p}".encode("ascii")
    sig = hmac.new(HS256_SECRET, signing_input, hashlib.sha256).digest()
    return f"{h}.{p}.{b64url(sig)}"


def _parse_exp(arg: str) -> int:
    if arg.startswith("+") or arg.startswith("-"):
        return int(time.time()) + int(arg)
    return int(arg)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--aud", required=True, help="audience (string)")
    parser.add_argument("--scope", default="mcp:read")
    parser.add_argument(
        "--exp",
        default="+3600",
        help="absolute epoch or relative offset like '+3600' / '-60'",
    )
    parser.add_argument("--iss", default="https://auth.e2e.local")
    parser.add_argument("--sub", default="e2e-user")
    parser.add_argument(
        "--bad-sig",
        action="store_true",
        help="emit a token whose signature segment is corrupted",
    )
    parser.add_argument(
        "--no-scope", action="store_true", help="omit the scope claim entirely"
    )
    args = parser.parse_args()

    header = {"alg": "HS256", "typ": "JWT", "kid": KID}
    payload: dict[str, object] = {
        "iss": args.iss,
        "sub": args.sub,
        "aud": args.aud,
        "exp": _parse_exp(args.exp),
        "iat": int(time.time()),
    }
    if not args.no_scope:
        payload["scope"] = args.scope

    jwt = sign(header, payload)
    if args.bad_sig:
        parts = jwt.split(".")
        pad = "=" * ((4 - len(parts[2]) % 4) % 4)
        sig = bytearray(base64.urlsafe_b64decode(parts[2] + pad))
        sig[0] ^= 0xFF
        parts[2] = b64url(bytes(sig))
        jwt = ".".join(parts)
    sys.stdout.write(jwt + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
