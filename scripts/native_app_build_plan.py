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
    unused = ('DMG_DIGEST', 'JOURNEY_JOB', 'JOURNEY_ARTIFACT', 'JOURNEY_DIGEST', 'EXTRA_PRODUCTS',
        'EXTRA_PRODUCTS_SHA', 'EXTRA_FAILURE', 'EXTRA_FAILURE_SHA', 'PRODUCTS_ID', 'PRODUCTS_DIGEST',
        'FAILURE_ID', 'FAILURE_DIGEST', 'RUNTIME_FAILURE_BINDING', 'PACKAGING_PRODUCER_SOURCE',
        'PACKAGING_PROVENANCE_ARTIFACT_ID', 'PACKAGING_PROVENANCE_ARTIFACT_SHA256')
    require(not any(env.get(key) for key in unused), 'Unrelated selectors cannot be ignored by build planning')
    return result


def bind(root):
    from verified_pr_source_checks import original_receipt, verify_run_identity, verify_steps, test_completion
    require(os.environ.get('GITHUB_REPOSITORY') == 'iret77/nexgenvideo', 'Wrong repository')
    selected = validate_inputs(os.environ)
    head = os.environ['GITHUB_SHA']
    require(git('rev-parse', 'HEAD') == head and not git('status', '--porcelain', '--untracked-files=no'), 'Dirty source')
    subprocess.run(['git', 'merge-base', '--is-ancestor', selected['appSourceSHA'], head], check=True, timeout=30)
    changed = git('diff', '--name-only', '--no-renames', selected['appSourceSHA'], head).splitlines()
    require(changed and set(changed) <= PATHS, 'App, package or unrelated source changed')
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
        'activeRunDestination': {'platform': 'macosx', 'sdk': sdk, 'sdkVariant': None,
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
        _, text = logged(['swift', 'package', '--package-path', str(path), 'dump-package'], 'package-' + str(index))
        packages.append(json.loads(text))
        resolved.append({'identity': identity, 'revision': revision,
            'metadataSHA256': sha(root / ('package-' + str(index) + '.stdout'))})
    no_plugins(packages)
    for name, value in MANIFEST_HASHES.items():
        require(sha(Path(name)) == value, 'Manifest changed during metadata evaluation')
    write(root / 'pinned-graph.json', {'packages': packages, 'pins': resolved, 'buildToolPlugins': 0,
        'localEngineManifestSHA256': sha(Path('Engine/Package.swift'))})
    profiles = []
    for profile in ('production', 'testable'):
        arguments = [*package, '-c', 'release']
        if profile == 'testable': arguments += ['-Xswiftc', '-enable-testing']
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
        candidates = []
        for key, value in planned.items():
            argv = value.get('args')
            if isinstance(argv, list) and '-module-name' in argv:
                index = argv.index('-module-name')
                if index + 1 < len(argv) and argv[index + 1] in {'NexGenVideo', 'NexGenVideoTests'}:
                    candidates.append({'key': key, 'command': value})
        require(candidates, 'Description contains no actual App/Test driver arguments')
        for candidate in candidates:
            argv = candidate['command']['args']
            if '-emit-module-path' in argv:
                output = Path(argv[argv.index('-emit-module-path') + 1])
                require(not output.exists(), 'Description unexpectedly compiled an App/Test module')
        write(folder / 'app-driver-tasks.json', candidates)
        profiles.append({'profile': profile, 'pifSHA256': sha(pif_path), 'requestSHA256': sha(request_path),
            'targetGUID': targets[profile], 'manifest': manifest_path.relative_to(root).as_posix(),
            'manifestSHA256': sha(manifest_path), 'taskStoreSHA256': sha(task_store),
            'plannedAppDriverTasks': len(candidates), 'driverJobsExecuted': False})
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
        'nativeTestExecutions': 0, 'appLaunches': 0, 'functionalAcceptance': False})


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
