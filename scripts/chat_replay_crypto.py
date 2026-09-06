"""Authenticated encryption for owner-approved private replay fixtures and diagnostics."""
import argparse
import base64
import io
import os
from pathlib import Path
import zipfile

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

CONTEXT = b"NGV private chat replay v1"


def key():
    value = os.environ.get("NGV_CHAT_REPLAY_KEY")
    if value is None:
        value = Path(os.environ["NGV_CHAT_REPLAY_KEY_FILE"]).read_text().strip()
    decoded = base64.b64decode(value, validate=True)
    if len(decoded) != 32:
        raise ValueError("Invalid replay key")
    return decoded


def seal(data, destination):
    nonce = os.urandom(12)
    Path(destination).write_bytes(nonce + AESGCM(key()).encrypt(nonce, data, CONTEXT))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=["pack", "unpack"])
    parser.add_argument("destination", type=Path)
    parser.add_argument("sources", nargs="+", type=Path)
    args = parser.parse_args()
    os.umask(0o077)
    if args.mode == "pack":
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as archive:
            for index, source in enumerate(args.sources):
                archive.writestr(f"session-{index}.json", source.read_bytes())
        seal(buffer.getvalue(), args.destination)
    else:
        if len(args.sources) != 1:
            raise ValueError("Expected one encrypted archive")
        data = args.sources[0].read_bytes()
        plaintext = AESGCM(key()).decrypt(data[:12], data[12:], CONTEXT)
        args.destination.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(io.BytesIO(plaintext)) as archive:
            for entry in archive.infolist():
                if Path(entry.filename).name != entry.filename or not entry.filename.endswith(".json"):
                    raise ValueError("Invalid fixture entry")
                (args.destination / entry.filename).write_bytes(archive.read(entry))


if __name__ == "__main__":
    main()
