#!/usr/bin/env python3
import argparse
import shutil
import struct
import subprocess
from pathlib import Path


VIEWPORTS = ((240, 1050), (400, 1050), (640, 1050), (1180, 1100))


def png_size(path: Path) -> tuple[int, int]:
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        raise RuntimeError(f"{path} is not a PNG")
    return struct.unpack(">II", data[16:24])


def browser_path() -> str:
    for name in ("google-chrome", "google-chrome-stable", "chromium", "chromium-browser"):
        resolved = shutil.which(name)
        if resolved:
            return resolved
    raise RuntimeError("Chrome or Chromium is required to render the Agent UI specification")


def render(source: Path, output: Path) -> None:
    browser = browser_path()
    output.mkdir(parents=True, exist_ok=True)
    url = source.resolve().as_uri() + "#mockups"
    for width, height in VIEWPORTS:
        destination = output / f"agent-chat-{width}x{height}.png"
        subprocess.run(
            [
                browser,
                "--headless=new",
                "--disable-gpu",
                "--hide-scrollbars",
                "--no-sandbox",
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
