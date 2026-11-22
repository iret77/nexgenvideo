"""Run the two open diagnostic cases against the qualified Build 128 binaries."""
import argparse
import hashlib
import io
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
import release_test_repair as bank
import signed_component_carrier
from file_dialog_presign import verify_intake
from retained_app_test_products import api, archive_bytes, checksum, download, require, verify_artifact

PRODUCT = '28aeb663d3e7cfc2d75bf73ca3de7cd2c1081136'
NATIVE = 44964061205
RUNTIME = 44967074564
CLIENT = 14730984768
ROLE = {
    'metadata': (14731478194, 'fc857311540a2f511b5d81ac278340a92b52fa861518327a82fd3c77bc8307f2', None),
    'production': (14731261598, '4aac51c60a8631bc69c41fa23e9c5091b0fa51fe378a65a98f344a0b6d807281', '93121511e7c5908d0ec7071e39fe6f1b91969dbb1f5c436ac240907f35ffba41'),
    'tests': (14731895904, '26de61f42aabc551d46ba44a8326bd9f7b47b080606a35c6cfcdb73faa01e6e6', '3d0a3af1226936b2b4da35c753c1a8cb58c610d8f7856b75a8e3e49d298cadf2'),
}


def fetch(role):
    identifier, digest, receipt = ROLE[role]
    selected = dict(runID=NATIVE, sourceSHA=PRODUCT, artifactID=identifier, artifactSHA256=digest)
    if receipt:
        selected['receiptSHA256'] = receipt
    return release.producer(selected, role)


def restore_image(root, role):
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
    require(arena == runner / 'app-build-plan-evidence' / ('production' if role == 'production' else 'testable') / 'derived-data'
            and not arena.exists(), 'Unexpected compiler arena')
    producer = fetch(role)
    restored = targets.restore_product(root, role, prepared, producer)
    require(checksum(Path(restored['folder']) / 'original.zip') == ROLE[role][1], 'Native archive digest differs')
    release.verify_product(restored['receipt'], producer['selected'], role, prepared)
    link, = [item for item in plan['operations']['links'] if item['targetGUID'] == plan['driver']['targetGUID']]
    image = Path(link['output'])
    expected = {'production':'da983f80f077e96dffbd13a0709dab11febb09490dbd0f3c37e1737a2fa8ac8f',
                'tests':'9c276833f894d5755d08b447c7db62842be2fda75b9dc50a771d1c264c4eb27b'}
    require(image.is_relative_to(arena) and checksum(image) == expected[role], 'Native image differs')
    return image


def restore_client(runner):
    job = api('actions/jobs/137038549447')
    run = api(f'actions/runs/{RUNTIME}')
    item = api(f'actions/artifacts/{CLIENT}')
    require(run['path'] == '.github/workflows/release.yml' and run['head_sha'] == PRODUCT
            and run['run_attempt'] == job['run_attempt'] == 1 and job['run_id'] == RUNTIME
            and job['name'] == 'release-build' and job['labels'] == ['macrunner']
            and any(s['name'] == 'Build file dialog XCTest' and s['conclusion'] == 'success' for s in job['steps']),
            'Original dialog client producer differs')
    verify_artifact(item, run, job, CLIENT, '5ac2e69918c24ec2c58403c98166e3cf4c35e21471f1863d6e750a7a5ba0433e', 'file-dialog-ui')
    work = runner / 'file-dialog-ui'
    work.mkdir()
    with zipfile.ZipFile(io.BytesIO(dialogs.artifact_bytes(item, 117785))) as outer:
        receipt = json.loads(archive_bytes(outer, 'client.json', 16384))
        raw = archive_bytes(outer, 'products.tar.gz', 1024**2)
    require(receipt['source'] == PRODUCT and receipt['run'] == RUNTIME and receipt['attempt'] == 1
            and receipt['tree'] == dialogs.project_tree(PRODUCT) == dialogs.project_tree(os.environ['GITHUB_SHA'])
            and hashlib.sha256(raw).hexdigest() == receipt['sha256'], 'Original test client receipt differs')
    products = work / 'build/Build/Products'
    archive = work / 'products.tar.gz'
    archive.write_bytes(raw)
    dialogs.unpack_products(archive, products)
    sidecar = products / '._Debug'
    require(sidecar.is_file() and not sidecar.is_symlink() and sidecar.stat().st_size == 172
            and checksum(sidecar) == '4798dcd53450d1b8bd450cf6e57b913e12a90a3baf6a63c051c5153c68cc3c1e',
            'Original AppleDouble transport member differs')
    sidecar.rename(work / 'original-appledouble')
    dialogs.check_test_paths(products / receipt['xctestrun'], products)
    require(dialogs.products_sha256(products) == receipt['products'], 'Restored test client differs from the compiled tree')
    (work / 'client.json').write_text(json.dumps(dict(receipt, artifactID=CLIENT, artifactDigest=item['digest'])))
    os.environ['NGV_FILE_DIALOG_PRODUCTS'] = str(products)


def intake(runner, root):
    restore_client(runner)
    image = restore_image(root, 'production')
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
        dict(product=PRODUCT, nativeRun=NATIVE, client=CLIENT, harness=os.environ['GITHUB_SHA'],
             run=os.environ['GITHUB_RUN_ID'], imageUUID=uuid, distributionPayload=payload)))
    verify_intake(app, pack, uuid, payload)


def camera(runner, root):
    image = restore_image(root, 'tests')
    require(release.image_uuid(image, 8).upper() == '2E474577-CBFA-3970-885A-BD6195B7DC83', 'Test UUID differs')
    bundle = image.parents[2]
    subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict',bundle], check=True, timeout=90)
    identifier, digest = bank.ARTIFACTS['runtime'][:2]
    item = api(f'actions/artifacts/{identifier}')
    require(item['digest'] == 'sha256:' + digest and not item['expired'], 'Runtime bank differs')
    archive = root / 'runtime.zip'
    download(item, archive)
    require(checksum(archive) == digest, 'Runtime bank bytes differ')
    with zipfile.ZipFile(archive) as z:
        raw = archive_bytes(z,'runtime-manifest.json',4 * 1024**2)
    (root / 'bank-runtime-manifest.json').write_bytes(raw)
    run = lambda args, label, timeout=180: targets.logged(root, label, args, timeout=timeout)
    binary = bank.restore_runtime(root, json.loads(raw), run, reuse_crc=True)
    runtime = root / 'runtime'
    def ignored(directory, names):
        if Path(directory) == binary:
            return {'NexGenVideo', 'NexGenVideo.swiftmodule', 'NexGenVideoTests.swiftmodule',
                    'NexGenVideoTests.xctest', 'NexGenVideoTests.xctest.dSYM', 'NexGenVideo.dSYM'}.intersection(names)
        if Path(directory) == binary / 'ExecutableModules':
            return {Path(bank.APP_OBJECT).name}.intersection(names)
        return set()
    shutil.copytree(binary, runtime, symlinks=True, ignore=ignored, copy_function=os.link)
    subprocess.run(['python3','scripts/rc128_tab_observation.py','--tests',bundle,'--runtime',runtime,
                    '--output',runner / 'rc128-tab'], stdin=subprocess.DEVNULL, check=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('case', choices=('intake','camera'))
    case = parser.parse_args().case
    runner = Path(os.environ['RUNNER_TEMP']).resolve(strict=True)
    require(os.environ.get('GITHUB_REPOSITORY') == 'iret77/nexgenvideo' and os.environ.get('GITHUB_RUN_ATTEMPT') == '1'
            and os.environ.get('GITHUB_JOB') == 'rc128-observation' and os.uname().machine == 'arm64'
            and subprocess.check_output(['sw_vers','-productVersion'],text=True).startswith('27.')
            and cohort.git('rev-parse','HEAD') == os.environ['GITHUB_SHA'], 'Requires the exact owned diagnostic VM')
    subprocess.run(['git','merge-base','--is-ancestor',PRODUCT,'HEAD'], check=True, timeout=10)
    changed = set(cohort.git('diff','--name-only',PRODUCT,'HEAD').splitlines())
    require(changed <= {'.github/workflows/native-acceptance-probes.yml','scripts/rc128_native_observation.py',
                        'scripts/rc128_tab_observation.py','scripts/rc128_tab_observation.m'}, 'Product or fixture source changed')
    require(shutil.disk_usage(runner).free >= 18 * 1024**3, 'Insufficient scratch for retained inputs')
    root = runner / ('rc128-' + case + '-inputs')
    root.mkdir()
    (intake if case == 'intake' else camera)(runner, root)
