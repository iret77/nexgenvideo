"""Render the immutable approved workbench alongside native acceptance evidence."""
import argparse
import json
from pathlib import Path
import subprocess

from render_agent_chat_spec import browser_path, validate_visual_content


REFERENCE = "e3ea08de33ca7cf0b0d7fbe27dc96fb88561e84b"
SOURCE = "docs/ui/implementation/workbench.html"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    output = parser.parse_args().output
    output.mkdir(parents=True, exist_ok=True)
    subprocess.run(["git", "fetch", "--no-tags", "--depth=1", "origin", REFERENCE],
                   check=True, timeout=60, stdin=subprocess.DEVNULL)
    source = subprocess.check_output(["git", "show", f"{REFERENCE}:{SOURCE}"],
                                     text=True, timeout=30)
    browser = browser_path()
    for view in ("brief", "board", "blocking"):
        setup = ('<script>const reference=document.getElementById("ngv-desk").ngvTest;'
                 'reference.fixture("Storyboard");'
                 f'reference.action("open:{view}");</script>')
        page = output / f"reference-{view}.html"
        page.write_text(source.replace("</body>", setup + "</body>"))
        image = output / f"reference-{view}.png"
        subprocess.run([browser, "--headless=new", "--disable-gpu", "--no-sandbox",
                        "--disable-dev-shm-usage", "--hide-scrollbars", "--no-first-run",
                        "--disable-background-networking", "--virtual-time-budget=1000",
                        "--force-device-scale-factor=1", "--window-size=1470,950",
                        f"--screenshot={image}", page.resolve().as_uri()],
                       check=True, timeout=45, stdin=subprocess.DEVNULL)
        validate_visual_content(image)
    (output / "reference.json").write_text(json.dumps({"commit": REFERENCE, "source": SOURCE}, indent=2))


if __name__ == "__main__":
    main()
