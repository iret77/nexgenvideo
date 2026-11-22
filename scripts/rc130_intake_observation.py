"""Exercise the native Open dialog on the unchanged Build 130 with the newly built XCTest."""
from contextlib import ExitStack
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import time
from urllib.parse import unquote, urlsplit
import zipfile

import app_cohort_v2 as cohort
import app_release_v2
import compiled_app_release as release
import file_dialog_products as dialogs
import native_app_target_build as targets
import release_checkpoint
import signed_component_carrier
from file_dialog_ui import session, start
from isolated_test_home import environment
from private_audio_ui import config_for
from retained_app_test_products import archive_bytes, checksum, download, require

PRODUCT = '28817a4e21dd02046ee8b424bccbdb08c9300c21'
NATIVE = 44978711174
ROLE = {'metadata': (14736509315, '0c07c9140e57c19b381e9878488246589325e0360764b815822afd767435fa44', None), 'production': (14737197920, 'f26b4262b6df08f564739215e68aaf890617d78e25f691f110a611d07f4ab1bb', '155aa6b0b9f747e8f785f8546b2e471f93a7ef39d63fbef65c0d359141be5f64')}


def fetch(role):
    identifier, digest, receipt = ROLE[role]
    selected = dict(runID=NATIVE, sourceSHA=PRODUCT, artifactID=identifier, artifactSHA256=digest)
    if receipt:
        selected['receiptSHA256'] = receipt
    return release.producer(selected, role)


def restore_image(root):
    role = 'production'
    origin = fetch('metadata')
    metadata = root.parent / 'rc130-native-metadata.zip'
    if not metadata.exists():
        download(origin['artifact'], metadata)
    require(checksum(metadata) == ROLE['metadata'][1], 'Metadata digest differs')
    with zipfile.ZipFile(metadata) as archive:
        prepared = json.loads(archive_bytes(archive, 'prepared.json', 32 * 1024**2))
    require(prepared['sourceSHA'] == PRODUCT, 'Foreign compiler metadata')
    plan = prepared['plans'][role]
    arena = Path(plan['operations']['arena'])
    runner = Path(os.environ['RUNNER_TEMP']).resolve(strict=True)
    require(arena == runner / 'app-build-plan-evidence' / 'production' / 'derived-data'
            and not arena.exists(), 'Unexpected compiler arena')
    producer = fetch(role)
    restored = targets.restore_product(root, role, prepared, producer)
    require(checksum(Path(restored['folder']) / 'original.zip') == ROLE[role][1], 'Native archive digest differs')
    release.verify_product(restored['receipt'], producer['selected'], role, prepared)
    link, = [item for item in plan['operations']['links'] if item['targetGUID'] == plan['driver']['targetGUID']]
    image = Path(link['output'])
    expected = '24126d5c6ced8d90a06c3bed9b1de9d02f4d2df28b0bda376ded444e6f95a950'
    require(image.is_relative_to(arena) and checksum(image) == expected, 'Native image differs')
    return image


def verify_client(runner):
    work = runner / 'file-dialog-ui'
    products = work / 'build/Build/Products'
    transfer = work / 'transfer'
    receipt = json.loads((transfer / 'client.json').read_bytes())
    require(os.environ['NGV_FILE_DIALOG_PRODUCTS'] == str(products) and receipt['source'] == os.environ['GITHUB_SHA']
            and receipt['run'] == int(os.environ['GITHUB_RUN_ID']) and receipt['attempt'] == 1
            and receipt['tree'] == dialogs.project_tree(receipt['source'])
            and receipt['sha256'] == checksum(transfer / 'products.tar.gz')
            and receipt['products'] == dialogs.products_sha256(products), 'Current client build is not bound')
    dialogs.check_test_paths(products / receipt['xctestrun'], products)


def intake(runner, root):
    verify_client(runner)
    image = restore_image(root)
    value = cohort.manifest(PRODUCT)
    original, manifest = signed_component_carrier.acquire(root, value)
    app = root / 'NexGenVideo.app'
    release_checkpoint.validate_app_zip(original / 'NexGenVideo.zip')
    subprocess.run(['/usr/bin/ditto', '-x', '-k', original / 'NexGenVideo.zip', root], check=True, timeout=240)
    require(release_checkpoint.tree_digest(app) == manifest['appTreeSHA256'], 'Carrier app differs')
    signed_component_carrier.verify_components(app_release_v2.unchanged_components(app), value)
    release_checkpoint.extract_tar(original / 'plugins.tar.gz', root, {'plugins'})
    folder = root / 'plugins'
    pack = folder / 'musicvideo.ngvpack'
    require(checksum(folder / 'musicvideo.ngvpack.zip') == value['signedBase']['packArchiveSHA256'], 'Pack archive differs')
    if not pack.exists():
        subprocess.run(['/usr/bin/ditto','-x','-k',folder / 'musicvideo.ngvpack.zip',folder], check=True, timeout=120)
    require(release.canonical_bundle_tree(pack) == value['signedBase']['packTreeSHA256'], 'Pack tree differs')
    subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict',pack], check=True, timeout=90)
    target = app / 'Contents/MacOS/NexGenVideo'
    target.unlink()
    shutil.copyfile(image, target)
    target.chmod(0o755)
    subprocess.run(['/usr/bin/install_name_tool','-add_rpath','@executable_path/../Frameworks',target], check=True, timeout=60)
    uuid = release.image_uuid(target, 2)
    require(uuid.upper() == 'AFC32832-2F29-3C74-AB39-610D1FD657D2', 'Production UUID differs')
    resources = Path('Sources/NexGenVideo/Resources')
    info = plistlib.loads((resources / 'Info.plist').read_bytes())
    info_path = app / 'Contents/Info.plist'
    prior = plistlib.loads(info_path.read_bytes())
    if 'SentryDSN' in prior:
        info['SentryDSN'] = prior['SentryDSN']
    info.update(NGVSourceCommit=PRODUCT, NGVBuildConfiguration='release', NGVBuildSDK='27.2',
                CFBundleShortVersionString='1.8.0', CFBundleVersion='130')
    info_path.write_bytes(plistlib.dumps(info))
    shutil.copyfile(resources / 'Changelog/changelog.json', app / 'Contents/Resources/Changelog/changelog.json')
    payload = release.signed_payload_sha(target, 2)
    (runner / 'rc130-menu-control-binding.json').write_text(json.dumps(
        dict(product=PRODUCT, nativeRun=NATIVE, clientTree=dialogs.project_tree(os.environ['GITHUB_SHA']), harness=os.environ['GITHUB_SHA'],
             run=os.environ['GITHUB_RUN_ID'], imageUUID=uuid, distributionPayload=payload)))
    subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', app], check=True, timeout=90)
    require(release.image_uuid(target, 2) == uuid and release.signed_payload_sha(target, 2) == payload,
            'Diagnostic app identity changed')
    report = runner / 'analysis-report'
    report.mkdir()
    failed = []
    for route in ('private', 'workspace'):
        evidence = report if route == 'private' else report / 'workspace'
        evidence.mkdir(exist_ok=True)
        try:
            observe(runner, app, pack, evidence, route)
        except Exception:
            import traceback
            (evidence / 'route-error.log').write_text(traceback.format_exc())
            failed.append(route)
    require(not failed, 'Track observation failed in ' + ', '.join(failed))


class HandoffObserved(Exception):
    pass


def selection_result(observed):
    require(observed['axTrusted'] and observed['targetPID'] == observed['frontmostPID'],
            'Inconclusive: no trusted frontmost target for the observed selection')
    system = observed['systemFocus']
    local = observed['applicationFocus']
    require(system.get('status') == 0 and system.get('pid', -1) > 0,
            'Inconclusive: system focus could not be read')
    if local.get('status') == 0 and local.get('pid', -1) > 0 and system['pid'] != local['pid']:
        return 'system-and-application-focus-differ'
    focus = system if system.get('AXRole') else local
    require(focus.get('status') == 0 and focus.get('pid') == system['pid'] and focus.get('AXRole'),
            'Inconclusive: no attributable focused element')
    if focus.get('AXIdentifier') == 'PathTextField' or (focus['AXRole'] in ('AXTextField', 'AXTextArea')
                                                        and focus.get('matchesPathValue') is True):
        require(focus.get('selectionStart', -1) >= 0 and focus.get('selectionLength', -1) >= 0,
                'Inconclusive: focused editor returned no selection range')
        return 'measured-editor-selection'
    require(focus['AXRole'] not in ('AXTextField', 'AXTextArea') or focus.get('AXIdentifier'),
            'Inconclusive: the focused text element has no identity')
    return 'different-focused-element'


def observe(runner, app, pack, report, route):
    common = ('PATH', 'TMPDIR', 'LANG', 'LC_ALL', 'DEVELOPER_DIR', 'DISPLAY', 'GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT')
    private = route == 'private'
    keys = common + (('NGV_EXAMPLE_FIXTURE_ROOT', 'NGV_EXAMPLE_FIXTURE_MANIFEST', 'NGV_EXAMPLE_REGISTRY_REFERENCE',
                     'NGV_EXAMPLE_DATASET') if private else ())
    env = environment({key: os.environ[key] for key in keys if key in os.environ},
                      runner / ('nexgenvideo-test-home' if private else 'workspace-test-home'))
    if private:
        env.update(NGV_EXAMPLE_ANALYSIS_PACK=str(pack), NGV_EXAMPLE_REPORT_DIR=str(report), NGV_GIT_COMMIT=PRODUCT)
        config = dict(config_for(), observeSelectionOnly=True)
        startup = report
    else:
        output = report / 'scale-100-performance-roles'
        env.update(NGV_WORKSPACE_UI_ACCEPTANCE='1', NGV_WORKSPACE_UI_EVIDENCE=str(report),
                   NGV_WORKSPACE_UI_CASE='performanceroles', NGV_WORKSPACE_UI_SCALE='1.0', NGV_WORKSPACE_UI_PACK=str(pack))
        config = dict(track=(output / 'role-source.wav').as_uri(), fixtureRoot=output.as_uri())
        startup = output / 'startup'
    paths = [Path(unquote(urlsplit(config['track']).path))]
    steps = [1]
    try:
        with session(app, env, report, 'private-audio', report=report, private=config) as client, ExitStack() as stack:
            require(client is not None, 'Missing actual XCTest')
            log = stack.enter_context((report / 'app.log').open('xb'))
            process = start(stack, [app / 'Contents/MacOS/NexGenVideo', '-ApplePersistenceIgnoreState', 'YES',
                                    '-AppleLanguages', '(en)', '-AppleLocale', 'en_US'], env=env, log=log)
            client.attach(process.pid)
            until = time.monotonic() + 150
            while time.monotonic() < until:
                selection = report / 'file-panel-1-editor-selection.json'
                if private and selection.exists():
                    observed = json.loads(selection.read_bytes())
                    visible = json.loads((report / 'file-panel-1-visible.json').read_bytes())
                    require(observed['targetPID'] == visible['pid'] == process.pid and visible['step'] == 1
                            and visible['action'] == 'open' and observed['pathField'] == 'PathTextField',
                            'Private selection observation did not belong to the supervised Track panel')
                    result = selection_result(observed)
                    raise HandoffObserved
                if not private and list(startup.glob('hostflow-*-analysis.png')):
                    record = json.loads((startup / 'hostflow-track-lyrics-result.json').read_bytes())
                    panels = [r for r in record['interactions'] if r.get('kind') == 'file-panel']
                    require([r.get('dialogTestStep') for r in panels] == steps
                            and all(r.get('selectedURLVerified') is True and r.get('nativePathEditorVerified') is True for r in panels),
                            'Missing the expected native file selections')
                    require(checksum(paths[0]) == checksum(startup / 'intake-track-source.bin') == checksum(startup / 'intake-track-assigned.bin'),
                            'The assigned Track differs')
                    for number, path in zip(steps, paths):
                        observed = json.loads((report / f'file-panel-{number}-observed').read_bytes())
                        receipt = json.loads((report / f'file-panel-{number}-input.json').read_bytes())
                        require((receipt['pid'], receipt['step'], receipt['action']) == (process.pid, number, 'open')
                                and receipt['pathInput'] == 'commandV' and receipt['typed'] == observed['selected'] == str(path) and receipt['pathField'] == 'PathTextField'
                                and receipt['window'] > 0 and observed['pid'] == process.pid and observed['window'] == receipt['window'],
                                'The observed dialog path, process or window differs')
                    raise HandoffObserved
                require(process.poll() is None, 'Track observation exited before its required evidence')
                client.check()
                time.sleep(0.1)
            raise TimeoutError('No analysis handoff within the intake deadline')
    except HandoffObserved:
        require(process.poll() is not None and client.process.poll() is not None, 'Diagnostic child was not reaped')
        (report / 'route-result.json').write_text(json.dumps(dict(route=route, observed=result if private else 'analysis-handoff', source=PRODUCT,
            clientRun=int(os.environ['GITHUB_RUN_ID']), clientSource=os.environ['GITHUB_SHA'], appPID=process.pid, nativeExit=process.returncode,
            testExit=client.process.returncode, privateFullAcceptance=False)))
        print(f"Track observation completed for {route}.")


if __name__ == '__main__':
    runner = Path(os.environ['RUNNER_TEMP']).resolve(strict=True)
    require(os.environ.get('GITHUB_REPOSITORY') == 'iret77/nexgenvideo'
            and os.environ.get('GITHUB_RUN_ATTEMPT') == '1'
            and os.environ.get('GITHUB_JOB') == 'rc130-menu-control'
            and os.uname().machine == 'arm64'
            and subprocess.check_output(['sw_vers','-productVersion'],text=True).startswith('27.')
            and cohort.git('rev-parse','HEAD') == os.environ['GITHUB_SHA'], 'Requires the owned macOS 27 CI job')
    require(cohort.git('rev-parse', 'HEAD^') == PRODUCT, 'Unexpected product parent')
    changed = set(cohort.git('diff','--name-only',PRODUCT,'HEAD').splitlines())
    require(changed == {'.github/workflows/native-acceptance-probes.yml', 'scripts/rc130_intake_observation.py',
                        'scripts/file-dialog-ui/Tests/FileDialogTests.swift'},
            'Unexpected diagnostic source change')
    require(shutil.disk_usage(runner).free >= 12 * 1024**3, 'Insufficient scratch for retained inputs')
    root = runner / 'rc130-intake-inputs'
    root.mkdir()
    try:
        intake(runner, root)
    except Exception as error:
        import traceback
        report = runner / 'analysis-report'
        report.mkdir(exist_ok=True)
        (report / 'collector-error.log').write_text(traceback.format_exc())
        raise SystemExit('Private intake stopped: ' + type(error).__name__) from None
