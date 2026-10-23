#!/usr/bin/env python3
from __future__ import annotations
import argparse
import datetime
import hashlib
import json
import os
import re
import shutil
import signal
import struct
import subprocess
import tempfile
import time
import zlib
from pathlib import Path


CAPTURE_SIZE = (1400, 840)
STATES = (
    "empty",
    "prose",
    "activity",
    "activity-completed",
    "long-prose",
    "structured",
    "clarification",
    "visual-choice",
    "decision",
    "spend",
    "intake-first",
    "intake-partial",
    "intake-next",
    "workflow-receipts",
    "pipeline",
    "generation",
    "failed",
    "terminal-failure",
    "backend-checking",
    "backend",
    "authentication",
    "conversations",
    "stress",
)


def png_size(path: Path) -> tuple[int, int]:
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        raise RuntimeError(f"{path} is not a PNG")
    return struct.unpack(">II", data[16:24])


def png_visual_statistics(path: Path) -> tuple[int, float, int]:
    data = path.read_bytes()
    offset = 8
    width = height = bit_depth = color_type = interlace = None
    compressed = bytearray()
    while offset < len(data):
        length = struct.unpack(">I", data[offset : offset + 4])[0]
        chunk_type = data[offset + 4 : offset + 8]
        payload = data[offset + 8 : offset + 8 + length]
        offset += 12 + length
        if chunk_type == b"IHDR":
            width, height, bit_depth, color_type, _, _, interlace = struct.unpack(
                ">IIBBBBB", payload
            )
        elif chunk_type == b"IDAT":
            compressed.extend(payload)
        elif chunk_type == b"IEND":
            break

    if bit_depth != 8 or color_type not in (2, 6) or interlace != 0:
        raise RuntimeError(f"{path} uses an unsupported PNG encoding")
    channels = 3 if color_type == 2 else 4
    stride = width * channels
    raw = zlib.decompress(compressed)
    if len(raw) != (stride + 1) * height:
        raise RuntimeError(f"{path} has an invalid scanline payload")

    previous = bytearray(stride)
    unique_colors: set[tuple[int, int, int]] = set()
    background: tuple[int, int, int] | None = None
    changed = 0
    light = 0
    cursor = 0
    for _ in range(height):
        filter_type = raw[cursor]
        cursor += 1
        encoded = raw[cursor : cursor + stride]
        cursor += stride
        row = bytearray(stride)
        for index, value in enumerate(encoded):
            left = row[index - channels] if index >= channels else 0
            above = previous[index]
            upper_left = previous[index - channels] if index >= channels else 0
            if filter_type == 0:
                predictor = 0
            elif filter_type == 1:
                predictor = left
            elif filter_type == 2:
                predictor = above
            elif filter_type == 3:
                predictor = (left + above) // 2
            elif filter_type == 4:
                estimate = left + above - upper_left
                distances = (
                    abs(estimate - left),
                    abs(estimate - above),
                    abs(estimate - upper_left),
                )
                predictor = (left, above, upper_left)[distances.index(min(distances))]
            else:
                raise RuntimeError(f"{path} uses unknown PNG filter {filter_type}")
            row[index] = (value + predictor) & 0xFF

        for index in range(0, stride, channels):
            color = tuple(row[index : index + 3])
            if background is None:
                background = color
            if len(unique_colors) < 256:
                unique_colors.add(color)
            if color != background:
                changed += 1
            if max(color) >= 160:
                light += 1
        previous = row

    total = width * height
    return len(unique_colors), changed / total, light


def validate_visual_content(path: Path) -> None:
    unique, changed_ratio, light_pixels = png_visual_statistics(path)
    if unique < 24 or changed_ratio < 0.01 or light_pixels < 100:
        raise RuntimeError(
            f"{path.name} appears blank: {unique} colors, "
            f"{changed_ratio:.3%} changed pixels, {light_pixels} light pixels"
        )


def declared_states(source: Path) -> tuple[str, ...]:
    text = source.read_text(encoding="utf-8")
    try:
        declaration = text.split("var states = [", 1)[1].split("\n    ];", 1)[0]
    except IndexError as error:
        raise RuntimeError("Agent UI specification has no state declaration") from error
    return tuple(re.findall(r'\bid:\s*"([a-z0-9-]+)"', declaration))


def browser_path(diagnostic: Path | None = None) -> str:
    browser = None
    for name in ("google-chrome", "google-chrome-stable", "chromium", "chromium-browser"):
        resolved = shutil.which(name)
        if resolved:
            browser = resolved
            break
    if diagnostic is not None:
        diagnostic.parent.mkdir(parents=True, exist_ok=True)
        with diagnostic.open("x") as stream:
            json.dump({"browser": browser, "runID": os.environ.get("GITHUB_RUN_ID"),
                       "runAttempt": os.environ.get("GITHUB_RUN_ATTEMPT"),
                       "sourceSHA": os.environ.get("GITHUB_SHA")}, stream, indent=2)
    if browser:
        return browser
    raise RuntimeError("Chrome or Chromium is required to render the Agent UI specification")


def stop_browser_group(process: subprocess.Popen) -> dict:
    records = []
    interrupted = None
    for signum in (signal.SIGTERM, signal.SIGKILL):
        record = {"processGroup": process.pid, "signal": int(signum)}
        try:
            os.killpg(process.pid, signum)
            record["status"] = "sent"
        except ProcessLookupError:
            record["status"] = "group-absent"
        except OSError as error:
            record.update(status="unavailable", errorType=type(error).__name__)
        except BaseException as error:
            interrupted = interrupted or error
            record.update(status="interrupted", errorType=type(error).__name__)
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            record["rootWait"] = "timed-out"
        except OSError as error:
            record["rootWaitError"] = type(error).__name__
        except BaseException as error:
            interrupted = interrupted or error
            record["rootWaitError"] = type(error).__name__
        records.append(record)
        if record["status"] == "group-absent" and interrupted is None:
            break
    if interrupted is not None:
        raise interrupted
    return {"scope": "owned-process-group", "signals": records,
            "rootReaped": process.returncode is not None, "rootExitCode": process.returncode}


def run_browser(browser: str, url: str, diagnostic: Path, arguments: list[str], *, timeout: float = 45) -> str:
    diagnostic.mkdir(parents=True, exist_ok=False)
    stdout = diagnostic / "stdout.log"
    stderr = diagnostic / "stderr.log"
    started = time.monotonic()
    process = None
    profile = None
    failed = False
    result = {"status": "launch-pending", "timeoutSeconds": timeout,
              "startedAt": datetime.datetime.now(datetime.timezone.utc).isoformat()}
    with stdout.open("xb") as output, stderr.open("xb") as error_output:
        try:
            profile = tempfile.TemporaryDirectory(prefix="ngv-ui-browser-")
            command = [browser, "--headless=new", "--disable-gpu", "--disable-dev-shm-usage",
                       "--no-sandbox", "--disable-background-networking", "--no-first-run",
                       "--virtual-time-budget=1000", f"--user-data-dir={profile.name}", *arguments, url]
            with (diagnostic / "request.json").open("x") as stream:
                json.dump({"command": command, "timeoutSeconds": timeout, "stdin": "DEVNULL",
                           "newSession": True, "profileMode": os.stat(profile.name).st_mode & 0o777,
                           "profileLifetime": "fresh-private-directory-for-this-invocation"}, stream, indent=2)
            process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=output,
                                       stderr=error_output, start_new_session=True)
            result.update(pid=process.pid, processGroup=process.pid)
            process.wait(timeout=timeout)
            result.update(status="process-exited", exitCode=process.returncode)
            if process.returncode:
                raise subprocess.CalledProcessError(process.returncode, command)
        except BaseException as error:
            failed = True
            result.update(status="timed-out" if isinstance(error, subprocess.TimeoutExpired) else "failed",
                          failureType=type(error).__name__)
            raise
        finally:
            result["executionElapsedSeconds"] = time.monotonic() - started
            cleanup_error = None
            try:
                cleanup = stop_browser_group(process) if process is not None else {"scope": "not-started", "rootReaped": True}
            except BaseException as error:
                cleanup_error = error
                cleanup = {"scope": "owned-process-group", "rootReaped": process.returncode is not None,
                           "errorType": type(error).__name__}
            result["cleanup"] = cleanup
            if profile is not None:
                try:
                    profile.cleanup()
                except BaseException as error:
                    cleanup_error = cleanup_error or error
                    cleanup["profileError"] = type(error).__name__
            output.flush()
            error_output.flush()
            for name, path in (("stdout", stdout), ("stderr", stderr)):
                raw = path.read_bytes()
                result[name] = {"file": path.name, "bytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest()}
            result["finishedAt"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
            with (diagnostic / "result.json").open("x") as stream:
                json.dump(result, stream, indent=2)
            if isinstance(cleanup_error, (KeyboardInterrupt, SystemExit)) or (not failed and cleanup_error is not None):
                raise cleanup_error
            if not failed and (not cleanup["rootReaped"] or cleanup.get("profileError") or any(
                    row.get("status") == "unavailable" or row.get("rootWaitError")
                    for row in cleanup.get("signals", []))):
                raise RuntimeError(f"Browser cleanup incomplete; see {diagnostic}")
    return stdout.read_text(encoding="utf-8")


def validate_capture_dom(content: str, state: str, reduce_motion: bool = False) -> None:
    required = [
        f'data-capture-state="{state}"',
        'data-render-ready="true"',
        f'data-state-section="{state}"',
        'aria-label="240 point Agent panel',
        'aria-label="400 point Agent panel',
        'aria-label="640 point Agent panel',
    ]
    if reduce_motion:
        required.append('data-reduce-motion="true"')
    missing = [marker for marker in required if marker not in content]
    if missing:
        raise RuntimeError(
            f"Agent UI capture {state} did not reach its rendered state: {missing}"
        )


def rendered_dom(browser: str, url: str, state: str, diagnostic: Path, reduce_motion: bool = False) -> None:
    motion_args = ["--force-prefers-reduced-motion"] if reduce_motion else []
    content = run_browser(browser, url, diagnostic, ["--dump-dom", *motion_args])
    validate_capture_dom(content, state, reduce_motion)


def render(source: Path, output: Path) -> None:
    output.mkdir(parents=True, exist_ok=True)
    diagnostics = output / "diagnostics"
    browser = browser_path(diagnostics / "agent-chat-browser.json")
    actual_states = declared_states(source)
    if actual_states != STATES:
        raise RuntimeError(
            "Agent UI capture states differ from the required matrix: "
            f"expected {STATES}, got {actual_states}"
        )
    width, height = CAPTURE_SIZE
    captures = [(state, False) for state in STATES] + [("stress", True)]
    for state, reduce_motion in captures:
        mode = "-reduced-motion" if reduce_motion else ""
        destination = output / f"agent-chat-{state}{mode}-240-400-640.png"
        query = f"?capture={state}"
        if reduce_motion:
            query += "&reduceMotion=1"
        url = source.resolve().as_uri() + query
        rendered_dom(browser, url, state, diagnostics / f"agent-chat-{state}{mode}-dom", reduce_motion)
        motion_args = ["--force-prefers-reduced-motion"] if reduce_motion else []
        run_browser(browser, url, diagnostics / f"agent-chat-{state}{mode}-screenshot",
            [
                "--hide-scrollbars",
                "--force-device-scale-factor=1",
                *motion_args,
                f"--window-size={width},{height}",
                f"--screenshot={destination}",
            ],
        )
        actual = png_size(destination)
        if actual != (width, height):
            raise RuntimeError(
                f"{destination.name} rendered at {actual[0]}x{actual[1]}, expected {width}x{height}"
            )
        validate_visual_content(destination)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, default=Path("docs/ui/agent-chat.html"))
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not args.source.is_file():
        raise RuntimeError(f"Agent UI specification not found: {args.source}")
    render(args.source, args.output)


if __name__ == "__main__":
    main()
