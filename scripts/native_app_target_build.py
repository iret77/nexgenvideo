import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import time
import urllib.parse
import zipfile

import native_app_build_plan as capture
from native_app_target_recipe import module_driver, profile_operations, validate_frontend_jobs
import release_test_repair as retained
from release_engine_resume import verify_engine_source_objects
from retained_app_test_products import api, archive_bytes, download, require, verify_artifact, write


MODE = 'native-app-targets'
DRIVER_INPUT_ORIGINS = {
    'production-cache': {'selected': {'runID': 42579228502, 'sourceSHA': 'ce3f5dab418cb740159d9348d2cca4921ce81b04',
        'artifactID': 13656049747, 'artifactSHA256': '78edea90be9d7701870d7c67b49dcb33660b45e5a5507e10172023eaab72457b',
        'receiptSHA256': 'e5d37d8cb052c2f830401030b9452b83936661217c2858cc65f9a6b8debf248b'},
        'nestedSHA256': '399b9393316c96bda5d0f69af81dbf0e4fb5bad3596fa91d6644c5b8e148e6f1', 'files': 114},
    'production-plan': {'selected': {'runID': 42586326278, 'sourceSHA': 'b06b26295bca9cbd3d96d0841c4c068077984bb0',
        'artifactID': 13659142258, 'artifactSHA256': '98e5797340b89a7bbe978f4dcfbc44db1a95c594077bae9231aa8b679f7af53c',
        'receiptSHA256': '5bd6f9015a352a8a238cddcc09fecaf4ee095bdc93caf5ae859749d688bde17b'},
        'nestedSHA256': 'd6f1a613f842ae6ce3ad0814ec3273bd20becb54ae37574090576461d0eb1b49', 'files': 115,
        'stdoutSHA256': '677f693ca82d5e1c4ea3314fdf4c22e5b9d80b7b46bd4215d876237da0495d18'}
}
PATHS = capture.PATHS | {'scripts/native_app_target_recipe.py', 'scripts/test_native_app_target_recipe.py',
    'scripts/native_app_target_build.py', 'scripts/test_native_app_target_build.py',
    'scripts/test_diagnostic_acceptance.py'}


def selector(env, names, pattern):
    require(all(name not in env or isinstance(env[name], str) for name in names), 'Selector is not a string')
    values = [env[name] for name in names if env.get(name)]
    require(values and all(isinstance(value, str) and re.fullmatch(pattern, value) for value in values)
        and len(set(values)) == 1, 'Missing, invalid or conflicting selector: ' + '/'.join(names))
    return values[0]


def resume_inputs(raw):
    require(isinstance(raw, str), 'Target resume input must be JSON text')
    if not raw: return {}
    def unique(items):
        result = {}
        for key, value in items:
            require(key not in result, 'Duplicated target resume field')
            result[key] = value
        return result
    value = json.loads(raw, object_pairs_hook=unique)
    require(isinstance(value, dict) and set(value) <= {'production', 'testable', 'tests', *DRIVER_INPUT_ORIGINS},
        'Unknown resumed target role')
    require(len(set(value) & {'production', *DRIVER_INPUT_ORIGINS}) <= 1, 'Conflicting production product and cache roles')
    keys = {'runID', 'sourceSHA', 'artifactID', 'artifactSHA256', 'receiptSHA256'}
    for item in value.values():
        require(isinstance(item, dict) and set(item) == keys and all(type(item[key]) is int and item[key] > 0
            for key in ('runID', 'artifactID')), 'Incomplete resumed target identity')
        require(isinstance(item['sourceSHA'], str) and re.fullmatch('[a-f0-9]{40}', item['sourceSHA'])
            and all(isinstance(item[key], str) and re.fullmatch('[a-f0-9]{64}', item[key])
            for key in ('artifactSHA256', 'receiptSHA256')), 'Invalid resumed target source or digest')
    return value


def validate_inputs(env):
    require(selector(env, ('KIND', 'REPLAY_KIND'), MODE) == MODE and env.get('SCALE') == '1', 'Wrong compiler role')
    app = {'runID': int(selector(env, ('PRODUCER_RUN',), r'[1-9][0-9]*')),
        'sourceSHA': selector(env, ('PRODUCER_SHA',), r'[a-f0-9]{40}'),
        'artifactID': int(selector(env, ('DIAGNOSTIC_ID',), r'[1-9][0-9]*')),
        'artifactSHA256': selector(env, ('DIAGNOSTIC_DIGEST',), r'[a-f0-9]{64}'),
        'appSourceSHA': selector(env, ('EXTRA_SOURCE', 'PRODUCT_SHA'), r'[a-f0-9]{40}'),
        'verifiedPRRunID': int(selector(env, ('VERIFIED_PR',), r'[1-9][0-9]*'))}
    native = {'artifactID': int(selector(env, ('EXTRA_FAILURE', 'FAILURE_ID'), r'[1-9][0-9]*')),
        'artifactSHA256': selector(env, ('EXTRA_FAILURE_SHA', 'FAILURE_DIGEST'), r'[a-f0-9]{64}')}
    bank = {'artifactID': int(selector(env, ('EXTRA_PRODUCTS', 'PRODUCTS_ID'), r'[1-9][0-9]*')),
        'artifactSHA256': selector(env, ('EXTRA_PRODUCTS_SHA', 'PRODUCTS_DIGEST'), r'[a-f0-9]{64}')}
    require((bank['artifactID'], bank['artifactSHA256']) == retained.ARTIFACTS['runtime'][:2], 'Unreviewed retained product bank')
    unused = ('DMG_DIGEST', 'JOURNEY_JOB', 'JOURNEY_ARTIFACT', 'JOURNEY_DIGEST', 'PACKAGING_PRODUCER_SOURCE',
        'PACKAGING_PROVENANCE_ARTIFACT_ID', 'PACKAGING_PROVENANCE_ARTIFACT_SHA256')
    require(not any(env.get(name) for name in unused), 'Unrelated runtime selectors cannot be ignored')
    return {'app': app, 'metadata': native, 'bank': bank, 'resume': resume_inputs(env.get('RUNTIME_FAILURE_BINDING', ''))}


def file_hashes(files):
    return {name: hashlib.sha256(raw).hexdigest() for name, raw in files.items()}


def raw_metadata(root, selected, app):
    artifact = api('actions/artifacts/' + str(selected['artifactID']))
    runid = artifact['workflow_run']['id']
    run = api('actions/runs/' + str(runid))
    jobs = api(f'actions/runs/{runid}/attempts/1/jobs?per_page=100')
    require(jobs['total_count'] == len(jobs['jobs']) and run['workflow_id'] == 355242770
        and run['repository']['full_name'] == 'iret77/nexgenvideo' and run['actor']['login'] == 'iret77'
        and run['path'] == '.github/workflows/diagnostic-acceptance.yml' and run['event'] == 'workflow_dispatch'
        and run['run_attempt'] == 1 and run['status'] == 'completed' and run['conclusion'] == 'failure',
        'Wrong original native metadata producer')
    native = [job for job in jobs['jobs'] if job['name'] == 'app-build-plan']
    source = [job for job in jobs['jobs'] if job['name'] == 'source']
    require(len(native) == len(source) == 1 and native[0]['labels'] == ['macrunner']
        and native[0]['conclusion'] == 'failure' and source[0]['conclusion'] == 'success'
        and all(job['id'] == native[0]['id'] for job in jobs['jobs']
            if job['conclusion'] != 'skipped' and job['labels'] == ['macrunner']), 'Metadata job roles differ')
    verify_artifact(artifact, run, native[0], selected['artifactID'], selected['artifactSHA256'], 'app-build-plan-evidence')
    archive = root / 'raw-metadata-original.zip'; download(artifact, archive)
    files = capture.archive_files(archive.read_bytes())
    source_artifact = json.loads(files['source-binding-artifact.json'])
    current = api('actions/artifacts/' + str(source_artifact['id']))
    require(current == source_artifact, 'Original source binding artifact metadata changed')
    verify_artifact(current, run, source[0], current['id'], current['digest'].removeprefix('sha256:'), 'app-build-plan-source-binding')
    source_zip = root / 'raw-source-binding-original.zip'; download(current, source_zip)
    source_files = capture.archive_files(source_zip.read_bytes())
    binding = json.loads(source_files['binding.json'])
    require(binding['schema'] == 'native-app-build-plan-binding/v1' and binding['harnessSourceSHA'] == run['head_sha']
        and binding['nativeSourceObjects'] == app['nativeSourceObjects'], 'Metadata native source objects differ')
    for key in ('runID', 'sourceSHA', 'artifactID', 'artifactSHA256', 'appSourceSHA'):
        require(binding['selected'][key] == app['selected'][key], 'Original App source selector changed: ' + key)
    require(set(capture.git('diff', '--name-only', '--no-renames', run['head_sha'], os.environ['GITHUB_SHA']).splitlines()) <= PATHS,
        'Metadata source graph changed beyond reviewed compiler tooling')
    resume = binding['resumeCapture']
    require(resume['schema'] == 'native-app-build-plan-resume/v2', 'Unsupported metadata origin chain')
    previous_raw = source_files['prior-metadata-original.zip']
    require(hashlib.sha256(previous_raw).hexdigest() == resume['originArtifact']['digest'].removeprefix('sha256:'),
        'Retained production metadata archive changed')
    previous = capture.archive_files(previous_raw)
    require(file_hashes(previous) == resume['originalMetadataFiles']
        and {name.removeprefix('prior-capture/'): raw for name, raw in files.items()
            if name.startswith('prior-capture/')} == previous, 'Retained metadata bytes changed')
    workspace = resume['snapshot']['workspace']
    production = capture.description_snapshot(previous, 'production', workspace)
    require(production == resume['retainedProfileSnapshots']['production'], 'Production description origin changed')
    require(all(files[name] == previous[name] for name in production['fileHashes']), 'Production profile was rewritten')
    testable = capture.description_snapshot(files, 'testable', workspace)
    require(json.loads(files['toolchain.json']) == resume['snapshot']['toolchain'], 'Metadata toolchain changed')
    return {'run': run, 'jobs': jobs, 'nativeJob': native[0], 'sourceJob': source[0], 'artifact': artifact,
        'sourceArtifact': current, 'binding': binding, 'profiles': {'production': production, 'testable': testable},
        'allFileHashes': file_hashes(files), 'workspace': workspace, 'toolchain': resume['snapshot']['toolchain']}


def bank_metadata(root, selected, head):
    run = api('actions/runs/' + str(retained.RUN))
    jobs = api(f'actions/runs/{retained.RUN}/attempts/1/jobs?per_page=100')
    job = retained.verify_original(run, jobs)
    products = api('actions/artifacts/' + str(selected['artifactID']))
    verify_artifact(products, run, job, selected['artifactID'], selected['artifactSHA256'], retained.ARTIFACTS['runtime'][2])
    identifier, digest, name = retained.ARTIFACTS['metadata']
    artifact = api('actions/artifacts/' + str(identifier))
    verify_artifact(artifact, run, job, identifier, digest, name)
    archive = root / 'bank-metadata-original.zip'; download(artifact, archive)
    with zipfile.ZipFile(archive) as contents:
        raw = archive_bytes(contents, 'release-test-product-checkpoints/runtime-manifest.json', 4 * 1024**2)
    require(hashlib.sha256(raw).hexdigest() == retained.MANIFEST_SHA, 'Retained runtime manifest differs')
    manifest = json.loads(raw)
    require(manifest['sourceSHA'] == retained.SOURCE and manifest['runID'] == str(retained.RUN)
        and manifest['attempt'] == '1' and manifest['runtimeReady'] is True and manifest['configuration'] == 'release'
        and manifest['swiftcFlags'] == ['-enable-testing'] and manifest['treeSHA256'] == retained.TREE_SHA,
        'Retained compiler product context differs')
    objects, role = verify_engine_source_objects(head)
    (root / 'bank-runtime-manifest.json').write_bytes(raw)
    return {'run': run, 'job': job, 'runtimeArtifact': products, 'metadataArtifact': artifact,
        'manifestSHA256': retained.MANIFEST_SHA, 'treeSHA256': retained.TREE_SHA,
        'currentEngineSourceObjects': objects, 'appHostRole': role}


def resumed_products(selected, objects, head):
    result = {}
    for phase, item in selected.items():
        cache_only = phase in DRIVER_INPUT_ORIGINS
        artifact_phase = 'production' if cache_only else phase
        if cache_only:
            require(item == DRIVER_INPUT_ORIGINS[phase]['selected'],
                'Unqualified partial driver cache producer')
        run = api('actions/runs/' + str(item['runID']))
        jobs = api(f"actions/runs/{item['runID']}/attempts/1/jobs?per_page=100")
        require(jobs['total_count'] == len(jobs['jobs']) and run['repository']['full_name'] == 'iret77/nexgenvideo'
            and run['workflow_id'] == 355242770 and run['path'] == '.github/workflows/diagnostic-acceptance.yml'
            and run['event'] == 'workflow_dispatch' and run['actor']['login'] == 'iret77' and run['run_attempt'] == 1
            and run['status'] == 'completed' and run['conclusion'] in {'success', 'failure'}
            and run['head_sha'] == item['sourceSHA'], 'Resumed native target producer differs')
        source = [job for job in jobs['jobs'] if job['name'] == 'source']
        native = [job for job in jobs['jobs'] if job['name'] == 'app-target-build']
        require(len(source) == len(native) == 1 and source[0]['conclusion'] == 'success'
            and native[0]['labels'] == ['macrunner'] and native[0]['conclusion'] in {'success', 'failure'},
            'Resumed target producer jobs differ')
        artifact = api('actions/artifacts/' + str(item['artifactID']))
        verify_artifact(artifact, run, native[0], item['artifactID'], item['artifactSHA256'], 'app-target-' + artifact_phase + '-products')
        require(objects == {name: capture.git('rev-parse', item['sourceSHA'] + ':' + name) for name in capture.INPUT_OBJECTS}
            and set(capture.git('diff', '--name-only', '--no-renames', item['sourceSHA'], head).splitlines()) <= PATHS,
            'Resumed target native source changed')
        result[phase] = {'selected': item, 'artifact': artifact, 'run': run, 'job': native[0], 'sourceJob': source[0]}
    return result


def bind(root):
    require(os.environ.get('GITHUB_REPOSITORY') == 'iret77/nexgenvideo' and os.environ.get('GITHUB_JOB') == 'source'
        and os.environ.get('GITHUB_ACTIONS') == 'true' and os.environ.get('GITHUB_RUN_ATTEMPT') == '1', 'Wrong compiler source role')
    selected = validate_inputs(os.environ)
    root.mkdir(parents=True, exist_ok=False)
    capture.bind_sources(root / 'app-source', selected['app'], PATHS)
    app = json.loads((root / 'app-source/binding.json').read_text())
    metadata = raw_metadata(root, selected['metadata'], app)
    bank = bank_metadata(root, selected['bank'], os.environ['GITHUB_SHA'])
    resumed = resumed_products(selected['resume'], app['nativeSourceObjects'], os.environ['GITHUB_SHA'])
    write(root / 'binding.json', {'schema': 'native-app-target-source-binding/v1', 'sourceSHA': os.environ['GITHUB_SHA'],
        'selected': selected, 'appSource': app, 'metadata': metadata, 'retainedBank': bank, 'resumedProducts': resumed,
        'appSourceSHA': selected['app']['appSourceSHA'], 'nativeSourceObjects': app['nativeSourceObjects'],
        'functionalAcceptance': False, 'publicationAuthorised': False})


def logged(root, label, argv, env=None, cwd=None, timeout=600):
    root.mkdir(parents=True, exist_ok=True)
    write(root / (label + '.argv.json'), argv)
    with (root / (label + '.stdout')).open('xb') as out, (root / (label + '.stderr')).open('xb') as err:
        process = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=out, stderr=err,
            env=env, cwd=cwd, start_new_session=True)
        try:
            status = process.wait(timeout=timeout)
        except BaseException:
            os.killpg(process.pid, signal.SIGTERM)
            try: process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL); process.wait(timeout=10)
            raise
    write(root / (label + '.exit.json'), {'exitCode': status})
    require(status == 0, 'Native target command failed: ' + label)
    return (root / (label + '.stdout')).read_text()


def repository_origin(value):
    require(isinstance(value, str), 'Repository origin is not text')
    origin = urllib.parse.urlsplit(value)
    require(origin.scheme == 'https' and origin.hostname == 'github.com' and not origin.username
        and not origin.password and origin.port is None and not origin.query and not origin.fragment
        and re.fullmatch(r'/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', origin.path)
        and all(part not in {'.', '..'} for part in origin.path.split('/')[1:]), 'Unreviewed repository origin')
    return 'https://github.com' + origin.path.lower().removesuffix('.git')


def checkout_locations(packages, identities, scratch, workspace):
    require(isinstance(packages, list) and len(packages) == len(identities) + 1,
        'Qualified package metadata inventory changed')
    locations = {}
    root_packages = 0
    for package in packages:
        require(isinstance(package, dict) and isinstance(package.get('packageKind'), dict)
            and set(package['packageKind']) == {'root'}, 'Missing qualified package root')
        roots = package['packageKind']['root']
        require(isinstance(roots, list) and len(roots) == 1 and isinstance(roots[0], str), 'Ambiguous qualified package root')
        path = Path(roots[0])
        require(path.is_absolute() and str(path) == roots[0] and '..' not in path.parts
            and '\\' not in roots[0] and '\0' not in roots[0], 'Unbound qualified checkout path')
        if path == workspace:
            root_packages += 1
            continue
        identity = path.name.lower()
        require(path.parent == scratch / 'checkouts' and identity in identities and identity not in locations,
            'Qualified checkout path does not match one pinned identity')
        locations[identity] = path
    require(root_packages == 1 and set(locations) == identities, 'Qualified checkout roots are incomplete')
    return locations


def restore_checkouts(root, scratch, cache, pins, environment, packages, workspace):
    require(isinstance(pins, list) and len(pins) == 18, 'Pinned source checkout inventory changed')
    identities = set()
    for pin in pins:
        require(isinstance(pin, dict) and isinstance(pin.get('state'), dict)
            and isinstance(pin.get('identity'), str) and isinstance(pin.get('location'), str)
            and isinstance(pin['state'].get('revision'), str), 'Malformed pinned source checkout')
        identity = pin.get('identity', '')
        repository_origin(pin['location'])
        require(isinstance(identity, str) and re.fullmatch('[a-z0-9][a-z0-9._-]*', identity)
            and identity not in identities and pin.get('kind') == 'remoteSourceControl'
            and re.fullmatch('[a-f0-9]{40}', pin.get('state', {}).get('revision', '')),
            'Invalid pinned source checkout identity, origin or revision')
        identities.add(identity)
    locations = checkout_locations(packages, identities, scratch, workspace)
    destination_root = scratch / 'checkouts'
    require(not scratch.exists() and not scratch.is_symlink(), 'Source checkout scratch path is occupied')
    destination_root.mkdir(parents=True)
    repositories = cache / 'repositories'
    cached = sorted(repositories.iterdir()) if repositories.is_dir() else []
    require(len(cached) <= 256, 'Dependency repository cache exceeds its bound')
    restored = []
    for pin in pins:
        identity, revision = pin['identity'], pin['state']['revision']
        selected_cache, cache_origin = None, None
        for candidate in cached:
            if not candidate.name.lower().startswith(identity + '-'): continue
            require(candidate.is_dir() and not candidate.is_symlink()
                and candidate.resolve().parent == repositories.resolve(), 'Cached source repository escapes its job')
            origin_probe = subprocess.run(['git', '--git-dir', str(candidate), 'config', '--get', 'remote.origin.url'],
                stdin=subprocess.DEVNULL, capture_output=True, env=environment, timeout=15)
            if origin_probe.returncode != 0: continue
            try:
                actual_origin = origin_probe.stdout.decode().strip()
                if repository_origin(actual_origin) != repository_origin(pin['location']): continue
            except (ValueError, UnicodeError):
                continue
            probe = subprocess.run(['git', '--git-dir', str(candidate), 'cat-file', '-e', revision + '^{commit}'],
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                env=environment, timeout=15)
            if probe.returncode == 0:
                selected_cache, cache_origin = candidate, actual_origin
                break
        destination = locations[identity]
        source = str(selected_cache) if selected_cache else pin['location']
        git = ['git', '-c', 'core.hooksPath=/dev/null', '-c', 'maintenance.autoDetach=false', '-c', 'gc.autoDetach=false']
        logged(root, identity + '-clone-source', [*git, 'clone',
            '--no-checkout', '--no-hardlinks', source, str(destination)], environment, timeout=180)
        logged(root, identity + '-canonical-origin', [*git, '-C', str(destination), 'remote', 'set-url',
            'origin', pin['location']], environment)
        logged(root, identity + '-checkout-pin', [*git, '-C', str(destination),
            '-c', 'submodule.recurse=false', 'checkout', '--detach', revision], environment, timeout=180)
        restored.append({'identity': identity, 'revision': revision, 'origin': pin['location'],
            'cacheRepository': str(selected_cache) if selected_cache else None,
            'originalCacheOrigin': cache_origin, 'checkout': str(destination)})
    write(root / 'restored-source-checkouts.json', {'sourceOnly': True, 'binaryArtifactDownloads': 0, 'checkouts': restored})


def native_guard(root):
    require(sys.platform == 'darwin' and platform.machine() == 'arm64'
        and os.environ.get('GITHUB_REPOSITORY') == 'iret77/nexgenvideo'
        and os.environ.get('GITHUB_ACTIONS') == 'true' and os.environ.get('GITHUB_RUN_ATTEMPT') == '1'
        and os.environ.get('GITHUB_JOB') == 'app-target-build' and os.environ.get('REPLAY_KIND') == MODE,
        'App targets require the owned native job')
    temporary = Path(os.environ['RUNNER_TEMP']).resolve()
    require(root.is_absolute() and root == temporary / 'app-target-build' and not root.is_symlink(),
        'Compiler output must use the owned job root')
    return temporary


def pinned_header_inputs(plans, checkouts, workspace):
    roots = [path.resolve() for path in checkouts]
    workspace = workspace.resolve()
    result = {}
    seen = set()
    for plan in plans.values():
        argv = plan['driver']['argv']
        for index, value in enumerate(argv[:-1]):
            if value != '-Xcc' or not argv[index + 1].startswith('-I'): continue
            path = Path(argv[index + 1][2:])
            require(path.is_absolute(), 'Clang include root must be absolute')
            packages = [root for root in roots if path.is_relative_to(root)]
            if packages:
                require(len(packages) == 1 and path.resolve().is_relative_to(packages[0]) and not path.is_symlink(),
                    'Public header root escapes its pinned package')
                package = packages[0]
            elif path.is_relative_to(workspace):
                allowed = [workspace / name for name in ('Sources/BpySupervisorPOSIX', 'Sources/HangStackSampler', 'Tests/AppKitTestHostSupport')]
                require(any(path.is_relative_to(root) for root in allowed), 'Unreviewed host Clang include root')
                package = workspace
            else:
                arena = Path(plan['operations']['arena'])
                require(path.is_relative_to(arena), 'Clang include root is outside its exact source or product graph')
                continue
            identity = (str(package), str(path))
            if identity in seen: continue
            headers = retained.header_inputs(package, path.parent, path)
            result.update({str(package / name): digest for name, digest in headers.items()})
            seen.add(identity)
    require(result, 'Pinned public header inventory is missing')
    return result


def prepare(root, source_binding):
    temporary = native_guard(root)
    root.mkdir(parents=True, exist_ok=False)
    require(source_binding.resolve().is_relative_to(temporary) and not source_binding.is_symlink(), 'Source binding escapes this job')
    binding = json.loads(source_binding.read_text())
    require(binding['schema'] == 'native-app-target-source-binding/v1' and binding['sourceSHA'] == os.environ['GITHUB_SHA']
        and binding['selected'] == validate_inputs(os.environ) and capture.git('rev-parse', 'HEAD') == binding['sourceSHA']
        and not capture.git('status', '--porcelain', '--untracked-files=no'), 'Native source or selected inputs differ')
    current_objects = {name: capture.git('rev-parse', 'HEAD:' + name) for name in capture.INPUT_OBJECTS}
    require(current_objects == binding['nativeSourceObjects'], 'Native App source changed after source qualification')
    identifier = int(os.environ['TARGET_BINDING_ARTIFACT_ID'])
    digest = os.environ['TARGET_BINDING_DIGEST']
    artifact = api('actions/artifacts/' + str(identifier))
    run = api('actions/runs/' + os.environ['GITHUB_RUN_ID'])
    jobs = api('actions/runs/' + os.environ['GITHUB_RUN_ID'] + '/attempts/1/jobs?per_page=100')
    source = [job for job in jobs['jobs'] if job['name'] == 'source']
    require(jobs['total_count'] == len(jobs['jobs']) and len(source) == 1 and source[0]['conclusion'] == 'success'
        and source[0]['run_attempt'] == 1 and run['head_sha'] == binding['sourceSHA'], 'Current source producer differs')
    verify_artifact(artifact, run, source[0], identifier, digest, 'app-target-source-binding')
    incoming = root / 'source-binding-original.zip'; download(artifact, incoming)
    transferred = capture.archive_files(incoming.read_bytes())
    actual = {path.relative_to(source_binding.parent).as_posix(): path.read_bytes()
        for path in source_binding.parent.rglob('*') if path.is_file()}
    require(transferred == actual, 'Transferred native source binding differs from its original archive')
    write(root / 'source-binding-artifact.json', artifact)
    write(root / 'binding.json', binding)
    environment = capture.probe_environment(os.environ)
    toolchain = binding['metadata']['toolchain']
    require(capture.sha(Path(toolchain['compiler'])) == toolchain['compilerSHA256']
        and capture.sha(Path(toolchain['console'])) == toolchain['consoleSHA256'], 'Measured native toolchain changed')
    require(logged(root, 'xcode', ['xcodebuild', '-version'], environment).strip() == 'Xcode 27.2\nBuild version 27B52'
        and logged(root, 'swift', ['swift', '--version'], environment).splitlines()[0]
        == 'Apple Swift version 6.4.2 (swiftlang-6.4.2.1.9 clang-2100.4.1.1)'
        and logged(root, 'sdk-version', ['xcrun', '--sdk', 'macosx', '--show-sdk-version'], environment).strip() == '27.2',
        'Retained compiler or SDK version changed')
    logged(root, 'os-version', ['sw_vers', '-productVersion'], environment)
    logged(root, 'os-build', ['sw_vers', '-buildVersion'], environment)
    metadata = root / 'metadata'; metadata.mkdir()
    files = capture.archive_files((source_binding.parent / 'raw-metadata-original.zip').read_bytes())
    require(file_hashes(files) == binding['metadata']['allFileHashes'], 'Native metadata transfer changed')
    for name, raw in files.items():
        destination = metadata / name; destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(raw)
    snapshot = binding['metadata']['binding']['resumeCapture']['snapshot']
    require(str(Path.cwd().resolve()) == snapshot['workspace'] and str(Path(os.environ['NGV_SWIFTPM_CACHE_PATH'])) == snapshot['cache'],
        'The exact metadata workspace or dependency cache cannot be restored')
    scratch = Path(snapshot['scratch'])
    require(scratch.is_relative_to(temporary) and not scratch.exists(), 'Pinned checkout path is occupied or outside this job')
    pins = json.loads(Path('Package.resolved').read_text())['pins']
    restore_checkouts(root, scratch, Path(snapshot['cache']), pins, environment, snapshot['graph']['packages'], Path.cwd())
    checkouts = list((scratch / 'checkouts').iterdir())
    require(len(pins) == len(checkouts) == 18, 'Pinned checkout inventory changed')
    for pin in pins:
        found = [path for path in checkouts if path.name.lower() == pin['identity'].lower()]
        require(len(found) == 1 and capture.command(['git', '-C', str(found[0]), 'rev-parse', 'HEAD']).decode().strip()
            == pin['state']['revision'], 'Pinned dependency checkout changed')
        require(not found[0].is_symlink() and found[0].resolve().parent == (scratch / 'checkouts').resolve()
            and not capture.command(['git', '-C', str(found[0]), 'status', '--porcelain', '--untracked-files=all']).strip(),
            'Pinned dependency checkout has changed or additional source files')
    require(not capture.git('status', '--porcelain', '--untracked-files=no'), 'Checkout restoration mutated tracked source')
    bank = binding['retainedBank']['runtimeArtifact']
    current = api('actions/artifacts/' + str(bank['id']))
    require(current == bank and not current['expired'], 'Retained runtime product artifact changed')
    download(current, root / 'runtime.zip')
    manifest = json.loads((source_binding.parent / 'bank-runtime-manifest.json').read_text())
    binary = retained.restore_runtime(root, manifest, lambda argv, label, timeout=180:
        logged(root, label, argv, environment, timeout=timeout))
    plans = {}
    for phase, profile, module in [('production', 'production', 'NexGenVideo'),
            ('testable', 'testable', 'NexGenVideo'), ('tests', 'testable', 'NexGenVideoTests')]:
        folder = metadata / profile
        driver = module_driver(folder, profile, module, snapshot['workspace'], toolchain['compiler'])
        operations = profile_operations(folder)
        arena = Path(operations['arena'])
        require(arena == temporary / 'app-build-plan-evidence' / profile / 'derived-data', 'Original compiler arena changed')
        plans[phase] = {'profile': profile, 'driver': driver, 'operations': operations}
    headers = pinned_header_inputs(plans, checkouts, Path.cwd())
    for profile in ('production', 'testable'):
        operations = plans[profile]['operations']
        arena = Path(operations['arena'])
        require(not arena.exists() and not arena.is_symlink(), 'Compiler arena must be fresh')
        products = arena / 'Products/Release'
        def ignored(directory, names):
            excluded = {'NexGenVideo', 'NexGenVideo.swiftmodule', 'NexGenVideo.dSYM', 'NexGenVideoTests.swiftmodule'}
            if Path(directory) == binary: return excluded.intersection(names)
            if Path(directory) == binary / 'ExecutableModules': return {Path(retained.APP_OBJECT).name}.intersection(names)
            if Path(directory) == binary / 'NexGenVideoTests.xctest/Contents/MacOS': return {'NexGenVideoTests'}.intersection(names)
            return set()
        shutil.copytree(binary, products, symlinks=True, ignore=ignored)
        auxiliary_log = root / (profile + '-auxiliary.stdout')
        auxiliary_log.open('xb').close()
        for item in operations['auxiliaryFiles']:
            source = metadata / profile / item['attachment']
            require(capture.sha(source) == item['sha256'], 'Auxiliary content changed')
            output = Path(item['output']); output.parent.mkdir(parents=True, exist_ok=True)
            require(not output.exists() and not output.is_symlink(), 'Auxiliary output is occupied')
            output.write_bytes(source.read_bytes())
            if item['logContents']:
                with auxiliary_log.open('ab') as stream: stream.write(source.read_bytes())
        for item in operations['copies']:
            if item['kind'] != 'module-map': continue
            source, output = Path(item['source']), Path(item['output'])
            require(source.is_file() and not source.is_symlink() and not output.exists(), 'Generated module map is incomplete')
            output.parent.mkdir(parents=True, exist_ok=True); shutil.copyfile(source, output)
        require(len(operations['sdkStatCaches']) == 1, 'Missing unique SDK stat cache task')
        cache = operations['sdkStatCaches'][0]
        Path(cache['argv'][3]).parent.mkdir(parents=True, exist_ok=True)
        logged(root, profile + '-sdk-stat-cache', cache['argv'], dict(environment, **cache['environment']), cache['cwd'])
    prepared = {'schema': 'native-app-target-prepared/v1', 'sourceSHA': binding['sourceSHA'],
        'appSourceSHA': binding['appSourceSHA'], 'nativeSourceObjects': current_objects, 'plans': plans,
        'bankBinary': str(binary), 'environment': environment, 'compilerSHA256': toolchain['compilerSHA256'],
        'appProductCompilerExecutions': 0, 'packageMetadataQueriesRepeated': 0, 'pinnedHeaderInputs': headers,
        'productionDescriptionQueriesRepeated': 0, 'testableDescriptionQueriesRepeated': 0}
    prepared['resumedProducts'] = {phase: restore_product(root, phase, prepared, origin)
        for phase, origin in binding['resumedProducts'].items() if phase not in DRIVER_INPUT_ORIGINS}
    partial = binding['resumedProducts'].get('production-cache')
    prepared['partialDriverCaches'] = restore_partial_driver_cache(root, prepared, partial) if partial else None
    printed = binding['resumedProducts'].get('production-plan')
    prepared['retainedProductionPlanning'] = restore_printed_driver_plan(root, prepared, printed) if printed else None
    if printed: prepared['partialDriverCaches'] = prepared['retainedProductionPlanning']['cacheInput']
    prepared['clangBuildSessions'] = create_clang_sessions(root, plans, temporary)
    write(root / 'prepared.json', prepared)


def recipe_identity(prepared, phase):
    plan = prepared['plans'][phase]
    value = {'driver': plan['driver'], 'operations': plan['operations'],
        'nativeSourceObjects': prepared['nativeSourceObjects'], 'appSourceSHA': prepared['appSourceSHA'],
        'compilerSHA256': prepared['compilerSHA256']}
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def clang_session_paths(plans, temporary):
    require(set(plans) == {'production', 'testable', 'tests'}, 'Incomplete Clang session driver inventory')
    paths = {}
    for phase, plan in plans.items():
        profile = 'production' if phase == 'production' else 'testable'
        arena = temporary / 'app-build-plan-evidence' / profile / 'derived-data'
        require(plan['operations']['arena'] == str(arena), 'Clang session arena differs')
        argv = plan['driver']['argv']
        indexes = [index for index, value in enumerate(argv) if value == '-clang-build-session-file']
        require(len(indexes) == 1 and indexes[0] + 1 < len(argv), 'Missing or ambiguous Clang build session input')
        path = arena / 'ModuleCache.noindex/Session.modulevalidation'
        require(argv[indexes[0] + 1] == str(path), 'Clang build session path escapes its exact arena')
        paths[profile] = path
    return paths


def create_clang_sessions(root, plans, temporary):
    result = {}
    paths = clang_session_paths(plans, temporary)
    for path in paths.values():
        require(not path.exists() and not path.is_symlink()
            and path.parent.resolve() == path.parent and path.parent.is_relative_to(temporary),
            'Clang build session path is occupied or linked')
    for profile, path in paths.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        timestamp = time.time()
        require(math.isfinite(timestamp) and timestamp > 0, 'Invalid Clang build session time')
        raw = f'{timestamp}: Module build session file for module cache at {path.parent}\n'.encode()
        with path.open('xb') as stream: stream.write(raw)
        result[profile] = {'path': str(path), 'sha256': capture.sha(path), 'bytes': len(raw),
            'mtimeNS': path.stat().st_mtime_ns, 'sessionTimestamp': timestamp,
            'driverRoles': ['production'] if profile == 'production' else ['testable', 'tests'],
            'sourceSHA': os.environ['GITHUB_SHA'], 'runID': int(os.environ['GITHUB_RUN_ID']), 'attempt': 1}
    write(root / 'clang-build-sessions.json', result)
    return result


def product_archive(folder, phase, artifact):
    outer = folder / 'original.zip'
    download(artifact, outer)
    archive_path = folder / 'product.zip'
    with zipfile.ZipFile(outer) as archive:
        require(archive.namelist() == [phase + '-products.zip'] and archive.testzip() is None
            and archive.getinfo(phase + '-products.zip').file_size <= 12 * 1024**3,
            'Target product outer archive differs')
        with archive.open(phase + '-products.zip') as source, archive_path.open('xb') as destination:
            shutil.copyfileobj(source, destination, 1024 * 1024)
    return archive_path


def restore_partial_driver_cache(root, prepared, origin):
    return restore_driver_cache(root, prepared, origin, 'production-cache')


def restore_driver_cache(root, prepared, origin, role):
    require(role in DRIVER_INPUT_ORIGINS, 'Unknown partial driver input role')
    specification = DRIVER_INPUT_ORIGINS[role]
    folder = root / 'partial-driver-cache'; folder.mkdir()
    path = product_archive(folder, 'production', origin['artifact'])
    restored = {}
    plan = prepared['plans']['production']
    arena = Path(plan['operations']['arena'])
    cache_root = arena / 'ModuleCache.noindex/1U72Z291X4DNG'
    require(capture.sha(path) == specification['nestedSHA256'],
        'Actual partial driver nested archive changed')
    with zipfile.ZipFile(path) as archive:
        entries = archive.infolist()
        require(len(entries) <= 200_000 and sum(item.file_size for item in entries) <= 12 * 1024**3
            and len({item.filename.casefold() for item in entries}) == len(entries) and archive.testzip() is None,
            'Partial driver cache archive inventory, bounds or CRC differ')
        raw = archive_bytes(archive, 'product-receipt.json', 16 * 1024**2)
        require(hashlib.sha256(raw).hexdigest() == origin['selected']['receiptSHA256'], 'Partial driver cache receipt changed')
        receipt = json.loads(raw)
        require(receipt['schema'] == 'native-app-target-product/v1' and receipt['phase'] == 'production'
            and receipt['sourceSHA'] == origin['selected']['sourceSHA'] and receipt['runID'] == origin['selected']['runID']
            and receipt['attempt'] == 1 and receipt['appSourceSHA'] == prepared['appSourceSHA']
            and receipt['nativeSourceObjects'] == prepared['nativeSourceObjects'] and receipt['arena'] == str(arena)
            and receipt['compilerSHA256'] == prepared['compilerSHA256']
            and receipt['recipeSHA256'] == recipe_identity(prepared, 'production')
            and receipt['state'] == {'compileComplete': False, 'linkComplete': False, 'compilerExecutions': 0, 'resumed': False},
            'Partial driver cache cannot claim a completed App compiler product')
        require(len(receipt['files']) == specification['files'], 'Actual partial driver cache inventory changed')
        for name, item in receipt['files'].items():
            relative = Path(name)
            require(str(relative) == name and not relative.is_absolute() and '..' not in relative.parts
                and '\\' not in name and '\0' not in name and item['kind'] == 'file'
                and type(item['mode']) is int and item['mode'] & ~0o777 == 0, 'Unsafe partial driver cache file')
            member = archive.getinfo('outputs/' + name)
            require(member.file_size == item['bytes'], 'Partial driver cache file size changed')
            with archive.open(member) as stream:
                require(hashlib.file_digest(stream, 'sha256').hexdigest() == item['sha256'], 'Partial driver cache bytes changed')
            destination = arena / relative
            if destination.suffix != '.pcm':
                continue
            require(destination.parent == cache_root
                and not destination.exists() and not destination.is_symlink()
                and destination.parent.resolve() == destination.parent, 'Partial PCM cache escapes or is occupied')
            with archive.open(member) as stream:
                require(stream.read(4) == b'CPCH', 'Partial cache is not a Clang PCM')
            destination.parent.mkdir(parents=True, exist_ok=True)
            with archive.open(member) as source, destination.open('xb') as output:
                shutil.copyfileobj(source, output, 1024 * 1024)
            os.chmod(destination, item['mode'])
            actual = {'kind': 'file', 'sha256': capture.sha(destination), 'bytes': destination.stat().st_size,
                'mode': stat.S_IMODE(destination.stat().st_mode)}
            require(actual == item, 'Restored partial PCM bytes, size or permissions differ')
            restored[name] = actual
        require(len(restored) == 108, 'Actual partial PCM candidate inventory changed')
    result = {'schema': 'native-app-partial-driver-cache/v1', 'origin': origin,
        'recipeSHA256': receipt['recipeSHA256'], 'restoredPCMCandidates': restored,
        'originalNestedArchiveSHA256': capture.sha(path),
        'successfulAppCompilationClaimed': False, 'currentCompilerValidationRequired': True}
    write(folder / 'candidate-receipt.json', result)
    return result


def restore_planning_files(archive, records, destination):
    require(isinstance(records, dict) and len(records) == 6, 'Retained driver planning temporary inventory changed')
    result = {}
    for name, item in records.items():
        relative = Path(name)
        require(str(relative) == name and not relative.is_absolute() and '..' not in relative.parts
            and relative.parent == Path('tmp/TemporaryDirectory.pzfKPD') and '\\' not in name and '\0' not in name
            and item['kind'] == 'file', 'Retained planning temporary input escapes its exact namespace')
        entry = archive.getinfo('evidence/' + name)
        require(stat.S_ISREG(entry.external_attr >> 16) and stat.S_IMODE(entry.external_attr >> 16) == 0o644
            and entry.file_size == item['bytes'] and item['bytes'] <= 16 * 1024**2,
            'Retained planning temporary mode or size differs')
        target = destination / relative
        require(not target.exists() and not target.is_symlink() and target.parent.resolve() == target.parent,
            'Retained planning temporary target is occupied or linked')
        target.parent.mkdir(parents=True, exist_ok=True)
        with archive.open(entry) as source, target.open('xb') as output:
            shutil.copyfileobj(source, output, 1024 * 1024)
        os.chmod(target, 0o644)
        actual = {'kind': 'file', 'sha256': capture.sha(target), 'bytes': target.stat().st_size,
            'mode': stat.S_IMODE(target.stat().st_mode)}
        require({key: actual[key] for key in item} == item and actual['mode'] == 0o644,
            'Restored planning temporary bytes, size or mode differ')
        result[name] = actual
    return result


def restore_printed_driver_plan(root, prepared, origin):
    specification = DRIVER_INPUT_ORIGINS['production-plan']
    require(origin['selected'] == specification['selected'], 'Unqualified retained printed driver producer')
    cache = restore_driver_cache(root, prepared, origin, 'production-plan')
    folder = root / 'partial-driver-cache'
    with zipfile.ZipFile(folder / 'product.zip') as archive:
        receipt = json.loads(archive_bytes(archive, 'product-receipt.json', 16 * 1024**2))
        raw = archive_bytes(archive, 'evidence/driver-jobs.stdout', 16 * 1024**2)
        require(len(raw) == 997274 and hashlib.sha256(raw).hexdigest() == specification['stdoutSHA256']
            and archive_bytes(archive, 'evidence/driver-jobs.stderr') == b''
            and json.loads(archive_bytes(archive, 'evidence/driver-jobs.exit.json')) == {'exitCode': 0}
            and json.loads(archive_bytes(archive, 'evidence/driver-jobs.argv.json'))
                == [*prepared['plans']['production']['driver']['argv'], '-driver-print-jobs'],
            'Retained printed driver command, original exit or bytes differ')
        jobs = [shlex.split(line) for line in raw.decode().splitlines() if line.strip()]
        require(len(jobs) == 115 and not any('build-session-timestamp' in argument for job in jobs for argument in job),
            'Retained printed driver graph or session timestamp boundary changed')
        inputs = restore_planning_files(archive, receipt['temporaryFiles'], folder / 'planning-inputs')
    (folder / 'driver-jobs-original.stdout').write_bytes(raw)
    result = {'schema': 'native-app-retained-printed-driver-plan/v1', 'origin': origin,
        'recipeSHA256': recipe_identity(prepared, 'production'), 'stdoutSHA256': specification['stdoutSHA256'],
        'stdoutPath': str(folder / 'driver-jobs-original.stdout'), 'temporaryRoot': str(folder / 'planning-inputs'),
        'temporaryFiles': inputs, 'cacheInput': cache, 'originalPlanningExitCode': 0,
        'currentPlanningExecutions': 0, 'frontendScopeQualified': False, 'successfulAppCompilationClaimed': False}
    write(folder / 'printed-plan-receipt.json', result)
    return result


def stage_printed_driver_plan(folder, prepared):
    planning = prepared['retainedProductionPlanning']
    require(planning['schema'] == 'native-app-retained-printed-driver-plan/v1'
        and planning['recipeSHA256'] == recipe_identity(prepared, 'production')
        and planning['origin']['selected'] == DRIVER_INPUT_ORIGINS['production-plan']['selected'],
        'Retained printed driver context changed before scope validation')
    for name, item in planning['temporaryFiles'].items():
        relative = Path(name)
        require(relative.parent == Path('tmp/TemporaryDirectory.pzfKPD') and str(relative) == name,
            'Retained driver temporary namespace changed before planning')
        source = Path(planning['temporaryRoot']) / relative
        target = folder / relative
        require(source.is_file() and not source.is_symlink() and source.parent.resolve() == source.parent
            and capture.sha(source) == item['sha256'] and source.stat().st_size == item['bytes']
            and stat.S_IMODE(source.stat().st_mode) == item['mode']
            and not target.exists() and not target.is_symlink() and target.parent.resolve() == target.parent,
            'Retained driver temporary input changed or target is occupied')
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target); os.chmod(target, item['mode'])
        require(capture.sha(target) == item['sha256'] and target.stat().st_size == item['bytes']
            and stat.S_IMODE(target.stat().st_mode) == item['mode'], 'Staged retained driver temporary bytes differ')
    source = Path(planning['stdoutPath'])
    require(source.is_file() and not source.is_symlink() and capture.sha(source) == planning['stdoutSHA256'],
        'Retained printed driver bytes changed before scope validation')
    raw = source.read_bytes()
    (folder / 'driver-jobs.stdout').write_bytes(raw)
    write(folder / 'driver-jobs-reused.json', {'schema': planning['schema'], 'origin': planning['origin'],
        'stdoutSHA256': planning['stdoutSHA256'], 'temporaryFiles': planning['temporaryFiles'],
        'originalPlanningExitCode': 0, 'currentPlanningExecutions': 0,
        'newSession': prepared['clangBuildSessions']['production']})
    return raw.decode()


def driver_planning_jobs(folder, phase, prepared, driver, environment):
    if phase == 'production' and prepared.get('retainedProductionPlanning'):
        return stage_printed_driver_plan(folder, prepared)
    return logged(folder, 'driver-jobs', [*driver['argv'], '-driver-print-jobs'], environment, driver['cwd'], 600)


def verify_partial_driver_cache(root, prepared):
    cache = prepared.get('partialDriverCaches')
    if cache is None: return
    require(cache['schema'] == 'native-app-partial-driver-cache/v1'
        and cache['successfulAppCompilationClaimed'] is False and cache['currentCompilerValidationRequired'] is True
        and cache['recipeSHA256'] == recipe_identity(prepared, 'production'), 'Partial cache planning identity differs')
    arena = Path(prepared['plans']['production']['operations']['arena'])
    cache_root = arena / 'ModuleCache.noindex/1U72Z291X4DNG'
    actual = {}
    expected = cache['restoredPCMCandidates']
    require(len(expected) == 108 and cache_root.is_dir() and not cache_root.is_symlink()
        and {path.relative_to(arena).as_posix() for path in cache_root.iterdir()} == set(expected),
        'Partial cache input inventory changed before planning')
    for name, item in expected.items():
        path = arena / name
        require(path.parent == cache_root and path.is_file() and not path.is_symlink()
            and path.parent.resolve() == path.parent, 'Partial cache input path changed before planning')
        actual[name] = {'kind': 'file', 'sha256': capture.sha(path), 'bytes': path.stat().st_size,
            'mode': stat.S_IMODE(path.stat().st_mode)}
        require(actual[name] == item, 'Partial cache input bytes, size or permissions changed before planning')
    write(root / 'partial-driver-cache-before-planning.json', {'schema': 'native-app-partial-cache-planning-input/v1',
        'sourceSHA': prepared['sourceSHA'], 'runID': int(os.environ['GITHUB_RUN_ID']),
        'recipeSHA256': cache['recipeSHA256'], 'originalProducer': cache['origin'], 'actualFiles': actual})


def restore_product(root, phase, prepared, origin):
    folder = root / 'resumed' / phase; folder.mkdir(parents=True)
    archive_path = product_archive(folder, phase, origin['artifact'])
    plan = prepared['plans'][phase]; arena = Path(plan['operations']['arena'])
    driver = plan['driver']; objects = Path(driver['argv'][driver['argv'].index('-emit-module-path') + 1]).parent
    links = [item for item in plan['operations']['links'] if item['targetGUID'] == driver['targetGUID']]
    require(len(links) == 1, 'Resumed target linker identity is ambiguous')
    output = Path(links[0]['output'])
    allowed = [objects, arena / 'SDKExplicitPrecompiledModules', arena / 'ModuleCache.noindex',
        arena / 'Intermediates.noindex/SwiftExplicitPrecompiledModules', Path(str(output) + '.dSYM')]
    allowed += [Path(item['output']) for category in ('copies', 'headers') for item in plan['operations'][category]
        if item['targetGUID'] == driver['targetGUID'] and (category == 'headers' or item['kind'] == 'swift-module')]
    if phase == 'tests': allowed.append(output.parents[2])
    with zipfile.ZipFile(archive_path) as archive:
        entries = archive.infolist()
        require(len(entries) <= 200_000 and sum(item.file_size for item in entries) <= 12 * 1024**3
            and len({item.filename.casefold() for item in entries}) == len(entries) and archive.testzip() is None,
            'Resumed compiler archive bounds, paths or CRC differ')
        raw = archive_bytes(archive, 'product-receipt.json', 16 * 1024**2)
        require(hashlib.sha256(raw).hexdigest() == origin['selected']['receiptSHA256'], 'Resumed product receipt differs')
        receipt = json.loads(raw)
        require(receipt['schema'] == 'native-app-target-product/v1' and receipt['phase'] == phase
            and receipt['sourceSHA'] == origin['selected']['sourceSHA'] and receipt['runID'] == origin['selected']['runID']
            and receipt['attempt'] == 1 and receipt['appSourceSHA'] == prepared['appSourceSHA']
            and receipt['nativeSourceObjects'] == prepared['nativeSourceObjects'] and receipt['arena'] == str(arena)
            and receipt['compilerSHA256'] == prepared['compilerSHA256'] and receipt['recipeSHA256'] == recipe_identity(prepared, phase)
            and receipt['state']['compileComplete'] is True, 'Resumed compiler product identity or successful compilation differs')
        expected = {'product-receipt.json'} | {'outputs/' + name for name in receipt['files']}
        require(all(item.filename in expected or item.filename.startswith('evidence/') for item in entries)
            and expected <= {item.filename for item in entries}, 'Resumed compiler archive inventory differs')
        pending_links = []
        for name, item in receipt['files'].items():
            relative = Path(name)
            require(not relative.is_absolute() and '..' not in relative.parts and str(relative) == name
                and '\\' not in name, 'Resumed output path is unsafe')
            destination = arena / relative
            require(destination == output or any(destination.is_relative_to(path) for path in allowed), 'Resumed output escapes this module')
            require(type(item['mode']) is int and item['mode'] & ~0o777 == 0, 'Invalid resumed output permissions')
            if destination == arena / 'ModuleCache.noindex/Session.modulevalidation': continue
            if not receipt['state']['linkComplete'] and destination.is_relative_to(arena / 'Products'): continue
            if item['kind'] == 'symlink':
                target = item['target']
                require(isinstance(target, str) and not Path(target).is_absolute()
                    and destination.parent.joinpath(target).resolve().is_relative_to(arena.resolve()), 'Resumed link escapes its arena')
                require(archive.read('outputs/' + name).decode() == target, 'Resumed link bytes differ')
                pending_links.append((destination, target))
            else:
                require(item['kind'] == 'file' and archive.getinfo('outputs/' + name).file_size == item['bytes'], 'Resumed output size differs')
                destination.parent.mkdir(parents=True, exist_ok=True)
                require(not destination.is_symlink() and destination.parent.resolve().is_relative_to(arena.resolve()), 'Resumed output parent is linked')
                with archive.open('outputs/' + name) as source, destination.open('wb') as output_stream:
                    shutil.copyfileobj(source, output_stream, 1024 * 1024)
                os.chmod(destination, item['mode'])
                require(capture.sha(destination) == item['sha256'], 'Resumed compiler output bytes differ')
        for destination, target in pending_links:
            destination.parent.mkdir(parents=True, exist_ok=True)
            if destination.is_symlink(): require(os.readlink(destination) == target, 'Occupied resumed link differs')
            else:
                require(not destination.exists(), 'Resumed link output is occupied')
                destination.symlink_to(target)
        if receipt['state'].get('linkerCommandSucceeded'):
            unsigned = folder / 'linker-output-unsigned'
            with archive.open('evidence/linker-output-unsigned') as source, unsigned.open('xb') as target:
                shutil.copyfileobj(source, target, 1024 * 1024)
            require(capture.sha(unsigned) == receipt['state']['unsignedLinkSHA256'], 'Passed unsigned linker output differs')
    write(folder / 'receipt.json', receipt)
    return {'receipt': receipt, 'origin': origin, 'folder': str(folder)}


def checkpoint(root, phase, prepared, state):
    plan = prepared['plans'][phase]
    arena = Path(plan['operations']['arena'])
    driver = plan['driver']
    objects = Path(driver['argv'][driver['argv'].index('-emit-module-path') + 1]).parent
    roots = [objects, arena / 'SDKExplicitPrecompiledModules', arena / 'ModuleCache.noindex',
        arena / 'Intermediates.noindex/SwiftExplicitPrecompiledModules']
    roots += [Path(item['output']) for category in ('copies', 'headers') for item in plan['operations'][category]
        if item['targetGUID'] == driver['targetGUID'] and (category == 'headers' or item['kind'] == 'swift-module')]
    linked = state.get('linkedOutput')
    if linked:
        if phase == 'tests': roots.append(Path(linked).parents[2])
        elif Path(linked).is_file(): roots.append(Path(linked))
        roots.append(Path(str(linked) + '.dSYM'))
    files = {}
    for folder in roots:
        paths = [folder] if folder.is_file() else folder.rglob('*') if folder.is_dir() else []
        for path in paths:
            if path.is_symlink():
                require(path.resolve().is_relative_to(arena.resolve()), 'Compiler output link escapes its arena')
                target = os.readlink(path)
                require(not Path(target).is_absolute(), 'Compiler output link must remain relative')
                files[path.relative_to(arena).as_posix()] = {'kind': 'symlink', 'target': target,
                    'mode': stat.S_IMODE(path.lstat().st_mode)}
            elif path.is_file():
                require(path.is_relative_to(arena) and path.resolve().is_relative_to(arena.resolve()), 'Compiler output escapes its arena')
                files[path.relative_to(arena).as_posix()] = {'kind': 'file', 'sha256': capture.sha(path),
                    'bytes': path.stat().st_size, 'mode': stat.S_IMODE(path.stat().st_mode)}
    receipt = {'schema': 'native-app-target-product/v1', 'phase': phase, 'sourceSHA': prepared['sourceSHA'],
        'appSourceSHA': prepared['appSourceSHA'], 'nativeSourceObjects': prepared['nativeSourceObjects'],
        'runID': int(os.environ['GITHUB_RUN_ID']), 'attempt': 1, 'recipeSHA256': recipe_identity(prepared, phase),
        'compilerSHA256': prepared['compilerSHA256'], 'arena': str(arena), 'state': state, 'files': files,
        'functionalAcceptance': False, 'publicationAuthorised': False}
    receipt['partialDriverCacheInput'] = prepared.get('partialDriverCaches') if phase == 'production' else None
    folder = root / phase
    temporary_files = {}
    for path in (folder / 'tmp').rglob('*'):
        if path.is_symlink():
            temporary_files[path.relative_to(folder).as_posix()] = {'kind': 'symlink', 'target': os.readlink(path)}
        elif path.is_file():
            temporary_files[path.relative_to(folder).as_posix()] = {'kind': 'file', 'sha256': capture.sha(path), 'bytes': path.stat().st_size}
    receipt['temporaryFiles'] = temporary_files
    write(folder / 'product-receipt.json', receipt)
    archive_path = root / (phase + '-products.zip')
    with zipfile.ZipFile(archive_path, 'x', compression=zipfile.ZIP_DEFLATED, compresslevel=1) as archive:
        archive.write(folder / 'product-receipt.json', 'product-receipt.json')
        for name in sorted(files):
            item = files[name]
            if item['kind'] == 'symlink':
                info = zipfile.ZipInfo('outputs/' + name)
                info.create_system = 3; info.external_attr = (stat.S_IFLNK | item['mode']) << 16
                archive.writestr(info, item['target'].encode())
            else: archive.write(arena / name, 'outputs/' + name)
        for path in sorted(folder.rglob('*')):
            name = path.relative_to(folder).as_posix()
            if path.is_symlink():
                info = zipfile.ZipInfo('evidence/' + name)
                info.create_system = 3; info.external_attr = (stat.S_IFLNK | 0o777) << 16
                archive.writestr(info, os.readlink(path).encode())
            elif path.is_file() and path != folder / 'product-receipt.json': archive.write(path, 'evidence/' + name)
        origin = root / 'resumed' / phase / 'product.zip'
        if state['resumed']:
            archive.write(root / 'resumed' / phase / 'original.zip', 'evidence/origin-original-artifact.zip')
            with zipfile.ZipFile(origin) as previous:
                for item in previous.infolist():
                    if item.filename == 'product-receipt.json' or item.filename.startswith('evidence/'):
                        copied = zipfile.ZipInfo('evidence/origin-evidence/' + item.filename)
                        copied.external_attr = item.external_attr; copied.create_system = item.create_system
                        archive.writestr(copied, previous.read(item))
    write(root / (phase + '-archive.json'), {'sha256': capture.sha(archive_path), 'bytes': archive_path.stat().st_size,
        'receiptSHA256': capture.sha(folder / 'product-receipt.json'), 'compileComplete': state['compileComplete'],
        'linkComplete': state['linkComplete']})


def execute(root, phase):
    native_guard(root)
    prepared = json.loads((root / 'prepared.json').read_text())
    require(prepared['sourceSHA'] == os.environ['GITHUB_SHA'] and not capture.git('status', '--porcelain', '--untracked-files=no'),
        'Prepared compiler source changed')
    if phase == 'tests':
        previous = json.loads((root / 'testable/product-receipt.json').read_text())
        require(previous['state']['compileComplete'] and previous['state']['linkComplete'], 'Tests require the new testable App module')
    plan = prepared['plans'][phase]
    driver, operations = plan['driver'], plan['operations']
    profile = 'production' if phase == 'production' else 'testable'
    session = prepared['clangBuildSessions'][profile]
    session_path = clang_session_paths(prepared['plans'], Path(os.environ['RUNNER_TEMP']).resolve())[profile]
    require(session['path'] == str(session_path) and session_path.is_file() and not session_path.is_symlink()
        and capture.sha(session_path) == session['sha256'] and session_path.stat().st_mtime_ns == session['mtimeNS'],
        'Clang build session changed after preparation')
    if phase == 'production': verify_partial_driver_cache(root, prepared)
    require(capture.sha(Path(driver['argv'][0])) == prepared['compilerSHA256'], 'Compiler changed after preparation')
    folder = root / phase; folder.mkdir()
    state = {'compileComplete': False, 'linkComplete': False, 'compilerExecutions': 0, 'resumed': False}
    resumed = prepared['resumedProducts'].get(phase)
    if resumed:
        state.update(resumed['receipt']['state'])
        state.update(compilerExecutions=0, resumed=True, resumedProducer=resumed['origin'])
    environment = dict(prepared['environment'], **driver['environment'])
    task_temporary = folder / 'tmp'; task_temporary.mkdir()
    environment['TMPDIR'] = str(task_temporary)
    write(folder / 'STARTED.json', {'runID': os.environ['GITHUB_RUN_ID'], 'phase': phase,
        'recipeSHA256': recipe_identity(prepared, phase), 'oneShot': True})
    try:
        argv = driver['argv']
        objects = Path(argv[argv.index('-emit-module-path') + 1]).parent
        objects.mkdir(parents=True, exist_ok=True)
        if not state['compileComplete']:
            require(all(capture.sha(Path(path)) == digest for path, digest in prepared['pinnedHeaderInputs'].items()),
                'Pinned compiler header bytes changed after preparation')
            source_lists = [value[1:] for value in argv if value.startswith('@')]
            require(len(source_lists) == 1, 'Missing unique actual Swift source list')
            sources = shlex.split(Path(source_lists[0]).read_text())
            jobs = driver_planning_jobs(folder, phase, prepared, driver, environment)
            if phase == 'production' and prepared.get('retainedProductionPlanning'):
                state['retainedDriverPlanningOrigin'] = prepared['retainedProductionPlanning']['origin']
            proof = validate_frontend_jobs(jobs, driver, sources, operations['arena'], str(Path.cwd().resolve()), str(task_temporary), prepared['pinnedHeaderInputs'])
            consumed = folder / 'consumed-inputs'; consumed.mkdir()
            for item in proof['consumedInputs']:
                source = Path(item['path'])
                require(source.stat().st_size == item['bytes'] and capture.sha(source) == item['sha256'],
                    'Frontend auxiliary input changed after scope validation')
                output = consumed / item['sha256']
                if not output.exists(): shutil.copyfile(source, output)
            write(folder / 'frontend-jobs.json', proof)
            state['compilerExecutions'] += 1
            logged(folder, 'compile', argv, environment, driver['cwd'], 900)
            state['compileComplete'] = True
            state['compilerOrigin'] = {'runID': int(os.environ['GITHUB_RUN_ID']), 'attempt': 1,
                'sourceSHA': prepared['sourceSHA'], 'job': 'app-target-build'}
        for item in operations['headers']:
            if item['targetGUID'] != driver['targetGUID']: continue
            from native_app_target_recipe import generated_header
            source, output = Path(item['source']), Path(item['output'])
            require(source.is_file() and not source.is_symlink() and not output.is_symlink(), 'Compiled Swift header is missing')
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_bytes(generated_header(source.read_bytes(), item['single']))
        for item in operations['copies']:
            if item['kind'] != 'swift-module' or item['targetGUID'] != driver['targetGUID']: continue
            source, output = Path(item['source']), Path(item['output'])
            require(source.is_file() and not source.is_symlink() and not output.is_symlink(), 'New Swift module product is missing or linked')
            if output.exists(): require(capture.sha(output) == capture.sha(source), 'Occupied Swift module product differs')
            else:
                output.parent.mkdir(parents=True, exist_ok=True); shutil.copyfile(source, output)
        if state['linkComplete']:
            unsigned = Path(resumed['folder']) / 'linker-output-unsigned'
            shutil.copyfile(unsigned, folder / 'linker-output-unsigned')
            return
        links = [item for item in operations['links'] if item['targetGUID'] == driver['targetGUID']]
        require(len(links) == 1, 'Missing unique module linker command')
        link = links[0]; output = Path(link['output'])
        require(link['argv'][0] in {driver['argv'][0], str(Path(driver['argv'][0]).parent / 'clang')}, 'Unreviewed module linker')
        output.parent.mkdir(parents=True, exist_ok=True)
        state['linkedOutput'] = str(output)
        link_environment = dict(prepared['environment'], **link['environment'], TMPDIR=str(task_temporary))
        if state.get('linkerCommandSucceeded'):
            unsigned = Path(resumed['folder']) / 'linker-output-unsigned'
            shutil.copyfile(unsigned, output)
            os.chmod(output, 0o755)
        else:
            logged(folder, 'link', link['argv'], link_environment, link['cwd'], 300)
        require(output.is_file(), 'Linker did not produce its declared output')
        state['linkerCommandSucceeded'] = True
        shutil.copyfile(output, folder / 'linker-output-unsigned')
        state['unsignedLinkSHA256'] = capture.sha(folder / 'linker-output-unsigned')
        image = logged(folder, 'image', ['otool', '-hvL', str(output)], prepared['environment'])
        expected_type = {'production': 'EXECUTE', 'testable': 'OBJECT', 'tests': 'BUNDLE'}[phase]
        require('ARM64' in image and expected_type in image, 'New native image architecture or type differs')
        if phase != 'testable': require('@rpath/libNexGenEngine.dylib' in image, 'New native image lost the retained Engine binding')
        image_uuid = logged(folder, 'uuid', ['xcrun', 'dwarfdump', '--uuid', str(output)], prepared['environment'])
        state['imageUUID'] = image_uuid
        if phase == 'tests':
            bundle = output.parents[2]
            retained.sign_copied_bundle(bundle, lambda argv, label, timeout=180:
                logged(folder, label, argv, prepared['environment'], timeout=timeout))
        if phase == 'production':
            logged(folder, 'dsym', ['xcrun', 'dsymutil', str(output), '-o', str(output) + '.dSYM'], prepared['environment'], timeout=300)
            state['dsymComplete'] = True
            state['dsymUUID'] = logged(folder, 'dsym-uuid', ['xcrun', 'dwarfdump', '--uuid', str(output) + '.dSYM'], prepared['environment'])
            uuid = lambda text: re.findall(r'UUID: ([A-Fa-f0-9-]{36}) \(arm64\)', text)
            require(len(uuid(image_uuid)) == 1 and uuid(image_uuid) == uuid(state['dsymUUID']), 'App and debug symbol UUIDs differ')
        state['linkComplete'] = True
    finally:
        checkpoint(root, phase, prepared, state)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('action', choices=('bind', 'prepare', 'production', 'testable', 'tests'))
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--source-binding', type=Path)
    args = parser.parse_args()
    if args.action == 'bind': bind(args.output)
    elif args.action == 'prepare':
        require(args.source_binding is not None, 'Exact source binding required')
        prepare(args.output, args.source_binding)
    else: execute(args.output, args.action)
