"""Supervise a fixed XCTest scenario on the existing CI-owned NexGenVideo process."""
from contextlib import ExitStack, contextmanager
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import time

def invocation(products, config, home):
    original, = products.glob("FileDialogUI*.xctestrun")
    plist = plistlib.loads(original.read_bytes())

    def targets(value):
        if isinstance(value, list):
            for item in value:
                yield from targets(item)
        elif isinstance(value, dict):
            if "TestBundlePath" in value:
                yield value
            else:
                for item in value.values():
                    yield from targets(item)

    target, = targets(plist)
    if not target["TestBundlePath"].endswith("/FileDialogTests.xctest"):
        raise ValueError("Unexpected UI test bundle")
    for key in ("EnvironmentVariables", "TestingEnvironmentVariables"):
        target.setdefault(key, {}).update(HOME=str(home), CFFIXED_USER_HOME=str(home), NGV_FILE_DIALOG_TEST_CONFIG=str(config))
    dest = products / (config.parent.name + ".xctestrun")
    with dest.open("xb") as out:
        plistlib.dump(plist, out)
    return dest


def start(stack, args, *, env, log):
    process = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, env=env)
    def reap():
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=8)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
    stack.callback(reap)
    return process


class DialogClient:
    def __init__(self, process, report):
        self.process = process
        self.report = report

    def attach(self, pid):
        marker = self.report / "dialog-native.pid"
        if marker.exists():
            raise ValueError("Dialog test PID is already bound")
        pending = marker.with_suffix(".pending")
        with pending.open("x") as out:
            out.write(str(pid))
        pending.replace(marker)

    def check(self):
        code = self.process.poll()
        if code is not None and (code or not (self.report / "dialog-test-steps").is_file()):
            raise RuntimeError("The supervised file dialog test failed")

    def finish(self):
        deadline = time.monotonic() + 5
        while not (self.report / "dialog-test-steps").is_file():
            self.check()
            if time.monotonic() >= deadline:
                raise RuntimeError("The application exited before the file dialog test finished")
            time.sleep(0.1)
        self.process.wait(timeout=45)
        self.check()


@contextmanager
def session(app, environment, evidence, scenario, *, report=None, scale=None, private=None):
    configured = os.environ.get("NGV_FILE_DIALOG_PRODUCTS")
    if not scenario or not configured:
        yield None
        return
    if os.environ.get("GITHUB_ACTIONS") != "true" or os.environ.get("GITHUB_REPOSITORY") != "iret77/nexgenvideo":
        raise ValueError("File dialog acceptance requires the NexGenVideo CI job")
    products = Path(configured).resolve(strict=True)
    runner = Path(os.environ["RUNNER_TEMP"]).resolve(strict=True)
    evidence = evidence.resolve(strict=True)
    home = Path(environment["HOME"]).resolve(strict=True)
    if (not home.is_relative_to(runner) or home == runner or str(home) != str(Path(environment["CFFIXED_USER_HOME"]).resolve(strict=True))
            or products != runner / "file-dialog-ui/build/Build/Products" or not evidence.is_relative_to(runner)):
        raise ValueError("Unexpected file dialog fixture or product root")
    if report is None:
        report = evidence / ("dialogs-" + scenario)
        report.mkdir(exist_ok=scenario == "packresume-finish")
    if (scenario != "packresume-finish" and any(report.glob("file-panel-*"))) or (report / "dialog-native.pid").exists():
        raise ValueError("The dialog test requires fresh evidence")
    app = app.resolve(strict=True)
    if app.name != "NexGenVideo.app":
        raise ValueError("Unexpected file dialog target")
    origin = runner / "file-dialog-ui/client.json"
    if not origin.exists():
        origin = runner / "file-dialog-ui/transfer/client.json"
    shutil.copyfile(origin, report / "dialog-client.json")
    config = dict(app=app.as_uri(), home=home.as_uri(), evidence=evidence.as_uri(), report=report.as_uri(),
                  scenario=scenario, scale=scale)
    if private:
        config.update(private)
    with ExitStack() as stack:
        scratch = Path(stack.enter_context(tempfile.TemporaryDirectory(dir=runner, prefix="file-dialog-")))
        settings = scratch / "fixture.json"
        settings.write_text(json.dumps(config))
        tests = invocation(products, settings, home)
        stack.callback(tests.unlink)
        log = stack.enter_context((report / "dialog-test.log").open("xb"))
        child = {key: value for key, value in os.environ.items() if key in
                 {"TMPDIR", "LANG", "LC_ALL", "DEVELOPER_DIR", "DISPLAY", "__CF_USER_TEXT_ENCODING"}}
        child.update(HOME=str(home), CFFIXED_USER_HOME=str(home), PATH="/usr/bin:/bin:/usr/sbin:/sbin")
        process = start(stack, ["/usr/bin/xcodebuild", "test-without-building", "-xctestrun", tests,
                        "-destination", "platform=macOS,arch=arm64", "-parallel-testing-enabled", "NO",
                        "-only-testing:FileDialogTests/FileDialogTests/testScenarioFileSelection",
                        "-resultBundlePath", scratch / "file-dialog.xcresult"], env=child, log=log)
        client = DialogClient(process, report)
        deadline = time.monotonic() + 90
        while not (report / "dialog-test-ready").exists():
            client.check()
            if time.monotonic() >= deadline:
                raise TimeoutError("The fixed file dialog test did not start")
            time.sleep(0.1)
        environment.update(NGV_FILE_DIALOG_TEST_CASE=scenario, NGV_FILE_DIALOG_EVIDENCE=str(report))
        yield client
        client.finish()


def wait_for_native(native, client, timeout):
    if client is None:
        return native.wait(timeout=timeout)
    client.attach(native.pid)
    deadline = time.monotonic() + timeout
    while native.poll() is None:
        client.check()
        if time.monotonic() >= deadline:
            raise subprocess.TimeoutExpired(native.args, timeout)
        time.sleep(0.1)
    return native.returncode
