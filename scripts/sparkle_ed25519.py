#!/usr/bin/env python3
"""Validate the Sparkle Ed25519 key and sign a file; macrunner's LibreSSL cannot load Ed25519 DER keys."""

import argparse
import base64
import sys
from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey


def load_key(path: Path) -> Ed25519PrivateKey:
    key = serialization.load_der_private_key(path.read_bytes(), password=None)
    if not isinstance(key, Ed25519PrivateKey):
        raise ValueError("Sparkle key is not an Ed25519 private key")
    return key


def sign(key_path: Path, file_path: Path) -> str:
    return base64.b64encode(load_key(key_path).sign(file_path.read_bytes())).decode("ascii")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    check = sub.add_parser("check")
    check.add_argument("key", type=Path)
    signer = sub.add_parser("sign")
    signer.add_argument("key", type=Path)
    signer.add_argument("file", type=Path)
    args = parser.parse_args(argv)
    if args.command == "check":
        load_key(args.key)
    else:
        print(sign(args.key, args.file))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
