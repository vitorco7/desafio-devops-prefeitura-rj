#!/usr/bin/env python3
"""
generate.py — Generate RSA-2048 key pair, JWKS document, and test JWT.

Usage (from repo root):
    python3 infra/jwt/generate.py

Outputs:
    infra/jwt/private.pem  — RSA private key (DEMO ONLY — do not use in production)
    infra/jwt/public.pem   — RSA public key
    infra/jwt/jwks.json    — JWKS document for Istio RequestAuthentication
    infra/jwt/token.jwt    — Pre-signed test JWT (expires 2030-01-01)

Requires: python3-cryptography (apt install python3-cryptography)
"""

import base64
import json
import os
import struct
import time
from pathlib import Path

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa, padding
from cryptography.hazmat.backends import default_backend

# ── Paths ──────────────────────────────────────────────────────────────────────
SCRIPT_DIR = Path(__file__).resolve().parent
PRIVATE_KEY_PATH = SCRIPT_DIR / "private.pem"
PUBLIC_KEY_PATH  = SCRIPT_DIR / "public.pem"
JWKS_PATH        = SCRIPT_DIR / "jwks.json"
TOKEN_PATH       = SCRIPT_DIR / "token.jwt"

# ── JWT configuration ──────────────────────────────────────────────────────────
KID     = "k3s-jwt"
ISSUER  = "cluster.local"
SUBJECT = "test-user"
# 2030-01-01 00:00:00 UTC — far enough ahead that token won't expire during evaluation
EXPIRY  = 1893456000

# ── Helpers ────────────────────────────────────────────────────────────────────

def int_to_base64url(n: int) -> str:
    """Encode a big integer as base64url (no padding), big-endian bytes."""
    byte_length = (n.bit_length() + 7) // 8
    raw = n.to_bytes(byte_length, "big")
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def base64url_encode(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def build_jwks(public_key) -> dict:
    pub_numbers = public_key.public_numbers()
    return {
        "keys": [
            {
                "kty": "RSA",
                "use": "sig",
                "kid": KID,
                "alg": "RS256",
                "n": int_to_base64url(pub_numbers.n),
                "e": int_to_base64url(pub_numbers.e),
            }
        ]
    }


def build_jwt(private_key) -> str:
    """Build and sign a JWT using RS256."""
    header = {"alg": "RS256", "typ": "JWT", "kid": KID}
    payload = {
        "iss": ISSUER,
        "sub": SUBJECT,
        "iat": int(time.time()),
        "exp": EXPIRY,
    }

    header_b64  = base64url_encode(json.dumps(header, separators=(",", ":")).encode())
    payload_b64 = base64url_encode(json.dumps(payload, separators=(",", ":")).encode())
    signing_input = f"{header_b64}.{payload_b64}".encode()

    signature = private_key.sign(signing_input, padding.PKCS1v15(), hashes.SHA256())
    sig_b64 = base64url_encode(signature)

    return f"{header_b64}.{payload_b64}.{sig_b64}"


# ── Main ───────────────────────────────────────────────────────────────────────

def main():
    # 1. Generate RSA-2048 private key
    print("Generating RSA-2048 key pair...")
    private_key = rsa.generate_private_key(
        public_exponent=65537,
        key_size=2048,
        backend=default_backend(),
    )

    # 2. Serialize keys to PEM
    private_pem = private_key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.TraditionalOpenSSL,
        encryption_algorithm=serialization.NoEncryption(),
    )
    public_pem = private_key.public_key().public_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PublicFormat.SubjectPublicKeyInfo,
    )

    PRIVATE_KEY_PATH.write_bytes(private_pem)
    PUBLIC_KEY_PATH.write_bytes(public_pem)
    print(f"  private key → {PRIVATE_KEY_PATH}")
    print(f"  public key  → {PUBLIC_KEY_PATH}")

    # 3. Build JWKS
    jwks = build_jwks(private_key.public_key())
    JWKS_PATH.write_text(json.dumps(jwks, indent=2) + "\n")
    print(f"  JWKS        → {JWKS_PATH}")

    # 4. Build and sign test JWT
    token = build_jwt(private_key)
    TOKEN_PATH.write_text(token + "\n")
    print(f"  token       → {TOKEN_PATH}")
    print(f"\nToken expires: 2030-01-01 00:00:00 UTC (unix={EXPIRY})")
    print(f"Issuer: {ISSUER}")
    print(f"KID:    {KID}")
    print("\nDone. Apply infra/k8s/jwt/jwks-server.yaml to serve the JWKS in-cluster.")


if __name__ == "__main__":
    main()
