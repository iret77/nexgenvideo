"""Exercise the actual native track assignment on the linked app before Developer ID signing."""
from contextlib import ExitStack
import json
import math
import os
from pathlib import Path
import plistlib
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import wave

from file_dialog_ui import session, start, wait_for_native
from isolated_test_home import environment
from retained_app_test_products import checksum, require


def intake_binding(app, pack, image_uuid, payload, native=False):
    import file_dialog_products as dialogs
    from compiled_app_release import canonical_bundle_tree
    from release_checkpoint import tree_digest
    runner = Path(os.environ['RUNNER_TEMP'])
    source = os.environ['GITHUB_SHA']
    products = Path(os.environ['NGV_FILE_DIALOG_PRODUCTS']).resolve(strict=True)
    work = runner / 'file-dialog-ui'
    if native:
        require(os.environ.get('GITHUB_JOB') == 'app-target-build', 'Unexpected native Track consumer')
        if (work / 'client.json').is_file():
            client = json.loads((work / 'client.json').read_bytes())
            require(client == dialogs.QUALIFIED_CLIENT,
                    'Restored original client does not match the qualified native Track consumer')
            origin_run = dialogs.QUALIFIED_CLIENT['run']
        else:
            client = json.loads((work / 'transfer/client.json').read_bytes())
            artifact_id = int(os.environ['DIALOG_CLIENT_ARTIFACT_ID'])
            digest = os.environ['DIALOG_CLIENT_ARTIFACT_SHA256'].removeprefix('sha256:')
            require(artifact_id > 0 and re.fullmatch('[a-f0-9]{64}', digest), 'Missing native file dialog artifact')
            client.update(artifactID=artifact_id, artifactDigest='sha256:' + digest)
            with (work / 'client.json').open('x') as out:
                json.dump(client, out)
            origin_run = int(os.environ['GITHUB_RUN_ID'])
    elif (work / 'transfer/native-client-origin.json').is_file():
        origin = json.loads((work / 'transfer/native-client-origin.json').read_bytes())
        client = json.loads((work / 'client.json').read_bytes())
        require(origin['releaseRun'] == int(os.environ['GITHUB_RUN_ID']) and origin['client'] == client
                and origin['metadata']['sourceSHA'] == source, 'Release file dialog origin changed')
        origin_run = dialogs.QUALIFIED_CLIENT['run'] if client == dialogs.QUALIFIED_CLIENT else origin['metadata']['runID']
    else:
        client = json.loads((work / 'transfer/client.json').read_bytes())
        origin_run = int(os.environ['GITHUB_RUN_ID'])
    require(products == (work / 'build/Build/Products').resolve(strict=True)
            and dialogs.bound_client_source(client, source) and client['run'] == origin_run
            and client['attempt'] == int(os.environ['GITHUB_RUN_ATTEMPT'])
            and client['tree'] == dialogs.project_tree(source) and client['products'] == dialogs.products_sha256(products),
            'Early intake and release require the same actual file dialog XCTest')
    return dict(source=source, runID=os.environ['GITHUB_RUN_ID'], attempt=client['attempt'], client=client,
                imageUUID=image_uuid, mainPayloadSHA256=payload, appTreeSHA256=tree_digest(app),
                packTreeSHA256=canonical_bundle_tree(pack))


def observed_intake(evidence, pid):
    report = evidence / 'dialogs-musicvideo-intake'
    track = evidence / 'Track.wav'
    proof = json.loads((evidence / 'hostflow-track-lyrics-result.json').read_bytes())
    rows = [r for r in proof['interactions'] if r.get('kind') == 'file-panel']
    require(len(rows) == 1 and rows[0].get('dialogTestStep') == 2 and rows[0].get('path') == track.name
            and rows[0].get('selectedURLVerified') is True and rows[0].get('nativePathEditorVerified') is True
            and (report / 'dialog-test-steps').read_text() == '2'
            and (evidence / 'intake-track-assigned.bin').read_bytes() == track.read_bytes(),
            'The independent input and actual track assignment differ')
    for index, action in enumerate(('save', 'open'), 1):
        row = json.loads((report / f'file-panel-{index}-input.json').read_bytes())
        require((row['step'], row['action'], row['pid']) == (index, action, pid)
                and row['pathField'] == 'PathTextField' and (report / f'file-panel-{index}-observed').is_file(),
                'Missing original native dialog interaction')
    return dict(trackSHA256=checksum(track), hostReportSHA256=checksum(evidence / 'hostflow-track-lyrics-result.json'),
                dialogReceipts=[checksum(report / f'file-panel-{index}-input.json') for index in (1, 2)])


def verify_intake(app, pack, image_uuid, payload, *, early=False, native=False):
    from compiled_app_release import image_uuid as uuid_of, signed_payload_sha
    runner = Path(os.environ['RUNNER_TEMP']).resolve(strict=True)
    work = runner / 'app-target-build/track-intake' if native else runner / 'file-dialog-intake'
    evidence = work / 'evidence'
    receipt = evidence / 'verified.json'
    require(not native or early, 'Native Track evidence is limited to the early check')
    binding = intake_binding(app, pack, image_uuid, payload, native=native)
    build = plistlib.loads((app / 'Contents/Info.plist').read_bytes())['CFBundleVersion']
    if not early and int(build) >= 129:
        require(receipt.is_file(), 'Missing early Track acceptance before signing')
        previous = json.loads(receipt.read_bytes())
        require(previous['binding'] == binding and previous['nativeExit'] == previous['testExit'] == 0
                and previous['observed'] == observed_intake(evidence, previous['appPID']),
                'Pre-sign app, pack, client or actual dialog evidence differs from the early intake')
        return
    work.mkdir()
    evidence.mkdir()
    track = evidence / 'Track.wav'
    with wave.open(str(track), 'wb') as wav:
        wav.setparams((1, 2, 16000, 0, 'NONE', 'not compressed'))
        wav.writeframes(b''.join(struct.pack('<h', round(8000 * math.sin(2 * math.pi * 440 * t / 16000))) for t in range(32000)))
    with tempfile.TemporaryDirectory(dir=work) as temp:
        clone = Path(temp) / 'NexGenVideo.app'
        executable = clone / 'Contents/MacOS/NexGenVideo'
        require(shutil.disk_usage(work).free > 512 * 1024**2, 'Insufficient scratch for the APFS clone and native evidence')
        subprocess.run(['/bin/cp', '-cR', app, clone], stdin=subprocess.DEVNULL, check=True, timeout=120)
        subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', clone], stdin=subprocess.DEVNULL, check=True, timeout=90)
        require(uuid_of(executable, 2) == image_uuid and signed_payload_sha(executable, 2) == payload,
                'The test signature did not preserve the linked app payload')
        normal_error = None
        try:
            parent = {k: os.environ[k] for k in ('PATH', 'TMPDIR', 'LANG', 'LC_ALL', 'DISPLAY') if k in os.environ}
            env = environment(parent, Path(temp) / 'home')
            env.update(NGV_WORKSPACE_UI_ACCEPTANCE='1', NGV_WORKSPACE_UI_CASE='musicvideo-intake', NGV_WORKSPACE_UI_SCALE='1.0',
                       NGV_WORKSPACE_UI_EVIDENCE=str(evidence), NGV_WORKSPACE_UI_PACK=str(pack.resolve(strict=True)))
            with ExitStack() as stack:
                client = stack.enter_context(session(clone, env, evidence, 'musicvideo-intake', scale=100))
                require(client is not None, 'The reviewed file dialog XCTest is missing')
                log = stack.enter_context((evidence / 'native.log').open('xb'))
                process = start(stack, [executable, '-ApplePersistenceIgnoreState', 'YES', '-AppleLanguages', '(en)', '-AppleLocale', 'en_US'],
                                env=env, log=log)
                require(wait_for_native(process, client, 180) == 0, 'The actual native track intake failed')
            observed = observed_intake(evidence, process.pid)
            with receipt.open('x') as out:
                json.dump(dict(binding=binding, observed=observed, source=binding['source'], runID=binding['runID'],
                               imageUUID=image_uuid, mainPayloadSHA256=payload, trackSHA256=observed['trackSHA256'],
                               appPID=process.pid, testExit=client.process.returncode, nativeExit=process.returncode), out)
        except Exception as error:
            if not native:
                raise
            normal_error = error
        if native:
            from private_audio_ui import verify_native_intake
            try:
                verify_native_intake(clone, pack, runner, binding)
            except Exception as private_error:
                if normal_error is not None:
                    raise ExceptionGroup('Both native intakes failed', [normal_error, private_error]) from None
                raise
        if normal_error is not None:
            raise normal_error


def early_intake(root):
    import app_cohort_v2 as cohort
    import compiled_app_release as release
    runner = release.native_guard(root)
    bound = json.loads((root / 'bound.json').read_bytes())
    context = bound['prepared'].get('cohortV2')
    if not context:
        return
    value = cohort.verify_context(context)
    if int(value['build']) < 129:
        return
    require(bound['sourceSHA'] == os.environ['GITHUB_SHA'] == cohort.git('rev-parse', 'HEAD')
            and bound['runID'] == int(os.environ['GITHUB_RUN_ID']) and bound['appSourceSHA'] == value['appSourceSHA'],
            'Intake compiler outputs belong to a different candidate')
    stage_intake(root, runner, value, bound, native=False)


def native_intake(root):
    import app_cohort_v2 as cohort
    import native_app_target_build as targets
    runner = targets.native_guard(root)
    prepared = json.loads((root / 'prepared.json').read_bytes())
    value = cohort.verify_context(prepared['cohortV2'], current=True)
    require(int(value['build']) >= 131 and prepared['sourceSHA'] == os.environ['GITHUB_SHA'],
            'Native Track intake requires the current candidate')
    receipt = json.loads((root / 'production/product-receipt.json').read_bytes())
    plan = prepared['plans']['production']
    link, = [row for row in plan['operations']['links'] if row['targetGUID'] == plan['driver']['targetGUID']]
    image = Path(link['output'])
    require(receipt['phase'] == 'production' and receipt['sourceSHA'] == prepared['sourceSHA']
            and receipt['runID'] == int(os.environ['GITHUB_RUN_ID']) and receipt['attempt'] == 1
            and receipt['cohortV2'] == prepared['cohortV2'] and receipt['recipePlan']['production'] == plan
            and receipt['state']['linkComplete'] and receipt['state']['compileComplete']
            and receipt['state']['linkedOutput'] == str(image)
            and receipt['files'][image.relative_to(plan['operations']['arena']).as_posix()]['sha256'] == checksum(image),
            'Native Track intake lost the current production linker output')
    bound = dict(sourceSHA=prepared['sourceSHA'], runtime=prepared['bankBinary'],
                 products={'production': {'output': str(image), 'receipt': receipt}})
    carrier_root = runner / 'native-intake-carrier'
    carrier_root.mkdir()
    stage_intake(carrier_root, runner, value, bound, native=True)


def stage_intake(root, runner, value, bound, *, native):
    import app_release_v2
    import compiled_app_release as release
    import release_checkpoint as checkpoint
    import signed_component_carrier as carrier
    require(shutil.disk_usage(runner).free >= 12 * 1024**3, 'Insufficient scratch for retained inputs and native intake')
    main = app_release_v2.main_product(bound)
    original, manifest = carrier.acquire(root, value)
    with tempfile.TemporaryDirectory(prefix='early-track-', dir=runner) as temp:
        stage = Path(temp)
        app = stage / 'NexGenVideo.app'
        checkpoint.validate_app_zip(original / 'NexGenVideo.zip')
        subprocess.run(['/usr/bin/ditto', '-x', '-k', original / 'NexGenVideo.zip', stage], check=True, timeout=240)
        require(checkpoint.tree_digest(app) == manifest['appTreeSHA256'], 'Restored signed app differs')
        carrier.verify_components(app_release_v2.unchanged_components(app), value)
        checkpoint.extract_tar(original / 'plugins.tar.gz', stage, {'plugins'})
        plugins = stage / 'plugins'
        archive = plugins / 'musicvideo.ngvpack.zip'
        pack = plugins / 'musicvideo.ngvpack'
        require(checksum(archive) == value['signedBase']['packArchiveSHA256'], 'Retained pack archive differs')
        if not pack.exists():
            subprocess.run(['/usr/bin/ditto', '-x', '-k', archive, plugins], check=True, timeout=120)
        require(release.canonical_bundle_tree(pack) == value['signedBase']['packTreeSHA256'], 'Retained pack tree differs')
        subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', pack], check=True, timeout=90)
        image = app / 'Contents/MacOS/NexGenVideo'
        image.unlink()
        shutil.copyfile(bound['products']['production']['output'], image)
        image.chmod(0o755)
        subprocess.run(['/usr/bin/install_name_tool', '-add_rpath', '@executable_path/../Frameworks', image], check=True, timeout=60)
        require(release.image_uuid(image, 2) == main['uuid'], 'Distribution rpath changed Main identity')
        resources = Path('Sources/NexGenVideo/Resources')
        info_path = app / 'Contents/Info.plist'
        old = plistlib.loads(info_path.read_bytes())
        info = plistlib.loads((resources / 'Info.plist').read_bytes())
        if 'SentryDSN' in old:
            info['SentryDSN'] = old['SentryDSN']
        info.update(NGVSourceCommit=bound['sourceSHA'], NGVBuildConfiguration='release', NGVBuildSDK='27.2',
                    CFBundleShortVersionString=value['version'], CFBundleVersion=value['build'])
        info_path.write_bytes(plistlib.dumps(info))
        shutil.copyfile(resources / 'Changelog/changelog.json', app / 'Contents/Resources/Changelog/changelog.json')
        verify_intake(app, pack, main['uuid'], release.signed_payload_sha(image, 2), early=True, native=native)


if __name__ == '__main__':
    root = Path(sys.argv[1])
    if sys.argv[2:] == ['native-intake']:
        native_intake(root)
    elif len(sys.argv) == 2:
        early_intake(root)
    else:
        raise SystemExit('Unexpected intake mode')
