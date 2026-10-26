from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import zipfile

import resume_core_app_assertions as assertions
from retained_app_test_products import api, archive_bytes, archive_json, checksum, download, require, verify_artifact, write
from resume_core_tests import command, toolchain


RUN = 40265902971
SOURCE = 'dce1c77b0a22708c8b4cafb609d7fc7c3bdd8222'
JOB = 121390478873
LOG_DIGEST = 'c49cac402d51cdad7c2c85fdb64679840f8bddbbe6d03077cc7d5fef8804335e'
PREFIX = 'Compile, unit tests, app and native bpy acceptance / '
ALLOWED = {'.github/workflows/ci.yml', '.github/workflows/workspace-ui-acceptance.yml',
           'scripts/resume_core_app_assertions.py', 'scripts/test_resume_core_app_assertions.py',
           'scripts/resume_core_bundle.py', 'scripts/resume_core_completed_app.py',
           'scripts/test_resume_core_completed_app.py'}
ARTIFACTS = {
    'tests': (12627091716, 'render-review-test-diagnostic-40265902971',
              '305fb153e9afc56f78162b5701c2e0874c4078d6c31063533d5cfa88286c90b4', 1409853, JOB),
    'backends': (12626927252, 'core-app-assertion-completion-40265902971-a1',
                 '15c119fea8b077b92f50bca676cdc7f36ef52be684899e4ed374a521af792e39', 3130481, JOB),
    'ui': (12626298816, 'agent-chat-spec-40265902971',
           '885087c60145ea4256e5d1fe1e273e1d8254414b8e4b977c6d1713575ab5dce8', 5557047, 121389745613),
    'blockout': (12626697892, 'blockout-orientation-evidence',
                 '72f3c5d1a0379f182acbe44cad23223d13d960e978da3ccfb19f90170e633f36', 1197989, JOB),
    'lottie': (12626987161, 'lottie-export-evidence',
               'abddccb43db9de6e27a3ad1bbce19a6ec4ffdc6cac163900d1ca2f851566d918', 6252, JOB),
}


def sources(head):
    require(re.fullmatch('[a-f0-9]{40}', head) and command(['git', 'rev-parse', 'HEAD']) == head,
            'Recovery checkout identity differs')
    subprocess.run(['git', 'merge-base', '--is-ancestor', SOURCE, head], check=True,
                   stdin=subprocess.DEVNULL, timeout=30)
    changed = command(['git', 'diff', '--name-only', '--no-renames', SOURCE, head]).splitlines()
    require(set(changed) <= ALLOWED, 'Recovery changed product, tests, runtime or unrelated inputs')
    require(not command(['git', 'status', '--porcelain', '--untracked-files=no']), 'Recovery checkout is dirty')
    require(all(checksum(Path(path)) == digest for path, digest in assertions.TESTS.items()),
            'Already passed App tests changed')
    from resume_core_bundle import BUILD
    original = command(['git', 'show', SOURCE + ':.github/workflows/ci.yml'])
    require('run: ' + BUILD in original and 'run: ' + BUILD in Path('.github/workflows/ci.yml').read_text(),
            'Reconstruction compilation command changed')
    patterns = sorted(ALLOWED | {Path(path).name for path in ALLOWED})
    result = subprocess.run(['git', 'grep', '-n', '-F', '-f', '-', head, '--', 'Sources', 'Tests',
                             'Engine', 'Plugins', '*.swift', 'Package.swift',
                             'scripts/stage_test_runtime.sh', 'scripts/run_macos_tests.py'],
                            input='\n'.join(patterns) + '\n', text=True, capture_output=True, timeout=30)
    require(result.returncode == 1, 'Recovery file is a native input or inspection failed')
    return changed


def producer(run, listing):
    require(run.get('id') == RUN and run.get('head_sha') == SOURCE and run.get('run_attempt') == 1
            and run.get('repository', {}).get('full_name') == 'iret77/nexgenvideo'
            and run.get('head_repository', {}).get('full_name') == 'iret77/nexgenvideo'
            and run.get('event') == 'workflow_dispatch' and run.get('path') == '.github/workflows/ci-batch.yml'
            and run.get('status') == 'completed' and run.get('conclusion') == 'failure',
            'Recovery requires the exact parser-failed Core attempt')
    require(listing.get('total_count') == len(listing.get('jobs', [])), 'Incomplete producer job list')
    jobs = {}
    for name, identifier, conclusion in [('Build & Test', JOB, 'failure'),
             ('Light Checks', 121388183959, 'success'), ('Agent UI Evidence', 121389745613, 'success'),
             ('bpy-source / source', 121389745714, 'success')]:
        matches = [j for j in listing['jobs'] if j.get('name') == PREFIX + name]
        require(len(matches) == 1, 'Missing or duplicate producer job')
        job = matches[0]
        require(job.get('id') == identifier and job.get('run_id') == RUN and job.get('run_attempt') == 1
                and job.get('head_sha') == SOURCE and job.get('status') == 'completed'
                and job.get('conclusion') == conclusion, 'Producer job identity or outcome changed')
        jobs[identifier] = job
    require({j['name'] for j in listing['jobs'] if j.get('conclusion') == 'failure'}
            == {PREFIX + 'Build & Test', PREFIX + 'Merge Gate'}, 'Another producer job failed')
    require(all(j.get('conclusion') in {'success', 'failure', 'skipped'} for j in listing['jobs']),
            'Producer job did not finish')
    steps = jobs[JOB]['steps']
    require([s['name'] for s in steps if s.get('conclusion') == 'failure'] == ['Test'],
            'Producer failed outside the known parser boundary')
    for name, conclusion in [('Build', 'success'), ('Stage test runtime inputs', 'success'),
             ('Verify assertion continuation source and platform', 'success'),
             ('Verify build did not mutate tracked source', 'success'),
             ('Upload App assertion continuation proof', 'success'),
             ('Upload render review test diagnosis', 'success'), ('HDR export QC', 'skipped'),
             ('Bundle (debug, ad-hoc signed)', 'skipped'), ('Upload .app artifact', 'skipped')]:
        found = [s for s in steps if s['name'] == name]
        require(len(found) == 1 and found[0].get('conclusion') == conclusion, 'Producer step differs: ' + name)
    for name in ('Verify CI and fixture tooling', 'Enforce AppTheme', 'Validate pack pipeline contracts',
                 'Require distributable bpy before app transfer'):
        found = [s for s in jobs[121388183959]['steps'] if s['name'] == name]
        require(len(found) == 1 and found[0].get('conclusion') == 'success', 'Original source gate failed')
    return jobs


def artifacts(root, receipt, jobs):
    require(set(receipt['artifacts']) == set(ARTIFACTS), 'Recovery artifact set differs')
    for key, (identifier, name, digest, size, job) in ARTIFACTS.items():
        path = root / (key + '.zip')
        require(path.stat().st_size == size and checksum(path) == digest, 'Original artifact bytes changed')
        verify_artifact(receipt['artifacts'][key], receipt['originalRun'], jobs[job], identifier, digest, name)
        require(receipt['artifacts'][key].get('size_in_bytes') == size, 'Original artifact size changed')
        require(datetime.fromisoformat(receipt['artifacts'][key]['expires_at'].replace('Z', '+00:00'))
                > datetime.now(timezone.utc) + timedelta(hours=12), 'Original evidence expires too soon')


def proof(root):
    from resume_core_bundle import host_proof
    backend = root / 'original-backends'; backend.mkdir(exist_ok=True)
    with zipfile.ZipFile(root / 'backends.zip') as archive:
        for name in ('receipt.json', 'original.zip', 'original-job.log'):
            (backend / name).write_bytes(archive_bytes(archive, name))
        require('completed.json' not in archive.namelist(), 'Original composition unexpectedly completed')
    binding = json.loads((backend / 'receipt.json').read_text())
    require(binding.get('sourceSHA') == SOURCE and binding.get('runID') == str(RUN)
            and binding.get('attempt') == '1' and binding.get('originalSourceSHA') == assertions.SOURCE,
            'Original backend binding belongs to another execution')
    assertions.verify_binding(backend, binding)
    changed = command(['git', 'diff', '--name-only', '--no-renames', assertions.SOURCE, SOURCE]).splitlines()
    require(changed == binding['changedPaths'] and set(assertions.TESTS) <= set(changed)
            <= assertions.HARNESS | set(assertions.TESTS), 'Original backend-to-App source chain changed')
    require(binding['completedAppInventory'] == binding['proof']['completedAppInventory'], 'App inventory differs')
    extracted = root / 'original-app'; extracted.mkdir(exist_ok=True)
    suite_root = extracted / 'hosted-suite'; phase = suite_root / 'app-swift-testing'; phase.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(root / 'tests.zip') as archive:
        for name in ('run.json', 'hosted-suite/suite.json', 'hosted-suite/combined.log',
                     'hosted-suite/app-swift-testing/events.jsonl', 'hosted-suite/app-swift-testing/host-receipt.json'):
            (extracted / name).write_bytes(archive_bytes(archive, name))
        capture = json.loads((extracted / 'run.json').read_text())
        require(capture.get('runID') == str(RUN) and capture.get('runLoopProbe', {}).get('status') == 'not-requested'
                and capture.get('command') == capture.get('originalCommand') == capture.get('actualCommand'),
                'Original App capture identity or normal profile differs')
        args = capture['actualCommand']
        require(len(args) == 8 and args[:2] == ['python3', 'scripts/run_macos_tests.py']
                and args[2] == '--cache-path' and args[4:6] == ['--scope', 'app-swift-testing']
                and args[6] == '--evidence', 'Original App command was filtered or instrumented')
        suite = json.loads((suite_root / 'suite.json').read_text())
        require(suite.get('schema') == 1 and capture.get('outputCompletion') == suite.get('combinedFrameworks'),
                'Original suite schema or wrapper framework completion differs')
        derived = root / 'derived'; derived.mkdir(exist_ok=True)
        assertions.complete_verified_app(derived, suite_root, extracted, binding)
        completed = json.loads((derived / 'completed.json').read_text())
        suite = completed['currentApp']; events = suite['phases'][0]['events']
        require(len(events['discoveredFunctionIDs']) == 3528 and events['functionExecutions'] == 3520
                and len(events['skippedFunctionIDs']) == 8 and events['recordCount'] == 12808,
                'Original completed App counts differ')
        host = json.loads((phase / 'host-receipt.json').read_text())
        host_proof(host, suite['phases'][0], suite, events, SOURCE)
        require(host['pid'] == 5789 and host['parentPID'] == 5772, 'Original host identity changed')
        watchdog = archive_json(archive, 'hosted-suite/app-swift-testing/watchdog/receipt.json')
        reports = watchdog.get('reports', [])
        require(len(reports) == 1 and reports[0].get('processID') == host['pid'], 'Original watchdog owner differs')
        raw = archive_bytes(archive, 'hosted-suite/app-swift-testing/watchdog/' + reports[0]['file'])
        report = json.loads(raw)
        require(hashlib.sha256(raw).hexdigest() == reports[0]['sha256'] and report.get('processID') == host['pid']
                and report.get('operatingSystem') == 'Version 27.0 (Build 26A428)', 'Original watchdog platform differs')
        compiler = archive_bytes(archive, 'hosted-suite/app-swift-testing/swiftc-path.stdout').decode().strip()
        require(compiler == '/Applications/Xcode_27.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc'
                and all(host[k].startswith('/Applications/Xcode_27.app/') for k in ('getterImagePath', 'entryPointImagePath')),
                'Original native compiler or framework differs')
    require(checksum(root / 'original-job.log') == LOG_DIGEST, 'Original parser failure log changed')
    log = (root / 'original-job.log').read_text()
    require(log.count('App assertion continuation failed: Unterminated string starting at: line 1 column 177 (char 176)') == 1,
            'Original parser failure differs')
    require(toolchain(log) == binding['toolchain'] and '(Selected)\t/Applications/Xcode_27.app' in log,
            'Original selected toolchain differs from backend binding')
    return {'completion': completed, 'compilerPath': compiler, 'watchdog': report,
            'watchdogCause': 'UNKNOWN', 'toolchain': toolchain(log)}


def prepare(root):
    root.mkdir(parents=True, exist_ok=False)
    changed = sources(os.environ['GITHUB_SHA'])
    run = api(f'actions/runs/{RUN}')
    listing = api(f'actions/runs/{RUN}/attempts/1/jobs?per_page=100')
    jobs = producer(run, listing)
    selected = {}
    for key, (identifier, name, digest, size, job) in ARTIFACTS.items():
        item = api(f'actions/artifacts/{identifier}')
        verify_artifact(item, run, jobs[job], identifier, digest, name)
        require(item.get('size_in_bytes') == size, 'Original artifact size differs')
        download(item, root / (key + '.zip')); selected[key] = item
    with (root / 'original-job.log').open('xb') as stream:
        subprocess.run(['gh', 'api', '--allow-escape-sequences', f'repos/iret77/nexgenvideo/actions/jobs/{JOB}/logs'],
                       stdin=subprocess.DEVNULL, stdout=stream, check=True, timeout=120)
    receipt = {'schema': 'core-completed-app-resume/v1', 'sourceSHA': os.environ['GITHUB_SHA'],
               'runID': os.environ['GITHUB_RUN_ID'], 'attempt': os.environ['GITHUB_RUN_ATTEMPT'],
               'originalRun': run, 'originalJobs': listing, 'changedPaths': changed, 'artifacts': selected,
               'originalExecution': {'runID': RUN, 'jobID': JOB, 'attempt': 1, 'sourceSHA': SOURCE},
               'reused': ['normal full App tests from40265902971', 'XCTest/Engine and signing fixtures from40254944746',
                          'Agent UI rendering from40265902971'],
               'limitations': 'Original post-test tracked-source checks did not execute. Compiled inputs were verified before tests; reconstruction uses the same committed product and test bytes. Original object-byte identity is unproven. Original GPU/watchdog/helper timeout causes remain unknown. No native UX or RC-DMG qualification.',
               'pending': ['fresh HDR QC', 'reconstructed bundle', 'pack loading/ABI', 'diagnostic/helper', 'bpy runtime',
                           'selected Chat/private audio', 'native UI matrix', 'signed installed DMG']}
    artifacts(root, receipt, jobs)
    receipt['nativeProof'] = proof(root)
    receipt['toolchain'] = receipt['nativeProof']['toolchain']
    backend = json.loads((root / 'original-backends/receipt.json').read_text())
    live = api(f'actions/runs/{assertions.RUN}')
    require(live.get('run_attempt') == 1 and live.get('head_sha') == assertions.SOURCE
            and live.get('status') == 'completed' and live.get('conclusion') == 'failure', 'Backend producer changed')
    item = api(f'actions/artifacts/{assertions.ARTIFACT}')
    original_job = assertions.verify_jobs(backend['originalRun'], backend['originalJobs'])
    verify_artifact(item, live, original_job, assertions.ARTIFACT, assertions.DIGEST,
                    f'render-review-test-diagnostic-{assertions.RUN}')
    require(datetime.fromisoformat(item['expires_at'].replace('Z', '+00:00'))
            > datetime.now(timezone.utc) + timedelta(hours=12), 'Backend evidence expires too soon')
    require(api(f'actions/runs/{RUN}').get('run_attempt') == 1, 'App producer was rerun during binding')
    write(root / 'receipt.json', receipt)


def verify(root, native=False):
    receipt = json.loads((root / 'receipt.json').read_text())
    require(receipt.get('schema') == 'core-completed-app-resume/v1'
            and receipt.get('sourceSHA') == os.environ.get('GITHUB_SHA')
            and receipt.get('runID') == os.environ.get('GITHUB_RUN_ID')
            and receipt.get('attempt') == os.environ.get('GITHUB_RUN_ATTEMPT'), 'Recovery belongs to another execution')
    require(sources(receipt['sourceSHA']) == receipt['changedPaths'], 'Recovery source binding changed')
    require(receipt.get('originalExecution') == {'runID': RUN, 'jobID': JOB, 'attempt': 1, 'sourceSHA': SOURCE},
            'Original execution label changed')
    jobs = producer(receipt['originalRun'], receipt['originalJobs'])
    artifacts(root, receipt, jobs)
    require(proof(root) == receipt['nativeProof'] and receipt['toolchain'] == receipt['nativeProof']['toolchain'],
            'Recovered native proof changed')
    if native:
        from resume_core_bundle import verify_platform
        verify_platform(receipt)
    return receipt


def finish_evidence(root, receipt):
    from resume_core_bundle import hdr_proof
    hdr = Path(os.environ['RUNNER_TEMP']) / 'hdr-export-qc'
    names = ['hosted-suite/suite.json', 'hosted-suite/app-swift-testing/console.log',
             'hosted-suite/app-swift-testing/events.jsonl', 'hosted-suite/app-swift-testing/host-receipt.json',
             'hdr-qc.v1.json', 'hdr-reference.mov']
    with zipfile.ZipFile(root / 'hdr.zip', 'w', compression=zipfile.ZIP_DEFLATED) as archive:
        for name in names:
            path = hdr / name
            require(path.is_file() and not path.is_symlink(), 'Fresh HDR evidence missing or linked')
            archive.write(path, name)
    fresh = hdr_proof(root, receipt['sourceSHA'])
    binding = json.loads((root / 'original-backends/receipt.json').read_text())
    job = assertions.verify_jobs(binding['originalRun'], binding['originalJobs'])
    return {'backendExecution': {'runID': assertions.RUN, 'sourceSHA': assertions.SOURCE, 'attempt': 1, 'jobID': job['id']},
            'freshHDR': {'runID': receipt['runID'], 'attempt': receipt['attempt'], 'sourceSHA': receipt['sourceSHA'],
                         'archiveSHA256': checksum(root / 'hdr.zip'), 'proof': fresh},
            'pending': [item for item in receipt['pending'] if item not in {'fresh HDR QC', 'reconstructed bundle', 'pack loading/ABI'}],
            'limitations': receipt['limitations']}
