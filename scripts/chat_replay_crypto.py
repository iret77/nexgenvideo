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
    parser.add_argument("mode", choices=["pack", "pack-project", "unpack"])
    parser.add_argument("destination", type=Path)
    parser.add_argument("sources", nargs="+", type=Path)
    args = parser.parse_args()
    os.umask(0o077)
    if args.mode in {"pack", "pack-project"}:
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as archive:
            for index, source in enumerate(args.sources):
                name = f"session-{index}.json"
                if args.mode == "pack-project":
                    if source.name in {"ngv.json", "project.json", "media.json"}:
                        name = source.name
                    elif source.name in {"brief.yaml", "gates.yaml", "intake.json", "ledger.yaml", "lineage.json", "project.yaml"}:
                        name = f"pipeline/{source.name}"
                    else:
                        raise ValueError("Unexpected project fixture file")
                archive.writestr(name, source.read_bytes())
        seal(buffer.getvalue(), args.destination)
    else:
        if len(args.sources) != 1:
            raise ValueError("Expected one encrypted archive")
        data = args.sources[0].read_bytes()
        plaintext = AESGCM(key()).decrypt(data[:12], data[12:], CONTEXT)
        args.destination.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(io.BytesIO(plaintext)) as archive:
            for entry in archive.infolist():
                relative = Path(entry.filename)
                if relative.is_absolute() or ".." in relative.parts or relative.suffix not in {".json", ".yaml"}:
                    raise ValueError("Invalid fixture entry")
                destination = args.destination / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(archive.read(entry))


if __name__ == "__main__":
    main()
