"""Run the fixed private musicvideo dialog journey alongside the real analysis process."""
from contextlib import ExitStack
import json
import os
from pathlib import Path
import subprocess
import sys
import time
from urllib.parse import unquote, urlsplit
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


def verify_native_intake(app, pack, runner, binding):
    from isolated_test_home import environment
    from retained_app_test_products import checksum, require
    from musicvideo_intake_evidence import observation
    report = runner / 'analysis-report'
    report.mkdir()
    keys = ('PATH', 'TMPDIR', 'LANG', 'LC_ALL', 'DISPLAY', 'GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT',
            'NGV_EXAMPLE_FIXTURE_ROOT', 'NGV_EXAMPLE_FIXTURE_MANIFEST', 'NGV_EXAMPLE_REGISTRY_REFERENCE', 'NGV_EXAMPLE_DATASET')
    env = environment({k: os.environ[k] for k in keys if k in os.environ}, runner / 'private-track-home')
    env.update(NGV_EXAMPLE_REPORT_DIR=str(report), NGV_EXAMPLE_ANALYSIS_PACK=str(pack),
               NGV_GIT_COMMIT=binding['source'])
    config = config_for()
    paths = [Path(unquote(urlsplit(config[key]).path)).resolve(strict=True) for key in ('track', 'lyrics') if config.get(key)]
    class HandoffObserved(Exception):
        pass

    try:
        with session(app, env, report, 'private-audio', report=report, private=config) as client, ExitStack() as stack:
            require(client is not None, 'Missing the bound file dialog client')
            log = stack.enter_context((report / 'private-app.log').open('xb'))
            native = start(stack, [app / 'Contents/MacOS/NexGenVideo', '-ApplePersistenceIgnoreState', 'YES',
                                   '-AppleLanguages', '(en)', '-AppleLocale', 'en_US'], env=env, log=log)
            client.attach(native.pid)
            deadline = time.monotonic() + 180
            while not list(report.glob('hostflow-*-analysis.png')):
                require(native.poll() is None, 'Private startup exited before Analysis')
                client.check()
                if time.monotonic() >= deadline:
                    raise TimeoutError('No private Analysis handoff')
                time.sleep(0.1)
            progress = json.loads((report / 'hostflow-track-lyrics-result.json').read_bytes())
            entered = observation(progress, 'native Track and optional Lyrics intake')
            require(entered['nextPhase'] == 'project_init' and entered['creativeIntakeAbsent'] is True
                    and entered['trackSHA256'] == checksum(paths[0]) and entered['lyricsSupplied'] == (len(paths) == 2)
                    and (len(paths) == 1 or entered['lyricsName'] == paths[1].name),
                    'Private Track or Lyrics assignment differs from the input')
            require(checksum(paths[0]) == checksum(report / 'intake-track-source.bin') == checksum(report / 'intake-track-assigned.bin'),
                    'The private assigned Track bytes differ')
            panels = [row for row in progress['interactions'] if row.get('kind') == 'file-panel']
            require([row.get('dialogTestStep') for row in panels] == list(range(1, len(paths) + 1))
                    and all(row.get('nativePathEditorVerified') is True and row.get('selectedURLVerified') is True
                            for row in panels), 'Missing a verified private file selection')
            for n, path in enumerate(paths, 1):
                marker = json.loads((report / f'file-panel-{n}-observed').read_bytes())
                receipt = json.loads((report / f'file-panel-{n}-input.json').read_bytes())
                require(marker['pid'] == receipt['pid'] == native.pid and marker['step'] == receipt['step'] == n
                        and marker['window'] == receipt['window'] and marker['window'] > 0
                        and marker['action'] == receipt['action'] == 'open' and receipt['pathField'] == 'PathTextField'
                        and marker['selected'] == receipt['typed'] == str(path), 'Private native selection does not match')
            raise HandoffObserved
    except HandoffObserved:
        require(native.poll() is not None and client.process.poll() is not None, 'Private intake child did not exit')
        (report / 'native-intake.json').write_text(json.dumps(dict(binding=binding, appPID=native.pid,
            nativeExit=native.returncode, clientExit=client.process.returncode, analysisHandoff=True, fullAcceptance=False)))


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
