#!/usr/bin/env python3
import argparse
import re
from pathlib import Path

from render_agent_chat_spec import browser_path, png_size, run_browser, validate_visual_content


CAPTURE_SIZE = (1400, 2500)


def render(source: Path, output: Path) -> None:
    output.mkdir(parents=True, exist_ok=True)
    diagnostics = output / "diagnostics"
    browser = browser_path(diagnostics / "generation-batch-browser.json")
    url = source.resolve().as_uri() + "?capture=mockups"
    content = run_browser(browser, url, diagnostics / "generation-batch-dom", ["--dump-dom"])
    required = [
        'data-render-ready="true"',
        'aria-label="240 point Agent panel with 1 batch item"',
        'aria-label="400 point Agent panel with 13 batch items"',
        'aria-label="640 point Agent panel with 50 batch items"',
    ]
    missing = [marker for marker in required if marker not in content]
    panel_count = len(re.findall(r'<div class="panel-shell w(?:240|400|640)">', content))
    if missing or panel_count != 9:
        raise RuntimeError(
            f"Generation batch UI specification is incomplete: {missing}; "
            f"rendered {panel_count} of 9 panels"
        )

    width, height = CAPTURE_SIZE
    destination = output / "generation-batch-review-1-13-50-240-400-640.png"
    run_browser(browser, url, diagnostics / "generation-batch-screenshot",
        [
            "--hide-scrollbars",
            "--force-device-scale-factor=1",
            f"--window-size={width},{height}",
            f"--screenshot={destination}",
        ],
    )
    if png_size(destination) != CAPTURE_SIZE:
        raise RuntimeError(f"{destination.name} rendered at an unexpected size")
    validate_visual_content(destination)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--source",
        type=Path,
        default=Path("docs/ui/generation-batch-review.html"),
    )
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not args.source.is_file():
        raise RuntimeError("Generation batch UI specification not found")
    render(args.source, args.output)


if __name__ == "__main__":
    main()
