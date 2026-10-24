import hashlib
import http.client
import re
import socket
import sys
import time
import urllib.error

from assemble_bpy_source_closure import transient_download_error


class TransferInterrupted(Exception):
    def __init__(self, error):
        self.error = error


def network(operation):
    try:
        return operation()
    except ValueError:
        raise
    except Exception as error:
        reason = error.reason if isinstance(error, urllib.error.URLError) else error
        if isinstance(reason, socket.timeout) or transient_download_error(error):
            raise TransferInterrupted(error) from None
        raise ValueError(f"Pinned download failed ({type(error).__name__}); URL withheld") from None


def download_file(open_response, destination, size, digest, limit):
    if (type(size) is not int or not 0 < size <= limit
            or not re.fullmatch(r"sha256:[0-9a-f]{64}", digest)):
        raise ValueError("Pinned download needs an exact bounded size and SHA256")
    deadline = time.monotonic() + 1500
    value = hashlib.sha256()
    with destination.open("xb") as output:
        for attempt in range(3):
            try:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise ValueError("Pinned download exceeded its transfer deadline")
                offset = output.tell()
                with network(lambda: open_response(offset, min(120, remaining))) as response:
                    if response.status == 200:
                        output.seek(0)
                        output.truncate()
                        offset = 0
                        value = hashlib.sha256()
                    elif response.status == 206 and offset > 0:
                        expected = f"bytes {offset}-{size - 1}/{size}"
                        if response.headers.get("Content-Range") != expected:
                            raise ValueError("Pinned download returned a different byte range")
                        if response.headers.get("Content-Length") != str(size - offset):
                            raise ValueError("Pinned partial download has no exact content length")
                    else:
                        raise ValueError("Pinned download returned an unexpected response status")
                    if response.headers.get("Content-Encoding", "identity") != "identity":
                        raise ValueError("Pinned download changed the byte representation")
                    length = response.headers.get("Content-Length")
                    if length is not None and length != str(size - offset):
                        raise ValueError("Pinned download returned a different content length")
                    while True:
                        if time.monotonic() >= deadline:
                            raise ValueError("Pinned download exceeded its transfer deadline")
                        block = network(lambda: response.read(1024 * 1024))
                        if not block:
                            break
                        if output.tell() + len(block) > size:
                            raise ValueError("Pinned download exceeds its size bound")
                        output.write(block)
                        value.update(block)
                    if output.tell() != size:
                        raise TransferInterrupted(http.client.IncompleteRead(b"", size - output.tell()))
                break
            except TransferInterrupted as interruption:
                error = interruption.error
                if attempt == 2:
                    raise ValueError(f"Pinned download failed ({type(error).__name__}); URL withheld") from None
                if output.tell() == size:
                    break
                print(f"Pinned download retry {attempt + 2}/3 at byte {output.tell()} "
                      f"after {type(error).__name__}", file=sys.stderr, flush=True)
                time.sleep(2 * (attempt + 1))
        if output.tell() != size or "sha256:" + value.hexdigest() != digest:
            raise ValueError("Pinned download size or digest mismatch")
    return destination
