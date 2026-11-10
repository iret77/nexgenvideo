import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

import native_app_build_plan as capture

APP_SOURCE = '87b9a04860428b625fdf09ee8edda4c402a45bc5'
APP_TREE = 'aa4eef3cbbe42d87be2b77e8ec8b77d7b43212f6'
TEMPLATE_SOURCE = 'a8175982c9f2c589beffe5813e0932996f903598'
TEMPLATE_SELECTED = {'appSourceSHA': TEMPLATE_SOURCE, 'runID': 42537057754,
    'sourceSHA': '34db32c65c9e58288a5161c57ba494ab8395b9be', 'artifactID': 13640385689,
    'artifactSHA256': '3148fd37c31e6c9242fea9d0f112ec5f39a359e3fb3f400c9cd377d56e83175f',
    'resumeArtifactID': 13645702215, 'resumeArtifactSHA256': '788177c686b1d5a8885befeae084bec447d910748e722bf7c8e12cfb56a70fb5',
    'verifiedPRRunID': 42554665357}
TEMPLATE_METADATA = (13647433566, 'b6f5e0ef652fd5996760ce5f59f19239760563216d2504ff6ee056fa4dee74a9')
UI_CI_PATHS = {'.github/workflows/external-gui-acceptance.yml',
    'scripts/external-gui/NexGenVideoExternalUITests/UserJourneyTests.swift',
    'scripts/external-gui/acceptance.py', 'scripts/test_external_gui_test_bundle.py'}
CI_PATHS = {'scripts/native_current_cohort.py', 'scripts/test_native_current_cohort.py',
    'scripts/compiled_core_reuse.py', 'scripts/test_compiled_core_reuse.py', 'scripts/fixtures/compiled-core-reuse-886.json',
    'scripts/native_xctest_host.m', 'scripts/native_xctest_host.py', 'scripts/test_native_xctest_host.py',
    'scripts/compiled_app_release.py', 'scripts/test_compiled_app_release.py', 'scripts/release_checkpoint.py',
    'scripts/test_release_recovery.py', 'scripts/test_compiled_xctest_reuse.py', 'scripts/retained_packaging.py', 'scripts/test_retained_packaging.py',
    'scripts/fixtures/compiled-app-native-inventory.json'} | UI_CI_PATHS


def objects(ref):
    return {name: capture.git('rev-parse', ref + ':' + name) for name in capture.INPUT_OBJECTS}


def source_paths(ref):
    return sorted(name for name in capture.git('ls-tree', '-r', '--name-only', ref, '--',
        'Sources/NexGenVideo', 'Tests/NexGenVideoTests').splitlines() if name.endswith('.swift'))


def buildshape(head):
    previous, current = source_paths(TEMPLATE_SOURCE), source_paths(head)
    capture.require(previous == current and len(current) == 1395, 'Template source-file inventory changed')
    old_objects, new_objects = objects(TEMPLATE_SOURCE), objects(head)
    capture.require(all(old_objects[name] == new_objects[name] for name in capture.INPUT_OBJECTS
        if name not in {'Sources', 'Tests'}), 'Template dependency graph changed')
    manifest = 'Sources/NexGenVideo/Resources/AppResources.txt'
    capture.require(capture.git('rev-parse', TEMPLATE_SOURCE + ':' + manifest)
        == capture.git('rev-parse', head + ':' + manifest), 'Template resource inventory changed')
    for name, digest in capture.MANIFEST_HASHES.items():
        capture.require(capture.sha(Path(name)) == digest, 'Template manifest changed: ' + name)
    def imports(ref):
        values = set()
        for name in previous:
            raw = capture.command(['git', 'show', ref + ':' + name]).decode()
            values.update(re.findall(r'^\s*(?:@\w+(?:\([^\n]*\))?\s+)*import\s+(?:class\s+|struct\s+|enum\s+|func\s+|var\s+|let\s+|typealias\s+|protocol\s+)?([A-Za-z_][A-Za-z_0-9]*)', raw, re.M))
        return sorted(values)
    old_imports, new_imports = imports(TEMPLATE_SOURCE), imports(head)
    capture.require(old_imports == new_imports, 'Template lexical import roots changed; fresh description required')
    return {'schema': 'native-current-cohort-buildshape/v1', 'templateAppSourceSHA': TEMPLATE_SOURCE,
        'currentAppSourceSHA': APP_SOURCE, 'sourceSHA': head, 'sourcePaths': current,
        'sourcePathsSHA256': hashlib.sha256(json.dumps(current, separators=(',', ':')).encode()).hexdigest(),
        'lexicalImports': new_imports, 'compilerDependencyScanReused': False,
        'sourceObjects': new_objects, 'templateSourceObjects': old_objects}


def bind(root, selected, allowed_paths):
    from verified_pr_source_checks import original_receipt, verify_run_identity, verify_steps, test_completion
    capture.require(os.environ.get('GITHUB_REPOSITORY') == 'iret77/nexgenvideo'
        and selected['appSourceSHA'] == APP_SOURCE, 'Wrong current App cohort')
    head = os.environ['GITHUB_SHA']
    capture.require(capture.git('rev-parse', 'HEAD') == head and not capture.git('status', '--porcelain', '--untracked-files=no')
        and capture.git('rev-parse', APP_SOURCE + '^{tree}') == APP_TREE, 'Dirty or unreviewed current source')
    subprocess.run(['git', 'merge-base', '--is-ancestor', APP_SOURCE, head], check=True, timeout=30)
    changed = capture.git('diff', '--name-only', '--no-renames', APP_SOURCE, head).splitlines()
    capture.require(changed and set(changed) <= allowed_paths | CI_PATHS and objects(head) == objects(APP_SOURCE),
        'Current cohort changed beyond CI tooling')
    current_path = Path(os.environ['RUNNER_TEMP']) / 'transport-source-proof/receipt.json'
    current = json.loads(current_path.read_text())
    capture.require(current['schema'] == 'core-pr-source-composition/v1' and current['sourceSHA'] == head
        and current['originalRun']['id'] == selected['verifiedPRRunID'] == selected['runID']
        and current['originalPR']['merged'] and current['originalPR']['merge_commit_sha'] == head,
        'Complete merged current cohort composition missing')
    root.mkdir(parents=True, exist_ok=False)
    run = capture.api('actions/runs/' + str(selected['runID']))
    jobs = capture.api(f"actions/runs/{selected['runID']}/attempts/1/jobs?per_page=100")
    job = verify_run_identity(run, jobs, selected['runID'])
    capture.require(run['head_sha'] == selected['sourceSHA'], 'Current cohort source-run head changed')
    artifact = capture.api('actions/artifacts/' + str(selected['artifactID']))
    capture.require(artifact['digest'] == 'sha256:' + selected['artifactSHA256'] and artifact['size_in_bytes'] <= 100_000,
        'Current cohort source artifact differs')
    raw = capture.command(['gh', 'api', f"repos/iret77/nexgenvideo/actions/artifacts/{selected['artifactID']}/zip", '--allow-escape-sequences'])
    with (root / 'app-source-original-proof.zip').open('xb') as stream:
        stream.write(raw); stream.flush(); os.fsync(stream.fileno())
    log = capture.command(['gh', 'api', f"repos/iret77/nexgenvideo/actions/jobs/{job['id']}/logs", '--allow-escape-sequences'])
    with (root / 'app-source-original-job.log').open('xb') as stream:
        stream.write(log); stream.flush(); os.fsync(stream.fileno())
    capture.write(root / 'originals-secured.json', {'artifactSHA256': hashlib.sha256(raw).hexdigest(),
        'jobLogSHA256': hashlib.sha256(log).hexdigest(), 'semanticReceiptReadStarted': False})
    receipt = original_receipt(artifact, raw, run)
    steps = verify_steps(job, receipt)
    pr = capture.api('pulls/' + str(receipt['pullRequest']))
    merge = capture.api('git/commits/' + head)
    qualified_pr = current['originalPR']
    capture.require(pr['number'] == qualified_pr['number'] and pr['head']['sha'] == qualified_pr['head']['sha']
        and pr['base']['sha'] == qualified_pr['base']['sha'] and pr['merged'] and pr['merge_commit_sha'] == head
        and pr['head']['sha'] == receipt['headSHA'] == selected['sourceSHA']
        and merge['tree']['sha'] == receipt['treeSHA'] == capture.git('rev-parse', 'HEAD^{tree}'),
        'Current App and CI composition is not the exact merged source tree')
    completion = test_completion(log)
    shape = buildshape(head)
    (root / 'current-source-composition.json').write_bytes(current_path.read_bytes())
    capture.write(root / 'binding.json', {'schema': 'native-current-cohort-binding/v1', 'harnessSourceSHA': head,
        'selected': selected, 'nativeSourceObjects': objects(head), 'changedHarnessPaths': sorted(changed),
        'appSourceRun': run, 'appSourceArtifact': artifact, 'appSourceReceipt': receipt, 'appSourcePR': pr,
        'appSourceMerge': merge, 'appSourceSteps': steps, 'appSourceCompletion': completion,
        'appSourceLogSHA256': hashlib.sha256(log).hexdigest(), 'currentSourceComposition': current,
        'appCandidateSHA': APP_SOURCE, 'appCandidateTree': APP_TREE, 'templateProjection': shape,
        'appProductCompilationAuthorised': False, 'functionalAcceptance': False})


def verify_template(binding, run, artifact, current):
    capture.require((artifact['id'], artifact['digest'].removeprefix('sha256:')) == TEMPLATE_METADATA
        and run['id'] == 42556707333 and run['head_sha'] == 'e238d854cdeeebd22391d5c820674c6bf9d046e2'
        and binding['schema'] == 'native-app-build-plan-binding/v1' and binding['harnessSourceSHA'] == run['head_sha']
        and binding['selected'] == TEMPLATE_SELECTED and binding['nativeSourceObjects'] == objects(TEMPLATE_SOURCE)
        and current['schema'] == 'native-current-cohort-binding/v1'
        and current['selected']['appSourceSHA'] == APP_SOURCE and current['nativeSourceObjects'] == objects(APP_SOURCE)
        and current['templateProjection'] == buildshape(os.environ['GITHUB_SHA']),
        'Original template provenance or current projection differs')
