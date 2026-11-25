"""Run the fixed private musicvideo dialog journey alongside the real analysis process."""
from contextlib import ExitStack
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
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


def observe_location_footer(report, pid):
    marker = report / 'hostflow-repeatable-intake-4-second-location-incomplete.png'
    progress = report / 'hostflow-repeatable-intake.json'
    result = report / 'hostflow-repeatable-intake-result.json'
    deadline = time.monotonic() + 49 * 60
    def check_deadline():
        if time.monotonic() >= deadline:
            raise TimeoutError('Location window observation timed out')

    def capture(window, path):
        before = time.monotonic()
        subprocess.run(['/usr/sbin/screencapture', '-x', '-o', '-l', str(window), str(path)],
                       stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                       check=True, timeout=4)
        return before, time.monotonic(), path

    while not (report / 'hostflow-repeatable-intake-0-file-panel.png').is_file():
        check_deadline()
        time.sleep(0.05)
    if int((report / 'dialog-native.pid').read_text()) != pid:
        raise ValueError('Location window belongs to another intake')
    rows = json.loads(progress.read_bytes())['interactions']
    first_picker = next(r for r in rows if r.get('id') == 'agent.dialog.choose-file' and r['kind'] == 'pointer')
    window = first_picker['window']
    if not isinstance(window, int) or window <= 0:
        raise ValueError('Missing original location window')
    with tempfile.TemporaryDirectory(dir=report.parent) as temp:
        capture(window, Path(temp) / 'first-location.png')
        arrival = None
        while arrival is None:
            check_deadline()
            if marker.is_file():
                rows = json.loads(progress.read_bytes())['interactions']
                index = next((i for i, r in enumerate(rows) if r['kind'] == 'text'
                              and r['field']['actual'] == 'Unfinished location' and r['field']['ownsEditor']
                              and r['field']['window'] == window), None)
                if index is not None:
                    arrival = next((event for r in rows[index + 1:] if r.get('label') == 'button hover'
                                    for event in r['evidence']['received'] if event['tagMatches'] and event['windowMatches']
                                    and event['xMatches'] and event['yMatches'] and event['window'] == window), None)
                if result.is_file() and arrival is None:
                    raise ValueError('Missing delivered hover after the second location field')
            if arrival is None:
                time.sleep(0.005 if marker.is_file() else 0.02)
        time.sleep(max(0, arrival['observedUptime'] + 0.15 - time.monotonic()))
        captures = []
        end = time.monotonic() + 2
        while time.monotonic() < end and not result.exists():
            path = Path(temp) / f'{len(captures)}.png'
            captures.append(capture(window, path))
        while not result.exists():
            if time.monotonic() >= deadline:
                raise TimeoutError('Location confirmation did not finish')
            time.sleep(0.05)
        raw = result.read_bytes()
        click, = [r['nativeInput'] for r in json.loads(raw)['interactions']
                  if r.get('id') == 'agent.dialog.clear-item' and r['kind'] == 'pointer']
        hover, = [e for e in click['movement']['received'] if e['tagMatches'] and e['windowMatches']
                  and e['xMatches'] and e['yMatches'] and e['window'] == window]
        down, = [e for e in click['posted'] if e['type'] == 1 and e['tag'] == hover['tag'] == click['tag']]
        if (click['status'] != 'delivered' or click['window'] != window or not click['originalHoverValidAtDown']
                or hover != arrival):
            raise ValueError('Missing observed Clear item activation')
        settled = [(a, b, path) for a, b, path in captures
                   if hover['observedUptime'] + 0.15 <= a <= b < down['postedUptime']]
        frames = []
        for a, b, path in settled:
            data = path.read_bytes()
            if data[:8] != bytes.fromhex('89504e470d0a1a0a'):
                raise ValueError('WindowServer capture is not a PNG')
            name = f'location-footer-settled-{len(frames)}.png'
            path.replace(report / name)
            frames.append(dict(name=name, begin=a, end=b, sha256=hashlib.sha256(data).hexdigest()))
        receipt = dict(pid=pid, window=window, transaction=click['transaction'], hover=hover['observedUptime'],
                       down=down['postedUptime'], resultSHA256=hashlib.sha256(raw).hexdigest(), frames=frames,
                       attempts=[[a, b] for a, b, _ in captures], runID=int(os.environ['GITHUB_RUN_ID']),
                       attempt=int(os.environ['GITHUB_RUN_ATTEMPT']))
        if not frames and captures:
            a, b, path = min(captures, key=lambda c: abs(c[1] - down['postedUptime']))
            diagnostic = 'location-footer-unqualified.png'
            path.replace(report / diagnostic)
            receipt['unqualifiedFrame'] = dict(name=diagnostic, begin=a, end=b)
        with (report / 'location-footer-observation.json').open('x') as stream:
            json.dump(receipt, stream, sort_keys=True)
        if not frames:
            raise RuntimeError('No WindowServer image inside the settled location interval')


def start_footer_observer(stack, app, env, report, native):
    build = plistlib.loads((app / 'Contents/Info.plist').read_bytes())['CFBundleVersion']
    if int(build) < 139:
        return None
    log = stack.enter_context((report / 'location-footer-observer.log').open('xb'))
    return start(stack, [sys.executable, __file__, '--observe-footer', str(report), str(native.pid)], env=env, log=log)


def finish_footer_observer(observer):
    if observer is not None and observer.wait(timeout=10) != 0:
        raise RuntimeError('Missing settled location footer evidence')


def verify_material_handoff(report, native, client, file_count, project):
    from musicvideo_intake_evidence import observation, validate
    from retained_app_test_products import require
    material_result = report / 'hostflow-material-actions-result.json'
    location_open = file_count + 2
    confirmation_path = report / f'file-panel-{location_open}-default-action.json'
    deadline = time.monotonic() + 600
    while not (material_result.is_file() and confirmation_path.is_file()):
        require(native.poll() is None, 'Private material intake exited before the Brief handoff')
        client.check()
        if time.monotonic() >= deadline:
            raise TimeoutError('Missing private material decisions, location Open or Brief handoff')
        time.sleep(0.2)
    stages = ['hostflow-track-lyrics-result.json', 'hostflow-repeatable-intake-result.json']
    validate(report, {'nativeIntakeEvidence': stages})
    location = json.loads((report / stages[1]).read_bytes())
    panels = [row for row in location['interactions'] if row['kind'] in ('file-panel-cancel', 'file-panel')]
    require([row['dialogTestStep'] for row in panels] == [location_open - 1, location_open], 'Wrong material file panels')
    for panel, action in zip(panels, ('cancel', 'open')):
        prefix = f"file-panel-{panel['dialogTestStep']}-"
        observed = json.loads((report / (prefix + 'observed')).read_bytes())
        typed = json.loads((report / (prefix + 'input.json')).read_bytes())
        require(observed['pid'] == typed['pid'] == native.pid and observed['step'] == typed['step'] == panel['dialogTestStep']
                and observed['action'] == typed['action'] == action and observed['window'] == typed['window'] == panel['dismissedWindow']
                and typed['window'] > 0, 'Material file panel no longer matches the app')
        if action == 'open':
            proof = json.loads(confirmation_path.read_bytes())
            require(proof['sentReturn'] is True and proof['visibleTargetWindows'][:1] == [typed['window']]
                    and proof['window'] == typed['window'] and typed['pathField'] == 'PathTextField'
                    and observed['selected'] == typed['typed'] == str(report / 'Stage.png'), 'Unconfirmed location selection')
        else:
            proof = json.loads((report / (prefix + 'cancel-action.json')).read_bytes())
            require(proof['sentEscape'] is True and proof['visibleTargetWindows'][:1] == [typed['window']]
                    and proof['window'] == typed['window'] and 'typed' not in typed and 'selected' not in observed,
                    'Unconfirmed location cancellation')
    material = json.loads(material_result.read_bytes())
    actions = [row for row in material['interactions'] if row.get('kind') == 'pointer']
    cards = [row['evidence'] for row in material['interactions'] if row.get('label') == 'material action']
    handoff = observation(material, 'material intake handoff')
    require([(card['role'], card['title'], card['button']) for card in cards] ==
            [('script', 'Existing story', 'Continue'), ('character', 'Prepared character 1', 'Skip'),
             ('style', 'Style references', 'Continue')] and len({card['dialogID'] for card in cards}) == 3
            and handoff['projectKey'] == project and handoff['phase'] == 'brief' and handoff['turnID'] and handoff['instructionsSHA256'],
            'Private material decisions did not hand the same project to Brief')
    require([row['id'] for row in actions] == [card['control'] for card in cards] ==
            ['agent.dialog.confirm', 'agent.dialog.complete', 'agent.dialog.confirm']
            and len({row['nativeInput']['transaction'] for row in actions}) == 3
            and all(row['nativeInput']['buttonDownObserved'] is True and row['nativeInput']['buttonReleased'] is True
                    for row in actions), 'Private material buttons did not receive their native clicks')


def verify_production_handoff(report, native, client, project):
    from retained_app_test_products import require
    progress = report / 'owner-v2-musicvideo.json'
    deadline = time.monotonic() + 180
    while time.monotonic() < deadline:
        require(native.poll() is None, 'Private app exited before entering Production')
        client.check()
        if progress.is_file():
            state = json.loads(progress.read_bytes())
            require(not state['failure'], 'Private Production handoff failed')
            rows = state['interactions']
            for index, row in enumerate(rows):
                if row.get('label') != 'private production workspace':
                    continue
                target = row['evidence']
                click = rows[index - 1] if index else {}
                proof = click.get('nativeInput', {})
                require(project and target['projectKey'] == project and target['workspace'] == 'production'
                        and click.get('kind') == 'pointer' and click.get('id') == 'editor.workspace.production'
                        and target['window'] == click.get('window') == proof.get('window') and target['window'] > 0
                        and proof.get('status') == 'delivered' and all(proof.get(key) is True for key in
                                ('ownedDownPosted', 'ownedUpPosted', 'buttonDownObserved', 'buttonReleased',
                                 'localMonitorDownObserved')),
                        'Private Production handoff lacks the completed click in its own document')
                return
        time.sleep(0.2)
    raise TimeoutError('Missing the private Production handoff')


def verify_native_intake(app, pack, runner, binding):
    from isolated_test_home import environment
    from retained_app_test_products import checksum, require
    from musicvideo_intake_evidence import observation
    build = int(plistlib.loads((app / 'Contents/Info.plist').read_bytes())['CFBundleVersion'])
    material_required = build >= 134
    production_required = build >= 140
    report = runner / 'analysis-report'
    report.mkdir()
    keys = ('PATH', 'TMPDIR', 'LANG', 'LC_ALL', 'DISPLAY', 'GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT',
            'NGV_EXAMPLE_FIXTURE_ROOT', 'NGV_EXAMPLE_FIXTURE_MANIFEST', 'NGV_EXAMPLE_REGISTRY_REFERENCE', 'NGV_EXAMPLE_DATASET')
    env = environment({k: os.environ[k] for k in keys if k in os.environ}, runner / 'private-track-home')
    env.update(NGV_EXAMPLE_REPORT_DIR=str(report), NGV_EXAMPLE_ANALYSIS_PACK=str(pack),
               NGV_GIT_COMMIT=binding['source'])
    class HandoffObserved(Exception):
        pass

    try:
        config = config_for()
        paths = [Path(unquote(urlsplit(config[key]).path)).resolve(strict=True) for key in ('track', 'lyrics') if config.get(key)]
        with session(app, env, report, 'private-audio', report=report, private=config) as client, ExitStack() as stack:
            require(client is not None, 'Missing the bound file dialog client')
            log = stack.enter_context((report / 'private-app.log').open('xb'))
            native = start(stack, [app / 'Contents/MacOS/NexGenVideo', '-ApplePersistenceIgnoreState', 'YES',
                                   '-AppleLanguages', '(en)', '-AppleLocale', 'en_US'], env=env, log=log)
            observer = start_footer_observer(stack, app, env, report, native)
            client.attach(native.pid)
            deadline = time.monotonic() + 180
            confirmations = [report / f'file-panel-{n}-default-action.json' for n in range(1, len(paths) + 1)]
            while not (list(report.glob('hostflow-*-analysis.png')) and all(path.is_file() for path in confirmations)):
                require(native.poll() is None, 'Private startup exited before Analysis')
                client.check()
                if time.monotonic() >= deadline:
                    raise TimeoutError('Missing private Analysis handoff or native Open confirmation')
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
                confirmation = json.loads((report / f'file-panel-{n}-default-action.json').read_bytes())
                require(confirmation['sentReturn'] is True and confirmation['visibleTargetWindows'][:1] == [marker['window']]
                        and confirmation['window'] == marker['window'], 'Unconfirmed private Open panel')
                require(marker['pid'] == receipt['pid'] == native.pid and marker['step'] == receipt['step'] == n
                        and marker['window'] == receipt['window'] and marker['window'] > 0
                        and marker['action'] == receipt['action'] == 'open' and receipt['pathField'] == 'PathTextField'
                        and marker['selected'] == receipt['typed'] == str(path), 'Private native selection does not match')
            if material_required:
                verify_material_handoff(report, native, client, len(paths), entered['projectKey'])
            finish_footer_observer(observer)
            if production_required:
                verify_production_handoff(report, native, client, entered['projectKey'])
            raise HandoffObserved
    except HandoffObserved:
        require(native.poll() is not None and client.process.poll() is not None, 'Private intake child did not exit')
        (report / 'native-intake.json').write_text(json.dumps(dict(binding=binding, appPID=native.pid,
            nativeExit=native.returncode, clientExit=client.process.returncode, analysisHandoff=True, materialIntakeHandoff=material_required,
            productionWorkspaceHandoff=production_required, fullAcceptance=False)))
    except Exception:
        import traceback
        (report / 'intake-error.log').write_text(traceback.format_exc())
        raise RuntimeError('Private native intake failed. See the private evidence.') from None


def record_analysis_failure(report, started, state):
    import pwd
    import traceback
    native, client = state.get("native"), state.get("client")
    crashes = report / "crash-reports"
    copied = []
    for directory in (Path(pwd.getpwuid(os.getuid()).pw_dir) / "Library/Logs/DiagnosticReports",
                      Path("/Library/Logs/DiagnosticReports")):
        try:
            candidates = sorted(directory.glob("NexGenVideo*.ips"))
        except OSError:
            continue
        for path in candidates:
            try:
                info = path.lstat()
                if not path.is_file() or path.is_symlink() or info.st_mtime < started or info.st_size > 32 * 1024 * 1024:
                    continue
                crashes.mkdir(exist_ok=True)
                destination = crashes / (str(len(copied)) + "-" + path.name)
                destination.write_bytes(path.read_bytes())
                copied.append(dict(original=str(path), file=destination.name, bytes=info.st_size))
            except OSError:
                continue
    with (report / "analysis-error.json").open("x") as out:
        json.dump(dict(traceback=traceback.format_exc(),
                       nativePID=native.pid if native else None, nativeExit=native.poll() if native else None,
                       testExit=client.process.poll() if client else None, crashReports=copied), out)


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
    started, state = time.time(), {}
    try:
        with session(app, env, report, "private-audio", report=report, private=config_for()) as client:
            if client is None:
                raise ValueError("Missing the bound file dialog XCTest products")
            state["client"] = client
            with ExitStack() as stack:
                log = stack.enter_context((report / "private-app.log").open("xb"))
                native = start(stack, [app / "Contents/MacOS/NexGenVideo", "-ApplePersistenceIgnoreState", "YES",
                                       "-AppleLanguages", "(en)", "-AppleLocale", "en_US"], env=env, log=log)
                state["native"] = native
                observer = start_footer_observer(stack, app, env, report, native)
                code = wait_for_native(native, client, 49 * 60)
                if code:
                    raise RuntimeError("The private analysis failed")
                finish_footer_observer(observer)
    except Exception:
        record_analysis_failure(report, started, state)
        raise
    with (report / "private-xctest-execution.json").open("x") as out:
        json.dump(dict(schema="private-audio-xctest/1", nativeExit=code, testExit=client.process.returncode,
                       appPID=native.pid, runnerTemp=str(runner), runID=int(os.environ["GITHUB_RUN_ID"]),
                       attempt=int(os.environ["GITHUB_RUN_ATTEMPT"]), harnessSHA=os.environ["GITHUB_SHA"],
                       productSHA=os.environ["NGV_GIT_COMMIT"]), out)


if __name__ == "__main__":
    try:
        if len(sys.argv) == 4 and sys.argv[1] == '--observe-footer':
            observe_location_footer(Path(sys.argv[2]), int(sys.argv[3]))
        else:
            analyze()
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
        print("Private audio UI failed (" + type(error).__name__ + ")", file=sys.stderr)
        sys.exit(1)
