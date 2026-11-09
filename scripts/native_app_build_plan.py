import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import time
import zipfile


MODE = 'native-app-build-plan'
PATHS = {'.github/workflows/diagnostic-acceptance.yml', 'scripts/native_app_build_plan.py',
         'scripts/test_native_app_build_plan.py'}
INPUT_OBJECTS = ('Sources', 'Engine', 'Tests', 'Package.swift', 'Package.resolved', 'Runtime', 'Metal', 'Vendor', 'plugins')
MANIFEST_HASHES = {'Package.swift': '8b9c4bef0703bf4456ab04a7dbe3f8bd551b8807df3642243660b12cd38edc76',
    'Package.resolved': 'be75aa459377d4eb8c025787071fb492c6565c678eeb3cbddf702d363f90dc24',
    'Engine/Package.swift': '4dba75ab153ccc10a4d26546ad3bbe9ce07ae2d585238f02d8010d6ef425760c'}


def require(value, message):
    if not value:
        raise ValueError(message)


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def write(path, value):
    with path.open('x') as stream:
        json.dump(value, stream, sort_keys=True, indent=2, allow_nan=False)
        stream.write('\n'); stream.flush(); os.fsync(stream.fileno())


def command(argv, timeout=45):
    return subprocess.check_output(argv, stdin=subprocess.DEVNULL, timeout=timeout)


def git(*args):
    return command(['git', *args]).decode().strip()


def api(route):
    return json.loads(command(['gh', 'api', '-H', 'Cache-Control: no-cache',
        'repos/iret77/nexgenvideo/' + route + ('&' if '?' in route else '?') + 'fresh=' + str(time.time_ns())]))


def validate_inputs(env):
    require(env.get('KIND', env.get('REPLAY_KIND')) == MODE, 'Wrong build-plan role')
    pairs = {'runID': ('PRODUCER_RUN', r'[1-9][0-9]*'), 'sourceSHA': ('PRODUCER_SHA', r'[a-f0-9]{40}'),
        'artifactID': ('DIAGNOSTIC_ID', r'[1-9][0-9]*'), 'artifactSHA256': ('DIAGNOSTIC_DIGEST', r'[a-f0-9]{64}'),
        'verifiedPRRunID': ('VERIFIED_PR', r'[1-9][0-9]*')}
    result = {}
    for name, (key, pattern) in pairs.items():
        require(isinstance(env.get(key), str) and re.fullmatch(pattern, env[key]), 'Missing or invalid ' + key)
        result[name] = int(env[key]) if name.endswith('ID') else env[key]
    source = env.get('EXTRA_SOURCE', env.get('PRODUCT_SHA', ''))
    require(isinstance(source, str) and re.fullmatch(r'[a-f0-9]{40}', source)
        and env.get('SCALE') == '1', 'Missing App source or wrong scale')
    result['appSourceSHA'] = source
    resume_id = env.get('EXTRA_FAILURE') or env.get('FAILURE_ID', '')
    resume_digest = env.get('EXTRA_FAILURE_SHA') or env.get('FAILURE_DIGEST', '')
    if resume_id or resume_digest:
        require(re.fullmatch(r'[1-9][0-9]*', resume_id or '')
            and re.fullmatch(r'[a-f0-9]{64}', resume_digest or ''), 'Incomplete prior capture selectors')
        for key in ('EXTRA_FAILURE', 'FAILURE_ID'):
            require(not env.get(key) or env[key] == resume_id, 'Conflicting prior capture identity')
        for key in ('EXTRA_FAILURE_SHA', 'FAILURE_DIGEST'):
            require(not env.get(key) or env[key] == resume_digest, 'Conflicting prior capture digest')
        result.update(resumeArtifactID=int(resume_id), resumeArtifactSHA256=resume_digest)
    unused = ('DMG_DIGEST', 'JOURNEY_JOB', 'JOURNEY_ARTIFACT', 'JOURNEY_DIGEST', 'EXTRA_PRODUCTS',
        'EXTRA_PRODUCTS_SHA', 'PRODUCTS_ID', 'PRODUCTS_DIGEST', 'RUNTIME_FAILURE_BINDING', 'PACKAGING_PRODUCER_SOURCE',
        'PACKAGING_PROVENANCE_ARTIFACT_ID', 'PACKAGING_PROVENANCE_ARTIFACT_SHA256')
    require(not any(env.get(key) for key in unused), 'Unrelated selectors cannot be ignored by build planning')
    return result


def bind(root):
    selected = validate_inputs(os.environ)
    bind_sources(root, selected, PATHS)


def bind_sources(root, selected, allowed_paths):
    from verified_pr_source_checks import original_receipt, verify_run_identity, verify_steps, test_completion
    require(os.environ.get('GITHUB_REPOSITORY') == 'iret77/nexgenvideo', 'Wrong repository')
    head = os.environ['GITHUB_SHA']
    require(git('rev-parse', 'HEAD') == head and not git('status', '--porcelain', '--untracked-files=no'), 'Dirty source')
    subprocess.run(['git', 'merge-base', '--is-ancestor', selected['appSourceSHA'], head], check=True, timeout=30)
    changed = git('diff', '--name-only', '--no-renames', selected['appSourceSHA'], head).splitlines()
    require(changed and set(changed) <= allowed_paths, 'App, package or unrelated source changed')
    objects = {name: git('rev-parse', 'HEAD:' + name) for name in INPUT_OBJECTS}
    require(objects == {name: git('rev-parse', selected['appSourceSHA'] + ':' + name) for name in INPUT_OBJECTS},
        'The native source graph differs from the reviewed App')
    for name, digest in MANIFEST_HASHES.items():
        require(sha(Path(name)) == digest, 'Pinned manifest or dependency graph changed: ' + name)
    root.mkdir(parents=True, exist_ok=False)
    current_path = Path(os.environ['RUNNER_TEMP']) / 'transport-source-proof'
    current = json.loads((current_path / 'receipt.json').read_text())
    require(current['schema'] == 'core-pr-source-composition/v1' and current['sourceSHA'] == head
        and current['originalRun']['id'] == selected['verifiedPRRunID']
        and current['originalPR']['merged'] and current['originalPR']['merge_commit_sha'] == head,
        'Complete current merged source composition missing')
    run = api('actions/runs/' + str(selected['runID']))
    jobs = api(f"actions/runs/{selected['runID']}/attempts/1/jobs?per_page=100")
    job = verify_run_identity(run, jobs, selected['runID'])
    require(run['head_sha'] == selected['sourceSHA'], 'Original App source run differs')
    artifact = api('actions/artifacts/' + str(selected['artifactID']))
    require(artifact['digest'] == 'sha256:' + selected['artifactSHA256'] and artifact['size_in_bytes'] <= 100_000,
        'App source artifact selector differs')
    raw = command(['gh', 'api', f"repos/iret77/nexgenvideo/actions/artifacts/{selected['artifactID']}/zip", '--allow-escape-sequences'])
    receipt = original_receipt(artifact, raw, run)
    steps = verify_steps(job, receipt)
    pr = api('pulls/' + str(receipt['pullRequest']))
    merge = api('git/commits/' + selected['appSourceSHA'])
    require(pr['merged'] and pr['merge_commit_sha'] == selected['appSourceSHA']
        and pr['head']['sha'] == receipt['headSHA'] == selected['sourceSHA']
        and merge['tree']['sha'] == receipt['treeSHA'], 'App is not the exact reviewed merge tree')
    log = command(['gh', 'api', f"repos/iret77/nexgenvideo/actions/jobs/{job['id']}/logs", '--allow-escape-sequences'])
    completion = test_completion(log)
    (root / 'app-source-original-proof.zip').write_bytes(raw)
    (root / 'app-source-original-job.log').write_bytes(log)
    (root / 'current-source-composition.json').write_bytes((current_path / 'receipt.json').read_bytes())
    value = {'schema': 'native-app-build-plan-binding/v1', 'harnessSourceSHA': head, 'selected': selected,
        'nativeSourceObjects': objects, 'changedHarnessPaths': sorted(changed), 'appSourceRun': run,
        'appSourceArtifact': artifact, 'appSourceReceipt': receipt, 'appSourcePR': pr,
        'appSourceMerge': merge, 'appSourceSteps': steps, 'appSourceCompletion': completion,
        'appSourceLogSHA256': hashlib.sha256(log).hexdigest(), 'currentSourceComposition': current,
        'resumeCapture': bind_resume(root, selected, objects, head),
        'appProductCompilationAuthorised': False, 'functionalAcceptance': False}
    write(root / 'binding.json', value)


def probe_environment(env):
    names = ('PATH', 'HOME', 'TMPDIR', 'DEVELOPER_DIR', 'LANG', 'LC_ALL', 'TERM', 'NO_COLOR')
    require(not any(env.get(key) for key in ('XCODE_XCCONFIG_FILE', 'SWIFT_EXEC', 'CC', 'CXX', 'TOOLCHAINS')),
        'Ambient compiler/configuration override must be reviewed first')
    return {name: env[name] for name in names if name in env}


def settings(profile, color):
    require(profile in {'production', 'testable'} and type(color) is bool, 'Unknown recipe context')
    swift = '$(inherited)' + (' -enable-testing' if profile == 'testable' else '')
    result = {'STRIP_INSTALLED_PRODUCT': 'NO', 'LM_SKIP_METADATA_EXTRACTION': 'YES', 'ONLY_ACTIVE_ARCH': 'YES',
        'GENERATE_TEST_ENTRYPOINTS_FOR_BUNDLES': 'YES', 'ADD_TOOLCHAIN_CONCURRENCY_BACK_DEPLOY_RPATH': 'YES',
        'ADD_TOOLCHAIN_SPAN_BACK_DEPLOY_RPATH': 'YES', 'DEAD_CODE_STRIPPING': 'YES',
        'SWIFT_FORCE_STATIC_LINK_STDLIB': 'NO', 'CLANG_COVERAGE_MAPPING': 'NO',
        'COLOR_DIAGNOSTICS': 'YES' if color else 'NO', 'OTHER_CFLAGS': '$(inherited)',
        'OTHER_CPLUSPLUSFLAGS': '$(inherited)', 'OTHER_SWIFT_FLAGS': swift,
        'OTHER_LDFLAGS_SWIFTC_LINKER_DRIVER_swiftc': swift,
        'OTHER_LDFLAGS': '$(inherited) $(OTHER_LDFLAGS_SWIFTC_LINKER_DRIVER_$(LINKER_DRIVER))'}
    for name in ('OTHER_CFLAGS', 'OTHER_CPLUSPLUSFLAGS', 'OTHER_SWIFT_FLAGS',
                 'OTHER_LDFLAGS_SWIFTC_LINKER_DRIVER_swiftc', 'OTHER_LDFLAGS'):
        result[name + '[__destination_platform=YES]'] = '$(inherited)'
    return result


def build_request(profile, target, arena, sdk, toolchain, color):
    require(profile in {'production', 'testable'} and target and Path(arena).is_absolute(), 'Invalid context/target/arena')
    require(Path(sdk).is_absolute() and toolchain, 'Missing measured SDK or registered toolchain')
    arena = str(arena)
    overrides = settings(profile, color)
    overrides['TOOLCHAINS'] = toolchain + ' $(inherited)'
    parameters = {'action': 'build', 'configurationName': 'Release', 'activeArchitecture': None,
        'activeRunDestination': {'platform': 'macosx', 'sdk': str(sdk), 'sdkVariant': None,
            'targetArchitecture': 'arm64', 'supportedArchitectures': [], 'disableOnlyActiveArch': False,
            'hostTargetedPlatform': None},
        'arenaInfo': {'derivedDataPath': arena, 'buildProductsPath': arena + '/Products',
            'buildIntermediatesPath': arena + '/Intermediates.noindex', 'pchPath': arena + '/PCH',
            'indexRegularBuildProductsPath': None, 'indexRegularBuildIntermediatesPath': None,
            'indexPCHPath': arena, 'indexDataStoreFolderPath': arena, 'indexEnableDataStore': False},
        'overrides': {'synthesized': {'table': overrides}, 'commandLine': None, 'commandLineConfigPath': None,
            'environmentConfigPath': None, 'toolchainOverride': None, 'commandLineConfig': None, 'environmentConfig': None}}
    return {'parameters': parameters, 'configuredTargets': [{'guid': target, 'parameters': parameters}],
        'useParallelTargets': True, 'useImplicitDependencies': False, 'dependencyScope': 'workspace',
        'useDryRun': False, 'continueBuildingAfterErrors': False, 'hideShellScriptEnvironment': True,
        'showNonLoggedProgress': True, 'recordBuildBacktraces': False, 'generatePrecompiledModulesReport': None,
        'buildPlanDiagnosticsDirPath': arena + '/plan-diagnostics',
        'buildCommand': {'command': 'build', 'style': 'buildOnly', 'skipDependencies': False},
        'schemeCommand': 'launch', 'containerPath': None, 'buildOnlyTheseFiles': None, 'buildOnlyTheseTargets': None,
        'buildDescriptionID': None, 'enableIndexBuildArena': False, 'qos': None,
        'schedulerLaneWidthOverride': 1, 'useLegacyBuildLocations': False}


def target_guids(pif):
    require(isinstance(pif, list), 'Expected canonical flat PIF')
    targets = [item['contents'] for item in pif if item.get('type') == 'target']
    def unique(name):
        found = [target for target in targets if target.get('name') == name]
        require(len(found) == 1 and isinstance(found[0].get('guid'), str), 'Missing or ambiguous PIF product: ' + name)
        return found[0]['guid']
    return {'production': unique('NexGenVideo-product'), 'testable': unique('NexGenVideoTests-product')}


def no_plugins(packages):
    require(isinstance(packages, list) and len(packages) == 19, 'Pinned package metadata inventory differs')
    for package in packages:
        require(isinstance(package.get('targets'), list), 'Missing actual package target graph')
        for target in package['targets']:
            require(target.get('type') != 'plugin' and not any(value for key, value in target.items()
                if 'plugin' in key.lower()), 'Build-tool plugin graph requires its own product binding')


def planned_commands(manifest):
    commands = manifest.get('commands')
    require(isinstance(commands, dict) and commands, 'Missing complete planned commands')
    return commands


def planned_app_tasks(manifest, pif, profile, source_root):
    require(profile in {'production', 'testable'} and Path(source_root).is_absolute(), 'Invalid raw task context')
    modules = {'NexGenVideo': 'NexGenVideo-product'} if profile == 'production' else {
        'NexGenVideo': 'NexGenVideo', 'NexGenVideoTests': 'NexGenVideoTests-product'}
    result = []
    for module, target_name in modules.items():
        targets = [row['contents'] for row in pif if row.get('type') == 'target'
            and row['contents'].get('name') == target_name]
        require(len(targets) == 1, 'Missing or ambiguous exact raw target: ' + target_name)
        target = targets[0]
        configurations = [row for row in target.get('buildConfigurations', []) if row.get('name') == 'Release']
        require(len(configurations) == 1 and configurations[0]['buildSettings'].get('PRODUCT_MODULE_NAME') == module,
            'PIF target module differs: ' + module)
        display = module
        if profile == 'testable' and target_name == 'NexGenVideo':
            require(target['guid'].startswith('PACKAGE-TARGET:' + module + '-') and target['guid'].endswith('-testable'),
                'Missing transformed executable target identity')
            display = target['guid'].removeprefix('PACKAGE-TARGET:')
        for tool, label, phase in [('swift-driver-compilation', 'SwiftDriver Compilation', 'P0'),
                ('swift-driver-compilation-requirement', 'SwiftDriver Compilation Requirements', 'P2')]:
            description = label + ' ' + display + ' normal arm64 com.apple.xcode.tools.swift.compiler'
            prefix = phase + ':target-' + target_name + '-' + target['guid'] + '-SDKROOT:'
            found = [(key, value) for key, value in planned_commands(manifest).items()
                if value.get('tool') == tool and value.get('description') == description
                and key.startswith(prefix) and key.endswith(':Release:' + description)]
            require(len(found) == 1, 'Missing or ambiguous exact dynamic task: ' + description)
            key, task = found[0]
            folder = 'Sources/NexGenVideo/' if module == 'NexGenVideo' else 'Tests/NexGenVideoTests/'
            require(isinstance(task.get('inputs'), list) and isinstance(task.get('outputs'), list) and task['outputs']
                and any(isinstance(path, str) and path.startswith(source_root + '/' + folder)
                    and path.endswith('.swift') for path in task['inputs']), 'Raw task lost its exact native source inputs')
            result.append({'module': module, 'targetGUID': target['guid'], 'taskRole': tool,
                'key': key, 'command': task, 'driverArgumentsExpanded': False})
    return result


def description_snapshot(files, profile, source_root):
    prefix = profile + '/'
    manifests = [name for name in files if name.startswith(prefix) and name.endswith('.xcbuilddata/manifest.json')]
    require(len(manifests) == 1, 'Missing or ambiguous retained raw description')
    manifest_path = manifests[0]; directory = manifest_path.rsplit('/', 1)[0]
    identifier = directory.rsplit('/', 1)[1].removesuffix('.xcbuilddata')
    require(re.fullmatch('[a-f0-9]{32}', identifier), 'Invalid retained description identity')
    required = [directory + '/' + name for name in ('manifest.json', 'task-store.msgpack', 'description.msgpack',
        'build-request.json', 'target-graph.txt')]
    require(all(name in files and files[name] for name in required), 'Incomplete retained raw description')
    attachments = [name for name in files if name.startswith(directory + '/attachments/')]
    require(attachments, 'Missing retained description attachments')
    request = json.loads(files[prefix + 'request.json'])
    require(isinstance(request['parameters']['activeRunDestination']['sdk'], str)
        and Path(request['parameters']['activeRunDestination']['sdk']).is_absolute()
        and request['parameters']['activeRunDestination']['targetArchitecture'] == 'arm64', 'Invalid retained SDK request')
    pif = json.loads(files[prefix + 'workspace.pif'])
    target_name = 'NexGenVideo-product' if profile == 'production' else 'NexGenVideoTests-product'
    targets = [row['contents'] for row in pif if row.get('type') == 'target' and row['contents'].get('name') == target_name]
    require(len(targets) == 1 and request['parameters']['configurationName'] == 'Release'
        and request['parameters']['action'] == 'build'
        and request['configuredTargets'] == [{'guid': targets[0]['guid'], 'parameters': request['parameters']}],
        'Retained request target or profile parameters differ')
    def normalized(value):
        if isinstance(value, dict): return {key: normalized(item) for key, item in value.items() if item is not None}
        if isinstance(value, list): return [normalized(item) for item in value]
        return value
    effective = json.loads(files[directory + '/build-request.json'])
    require(normalized(effective) == normalized(request), 'Actual description request differs from the reviewed input')
    flags = request['parameters']['overrides']['synthesized']['table']['OTHER_SWIFT_FLAGS']
    require(flags == ('$(inherited)' if profile == 'production' else '$(inherited) -enable-testing'), 'Retained profile differs')
    stdout = files[profile + '-description.stdout'].decode()
    messages = [json.loads(line) for line in stdout.splitlines() if line.startswith('{')]
    require([row['buildDescriptionID'] for row in messages if row.get('kind') == 'reportBuildDescription'] == [identifier]
        and [row.get('result') for row in messages if row.get('kind') == 'buildCompleted'] == ['ok'],
        'Retained description was not completed by the actual console')
    argv = json.loads(files[profile + '-description.argv.json'])
    require(len(argv) == 7 and argv[1:3] == ['createBuildDescription', '--target']
        and argv[3] == ('NexGenVideo-product' if profile == 'production' else 'NexGenVideoTests-product')
        and argv[4] == '--buildRequestFile', 'Retained capture was not description-only')
    commands = json.loads(files['commands.json'])
    require([row['exitCode'] for row in commands if row['label'] == profile + '-description'] == [0],
        'Retained description command did not pass')
    pif = json.loads(files[prefix + 'workspace.pif'])
    tasks = planned_app_tasks(json.loads(files[manifest_path]), pif, profile, source_root)
    selected = {name: hashlib.sha256(raw).hexdigest() for name, raw in files.items() if name.startswith(prefix)}
    return {'profile': profile, 'descriptionID': identifier, 'manifest': manifest_path,
        'manifestSHA256': hashlib.sha256(files[manifest_path]).hexdigest(),
        'taskStoreSHA256': hashlib.sha256(files[directory + '/task-store.msgpack']).hexdigest(),
        'pifSHA256': hashlib.sha256(files[prefix + 'workspace.pif']).hexdigest(),
        'requestSHA256': hashlib.sha256(files[prefix + 'request.json']).hexdigest(),
        'fileHashes': selected, 'plannedTasks': tasks, 'driverArgumentsExpanded': False}


def current_description_snapshot(root, profile, source_root):
    files = {path.relative_to(root).as_posix(): path.read_bytes() for path in (root / profile).rglob('*') if path.is_file()}
    for name in ('commands.json', profile + '-description.stdout', profile + '-description.argv.json'):
        files[name] = (root / name).read_bytes()
    return description_snapshot(files, profile, source_root)


def archive_files(raw):
    from pathlib import PurePosixPath
    result = {}; seen = set()
    with zipfile.ZipFile(io.BytesIO(raw)) as archive:
        entries = archive.infolist()
        require(len(entries) <= 2048 and sum(row.file_size for row in entries) <= 128 * 1024**2,
            'Prior metadata archive exceeds its scope')
        for row in entries:
            name = row.filename.rstrip('/') if row.is_dir() else row.filename
            path = PurePosixPath(name)
            require(name not in {'', '.'} and str(path) == name and not path.is_absolute()
                and '..' not in path.parts and '\\' not in name and name.casefold() not in seen
                and row.file_size <= 32 * 1024**2 and (row.external_attr >> 16) & 0o170000 != 0o120000,
                'Unsafe or duplicate prior metadata member')
            seen.add(name.casefold())
            if not row.is_dir(): result[name] = archive.read(row)
    return result


def metadata_snapshot(files):
    def data(name):
        require(name in files, 'Missing retained metadata: ' + name)
        return json.loads(files[name])
    require('result.json' not in files and not any(name.startswith('testable/')
        or name.endswith('-description.argv.json') for name in files), 'Prior capture is not the pre-description failure')
    graph = data('pinned-graph.json')
    no_plugins(graph['packages'])
    require(graph['buildToolPlugins'] == 0 and len(graph['pins']) == 18
        and sum(len(package['targets']) for package in graph['packages']) == 164
        and graph['localEngineManifestSHA256'] == MANIFEST_HASHES['Engine/Package.swift'], 'Prior native graph differs')
    require(data('package-root.stdout') == graph['packages'][0], 'Root metadata differs')
    for index, pin in enumerate(graph['pins']):
        name = 'package-' + str(index) + '.stdout'
        require(name in files and hashlib.sha256(files[name]).hexdigest() == pin['metadataSHA256']
            and data(name) == graph['packages'][index + 1], 'Pinned metadata bytes differ')
    require(files.get('production/workspace.pif') == files.get('production-pif.stdout')
        and 'production/workspace.pif' in files, 'Prior PIF bytes differ')
    pif = data('production/workspace.pif'); target_guids(pif)
    roots = graph['packages'][0].get('packageKind', {}).get('root', [])
    require(len(roots) == 1 and isinstance(roots[0], str) and Path(roots[0]).is_absolute(), 'Missing original workspace path')
    require(any(row.get('type') == 'project' and row['contents'].get('projectDirectory') == roots[0]
        for row in pif), 'PIF does not bind the original source workspace')
    resolve = data('resolve.argv.json')
    require(len(resolve) == 7 and resolve[:3] == ['swift', 'package', '--cache-path']
        and resolve[4] == '--scratch-path' and resolve[6] == 'resolve'
        and Path(resolve[3]).is_absolute() and Path(resolve[5]).is_absolute(), 'Prior package acquisition context differs')
    commands = data('commands.json')
    expected = ['developer', 'compiler', 'sdk', 'xcode', 'swift', 'os', 'architecture', 'sdk-version',
        'find-swbuild', 'console-help-1', 'console-version', 'resolve', 'package-root']
    expected += ['package-' + str(index) for index in range(18)] + ['production-pif']
    require([item['label'] for item in commands] == expected
        and all(item['exitCode'] == 0 for item in commands if item['label'] != 'find-swbuild'),
        'Prior metadata command frontier differs')
    toolchain = data('toolchain.json')
    require(set(toolchain) == {'developer', 'compiler', 'compilerSHA256', 'sdk', 'toolchainID', 'console',
        'consoleSHA256', 'NO_COLOR_present', 'appCompilerProducts', 'printedJobsExecuted'}
        and all(isinstance(toolchain[key], str) and Path(toolchain[key]).is_absolute()
            for key in ('developer', 'compiler', 'sdk', 'console'))
        and all(re.fullmatch('[a-f0-9]{64}', toolchain[key]) for key in ('compilerSHA256', 'consoleSHA256'))
        and isinstance(toolchain['toolchainID'], str) and toolchain['toolchainID']
        and type(toolchain['NO_COLOR_present']) is bool and toolchain['appCompilerProducts'] == 0
        and toolchain['printedJobsExecuted'] is False, 'Missing original description-only toolchain context')
    return {'graph': graph, 'toolchain': toolchain, 'workspace': roots[0],
        'scratch': resolve[5], 'cache': resolve[3], 'productionPIFSHA256': hashlib.sha256(files['production/workspace.pif']).hexdigest()}


def bind_resume(root, selected, objects, head):
    if 'resumeArtifactID' not in selected: return None
    artifact = api('actions/artifacts/' + str(selected['resumeArtifactID']))
    require(artifact['name'] == 'app-build-plan-evidence' and not artifact['expired']
        and artifact['digest'] == 'sha256:' + selected['resumeArtifactSHA256']
        and artifact['size_in_bytes'] <= 20 * 1024**2, 'Wrong prior metadata artifact')
    original = api('actions/runs/' + str(artifact['workflow_run']['id']))
    require(original['run_attempt'] == 1 and original['workflow_id'] == 355242770
        and original['status'] == 'completed' and original['conclusion'] == 'failure'
        and original['actor']['login'] == 'iret77' and original['event'] == 'workflow_dispatch'
        and original['repository']['full_name'] == 'iret77/nexgenvideo'
        and original['head_sha'] == artifact['workflow_run']['head_sha'], 'Wrong prior metadata producer')
    prior_head = original['head_sha']
    require(re.fullmatch('[a-f0-9]{40}', prior_head), 'Invalid prior source')
    subprocess.run(['git', 'merge-base', '--is-ancestor', prior_head, head], check=True, timeout=30)
    require(set(git('diff', '--name-only', '--no-renames', prior_head, head).splitlines()) <= PATHS,
        'Prior native inputs no longer qualify')
    require(objects == {name: git('rev-parse', prior_head + ':' + name) for name in INPUT_OBJECTS},
        'Prior native source graph changed')
    jobs = api(f"actions/runs/{original['id']}/attempts/1/jobs?per_page=100")
    require(jobs['total_count'] == len(jobs['jobs']), 'Incomplete prior job inventory')
    source = [job for job in jobs['jobs'] if job['name'] == 'source']
    require(len(source) == 1 and source[0]['status'] == 'completed' and source[0]['conclusion'] == 'success', 'Prior Source job did not pass')
    native = [job for job in jobs['jobs'] if job['name'] == 'app-build-plan']
    require(len(native) == 1 and native[0]['labels'] == ['macrunner'] and native[0]['conclusion'] == 'failure'
        and all(job['id'] == native[0]['id'] for job in jobs['jobs']
            if job['labels'] == ['macrunner'] and job['conclusion'] != 'skipped'), 'Prior role differs')
    raw = command(['gh', 'api', f"repos/iret77/nexgenvideo/actions/artifacts/{artifact['id']}/zip", '--allow-escape-sequences'])
    require(len(raw) == artifact['size_in_bytes'] and hashlib.sha256(raw).hexdigest() == selected['resumeArtifactSHA256'], 'Prior metadata bytes differ')
    files = archive_files(raw)
    source_artifact = json.loads(files['source-binding-artifact.json'])
    actual = api('actions/artifacts/' + str(source_artifact['id']))
    require(actual['name'] == 'app-build-plan-source-binding' and not actual['expired']
        and actual['digest'] == source_artifact['digest'] and actual['size_in_bytes'] == source_artifact['size_in_bytes']
        and actual['workflow_run']['id'] == original['id'] and actual['workflow_run']['head_sha'] == prior_head
        and actual['size_in_bytes'] <= 20 * 1024**2, 'Prior source binding differs')
    source_raw = command(['gh', 'api', f"repos/iret77/nexgenvideo/actions/artifacts/{actual['id']}/zip", '--allow-escape-sequences'])
    require(len(source_raw) == actual['size_in_bytes'] and hashlib.sha256(source_raw).hexdigest() == actual['digest'].removeprefix('sha256:'), 'Prior source binding bytes differ')
    source_files = archive_files(source_raw); prior_binding = json.loads(source_files['binding.json'])
    require(prior_binding['schema'] == 'native-app-build-plan-binding/v1'
        and prior_binding['harnessSourceSHA'] == prior_head and prior_binding['nativeSourceObjects'] == objects,
        'Prior capture origin or graph differs')
    for key in ('runID', 'sourceSHA', 'artifactID', 'artifactSHA256', 'appSourceSHA'):
        require(prior_binding['selected'][key] == selected[key], 'Prior App source selector differs: ' + key)
    composition = prior_binding['currentSourceComposition']
    require(composition['schema'] == 'core-pr-source-composition/v1' and composition['sourceSHA'] == prior_head
        and composition['originalRun']['id'] == prior_binding['selected']['verifiedPRRunID']
        and composition['originalPR']['merged'] and composition['originalPR']['merge_commit_sha'] == prior_head,
        'Prior complete source composition differs')
    captures = {}; metadata_origin = original
    parent = prior_binding.get('resumeCapture')
    if parent:
        require(parent['schema'] == 'native-app-build-plan-resume/v1' and parent['priorPartialRequestReusable'] is False,
            'Unreviewed nested capture origin')
        require(prior_binding['selected']['resumeArtifactID'] == parent['originArtifact']['id']
            and prior_binding['selected']['resumeArtifactSHA256'] == parent['originArtifact']['digest'].removeprefix('sha256:'),
            'Nested metadata selector differs')
        parent_raw = source_files['prior-metadata-original.zip']
        require(hashlib.sha256(parent_raw).hexdigest() == parent['originArtifact']['digest'].removeprefix('sha256:'),
            'Nested original metadata bytes differ')
        base = archive_files(parent_raw)
        require({name: hashlib.sha256(value).hexdigest() for name, value in base.items()} == parent['originalMetadataFiles']
            and {name.removeprefix('prior-capture/'): value for name, value in files.items()
                if name.startswith('prior-capture/')} == base, 'Nested metadata files changed')
        parent_source_raw = source_files['prior-source-binding-original.zip']
        require(hashlib.sha256(parent_source_raw).hexdigest() == parent['originSourceArtifact']['digest'].removeprefix('sha256:'),
            'Nested original source binding bytes differ')
        parent_binding = json.loads(archive_files(parent_source_raw)['binding.json'])
        require(parent_binding['harnessSourceSHA'] == parent['originHarnessSHA']
            and parent_binding['nativeSourceObjects'] == objects and not parent_binding.get('resumeCapture'),
            'Unreviewed nested native source graph')
        for key in ('runID', 'sourceSHA', 'artifactID', 'artifactSHA256', 'appSourceSHA'):
            require(parent_binding['selected'][key] == selected[key], 'Nested App selector differs')
        snapshot = metadata_snapshot(base)
        require(snapshot == parent['snapshot'] and files['pinned-graph.json'] == base['pinned-graph.json'],
            'Nested graph context differs')
        metadata_origin = parent['originRun']
        require(metadata_origin['id'] == parent['originArtifact']['workflow_run']['id']
            and metadata_origin['head_sha'] == parent['originHarnessSHA'] and metadata_origin['run_attempt'] == 1,
            'Nested origin run differs')
        captures['production'] = description_snapshot(files, 'production', snapshot['workspace'])
        require(captures['production']['pifSHA256'] == snapshot['productionPIFSHA256']
            and json.loads(files['toolchain.json']) == snapshot['toolchain'], 'Retained production context changed')
        reuse = json.loads(files['metadata-reuse.json'])
        require(reuse['originRunID'] == metadata_origin['id'] and reuse['originHarnessSHA'] == parent['originHarnessSHA']
            and reuse['packageMetadataQueriesRepeated'] == reuse['productionPIFQueriesRepeated'] == 0,
            'Nested metadata reuse receipt differs')
    else:
        snapshot = metadata_snapshot(files)
    (root / 'prior-metadata-original.zip').write_bytes(raw)
    (root / 'prior-source-binding-original.zip').write_bytes(source_raw)
    log = command(['gh', 'api', f"repos/iret77/nexgenvideo/actions/jobs/{native[0]['id']}/logs", '--allow-escape-sequences'])
    (root / 'prior-native-original-job.log').write_bytes(log)
    return {'schema': 'native-app-build-plan-resume/v2', 'originRun': original, 'originArtifact': artifact,
        'originSourceArtifact': actual, 'originNativeJob': native[0], 'originNativeLogSHA256': hashlib.sha256(log).hexdigest(),
        'originHarnessSHA': prior_head, 'snapshot': snapshot, 'metadataOriginRun': metadata_origin,
        'retainedProfileSnapshots': captures,
        'originalMetadataFiles': {name: hashlib.sha256(raw).hexdigest() for name, raw in files.items()},
        'productionPIFReusedVerbatim': True, 'priorPartialRequestReusable': False,
        'nativeProductCompilationAuthorised': False}


def run(root, source_binding):
    require(os.environ.get('GITHUB_ACTIONS') == 'true' and os.environ.get('GITHUB_REPOSITORY') == 'iret77/nexgenvideo'
        and os.environ.get('RUNNER_OS') == 'macOS' and sys.platform == 'darwin'
        and os.environ.get('GITHUB_RUN_ATTEMPT') == '1', 'Metadata probe requires owned macrunner Actions')
    root.mkdir(parents=True, exist_ok=False)
    binding = json.loads(source_binding.read_text())
    require(binding['schema'] == 'native-app-build-plan-binding/v1'
        and binding['harnessSourceSHA'] == os.environ['GITHUB_SHA'] == git('rev-parse', 'HEAD'), 'Source binding differs')
    artifact_id = os.environ.get('PLAN_BINDING_ARTIFACT_ID', '')
    artifact_digest = os.environ.get('PLAN_BINDING_DIGEST', '').removeprefix('sha256:')
    require(re.fullmatch('[1-9][0-9]*', artifact_id) and re.fullmatch('[a-f0-9]{64}', artifact_digest),
        'Confirmed source binding artifact is required')
    artifact = api('actions/artifacts/' + artifact_id)
    require(artifact['name'] == 'app-build-plan-source-binding'
        and artifact['workflow_run']['id'] == int(os.environ['GITHUB_RUN_ID'])
        and artifact['workflow_run']['head_sha'] == os.environ['GITHUB_SHA'] and not artifact['expired']
        and artifact['digest'] == 'sha256:' + artifact_digest and artifact['size_in_bytes'] <= 20 * 1024**2,
        'Source binding producer differs')
    archive = command(['gh', 'api', 'repos/iret77/nexgenvideo/actions/artifacts/' + artifact_id + '/zip', '--allow-escape-sequences'])
    require(len(archive) == artifact['size_in_bytes'] and hashlib.sha256(archive).hexdigest() == artifact_digest,
        'Source binding archive bytes differ')
    with zipfile.ZipFile(io.BytesIO(archive)) as original:
        require(original.namelist().count('binding.json') == 1
            and original.read('binding.json') == source_binding.read_bytes(), 'Downloaded binding differs')
    write(root / 'source-binding-artifact.json', artifact)
    for name, value in binding['nativeSourceObjects'].items():
        require(git('rev-parse', 'HEAD:' + name) == value, 'Native input changed: ' + name)
    environment = probe_environment(os.environ)
    commands = []
    def logged(argv, label, timeout=90, check=True):
        write(root / (label + '.argv.json'), argv)
        with (root / (label + '.stdout')).open('xb') as out, (root / (label + '.stderr')).open('xb') as err:
            result = subprocess.run(argv, stdin=subprocess.DEVNULL, stdout=out, stderr=err,
                env=environment, timeout=timeout)
        commands.append({'label': label, 'argv': argv, 'exitCode': result.returncode})
        with (root / 'commands.json').open('w') as out: json.dump(commands, out, indent=2)
        require(not check or result.returncode == 0, 'Metadata command failed: ' + label)
        return result.returncode, (root / (label + '.stdout')).read_text(errors='replace')
    _, developer = logged(['xcode-select', '-p'], 'developer')
    developer = Path(developer.strip()).resolve()
    _, compiler = logged(['xcrun', '--find', 'swiftc'], 'compiler')
    compiler = Path(compiler.strip())
    _, sdk = logged(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], 'sdk')
    sdk = Path(sdk.strip()).resolve()
    _, xcode = logged(['xcodebuild', '-version'], 'xcode')
    _, swift = logged(['swift', '--version'], 'swift')
    _, os_version = logged(['sw_vers', '-productVersion'], 'os')
    _, architecture = logged(['uname', '-m'], 'architecture')
    _, sdk_version = logged(['xcrun', '--sdk', 'macosx', '--show-sdk-version'], 'sdk-version')
    require(xcode.strip() == 'Xcode 27.2\nBuild version 27B52'
        and swift.splitlines()[0] == 'Apple Swift version 6.4.2 (swiftlang-6.4.2.1.9 clang-2100.4.1.1)'
        and os_version.strip() == sdk_version.strip() == '27.2' and architecture.strip() == 'arm64',
        'Original toolchain changed; reassess retained dependencies')
    toolchain_root = compiler.parent.parent.parent
    info = plistlib.loads((toolchain_root / 'ToolchainInfo.plist').read_bytes())
    toolchain_id = info.get('Identifier')
    require(isinstance(toolchain_id, str) and toolchain_id, 'No measured toolchain identifier')
    code, found = logged(['xcrun', '--find', 'swbuild'], 'find-swbuild', check=False)
    candidates = [Path(found.strip())] if code == 0 else []
    candidates += [developer.parent / 'SharedFrameworks/XCBuild.framework/Versions/A/Support/xcbuild',
        developer.parent / 'SharedFrameworks/SwiftBuild.framework/Versions/A/Support/swbuild']
    console = None
    for index, path in enumerate(candidates):
        if not path.is_file() or not path.resolve().is_relative_to(developer.parent):
            continue
        status, help_text = logged([str(path), '--help'], 'console-help-' + str(index), check=False)
        stderr = (root / ('console-help-' + str(index) + '.stderr')).read_text(errors='replace')
        if status == 0 and 'createBuildDescription' in help_text + stderr:
            console = path.resolve(); break
    write(root / 'toolchain.json', {'developer': str(developer), 'compiler': str(compiler), 'compilerSHA256': sha(compiler),
        'sdk': str(sdk), 'toolchainID': toolchain_id, 'console': str(console) if console else None,
        'consoleSHA256': sha(console) if console else None, 'NO_COLOR_present': 'NO_COLOR' in environment,
        'appCompilerProducts': 0, 'printedJobsExecuted': False})
    require(console is not None, 'Installed description-only console unavailable; no build/install fallback')
    logged([str(console), '--version'], 'console-version')
    cache = os.environ.get('NGV_SWIFTPM_CACHE_PATH')
    require(cache and Path(cache).is_absolute(), 'Pinned dependency cache is required')
    resume = binding.get('resumeCapture')
    retained = None
    if resume:
        archive_path = source_binding.parent / 'prior-metadata-original.zip'
        require(sha(archive_path) == resume['originArtifact']['digest'].removeprefix('sha256:'), 'Retained metadata bytes changed')
        retained = archive_files(archive_path.read_bytes())
        snapshot = resume['snapshot']
        require(sha(archive_path) == resume['originArtifact']['digest'].removeprefix('sha256:') and json.loads((root / 'toolchain.json').read_text()) == snapshot['toolchain'],
            'Prior metadata toolchain or graph context changed')
        scratch = root.parent / ('app-build-plan-workspace-' + str(resume['metadataOriginRun']['id']))
        require(str(scratch) == snapshot['scratch'] and cache == snapshot['cache']
            and str(Path.cwd().resolve()) == snapshot['workspace'], 'Prior PIF paths cannot be reused in this context')
        prior = root / 'prior-capture'; prior.mkdir()
        for name, raw in retained.items():
            require(hashlib.sha256(raw).hexdigest() == resume['originalMetadataFiles'][name], 'Retained file changed: ' + name)
            target = prior / name; target.parent.mkdir(parents=True, exist_ok=True); target.write_bytes(raw)
        (root / 'pinned-graph.json').write_bytes(retained['pinned-graph.json'])
        write(root / 'metadata-reuse.json', {'schema': 'native-app-build-plan-metadata-reuse/v1',
            'originRunID': resume['originRun']['id'], 'originHarnessSHA': resume['originHarnessSHA'],
            'originArtifact': resume['originArtifact'], 'productionPIFSHA256': snapshot['productionPIFSHA256'],
            'pinnedGraphSHA256': sha(root / 'pinned-graph.json'), 'packageMetadataQueriesRepeated': 0,
            'productionPIFQueriesRepeated': 0, 'productionDescriptionQueriesRepeated': 0,
            'metadataOriginRunID': resume['metadataOriginRun']['id'],
            'productionDescriptionOriginRunID': resume['originRun']['id'] if resume['retainedProfileSnapshots'] else None,
            'priorPartialRequestReusable': False,
            'originalScratchRestoredVerbatim': str(scratch)})
    else:
        scratch = root.parent / ('app-build-plan-workspace-' + os.environ['GITHUB_RUN_ID'])
    require(not scratch.exists(), 'Metadata workspace must be new')
    package = ['swift', 'package', '--cache-path', cache, '--scratch-path', str(scratch)]
    logged([*package, 'resolve'], 'resolve', 240)
    require(not git('status', '--porcelain', '--untracked-files=no'), 'Resolution mutated tracked inputs')
    lock = json.loads(Path('Package.resolved').read_text())
    pins = lock.get('pins')
    require(isinstance(pins, list) and len(pins) == 18, 'Pinned dependency inventory changed')
    checkouts = scratch / 'checkouts'
    require(checkouts.is_dir(), 'Resolved checkout inventory missing')
    repositories = list(checkouts.iterdir())
    require(len(repositories) == len(pins), 'Missing or additional pinned checkout')
    packages = []
    if not retained:
        _, text = logged([*package, 'dump-package'], 'package-root')
        packages.append(json.loads(text))
    resolved = []
    for index, pin in enumerate(pins):
        identity = pin['identity']
        matches = [path for path in repositories if path.name.lower() == identity.lower()]
        require(len(matches) == 1, 'Ambiguous pinned checkout: ' + identity)
        path = matches[0]
        revision = command(['git', '-C', str(path), 'rev-parse', 'HEAD']).decode().strip()
        require(revision == pin['state']['revision']
            and not command(['git', '-C', str(path), 'status', '--porcelain', '--untracked-files=no']).strip(),
            'Pinned dependency changed: ' + identity)
        if retained:
            old_pin = snapshot['graph']['pins'][index]
            require(old_pin['identity'] == identity and old_pin['revision'] == revision, 'Retained pin differs')
        else:
            _, text = logged(['swift', 'package', '--package-path', str(path), 'dump-package'], 'package-' + str(index))
            packages.append(json.loads(text))
            resolved.append({'identity': identity, 'revision': revision,
                'metadataSHA256': sha(root / ('package-' + str(index) + '.stdout'))})
    if not retained:
        no_plugins(packages)
        write(root / 'pinned-graph.json', {'packages': packages, 'pins': resolved, 'buildToolPlugins': 0,
            'localEngineManifestSHA256': sha(Path('Engine/Package.swift'))})
    for name, value in MANIFEST_HASHES.items():
        require(sha(Path(name)) == value, 'Manifest changed during metadata evaluation')
    profiles = []
    for profile in ('production', 'testable'):
        retained_profile = resume['retainedProfileSnapshots'].get(profile) if resume else None
        if retained_profile:
            actual = description_snapshot(retained, profile, snapshot['workspace'])
            require(actual == retained_profile, 'Retained raw profile changed')
            for name, digest in retained_profile['fileHashes'].items():
                raw = retained[name]; require(hashlib.sha256(raw).hexdigest() == digest, 'Retained profile file changed')
                path = root / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(raw)
            folder = root / profile
            write(folder / 'app-driver-tasks.json', actual['plannedTasks'])
            profiles.append({'profile': profile, 'pifSHA256': actual['pifSHA256'], 'requestSHA256': actual['requestSHA256'],
                'targetGUID': target_guids(json.loads(retained[profile + '/workspace.pif']))[profile],
                'manifest': actual['manifest'], 'manifestSHA256': actual['manifestSHA256'],
                'taskStoreSHA256': actual['taskStoreSHA256'], 'plannedAppDriverTasks': len(actual['plannedTasks']),
                'driverJobsExecuted': False, 'driverArgumentsExpanded': False,
                'pifOriginRunID': resume['metadataOriginRun']['id'], 'descriptionOriginRunID': resume['originRun']['id']})
            continue
        arguments = [*package, '-c', 'release']
        if profile == 'testable': arguments += ['-Xswiftc', '-enable-testing']
        if retained and profile == 'production':
            text = retained['production/workspace.pif'].decode()
        else:
            _, text = logged([*arguments, 'dump-pif'], profile + '-pif', 240)
        pif = json.loads(text)
        targets = target_guids(pif)
        folder = root / profile
        folder.mkdir()
        pif_path = folder / 'workspace.pif'
        pif_path.write_text(text)
        arena = folder / 'derived-data'
        request = build_request(profile, targets[profile], arena, sdk, toolchain_id, 'NO_COLOR' not in environment)
        request_path = folder / 'request.json'
        write(request_path, request)
        target_name = 'NexGenVideo-product' if profile == 'production' else 'NexGenVideoTests-product'
        logged([str(console), 'createBuildDescription', '--target', target_name,
            '--buildRequestFile', str(request_path), str(pif_path)],
            profile + '-description', 180)
        manifests = list(arena.rglob('manifest.json'))
        manifests = [path for path in manifests if path.parent.suffix == '.xcbuilddata']
        require(len(manifests) == 1, 'Missing or ambiguous complete build description')
        manifest_path = manifests[0]
        task_store = manifest_path.parent / 'task-store.msgpack'
        attachments = manifest_path.parent / 'attachments'
        require(task_store.is_file() and attachments.is_dir() and any(attachments.iterdir()),
            'Description lost task actions or generated source attachments')
        planned = planned_commands(json.loads(manifest_path.read_text()))
        actual = current_description_snapshot(root, profile, str(Path.cwd().resolve()))
        candidates = actual['plannedTasks']
        write(folder / 'raw-capture.json', {'schema': 'native-app-build-plan-raw-profile/v1',
            'executionRunID': int(os.environ['GITHUB_RUN_ID']), 'sourceSHA': os.environ['GITHUB_SHA'], **actual})
        for candidate in candidates:
            for output in candidate['command']['outputs']:
                path = Path(output)
                if path.is_absolute() and path.suffix in {'.o', '.swiftmodule'}:
                    require(not path.exists(), 'Description unexpectedly compiled an App/Test product')
        write(folder / 'app-driver-tasks.json', candidates)
        profiles.append({'profile': profile, 'pifSHA256': sha(pif_path), 'requestSHA256': sha(request_path),
            'targetGUID': targets[profile], 'manifest': manifest_path.relative_to(root).as_posix(),
            'manifestSHA256': sha(manifest_path), 'taskStoreSHA256': sha(task_store),
            'plannedAppDriverTasks': len(candidates), 'driverJobsExecuted': False,
            'driverArgumentsExpanded': False, 'descriptionOriginRunID': int(os.environ['GITHUB_RUN_ID']),
            'pifOriginRunID': resume['metadataOriginRun']['id'] if retained and profile == 'production' else int(os.environ['GITHUB_RUN_ID'])})
    require(not git('status', '--porcelain', '--untracked-files=no'), 'Planning mutated tracked source')
    inventory = []
    for path in sorted(root.rglob('*')):
        require(not path.is_symlink(), 'Metadata evidence contains an unexpected symlink')
        if path.is_file():
            require(path.suffix not in {'.o', '.a', '.dylib', '.metallib'}, 'Description unexpectedly compiled a product')
            inventory.append({'path': path.relative_to(root).as_posix(), 'bytes': path.stat().st_size, 'sha256': sha(path)})
    write(root / 'metadata-manifest.json', {'files': inventory})
    write(root / 'result.json', {'schema': 'native-app-build-plan-capture/v1', 'sourceSHA': os.environ['GITHUB_SHA'],
        'appSourceSHA': binding['selected']['appSourceSHA'], 'bindingSHA256': sha(source_binding), 'profiles': profiles,
        'metadataManifestSHA256': sha(root / 'metadata-manifest.json'), 'descriptionCaptureComplete': True,
        'compilerRecipeIndependentlyQualified': False, 'frontendExpansionStillRequired': True,
        'appProductCompilationAuthorised': False, 'appProductCompilerExecutions': 0,
        'nativeTestExecutions': 0, 'appLaunches': 0, 'functionalAcceptance': False,
        'metadataReuse': json.loads((root / 'metadata-reuse.json').read_text()) if retained else None})


if __name__ == '__main__':
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('action', choices=('bind', 'run'))
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--source-binding', type=Path)
    args = parser.parse_args()
    if args.action == 'bind':
        bind(args.output)
    else:
        require(args.source_binding is not None, 'Source binding required')
        run(args.output, args.source_binding)
