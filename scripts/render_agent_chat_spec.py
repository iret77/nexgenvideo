#!/usr/bin/env python3
import argparse
import re
import shutil
import struct
import subprocess
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


def browser_path() -> str:
    for name in ("google-chrome", "google-chrome-stable", "chromium", "chromium-browser"):
        resolved = shutil.which(name)
        if resolved:
            return resolved
    raise RuntimeError("Chrome or Chromium is required to render the Agent UI specification")


def validate_capture_dom(content: str, state: str) -> None:
    required = (
        f'data-capture-state="{state}"',
        'data-render-ready="true"',
        f'data-state-section="{state}"',
        'aria-label="240 point Agent panel',
        'aria-label="400 point Agent panel',
        'aria-label="640 point Agent panel',
    )
    missing = [marker for marker in required if marker not in content]
    if missing:
        raise RuntimeError(
            f"Agent UI capture {state} did not reach its rendered state: {missing}"
        )


def rendered_dom(browser: str, url: str, state: str) -> None:
    result = subprocess.run(
        [
            browser,
            "--headless=new",
            "--disable-gpu",
            "--no-sandbox",
            "--virtual-time-budget=1000",
            "--dump-dom",
            url,
        ],
        check=True,
        capture_output=True,
        text=True,
        timeout=45,
    )
    validate_capture_dom(result.stdout, state)


def render(source: Path, output: Path) -> None:
    browser = browser_path()
    output.mkdir(parents=True, exist_ok=True)
    actual_states = declared_states(source)
    if actual_states != STATES:
        raise RuntimeError(
            "Agent UI capture states differ from the required matrix: "
            f"expected {STATES}, got {actual_states}"
        )
    width, height = CAPTURE_SIZE
    for state in STATES:
        destination = output / f"agent-chat-{state}-240-400-640.png"
        url = source.resolve().as_uri() + f"?capture={state}"
        rendered_dom(browser, url, state)
        subprocess.run(
            [
                browser,
                "--headless=new",
                "--disable-gpu",
                "--hide-scrollbars",
                "--no-sandbox",
                "--run-all-compositor-stages-before-draw",
                "--virtual-time-budget=1000",
                "--force-device-scale-factor=1",
                f"--window-size={width},{height}",
                f"--screenshot={destination}",
                url,
            ],
            check=True,
            timeout=45,
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
