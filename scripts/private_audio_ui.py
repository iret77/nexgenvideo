"""Run the fixed private musicvideo dialog journey alongside the real analysis process."""
from contextlib import ExitStack
import json
import os
from pathlib import Path
import subprocess
import sys
from file_dialog_ui import session, start, wait_for_native


def config_for():
    root = Path(os.environ["NGV_EXAMPLE_FIXTURE_ROOT"]).resolve(strict=True)
    manifest = json.loads(Path(os.environ["NGV_EXAMPLE_FIXTURE_MANIFEST"]).read_bytes())
    dataset, = [d for d in manifest["datasets"] if d["id"] == os.environ["NGV_EXAMPLE_DATASET"]]

    def fixture(entry):
        path = (root / entry["path"]).resolve(strict=True)
        if not path.is_relative_to(root) or not path.is_file():
            raise ValueError("Invalid private fixture location")
        return path.as_uri()

    track, = [fixture(e) for e in dataset["files"] if e["kind"] == "audio"]
    lyrics = [fixture(e) for e in dataset["files"] if e["kind"] == "lyrics"]
    if len(lyrics) > 1:
        raise ValueError("Ambiguous private lyrics fixture")
    return dict(track=track,
                lyrics=next(iter(lyrics), None), fixtureRoot=root.as_uri())


def analyze():
    if os.environ.get("GITHUB_ACTIONS") != "true" or os.environ.get("GITHUB_REPOSITORY") != "iret77/nexgenvideo":
        raise ValueError("This acceptance runs in NexGenVideo CI")
    app = Path(".build/NexGenVideo.app").resolve(strict=True)
    home = Path(os.environ["CFFIXED_USER_HOME"]).resolve(strict=True)
    report = Path(os.environ["NGV_EXAMPLE_REPORT_DIR"]).resolve()
    runner = Path(os.environ["RUNNER_TEMP"]).resolve(strict=True)
    if (home != Path(os.environ["HOME"]).resolve(strict=True) or home != runner / "nexgenvideo-test-home"
            or report != runner / "analysis-report"):
        raise ValueError("Unexpected private acceptance paths")
    report.mkdir(exist_ok=True)
    if list(report.glob("file-panel-*")) or (report / "dialog-native.pid").exists():
        raise ValueError("Private dialog evidence already exists")
    env = dict(os.environ)
    with session(app, env, report, "private-audio", report=report, private=config_for()) as client:
        if client is None:
            raise ValueError("Missing the bound file dialog XCTest products")
        with ExitStack() as stack:
            log = stack.enter_context((report / "private-app.log").open("xb"))
            native = start(stack, [app / "Contents/MacOS/NexGenVideo", "-ApplePersistenceIgnoreState", "YES",
                                   "-AppleLanguages", "(en)", "-AppleLocale", "en_US"], env=env, log=log)
            code = wait_for_native(native, client, 49 * 60)
            if code:
                raise RuntimeError("The private analysis failed")
    with (report / "private-xctest-execution.json").open("x") as out:
        json.dump(dict(schema="private-audio-xctest/1", nativeExit=code, testExit=client.process.returncode,
                       appPID=native.pid, runnerTemp=str(runner), runID=int(os.environ["GITHUB_RUN_ID"]),
                       attempt=int(os.environ["GITHUB_RUN_ATTEMPT"]), harnessSHA=os.environ["GITHUB_SHA"],
                       productSHA=os.environ["NGV_GIT_COMMIT"]), out)


if __name__ == "__main__":
    try:
        analyze()
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
        print("Private audio UI failed (" + type(error).__name__ + ")", file=sys.stderr)
        sys.exit(1)
