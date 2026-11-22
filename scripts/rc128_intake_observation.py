"""Exercise the real track intake with the repaired dialog client and retained Build 128."""
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

PRODUCT = '28aeb663d3e7cfc2d75bf73ca3de7cd2c1081136'
NATIVE = 44964061205
ROLE = {
    'metadata': (14731478194, 'fc857311540a2f511b5d81ac278340a92b52fa861518327a82fd3c77bc8307f2', None),
    'production': (14731261598, '4aac51c60a8631bc69c41fa23e9c5091b0fa51fe378a65a98f344a0b6d807281', '93121511e7c5908d0ec7071e39fe6f1b91969dbb1f5c436ac240907f35ffba41'),
}


def fetch(role):
    identifier, digest, receipt = ROLE[role]
    selected = dict(runID=NATIVE, sourceSHA=PRODUCT, artifactID=identifier, artifactSHA256=digest)
    if receipt:
        selected['receiptSHA256'] = receipt
    return release.producer(selected, role)


def restore_image(root):
    role = 'production'
    origin = fetch('metadata')
    metadata = root.parent / 'rc128-native-metadata.zip'
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
    expected = 'da983f80f077e96dffbd13a0709dab11febb09490dbd0f3c37e1737a2fa8ac8f'
    require(image.is_relative_to(arena) and checksum(image) == expected, 'Native image differs')
    return image


def prepare_client(runner):
    build = runner / 'rc128-dialog-build'
    build.mkdir()
    compiled = build / 'build/Build/Products'
    dialogs.package(build, compiled, os.environ['GITHUB_SHA'])
    transfer = build / 'transfer'
    receipt = json.loads((transfer / 'client.json').read_bytes())
    archive = transfer / 'products.tar.gz'
    require(receipt['sha256'] == checksum(archive), 'Dialog transport checksum differs')
    work = runner / 'file-dialog-ui'
    products = work / 'build/Build/Products'
    dialogs.unpack_products(archive, products)
    dialogs.check_test_paths(products / receipt['xctestrun'], products)
    require(dialogs.products_sha256(products) == receipt['products'], 'Transported dialog client differs')
    shutil.copyfile(transfer / 'client.json', work / 'client.json')
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
    shutil.copy2(image, target)
    subprocess.run(['/usr/bin/install_name_tool','-add_rpath','@executable_path/../Frameworks',target], check=True, timeout=60)
    uuid = release.image_uuid(target, 2)
    require(uuid.upper() == 'D85F116C-AEED-3B7C-B286-43262A26F911', 'Production UUID differs')
    resources = Path('Sources/NexGenVideo/Resources')
    info = plistlib.loads((resources / 'Info.plist').read_bytes())
    info_path = app / 'Contents/Info.plist'
    prior = plistlib.loads(info_path.read_bytes())
    if 'SentryDSN' in prior:
        info['SentryDSN'] = prior['SentryDSN']
    info.update(NGVSourceCommit=PRODUCT, NGVBuildConfiguration='release', NGVBuildSDK='27.2',
                CFBundleShortVersionString='1.8.0', CFBundleVersion='128')
    info_path.write_bytes(plistlib.dumps(info))
    shutil.copyfile(resources / 'Changelog/changelog.json', app / 'Contents/Resources/Changelog/changelog.json')
    payload = release.signed_payload_sha(target, 2)
    (runner / 'rc128-intake-binding.json').write_text(json.dumps(
        dict(product=PRODUCT, nativeRun=NATIVE, clientTree=dialogs.project_tree(os.environ['GITHUB_SHA']), harness=os.environ['GITHUB_SHA'],
             run=os.environ['GITHUB_RUN_ID'], imageUUID=uuid, distributionPayload=payload)))
    verify_intake(app, pack, uuid, payload)


if __name__ == '__main__':
    runner = Path(os.environ['RUNNER_TEMP']).resolve(strict=True)
    require(os.environ.get('GITHUB_REPOSITORY') == 'iret77/nexgenvideo'
            and os.environ.get('GITHUB_RUN_ATTEMPT') == '1'
            and os.environ.get('GITHUB_JOB') == 'rc128-intake'
            and os.uname().machine == 'arm64'
            and subprocess.check_output(['sw_vers','-productVersion'],text=True).startswith('27.')
            and cohort.git('rev-parse','HEAD') == os.environ['GITHUB_SHA'], 'Requires the owned macOS 27 CI job')
    require(cohort.git('rev-parse', 'HEAD^') == PRODUCT, 'Unexpected product parent')
    changed = set(cohort.git('diff','--name-only',PRODUCT,'HEAD').splitlines())
    require(changed == {'.github/workflows/native-acceptance-probes.yml','scripts/rc128_intake_observation.py',
                        'scripts/file-dialog-ui/Tests/FileDialogTests.swift','scripts/file_dialog_products.py'},
            'Unexpected diagnostic source change')
    require(shutil.disk_usage(runner).free >= 12 * 1024**3, 'Insufficient scratch for retained inputs')
    root = runner / 'rc128-intake-inputs'
    root.mkdir()
    intake(runner, root)
