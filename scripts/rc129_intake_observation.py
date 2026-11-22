"""Exercise the real track intake with the retained Build 129 and its original dialog XCTest."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import zipfile

import app_cohort_v2 as cohort
import app_release_v2
import compiled_app_release as release
import file_dialog_products as dialogs
import native_app_target_build as targets
import release_checkpoint
import signed_component_carrier
from file_dialog_presign import verify_intake
from retained_app_test_products import archive_bytes, checksum, download, require

PRODUCT = 'cfc88ca595c9ed79c39465157e9113d2fdc225b7'
NATIVE = 44973099142
CLIENT_RUN = 44975626999
CLIENT_JOB = 137064920508
CLIENT_ID = 14735337799
CLIENT_DIGEST = 'c53eddcec59eb9b686b9393ff9fa1e7ef8bcafa0b996b8846e953e86756e1ddf'
ROLE = {'metadata': (14734829327, 'f6b5c0facf1778e58549685cc2815dadb6e7161779e3e09c41f58b3dcf405f42', None), 'production': (14734879221, 'cd6b4c3576f2a8572ec967d6724172739dd0d551179c34a0cadc041e760c88bc', 'd15b339a059731aaa3302b47110f141a802974892044515327ccc3b67d438380')}


def fetch(role):
    identifier, digest, receipt = ROLE[role]
    selected = dict(runID=NATIVE, sourceSHA=PRODUCT, artifactID=identifier, artifactSHA256=digest)
    if receipt:
        selected['receiptSHA256'] = receipt
    return release.producer(selected, role)


def restore_image(root):
    role = 'production'
    origin = fetch('metadata')
    metadata = root.parent / 'rc129-native-metadata.zip'
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
    expected = '3101fe7a9881fe827d3c9f900af0341a417c628dae89693ca07e6940a55da550'
    require(image.is_relative_to(arena) and checksum(image) == expected, 'Native image differs')
    return image


def prepare_client(runner):
    from retained_app_test_products import api, verify_artifact
    run = api(f'actions/runs/{CLIENT_RUN}')
    job = api(f'actions/jobs/{CLIENT_JOB}')
    item = api(f'actions/artifacts/{CLIENT_ID}')
    require(run['head_sha'] == PRODUCT and run['workflow_id'] == 303346287 and run['run_attempt'] == 1
            and run['actor']['login'] == 'iret77' and run['conclusion'] == 'failure'
            and job['run_id'] == CLIENT_RUN and job['run_attempt'] == 1 and job['head_sha'] == PRODUCT
            and job['labels'] == ['macrunner'] and job['name'] == 'release-build'
            and [s['conclusion'] for s in job['steps'] if s['name'] == 'Build file dialog XCTest'] == ['success'],
            'Wrong original file dialog client producer')
    verify_artifact(item, run, job, CLIENT_ID, CLIENT_DIGEST, 'file-dialog-ui')
    work = runner / 'file-dialog-ui'
    transfer = work / 'transfer'
    transfer.mkdir(parents=True)
    require(item['size_in_bytes'] == 123738, 'Unexpected original UI XCTest carrier size')
    original = work / 'original.zip'
    download(item, original)
    with zipfile.ZipFile(original) as outer:
        require(outer.namelist() == ['client.json', 'products.tar.gz'], 'Unexpected UI client members')
        for name, limit in (('client.json', 16384), ('products.tar.gz', 1024 ** 2)):
            (transfer / name).write_bytes(archive_bytes(outer, name, limit))
    receipt = json.loads((transfer / 'client.json').read_bytes())
    archive = transfer / 'products.tar.gz'
    require(receipt['source'] == PRODUCT and receipt['run'] == CLIENT_RUN and receipt['attempt'] == 1
            and receipt['tree'] == dialogs.project_tree(PRODUCT) == dialogs.project_tree(os.environ['GITHUB_SHA'])
            and receipt['sha256'] == checksum(archive), 'Prior UI XCTest source or bytes differ')
    products = work / 'build/Build/Products'
    dialogs.unpack_products(archive, products)
    dialogs.check_test_paths(products / receipt['xctestrun'], products)
    require(dialogs.products_sha256(products) == receipt['products'], 'Transported original XCTest differs')
    os.environ['NGV_FILE_DIALOG_PRODUCTS'] = str(products)


def intake(runner, root):
    prepare_client(runner)
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
    require(uuid.upper() == 'E72B7800-9E50-3CBA-B6D5-5DFF33AB0B82', 'Production UUID differs')
    resources = Path('Sources/NexGenVideo/Resources')
    info = plistlib.loads((resources / 'Info.plist').read_bytes())
    info_path = app / 'Contents/Info.plist'
    prior = plistlib.loads(info_path.read_bytes())
    if 'SentryDSN' in prior:
        info['SentryDSN'] = prior['SentryDSN']
    info.update(NGVSourceCommit=PRODUCT, NGVBuildConfiguration='release', NGVBuildSDK='27.2',
                CFBundleShortVersionString='1.8.0', CFBundleVersion='129')
    info_path.write_bytes(plistlib.dumps(info))
    shutil.copyfile(resources / 'Changelog/changelog.json', app / 'Contents/Resources/Changelog/changelog.json')
    payload = release.signed_payload_sha(target, 2)
    (runner / 'rc129-intake-binding.json').write_text(json.dumps(
        dict(product=PRODUCT, nativeRun=NATIVE, clientTree=dialogs.project_tree(os.environ['GITHUB_SHA']), harness=os.environ['GITHUB_SHA'],
             run=os.environ['GITHUB_RUN_ID'], imageUUID=uuid, distributionPayload=payload)))
    verify_intake(app, pack, uuid, payload, early=True, client_producer=(PRODUCT, CLIENT_RUN, 1),
                  window_arguments=('-NSAutomaticWindowAnimationsEnabled', '0'))


if __name__ == '__main__':
    runner = Path(os.environ['RUNNER_TEMP']).resolve(strict=True)
    require(os.environ.get('GITHUB_REPOSITORY') == 'iret77/nexgenvideo'
            and os.environ.get('GITHUB_RUN_ATTEMPT') == '1'
            and os.environ.get('GITHUB_JOB') == 'rc129-intake'
            and os.uname().machine == 'arm64'
            and subprocess.check_output(['sw_vers','-productVersion'],text=True).startswith('27.')
            and cohort.git('rev-parse','HEAD') == os.environ['GITHUB_SHA'], 'Requires the owned macOS 27 CI job')
    require(cohort.git('rev-parse', 'HEAD^') == PRODUCT, 'Unexpected product parent')
    changed = set(cohort.git('diff','--name-only',PRODUCT,'HEAD').splitlines())
    require(changed == {'.github/workflows/native-acceptance-probes.yml','scripts/rc129_intake_observation.py',
                        'scripts/file_dialog_presign.py'},
            'Unexpected diagnostic source change')
    require(shutil.disk_usage(runner).free >= 12 * 1024**3, 'Insufficient scratch for retained inputs')
    root = runner / 'rc129-intake-inputs'
    root.mkdir()
    intake(runner, root)
