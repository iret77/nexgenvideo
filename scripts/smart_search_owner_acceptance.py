"""Real native Smart Search download/CoreML/storage acceptance; never fakes a ready model."""
import argparse
import hashlib
import http.server
import json
import math
import os
from pathlib import Path
import shutil
import struct
import subprocess
import threading
import time


PINNED = {
    "ImageEncoder.mlpackage.zip": (91700398, "426115f240ead5faf69b073e08dd1b959d850ca5c592537cd81886992283b2fb"),
    "TextEncoder.mlpackage.zip": (258593083, "48f80e35ce40a9dcdc55bef986a104d3153e1cfa78229bb45c4724f3f3427368"),
    "tokenizer.zip": (5460173, "c37f2a8e8555d8561109564c4f60ee962b0072abddcfcfd599d321469d6d1ef5"),
}


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def checked_file(root, relative):
    path = root / relative
    if not path.resolve(strict=True).is_relative_to(root.resolve(strict=True)) or not path.is_file():
        raise AssertionError("Evidence left its actual isolated directory")
    return path


def verify_cache(cache, expected):
    actual = []
    for path in sorted(cache.rglob("*"), key=lambda value: str(value.relative_to(cache))):
        if path.is_file():
            checked_file(cache, str(path.relative_to(cache)))
            actual.append({"path": str(path.relative_to(cache)), "sha256": digest(path)})
    if not actual or actual != expected:
        raise AssertionError("The real installed model cache differs from its recorded bytes")
    return actual


def validate(output, home, cold):
    result = json.loads((output / "smart-search-result.json").read_text())
    if result["schema"] != "native-smart-search-owner/v1" or result["cold"] is not cold or result["semanticQualityClaim"]:
        raise AssertionError("Unexpected or overstated native search result")
    if result["dimension"] != 768 or result["indexRows"] <= 0:
        raise AssertionError("No actual declared model/index output")
    vector = json.loads((output / "text-embedding.json").read_text())
    if len(vector) != 768 or any(not math.isfinite(value) for value in vector) or sum(value * value for value in vector) <= 0:
        raise AssertionError("No actual finite nonzero text embedding")
    index_path = Path(result["indexPath"])
    if not index_path.resolve(strict=True).is_relative_to(home.resolve(strict=True)):
        raise AssertionError("The actual search index is outside isolated storage")
    index_bytes = index_path.read_bytes()
    if index_bytes[:8] != b"PALMEMB1" or len(index_bytes) < 12:
        raise AssertionError("No real binary embedding index")
    length = struct.unpack("<I", index_bytes[8:12])[0]
    header = json.loads(index_bytes[12:12 + length])
    if header["model"] != "siglip2-base-patch16-256" or header["modelVersion"] != 1 or header["dim"] != 768 or header["count"] != result["indexRows"]:
        raise AssertionError("The actual binary index has a different model/shape")
    rows = index_bytes[12 + length:]
    stride = 24 + 768 * 2
    if len(rows) != stride * header["count"]:
        raise AssertionError("The actual binary index payload is incomplete")
    for offset in range(0, len(rows), stride):
        moment, start, end = struct.unpack("<ddd", rows[offset:offset + 24])
        values = struct.unpack("<768e", rows[offset + 24:offset + stride])
        if (not all(math.isfinite(value) for value in (moment, start, end, *values))
                or not 0 <= start <= moment <= end <= 4 or sum(value * value for value in values) <= 0):
            raise AssertionError("The actual image encoding has invalid values or source ranges")
    files = result["manifest"]["files"]
    declared = {row["name"]: (row["bytes"], row["sha256"]) for row in files.values()}
    if declared != PINNED:
        raise AssertionError("Actual app manifest differs from the independently pinned public release")
    archive_results = []
    for name, (size, sha) in PINNED.items():
        path = output / "verified-archives" / name
        if cold:
            if path.stat().st_size != size or digest(path) != sha:
                raise AssertionError("Actual downloaded ZIP bytes failed independent size/SHA verification")
            receipt = json.loads((output / (name + ".receipt.json")).read_text())
            if receipt["name"] != name or receipt["sha256"] != sha or receipt["byteCount"] != size:
                raise AssertionError("Actual post-verify receipt does not describe its ZIP bytes")
            archive_results.append(receipt)
        elif path.exists():
            raise AssertionError("Warm layout downloaded the model again")
    progress = json.loads(checked_file(output, result["driver"]["progress"]).read_text())
    if progress.get("failure") is not None or progress["interactions"] != result["driver"]["interactions"]:
        raise AssertionError("Actual pointer evidence is incomplete")
    clicked = {row["id"] for row in progress["interactions"] if row.get("kind") == "pointer"}
    required = {"media.action.Import", "editor.workspace.media"}
    if cold:
        required |= {"media.index.download", "media.index.retry-model", "settings.toggle.Index imported media",
                     "settings.storage.index.clear", "settings.storage.model.remove"}
    if not required <= clicked:
        raise AssertionError("Missing actual required native inputs: " + str(required - clicked))
    controls = {"settings.toggle.Index imported media", "settings.storage.index.clear", "settings.storage.model.remove"}
    groups = [row for row in progress["interactions"] if row.get("kind") == "visible-group" and controls <= set(row["ids"])]
    if not groups:
        raise AssertionError("The actual Storage model controls were not inspected together")
    for group in groups:
        x, y, width, height = group["viewport"]
        frames = group["frames"]
        if width != 960 or height != 640:
            raise AssertionError("The actual Settings viewport changed")
        for i, (left, top, w, h) in enumerate(frames):
            if not all(math.isfinite(value) for value in (left, top, w, h)) or w <= 0 or h <= 0 or left < x or top < y or left + w > x + width or top + h > y + height:
                raise AssertionError("A real Storage control is clipped")
            for other in frames[:i]:
                a, b, c, d = other
                if min(left + w, a + c) > max(left, a) and min(top + h, b + d) > max(top, b):
                    raise AssertionError("Actual Storage controls overlap")
    images = result["driver"]["screenshots"]
    if len(images) < (4 if cold else 1) or len(images) != len(set(images)):
        raise AssertionError("Missing distinct actual native screenshots")
    for name in images:
        data = checked_file(output, name).read_bytes()
        if data[:8] != b"\x89PNG\r\n\x1a\n" or min(struct.unpack(">II", data[16:24])) <= 0:
            raise AssertionError("Screenshot is not a real nonempty PNG")
    cache = Path(result["cache"])
    if not cache.resolve(strict=True).is_relative_to(output.resolve(strict=True)):
        raise AssertionError("Model cache is not owned by this acceptance")
    verify_cache(cache, result["cacheFiles"])
    store = Path(result["modelStore"])
    store.relative_to(home)
    if cold and store.exists():
        raise AssertionError("Actual Storage Remove did not remove the installed model")
    if not cold and not store.is_dir():
        raise AssertionError("Warm layout did not use a real installed model")
    stages = result["stages"]
    if not stages or any(not math.isfinite(value) or value < 0 for value in stages.values()):
        raise AssertionError("Invalid actual stage durations")
    # These are temporary inputs, not a second 339 MiB published model distribution.
    shutil.rmtree(output / "verified-archives")
    return {"schema": "native-smart-search-owner-verified/v1", "scale": result["scale"], "cold": cold,
            "actualZIPs": archive_results, "stages": stages, "dimension": result["dimension"],
            "indexRows": result["indexRows"], "modelCacheFiles": len(result["cacheFiles"]),
            "nativePointerIDs": sorted(clicked), "semanticQualityClaim": False}


class FailureServer(http.server.ThreadingHTTPServer):
    daemon_threads = True


class FailureHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.server.requests.append({"method": "GET", "path": self.path, "status": 503})
        self.send_response(503)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *_):
        pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--executable", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--scales", default="1")
    parser.add_argument("--cache-export", type=Path)
    parser.add_argument("--cache-import", type=Path)
    args = parser.parse_args()
    scales = [float(value) for value in args.scales.split(",")]
    if (not scales or (not args.cache_import and scales[0] != 1)
            or any(value not in {1, 1.25, 1.5} for value in scales)):
        raise ValueError("Run actual cold100 first, or supply its verified model cache for pure layout cases")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    previous = None
    if args.cache_import:
        metadata = json.loads((args.cache_import / "source.json").read_text())
        pinned = [{"name": name, "bytes": value[0], "sha256": value[1]} for name, value in sorted(PINNED.items())]
        relative = Path(metadata["relativeStore"])
        if (metadata["schema"] != "actual-smart-search-cache/v1" or metadata["publicArchives"] != pinned
                or relative.is_absolute() or ".." in relative.parts):
            raise AssertionError("The warm cache has no validated cold producer metadata")
        verify_cache(args.cache_import / "store", metadata["files"])
        previous = {"cache": str(args.cache_import / "store"), "cacheFiles": metadata["files"],
                    "home": "/model-cache-source", "modelStore": str(Path("/model-cache-source") / relative)}
    server = FailureServer(("127.0.0.1", 0), FailureHandler)
    server.requests = []
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    summaries = []
    try:
        for index, scale in enumerate(scales):
            cold = index == 0 and args.cache_import is None
            case = output / ("cold100" if cold else "warm" + str(round(scale * 100)))
            case.mkdir()
            home = case / "isolated-user"
            home.mkdir()
            temporary = home / "tmp"
            temporary.mkdir()
            if previous:
                verify_cache(Path(previous["cache"]), previous["cacheFiles"])
                destination = home / Path(previous["modelStore"]).relative_to(Path(previous["home"]))
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copytree(previous["cache"], destination)
                verify_cache(destination, previous["cacheFiles"])
            keys = {"PATH", "TMPDIR", "LANG", "LC_ALL", "__CF_USER_TEXT_ENCODING", "DISPLAY", "TERM"}
            env = {key: value for key, value in os.environ.items() if key in keys}
            env.update({"CFFIXED_USER_HOME": str(home), "NGV_WORKSPACE_UI_ACCEPTANCE": "1",
                        "TMPDIR": str(temporary) + os.sep,
                        "NGV_SMART_SEARCH_OWNER_ACCEPTANCE": "1", "NGV_SMART_SEARCH_EVIDENCE": str(case),
                        "NGV_SMART_SEARCH_SCALE": str(scale), "NGV_SMART_SEARCH_MODE": "cold" if cold else "warm",
                        "NGV_SMART_SEARCH_FAILURE_URL": "http://localhost:" + str(server.server_address[1])})
            started = time.monotonic()
            with (case / "native.log").open("w") as log:
                process = subprocess.Popen([str(args.executable.resolve(strict=True)), "-ApplePersistenceIgnoreState", "YES"],
                    stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, env=env)
                try:
                    code = process.wait(timeout=720 if cold else 240)
                    if code:
                        failure = case / "smart-search-failure.txt"
                        raise RuntimeError(failure.read_text() if failure.exists() else "Native search process failed without a result")
                except subprocess.TimeoutExpired:
                    (case / "smart-search-process-timeout.json").write_text(json.dumps({
                        "schema": "native-smart-search-timeout/v1", "pid": process.pid,
                        "seconds": time.monotonic() - started, "completed": False,
                        "lastNativeProgress": (case / "smart-search-owner.json").read_text()
                        if (case / "smart-search-owner.json").exists() else None}, indent=2))
                    raise
                finally:
                    if process.poll() is None:
                        process.terminate()
                        try:
                            process.wait(timeout=10)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.wait(timeout=10)
            summary = validate(case, home, cold)
            summary["processSeconds"] = time.monotonic() - started
            (case / "smart-search-validation.json").write_text(json.dumps(summary, indent=2))
            summaries.append(summary)
            previous = json.loads((case / "smart-search-result.json").read_text()) | {"home": str(home)}
        if args.cache_import is None and not server.requests:
            raise AssertionError("No actual initial controlled HTTP503 request occurred")
        if args.cache_import is not None and server.requests:
            raise AssertionError("Warm layout attempted a model download")
        if any(row["status"] != 503 for row in server.requests):
            raise AssertionError("The controlled transport returned an unexpected status")
        if args.cache_export:
            args.cache_export.mkdir(parents=True, exist_ok=False)
            shutil.copytree(previous["cache"], args.cache_export / "store")
            verify_cache(args.cache_export / "store", previous["cacheFiles"])
            (args.cache_export / "source.json").write_text(json.dumps({"schema": "actual-smart-search-cache/v1",
                "relativeStore": str(Path(previous["modelStore"]).relative_to(Path(previous["home"]))),
                "files": previous["cacheFiles"], "publicArchives": [
                    {"name": name, "bytes": value[0], "sha256": value[1]} for name, value in sorted(PINNED.items())]}, indent=2))
        (output / "controlled-http.json").write_text(json.dumps(server.requests, indent=2))
        (output / "smart-search-summary.json").write_text(json.dumps({"schema": "native-smart-search-matrix/v1", "cases": summaries}, indent=2))
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)
        for directory in output.glob("*/verified-archives"):
            shutil.rmtree(directory)
        for directory in output.glob("*/isolated-user/tmp"):
            shutil.rmtree(directory)


if __name__ == "__main__":
    main()
