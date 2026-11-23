"""Verify ordinary scene edits and document shutdown on the private Build 141 disk image."""

import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import zipfile

from isolated_test_home import environment
from retained_app_test_products import api, archive_bytes, checksum, command, download, require, verify_artifact, write
from scene_history_hierarchy import scoped_files, scoped_success
import verified_pr_source_checks as source_checks

sys.path.insert(0, str(Path(__file__).resolve().parent / 'external-gui'))
from acceptance import metadata, tree_sha256


PRODUCT = '116e812d86f8886b7657daf005f955500fb05648'
PRODUCER = 45216062737
BRANCH = 'iret77/rc-141-signed-scene-history'
BASE = 'iret77/rc-delivery-base-795'
HARNESS_FILES = {'.github/workflows/diagnostic-acceptance.yml', 'scripts/signed_scene_history.py',
                 'scripts/test_signed_scene_history.py'}


def validate_dispatch(inputs):
    required = {'candidate_kind', 'run_id', 'source_sha', 'artifact_id', 'artifact_sha256',
                'expected_dmg_sha256', 'verified_pr_run_id'}
    neutral = {'interface_scale': '1', 'journey_scenario': 'journey'}
    require(required <= inputs.keys() and inputs['candidate_kind'] == 'signed-scene-history'
            and inputs['run_id'] == str(PRODUCER) and inputs['source_sha'] == PRODUCT
            and all(re.fullmatch('[1-9][0-9]*', inputs[k]) for k in ('artifact_id', 'verified_pr_run_id'))
            and all(re.fullmatch('[0-9a-f]{64}', inputs[k]) for k in ('artifact_sha256', 'expected_dmg_sha256'))
            and all(v == neutral.get(k, '') for k, v in inputs.items() if k not in required),
            'Unsupported selector or incomplete signed scene inputs')


def original_item(run, job, name):
    items = api(f"actions/runs/{run['id']}/artifacts?name={name}&per_page=100")
    require(items['total_count'] == len(items['artifacts']) == 1, 'Artifact missing or ambiguous: ' + name)
    item = api("actions/artifacts/" + str(items['artifacts'][0]['id']))
    verify_artifact(item, run, job, item['id'], item['digest'].removeprefix('sha256:'), name)
    return item


def bind_harness():
    head = os.environ['GITHUB_SHA']
    require(command(['git', 'rev-parse', 'HEAD']) == head and not command(['git', 'status', '--porcelain'])
            and not command(['git', 'merge-base', '--is-ancestor', PRODUCT, head])
            and set(command(['git', 'diff', '--no-renames', '--name-only', PRODUCT, head]).splitlines()) == HARNESS_FILES,
            'Unexpected scene harness checkout or product change')
    run_id = int(os.environ['HARNESS_PR_RUN'])
    run = api(f'actions/runs/{run_id}')
    job = source_checks.verify_run_identity(run, api(f'actions/runs/{run_id}/attempts/1/jobs?per_page=100'), run_id)
    require(run['head_sha'] == head and run['head_branch'] == BRANCH and job['labels'] == ['macrunner'],
            'Source checks belong to a different harness')
    item = original_item(run, job, f'verified-pr-source-{run_id}-a1')
    raw = source_checks.read_api(f"actions/artifacts/{item['id']}/zip", 100000)
    receipt = source_checks.original_receipt(item, raw, run)
    pr = api(f"pulls/{receipt['pullRequest']}")
    require(receipt['schema'] == 'verified-pr-source/v2' and receipt['headSHA'] == head
            and receipt['baseRef'] == BASE and pr['base']['ref'] == BASE and pr['base']['sha'] == PRODUCT
            and pr['head']['repo']['full_name'] == pr['base']['repo']['full_name'] == 'iret77/nexgenvideo'
            and pr['head']['sha'] == head and pr['head']['ref'] == BRANCH and pr['user']['login'] == 'iret77'
            and pr['state'] == 'open' and receipt['treeSHA'] == command(['git', 'rev-parse', 'HEAD^{tree}']),
            'Source check receipt differs from the current RC or harness')
    merge = api('git/commits/' + receipt['checkoutSHA'])
    require(merge['tree']['sha'] == receipt['treeSHA'] and [p['sha'] for p in merge['parents']] == [PRODUCT, head],
            'Tested source tree or parents differ')
    source_checks.verify_steps(job, receipt)
    summary = source_checks.test_completion(source_checks.read_api(f"actions/jobs/{job['id']}/logs"))
    return dict(head=head, tree=receipt['treeSHA'], sourceRun=run_id, sourceArtifact=item['id'], sourceResult=summary)


def acquire_image(root, expected):
    run = api(f'actions/runs/{PRODUCER}/attempts/1')
    require(run['id'] == PRODUCER and run['run_attempt'] == 1 and run['head_sha'] == PRODUCT
            and run['repository']['full_name'] == 'iret77/nexgenvideo' and run['actor']['login'] == 'iret77'
            and run['path'] == '.github/workflows/release.yml' and run['head_branch'] == BASE
            and run['event'] == 'workflow_dispatch' and run['status'] == 'completed', 'Unknown private image producer')
    inventory = api(f'actions/runs/{PRODUCER}/attempts/1/jobs?per_page=100')
    require(len(inventory['jobs']) == inventory['total_count'], 'Incomplete producer inventory')
    jobs = {j['name']: j for j in inventory['jobs']}
    for name in ('release-build', 'release', 'acceptance-pending'):
        j = jobs[name]
        require(j['labels'] == ['macrunner'] and j['run_id'] == PRODUCER and j['run_attempt'] == 1
                and j['head_sha'] == PRODUCT and j['conclusion'] == ('failure' if name == 'acceptance-pending' else 'success'),
                'Unexpected original producer job: ' + name)
    release = jobs['release']
    receipt_item = original_item(run, release, 'release-workspace-producer')
    require(0 < receipt_item['size_in_bytes'] <= 100000, 'Unexpected producer receipt size')
    receipt_zip = root / 'receipt.zip'
    download(receipt_item, receipt_zip)
    with zipfile.ZipFile(receipt_zip) as archive:
        mounted = json.loads(archive_bytes(archive, 'release-workspace-producer.json', 100000))
    require(mounted['schema'] == 'nexgenvideo/release-workspace-producer/1' and mounted['sourceSHA'] == PRODUCT
            and mounted['runID'] == str(PRODUCER) and mounted['runAttempt'] == '1' and mounted['dmgSHA256'] == expected
            and mounted['app']['CFBundleVersion'] == '141' and mounted['app']['CFBundleShortVersionString'] == '1.8.0',
            'The original mounted receipt differs')
    item = original_item(run, release, 'release-user-journey-input')
    require(item['id'] == int(os.environ['CANDIDATE_ARTIFACT']) and item['digest'] == 'sha256:' + os.environ['CANDIDATE_DIGEST']
            and 0 < item['size_in_bytes'] < 8 * 1024**3, 'Unexpected signed journey artifact')
    original = root / 'journey.zip'
    download(item, original)
    dmg = root / 'NexGenVideo.dmg'
    with zipfile.ZipFile(original) as archive:
        members = [x for x in archive.infolist() if x.filename == dmg.name]
        require(len(members) == 1 and 0 < members[0].file_size < 8 * 1024**3, 'Missing or ambiguous disk image')
        with archive.open(members[0]) as src, dmg.open('xb') as out:
            shutil.copyfileobj(src, out, 1024 * 1024)
    require(checksum(dmg) == expected, 'The actual inner image differs')
    return dmg, mounted, item


def execute_history(installed, root, evidence):
    executable = installed / 'Contents/MacOS/NexGenVideo'
    child = environment(os.environ, root / 'home')
    for key in list(child):
        if key.startswith(('NGV_', 'GITHUB_', 'ACTIONS_')) or key in ('GH_TOKEN', 'GIT_ASKPASS'):
            child.pop(key)
    native = evidence / 'scene'
    native.mkdir()
    child.update(NGV_SELFTEST_BPY=str(native), NGV_SELFTEST_BPY_SCOPE='scene-history')
    args = [str(executable), '-hangDiagnosticMode', 'disabled', '-agentBackend', 'anthropicAPI',
            '-de.h5ventures.nexgenvideo.mcp.enabled', 'NO']
    with (native / 'runtime.log').open('xb') as stdout, (native / 'runtime-stderr.log').open('xb') as stderr:
        process = subprocess.Popen(args, env=child, stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr)
        try:
            code = process.wait(timeout=300)
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
    require(code == 0, f'Scene history exited with {code}')
    write(native / 'process-result.json', dict(pid=process.pid, sourceSHA=PRODUCT, mode='runtime', returncode=code))
    return scoped_success(scoped_files(native), PRODUCT, process.pid)


def main():
    env = os.environ
    require(sys.platform == 'darwin' and platform.machine() == 'arm64' and command(['sw_vers', '-productVersion']).split('.')[0] == '27'
            and env['GITHUB_REPOSITORY'] == 'iret77/nexgenvideo' and env['GITHUB_ACTOR'] == 'iret77'
            and env['GITHUB_REF_NAME'] == BRANCH and env['GITHUB_RUN_ATTEMPT'] == '1'
            and env['GITHUB_JOB'] == 'signed-scene-history' and env['CANDIDATE_SOURCE'] == PRODUCT
            and env['CANDIDATE_RUN'] == str(PRODUCER), 'Unexpected scene-history job')
    validate_dispatch(json.loads(Path(env['GITHUB_EVENT_PATH']).read_bytes())['inputs'])
    harness = bind_harness()
    root = Path(env['RUNNER_TEMP']).resolve(strict=True) / 'signed-scene-history'
    evidence = root / 'evidence'
    evidence.mkdir(parents=True)
    expected = env['EXPECTED_DMG']
    dmg, original, item = acquire_image(root, expected)
    mount = root / 'volume'
    mount.mkdir()
    installed = Path('/Applications/NexGenVideo.app')
    require(not installed.exists() and not installed.is_symlink(), 'Installation destination is occupied')
    log = evidence / 'installation.log'
    def invoke(*args):
        with log.open('ab') as stream:
            subprocess.run(args, stdout=stream, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, check=True, timeout=180)
    invoke('hdiutil', 'verify', dmg)
    invoke('xcrun', 'stapler', 'validate', dmg)
    invoke('hdiutil', 'attach', dmg, '-readonly', '-nobrowse', '-mountpoint', mount)
    try:
        app = mount / installed.name
        pack = mount / 'musicvideo.ngvpack'
        require(metadata(app, PRODUCT) == original['app'] and original['app']['treeSHA256'] == original['mountedAppTreeSHA256']
                and tree_sha256(pack) == original['mountedPackTreeSHA256'] == original['packTreeSHA256'],
                'Mounted product differs from its independent producer receipt')
        invoke('ditto', app, installed)
    finally:
        invoke('hdiutil', 'detach', mount)
    require(metadata(installed, PRODUCT) == original['app']
            and command(['lipo','-archs', str(installed / 'Contents/MacOS/NexGenVideo')]) == 'arm64', 'Installed app changed')
    invoke('codesign', '--verify', '--deep', '--strict', installed)
    invoke('xcrun', 'stapler', 'validate', installed)
    proof = dict(harness=harness, producer=PRODUCER, product=PRODUCT, artifact=item['id'], artifactDigest=item['digest'],
                 innerSHA256=expected, app=original['app'], packTreeSHA256=original['packTreeSHA256'],
                 macOS=command(['sw_vers', '-productVersion']), architecture=platform.machine())
    write(evidence / 'input.json', proof)
    outcome = execute_history(installed, root, evidence)
    require(outcome['appScopePassed'] is True and checksum(dmg) == expected and metadata(installed, PRODUCT) == original['app'],
            'Scene history did not finish on the original product')
    write(evidence / 'verified.json', dict(input=proof, history=outcome))


if __name__ == '__main__':
    main()
