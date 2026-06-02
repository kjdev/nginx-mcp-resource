#!/usr/bin/env python3
"""Self-issued JWT demo utility (no-AS setup).

A minimal tool for "verify a JWT you signed yourself with nginx-mcp-resource
(JWT mode), without standing up an authorization server".

Subcommands:
  keygen  Generate an RSA key pair and write the private key (private.pem) and
          the public JWKS (jwks.json) under keys/. Mount jwks.json into nginx
          as MCP_JWT_KEY_FILE.
  mint    Issue a single JWT signed with the private key, printed to stdout.
          `aud` must match MCP_CANONICAL_URI exactly (RFC 8707 audience
          binding); `scope` is a space-separated string that includes the
          required scope.

Dependency: cryptography only (no PyJWT).
  python3 -m venv .venv && . .venv/bin/activate && pip install cryptography
"""

import argparse
import base64
import json
import sys
import time
from pathlib import Path

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa

KEYS_DIR = Path(__file__).resolve().parent / "keys"
PRIVATE_PEM = KEYS_DIR / "private.pem"
JWKS_JSON = KEYS_DIR / "jwks.json"
DEFAULT_KID = "self-jwt-demo"

# Demo defaults. Kept in sync with MCP_CANONICAL_URI in compose.yml.
DEFAULT_AUD = "http://localhost:8080/mcp"
DEFAULT_ISS = "https://self-jwt-demo.local"
DEFAULT_SCOPE = "mcp:read mcp:write"


def b64u(data: bytes) -> str:
    """base64url encode (padding stripped). The representation used by JWS/JWK."""
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def int_to_b64u(n: int) -> str:
    """Encode a non-negative integer as minimal big-endian bytes, base64url.
    Used for the JWK `n` (modulus) / `e` (exponent) representation."""
    length = (n.bit_length() + 7) // 8 or 1
    return b64u(n.to_bytes(length, "big"))


def cmd_keygen(args: argparse.Namespace) -> int:
    """Generate an RSA-2048 key pair and write the private PEM and public JWKS."""
    KEYS_DIR.mkdir(parents=True, exist_ok=True)

    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)

    PRIVATE_PEM.write_bytes(
        key.private_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PrivateFormat.PKCS8,
            encryption_algorithm=serialization.NoEncryption(),
        )
    )
    PRIVATE_PEM.chmod(0o600)

    pub = key.public_key().public_numbers()
    jwks = {
        "keys": [
            {
                "kty": "RSA",
                "use": "sig",
                "alg": "RS256",
                "kid": args.kid,
                "n": int_to_b64u(pub.n),
                "e": int_to_b64u(pub.e),
            }
        ]
    }
    JWKS_JSON.write_text(json.dumps(jwks, indent=2) + "\n")

    print(f"wrote {PRIVATE_PEM}", file=sys.stderr)
    print(f"wrote {JWKS_JSON}", file=sys.stderr)
    return 0


def cmd_mint(args: argparse.Namespace) -> int:
    """Issue one RS256-signed JWT with the private key, printed to stdout."""
    if not PRIVATE_PEM.exists():
        print("private key not found; run 'keygen' first", file=sys.stderr)
        return 1

    key = serialization.load_pem_private_key(PRIVATE_PEM.read_bytes(), password=None)

    now = int(time.time())
    header = {"alg": "RS256", "typ": "JWT", "kid": args.kid}
    payload = {
        "iss": args.iss,
        "sub": args.sub,
        "aud": args.aud,          # must match MCP_CANONICAL_URI exactly
        "scope": args.scope,      # space-separated, includes the required scope
        "iat": now,
        "exp": now + args.ttl,
    }

    signing_input = (
        b64u(json.dumps(header, separators=(",", ":")).encode())
        + "."
        + b64u(json.dumps(payload, separators=(",", ":")).encode())
    ).encode("ascii")

    signature = key.sign(signing_input, padding.PKCS1v15(), hashes.SHA256())
    token = signing_input.decode("ascii") + "." + b64u(signature)
    print(token)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_keygen = sub.add_parser("keygen", help="generate an RSA key pair + JWKS")
    p_keygen.add_argument("--kid", default=DEFAULT_KID)
    p_keygen.set_defaults(func=cmd_keygen)

    p_mint = sub.add_parser("mint", help="issue one JWT")
    p_mint.add_argument("--kid", default=DEFAULT_KID)
    p_mint.add_argument("--aud", default=DEFAULT_AUD, help="must match MCP_CANONICAL_URI")
    p_mint.add_argument("--iss", default=DEFAULT_ISS)
    p_mint.add_argument("--sub", default="demo-user")
    p_mint.add_argument("--scope", default=DEFAULT_SCOPE)
    p_mint.add_argument("--ttl", type=int, default=3600, help="lifetime in seconds (default 1h)")
    p_mint.set_defaults(func=cmd_mint)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
