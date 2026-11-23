"""Restore the verified Build 141 test compiler output before normal runtime staging."""

import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import zipfile

from release_checkpoint import tree_digest
from release_test_repair import validate_product_archive
from retained_app_test_products import api, archive_bytes, checksum, command, download, require, verify_artifact, write


RUN = 45207102608
JOB = 137809948319
SOURCE = '72b24c400bca22d8627c4fe6d1d78e0e543efede'
ARTIFACT = 14838045127
DIGEST = '23181badf9d8921887ae740fffa019365f697ce5612a587ce5f94d96cc93a198'
MANIFEST = 'aac4fac375fa640eb7d6e34f2c7ac1e320bc5fb7c266b4c3276588726be7cd41'
NESTED = '66aa604646bc25f586e419f194d18a245078c5be587e6d917d18f69bde9a3714'
TREE = 'c87ed689a46a862dfe342fcf86e93ad9a5e5d08a0d4c4bf7a857558f9c652e6d'
CI_PATHS = {'.github/workflows/release.yml', 'scripts/release_checkpoint.py', 'scripts/release_test_repair.py',
            'scripts/release_compiler_restore.py', 'scripts/test_release_workflow.py', 'scripts/test_release_recovery.py'}


def origin_receipt(consumer_sha, consumer_run):
    return dict(sourceSHA=SOURCE, runID=RUN, jobID=JOB, attempt=1, artifactID=ARTIFACT, artifactSHA256=DIGEST,
                compilerTreeSHA256=TREE, consumerSHA=consumer_sha, consumerRunID=consumer_run)


def compiler_artifact():
    run = api(f'actions/runs/{RUN}/attempts/1')
    job = api(f'actions/jobs/{JOB}')
    require(run['id'] == RUN and run['run_attempt'] == 1 and run['head_sha'] == SOURCE
            and run['head_branch'] == 'iret77/rc-delivery-base-795' and run['actor']['login'] == 'iret77'
            and run['repository']['full_name'] == 'iret77/nexgenvideo' and run['path'] == '.github/workflows/release.yml'
            and run['event'] == 'workflow_dispatch' and run['conclusion'] == 'failure', 'Unexpected compiler producer')
    require(job['id'] == JOB and job['run_id'] == RUN and job['run_attempt'] == 1 and job['head_sha'] == SOURCE
            and job['name'] == 'release-build' and job['labels'] == ['macrunner'] and job['conclusion'] == 'failure',
            'Unexpected compiler job')
    stages = {step['name']: step['conclusion'] for step in job['steps']}
    for name in ('Build the exact release test configuration', 'Verify release build did not mutate tracked source',
                 'Checkpoint successful native compiler products before staging', 'Upload native compiler products before staging'):
        require(stages.get(name) == 'success', 'Incomplete compiler producer: ' + name)
    require(stages.get('Confirm compiler product upload before staging') == 'failure'
            and stages.get('Test the exact release configuration') == 'skipped', 'Original failure boundary differs')
    item = api(f'actions/artifacts/{ARTIFACT}')
    verify_artifact(item, run, job, ARTIFACT, DIGEST, f'release-test-compiler-products-{RUN}-a1')
    require(item['size_in_bytes'] == 452084489, 'Compiler artifact size differs')
    return item


def restore():
    env = os.environ
    require(sys.platform == 'darwin' and env['GITHUB_REPOSITORY'] == 'iret77/nexgenvideo'
            and env['GITHUB_JOB'] == 'release-build' and env['GITHUB_RUN_ATTEMPT'] == '1'
            and env['GITHUB_REF_NAME'] == 'iret77/rc-delivery-base-795' and env['BUILD_NUMBER'] == '141'
            and env['REL_VERSION'] == '1.8.0', 'Unexpected compiler consumer')
    inputs = json.loads(Path(env['GITHUB_EVENT_PATH']).read_bytes())['inputs']
    require(inputs.get('compiler_checkpoint_run_id') == str(RUN) and
            all(inputs.get(key) in (True, 'true') for key in ('internal_image_only', 'dry_run', 'artifact_only')),
            'Compiler recovery is restricted to the reviewed internal image')
    temporary = Path(env['RUNNER_TEMP']).resolve(strict=True)
    require(Path.cwd() == temporary.parent / 'nexgenvideo/nexgenvideo',
            'The checkout path embedded in the test products differs')
    head = command(['git', 'rev-parse', 'HEAD'])
    require(head == env['GITHUB_SHA'] and not command(['git', 'merge-base', '--is-ancestor', SOURCE, head])
            and set(command(['git', 'diff', '--name-only', '--no-renames', SOURCE, head]).splitlines()) <= CI_PATHS,
            'Compiler input sources changed')
    plist_path = 'Sources/NexGenVideo/Resources/Info.plist'
    original = plistlib.loads(subprocess.check_output(['git', 'show', SOURCE + ':' + plist_path]))
    require(original['CFBundleVersion'] == '140', 'Unexpected original build number')
    original.update(CFBundleVersion='141', CFBundleShortVersionString='1.8.0')
    require(plistlib.loads(Path(plist_path).read_bytes()) == original, 'Build 141 version settings differ')
    require(command(['xcodebuild', '-version']).splitlines() == ['Xcode 27.2', 'Build version 27B52']
            and command(['sw_vers', '-buildVersion']) == '26B123'
            and command(['swift', '--version']).splitlines() == [
                'Apple Swift version 6.4.2 (swiftlang-6.4.2.1.9 clang-2100.4.1.1)', 'Target: arm64-apple-macosx27.2.0'],
            'Compiler toolchain differs')
    records = temporary / 'release-test-product-checkpoints'
    plan = json.loads((records / 'plan-manifest.json').read_bytes())
    binary = temporary / 'release-tests/out/Products/Release'
    require(str(binary) == plan['binaryRoot'] == env['NGV_RELEASE_TEST_PRODUCTS_ROOT']
            and plan['sourceSHA'] == head and plan['runID'] == env['GITHUB_RUN_ID'] and plan['phase'] == 'plan'
            and binary.resolve() == binary and not binary.is_symlink()
            and (not binary.exists() or (binary.is_dir() and not any(binary.iterdir()))),
            'Compiler destination differs from the fresh plan or is occupied')
    item = compiler_artifact()
    with tempfile.TemporaryDirectory(dir=temporary) as directory:
        outer = Path(directory) / 'original.zip'
        nested = Path(directory) / 'compiler-products.zip'
        download(item, outer)
        with zipfile.ZipFile(outer) as archive:
            expected = {'plan-manifest.json', 'compiler-manifest.json', 'compiler-archive.json', 'compiler-products.zip'}
            require(sorted(archive.namelist()) == sorted(expected), 'Unexpected compiler artifact inventory')
            manifest_path = records / 'compiler-manifest.json'
            manifest_path.write_bytes(archive_bytes(archive, 'compiler-manifest.json'))
            require(checksum(manifest_path) == MANIFEST, 'Original compiler manifest differs')
            manifest = json.loads(manifest_path.read_bytes())
            saved = json.loads(archive_bytes(archive, 'compiler-archive.json'))
            require(saved['runID'] == str(RUN) and saved['sourceSHA'] == SOURCE and saved['phase'] == 'compiler'
                    and saved['attempt'] == '1' and saved['manifestSHA256'] == MANIFEST and saved['sha256'] == NESTED
                    and archive.getinfo(nested.name).file_size == saved['bytes'] == 456535119, 'Unexpected nested archive')
            require(manifest['sourceObjects'] == plan['sourceObjects'] and manifest['swiftcFlags'] == ['-enable-testing']
                    and manifest['treeSHA256'] == TREE and manifest['configuration'] == 'release'
                    and manifest['binaryRoot'] == str(binary), 'Compiler inputs differ from the consumer')
            with archive.open(nested.name) as src, nested.open('xb') as out:
                shutil.copyfileobj(src, out, 1024 * 1024)
        require(checksum(nested) == NESTED, 'Native compiler archive digest differs')
        validate_product_archive(nested)
        binary.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(['/usr/bin/ditto', '-x', '-k', str(nested), str(binary.parent)],
                       stdin=subprocess.DEVNULL, check=True, timeout=300)
    require(tree_digest(binary) == TREE, 'Restored compiler file bytes, modes or links differ')
    receipt = origin_receipt(head, int(env['GITHUB_RUN_ID']))
    write(records / 'compiler-upload.json', {'artifact': item, 'archive': saved, 'restored': receipt})
    write(records / 'compiler-origin.json', receipt)
    with Path(env['GITHUB_ENV']).open('a') as environment:
        environment.write('RELEASE_COMPILER_ORIGIN=' + str(records / 'compiler-origin.json') + '\n')
    print(f'Restored Build 141 test products from run {RUN}, artifact {ARTIFACT}, tree {TREE}')


if __name__ == '__main__':
    restore()
