"""Shared decoding contract for authenticated replay keys."""
import base64
import binascii


def decode_base64_key(value):
    try:
        decoded = base64.b64decode(value.strip(), validate=True)
    except (binascii.Error, ValueError) as error:
        raise ValueError("Invalid replay key") from error
    if len(decoded) != 32:
        raise ValueError("Invalid replay key")
    return decoded
