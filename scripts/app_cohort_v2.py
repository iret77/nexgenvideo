"""Source-bound App roles that preserve unchanged compiler products across CI fixes."""
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import subprocess
import tempfile
import zipfile

from retained_app_test_products import api, archive_bytes, checksum, download, require, verify_artifact, write

MANIFEST = Path('scripts/fixtures/app-cohort.json')
ROLES = ('production', 'testable', 'tests')
NATIVE_OBJECTS = ('Sources', 'Engine', 'Tests', 'Package.swift', 'Package.resolved', 'Runtime', 'Metal', 'Vendor', 'plugins')
WHISPER_PREFIX = 'Products/Release/NexGenVideoTests.xctest/Contents/Frameworks/whisper.framework/'
WHISPER_SIGNED_SHA256 = 'c99f4c1ec811dbd250e599fc7d59b929990e5602ae64fe366433766dbec80129'
WHISPER_UNSIGNED_SHA256 = '50e9a18e22098bb673032ccb7205038de2cbd009fb67f969622bb939d0e89497'
WHISPER_UNSIGNED_BYTES = 5501136
ORIGINAL_NATIVE_REGRESSIONS = frozenset({
    'NexGenVideoTests.NativeButtonInteractionTests/actualDisabledSwiftUIButtonIsExcluded()',
    'NexGenVideoTests.NativeButtonInteractionTests/actualDuplicateButtonsCannotBecomeAUniqueTarget()',
    'NexGenVideoTests.NativeButtonInteractionTests/actualPreparedReaderProvesItsOwnParentImageAndTrust()',
    'NexGenVideoTests.NativeButtonInteractionTests/actualSwiftUIButtonIsDiscoveredWithoutAnExternalReader()',
    'NexGenVideoTests.NativeButtonInteractionTests/actualTraversalBudgetCannotQualifyAPartialTree()',
    'NexGenVideoTests.NativeButtonInteractionTests/actualWindowFrameCannotSubstituteForTheContentRoot()',
    'NexGenVideoTests.NativeButtonInteractionTests/cancellationDuringTheLastChildMessageCannotQualifyATree()',
    'NexGenVideoTests.NativeButtonInteractionTests/theLastChildMessageUsesItsOwnRemainingTimeout()',
})


def encoded(value):
    return (json.dumps(value, sort_keys=True, separators=(',', ':')) + '\n').encode()


def digest(value):
    return hashlib.sha256(encoded(value)).hexdigest()


def git(*args):
    return subprocess.check_output(['git', *args], stdin=subprocess.DEVNULL, timeout=30).decode().strip()


def objects(source, paths):
    require(re.fullmatch('[a-f0-9]{40}', source) is not None, 'Invalid App source identity')
    names = list(paths)
    require(all(isinstance(name, str) and str(Path(name)) == name and not name.startswith('/')
        and '..' not in Path(name).parts and '\n' not in name and '\0' not in name for name in names), 'Invalid source input path')
    result = subprocess.run(['git', 'cat-file', '--batch-check=%(objectname)'],
        input=''.join(source + ':' + name + '\n' for name in names), capture_output=True, text=True, check=True, timeout=30)
    values = result.stdout.splitlines()
    require(len(values) == len(names) and all(re.fullmatch('[a-f0-9]{40}', value) for value in values), 'Missing source input object')
    return dict(zip(names, values))


def lexical_imports(source, paths):
    names = list(paths)
    requests = ''.join(source + ':' + name + '\n' for name in names).encode()
    result = subprocess.run(['git', 'cat-file', '--batch'], input=requests, capture_output=True, check=True, timeout=30)
    raw, offset, imports = result.stdout, 0, set()
    require(len(raw) <= 64 * 1024**2, 'Compiler source projection exceeds its bound')
    for name in names:
        end = raw.index(b'\n', offset)
        fields = raw[offset:end].split()
        require(len(fields) == 3 and fields[1] == b'blob', 'Compiler source blob is missing: ' + name)
        size = int(fields[2]); offset = end + 1
        text = raw[offset:offset + size].decode()
        offset += size + 1
        imports.update(re.findall(r'^\s*(?:@\w+(?:\([^\n]*\))?\s+)*import\s+(?:class\s+|struct\s+|enum\s+|func\s+|var\s+|let\s+|typealias\s+|protocol\s+)?([A-Za-z_][A-Za-z_0-9]*)', text, re.M))
    require(offset == len(raw), 'Compiler source blob inventory is incomplete')
    return sorted(imports)


def manifest(source=None):
    raw = MANIFEST.read_bytes() if source is None else subprocess.check_output(
        ['git', 'show', source + ':' + MANIFEST.as_posix()], stdin=subprocess.DEVNULL, timeout=30)
    value = json.loads(raw)
    require(isinstance(value, dict) and value.get('schema') == 'native-app-cohort/v2'
        and set(value) == {'schema', 'appSourceSHA', 'appTreeSHA', 'version', 'build', 'nativeSourceObjects',
            'roleSourceObjects', 'componentSourceObjects', 'compilerSHA256', 'criteria', 'templateMetadata', 'retainedXCTestHost', 'signedBase', 'ciPaths'},
        'Unsupported App cohort manifest')
    require(re.fullmatch('[a-f0-9]{40}', value.get('appSourceSHA', ''))
        and re.fullmatch('[a-f0-9]{40}', value.get('appTreeSHA', ''))
        and re.fullmatch('[1-9][0-9]*', value.get('build', ''))
        and re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', value.get('version', ''))
        and set(value['nativeSourceObjects']) == set(NATIVE_OBJECTS)
        and set(value['roleSourceObjects']) == set(ROLES), 'Incomplete App cohort identity')
    require(isinstance(value['ciPaths'], list) and value['ciPaths'] == sorted(set(value['ciPaths']))
        and all(isinstance(name, str) and not name.startswith(('Sources/', 'Tests/', '/'))
            and '..' not in Path(name).parts for name in value['ciPaths']), 'Cohort CI closure includes product source')
    for role, inputs in value['roleSourceObjects'].items():
        require(isinstance(inputs, dict) and inputs and ('Tests/NexGenVideoTests' in inputs) == (role == 'tests')
            and 'Sources/NexGenVideo' not in inputs and not any(name.startswith('Sources/NexGenVideo/Resources/') for name in inputs)
            and all(isinstance(item, str) and re.fullmatch('[a-f0-9]{40}', item) for item in inputs.values()),
            'Compiler role includes unrelated or missing test inputs')
    criterion = value['criteria']
    require(criterion.get('path') == 'scripts/fixtures/app-cohort-native-inventory.json', 'Unsupported native inventory path')
    criterion_raw = Path(criterion['path']).read_bytes() if source is None else subprocess.check_output(
        ['git', 'show', source + ':' + criterion['path']], stdin=subprocess.DEVNULL, timeout=30)
    require(hashlib.sha256(criterion_raw).hexdigest() == criterion.get('sha256'), 'Independent App inventory changed')
    return value


def selects(source):
    return MANIFEST.is_file() and manifest()['appSourceSHA'] == source


def has_manifest(source):
    return subprocess.run(['git', 'cat-file', '-e', source + ':' + MANIFEST.as_posix()],
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30).returncode == 0


def compatible_source(source, role):
    previous, current = manifest(source), manifest()
    if role == 'metadata':
        require(previous['nativeSourceObjects'] == current['nativeSourceObjects'], 'Compiler metadata has different native inputs')
    else:
        require(role in ROLES and previous['roleSourceObjects'][role] == current['roleSourceObjects'][role]
            and objects(source, previous['roleSourceObjects'][role]) == previous['roleSourceObjects'][role],
            'Compiler role source inputs differ')
    require(previous['compilerSHA256'] == current['compilerSHA256'], 'Compiler toolchain changed')
    return previous


def consumer_ci_paths(product, harness):
    value, current = manifest(product), manifest(harness)
    require(objects(product, NATIVE_OBJECTS) == objects(harness, NATIVE_OBJECTS) == value['nativeSourceObjects'],
        'Runtime consumer has different App, test or component sources')
    require(current['appSourceSHA'] == value['appSourceSHA']
        and current['nativeSourceObjects'] == value['nativeSourceObjects']
        and current['roleSourceObjects'] == value['roleSourceObjects']
        and current['componentSourceObjects'] == value['componentSourceObjects']
        and objects(harness, value['componentSourceObjects']) == value['componentSourceObjects'],
        'Runtime cohort changed compiled or retained component inputs')
    subprocess.run(['git', 'merge-base', '--is-ancestor', product, harness],
        stdin=subprocess.DEVNULL, check=True, timeout=30)
    return set(current['ciPaths'])


def consumer_paths(product, harness):
    allowed = consumer_ci_paths(product, harness)
    require(git('rev-parse', 'HEAD') == harness == os.environ['GITHUB_SHA']
        and not git('status', '--porcelain', '--untracked-files=no'), 'Dirty or foreign runtime harness')
    changed = git('diff', '--name-only', '--no-renames', product, harness).splitlines()
    require(set(changed) <= allowed, 'Runtime consumer changed outside its reviewed CI closure')
    return allowed


def verify_context(context, *, current=False):
    require(isinstance(context, dict) and context.get('schema') == 'verified-native-app-cohort/v2', 'Missing verified App cohort')
    source = context.get('harnessSourceSHA', '')
    require(re.fullmatch('[a-f0-9]{40}', source) is not None, 'Invalid cohort harness identity')
    raw = subprocess.check_output(['git', 'show', source + ':' + MANIFEST.as_posix()], stdin=subprocess.DEVNULL, timeout=30)
    value = manifest(source)
    require(context.get('manifestSHA256') == hashlib.sha256(raw).hexdigest() and context.get('appSourceSHA') == value['appSourceSHA']
        and context.get('appTreeSHA') == value['appTreeSHA'] and context.get('nativeSourceObjects') == value['nativeSourceObjects']
        and context.get('roleSourceObjects') == value['roleSourceObjects']
        and context.get('componentSourceObjects') == value['componentSourceObjects'], 'App cohort context changed')
    if current:
        head = git('rev-parse', 'HEAD')
        require(head == os.environ.get('GITHUB_SHA') == context.get('harnessSourceSHA')
            and not git('status', '--porcelain', '--untracked-files=no'), 'Dirty or foreign compiler harness')
        require(value == manifest() and checksum(MANIFEST) == context['manifestSHA256']
            and objects(head, NATIVE_OBJECTS) == value['nativeSourceObjects'], 'Current native inputs differ from the App candidate')
        require(objects(head, value['componentSourceObjects']) == value['componentSourceObjects'], 'Retained component source changed')
    return value


def bind(root, selected):
    import native_current_cohort as legacy
    head = git('rev-parse', 'HEAD')
    value = manifest()
    require(selected['appSourceSHA'] == value['appSourceSHA'] and head == os.environ.get('GITHUB_SHA')
        and os.environ.get('GITHUB_REPOSITORY') == 'iret77/nexgenvideo'
        and not git('status', '--porcelain', '--untracked-files=no'), 'Wrong or dirty App cohort source')
    subprocess.run(['git', 'merge-base', '--is-ancestor', value['appSourceSHA'], head],
        stdin=subprocess.DEVNULL, check=True, timeout=30)
    require(git('rev-parse', value['appSourceSHA'] + '^{tree}') == value['appTreeSHA']
        and objects(value['appSourceSHA'], NATIVE_OBJECTS) == objects(head, NATIVE_OBJECTS) == value['nativeSourceObjects'],
        'App source tree or current native objects changed')
    changed = git('diff', '--name-only', '--no-renames', value['appSourceSHA'], head).splitlines()
    require(changed and set(changed) <= set(value['ciPaths']), 'Unreviewed source outside the cohort CI closure')
    require(objects(head, value['componentSourceObjects']) == value['componentSourceObjects'], 'Unchanged component contract differs')
    for role, expected in value['roleSourceObjects'].items():
        require(objects(head, expected) == expected, 'Compiler role input changed: ' + role)
    current_path = Path(os.environ['RUNNER_TEMP']) / 'transport-source-proof/receipt.json'
    current = json.loads(current_path.read_bytes())
    require(current.get('schema') == 'core-pr-source-composition/v1' and current.get('sourceSHA') == head
        and current.get('originalRun', {}).get('id') == selected['verifiedPRRunID']
        and current.get('originalPR', {}).get('merged') is True
        and current['originalPR'].get('merge_commit_sha') == head, 'Complete merged source receipt is missing')
    original, artifact = current['originalRun'], current['originalArtifact']
    require(selected == {'appSourceSHA': value['appSourceSHA'], 'verifiedPRRunID': original['id'],
        'runID': original['id'], 'sourceSHA': original['head_sha'], 'artifactID': artifact['id'],
        'artifactSHA256': artifact['digest'].removeprefix('sha256:')}, 'App source selectors do not name the qualified current receipt')
    root.mkdir(parents=True, exist_ok=False)
    context = {'schema': 'verified-native-app-cohort/v2', 'manifestSHA256': checksum(MANIFEST),
        'appSourceSHA': value['appSourceSHA'], 'appTreeSHA': value['appTreeSHA'], 'harnessSourceSHA': head,
        'nativeSourceObjects': value['nativeSourceObjects'], 'roleSourceObjects': value['roleSourceObjects'],
        'componentSourceObjects': value['componentSourceObjects']}
    shape = legacy.buildshape(head, app_source=value['appSourceSHA'])
    write(root / 'binding.json', {'schema': 'native-current-cohort-binding/v2', 'harnessSourceSHA': head,
        'selected': selected, 'nativeSourceObjects': value['nativeSourceObjects'], 'changedHarnessPaths': changed,
        'currentSourceComposition': current, 'cohortV2': context, 'templateProjection': shape,
        'appCandidateSHA': value['appSourceSHA'], 'appCandidateTree': value['appTreeSHA'],
        'appProductCompilationAuthorised': False, 'functionalAcceptance': False})
    shutil.copyfile(current_path, root / 'current-source-composition.json')


def verify_template(binding, run, artifact, current):
    import native_current_cohort as legacy
    value = verify_context(current['cohortV2'])
    origin = value['templateMetadata']
    require((artifact['id'], artifact['digest'].removeprefix('sha256:'))
        == (origin['artifactID'], origin['artifactSHA256'])
        and run['id'] == origin['runID'] and run['head_sha'] == origin['sourceSHA']
        and binding['schema'] == 'native-app-build-plan-binding/v1'
        and binding['harnessSourceSHA'] == run['head_sha'] and binding['selected'] == legacy.TEMPLATE_SELECTED
        and binding['nativeSourceObjects'] == legacy.objects(legacy.TEMPLATE_SOURCE)
        and current['nativeSourceObjects'] == value['nativeSourceObjects']
        and current['templateProjection'] == legacy.buildshape(os.environ['GITHUB_SHA'], app_source=value['appSourceSHA']),
        'Original recipe metadata or new App projection differs')


def recipe_identity(prepared, phase):
    value = verify_context(prepared['cohortV2'])
    require(phase in ROLES and prepared['compilerSHA256'] == value['compilerSHA256'], 'Unknown compiler role or toolchain')
    plan = prepared['plans'][phase]
    return digest({'driver': plan['driver'], 'operations': plan['operations'],
        'roleSourceObjects': value['roleSourceObjects'][phase], 'compilerSHA256': prepared['compilerSHA256']})


def compatible_product(receipt, prepared, phase):
    current = verify_context(prepared['cohortV2'])
    context = receipt.get('cohortV2', {})
    source = receipt.get('sourceSHA', '')
    require(re.fullmatch('[a-f0-9]{40}', source) is not None, 'Invalid retained compiler source')
    raw = subprocess.check_output(['git', 'show', source + ':' + MANIFEST.as_posix()], stdin=subprocess.DEVNULL, timeout=30)
    previous = json.loads(raw)
    require(context.get('schema') == 'verified-native-app-cohort/v2'
        and hashlib.sha256(raw).hexdigest() == context.get('manifestSHA256')
        and context.get('appSourceSHA') == previous.get('appSourceSHA') == receipt.get('appSourceSHA')
        and receipt.get('nativeSourceObjects') == context.get('nativeSourceObjects') == previous.get('nativeSourceObjects')
        and objects(source, NATIVE_OBJECTS) == previous['nativeSourceObjects']
        and context.get('roleSourceObjects') == previous.get('roleSourceObjects')
        and previous['roleSourceObjects'][phase] == current['roleSourceObjects'][phase]
        and objects(source, previous['roleSourceObjects'][phase]) == previous['roleSourceObjects'][phase]
        and receipt.get('compilerSHA256') == current['compilerSHA256'] == previous.get('compilerSHA256')
        and receipt.get('recipeSHA256') == recipe_identity(prepared, phase), 'Retained compiler role inputs or recipe changed')
    return True


def criteria(source=None):
    value = manifest(source)
    raw = Path(value['criteria']['path']).read_bytes() if source is None else subprocess.check_output(
        ['git', 'show', source + ':' + value['criteria']['path']], stdin=subprocess.DEVNULL, timeout=30)
    expected = json.loads(raw)
    require(expected.get('schema') == 'compiled-app-native-inventory/v1'
        and expected.get('appSourceSHA') == value['appSourceSHA']
        and expected.get('nativeSourceObjects') == value['nativeSourceObjects'], 'Cohort native inventory identity differs')
    for module in expected['modules'].values():
        ended, skipped = module['exactEndedFunctionIDs'], module['exactSkippedFunctionIDs']
        require(len(set(ended)) == len(ended) and len(set(skipped)) == len(skipped)
            and not set(ended) & set(skipped), 'Native inventory has duplicate or overlapping roles')
        module['exactDiscoveredFunctionIDs'] = sorted(set(ended) | set(skipped))
    regressions = expected.get('originalEightAppFailureIDsRequiredToEndWithoutIssues')
    require(isinstance(regressions, list) and len(regressions) == len(ORIGINAL_NATIVE_REGRESSIONS)
        and all(isinstance(identity, str) for identity in regressions)
        and len(set(regressions)) == len(regressions)
        and {identity.rsplit('/', 1)[0] for identity in regressions} == ORIGINAL_NATIVE_REGRESSIONS
        and set(regressions) <= set(expected['modules']['app']['exactEndedFunctionIDs']),
        'Original native regressions must name exact current App execution IDs')
    require(expected['expectedActualExecutions'] == sum(len(module['exactEndedFunctionIDs']) for module in expected['modules'].values())
        + len(expected['xctest']['exactIndividualPassedIDs']), 'Native expected count differs from independent IDs')
    return expected


def acquire_host(root):
    value = manifest()['retainedXCTestHost']
    selected = value['producer']
    run = api('actions/runs/' + str(selected['runID']))
    jobs = api(f"actions/runs/{selected['runID']}/attempts/1/jobs?per_page=100")
    require(run.get('head_sha') == selected['sourceSHA'] and run.get('repository', {}).get('full_name') == 'iret77/nexgenvideo'
        and run.get('actor', {}).get('login') == 'iret77' and run.get('run_attempt') == 1
        and run.get('path') == '.github/workflows/diagnostic-acceptance.yml' and run.get('status') == 'completed'
        and jobs.get('total_count') == len(jobs.get('jobs', [])), 'Retained XCTest host producer changed')
    native = [job for job in jobs['jobs'] if job.get('name') == 'app-target-build']
    require(len(native) == 1 and native[0].get('labels') == ['macrunner']
        and [step.get('conclusion') for step in native[0].get('steps', [])
            if step.get('name') == 'Build only the dependent App tests target'] == ['success'], 'Host compiler product did not complete')
    artifact = api('actions/artifacts/' + str(selected['artifactID']))
    verify_artifact(artifact, run, native[0], selected['artifactID'], selected['artifactSHA256'], 'app-target-tests-products')
    folder = root / 'retained-xctest-host'; folder.mkdir()
    with tempfile.TemporaryDirectory(dir=root) as directory:
        outer = Path(directory) / 'original.zip'; download(artifact, outer)
        require(checksum(outer) == selected['artifactSHA256'], 'Original host product archive changed')
        with zipfile.ZipFile(outer) as archive:
            require(archive.namelist() == ['tests-products.zip'], 'Original test product wrapper changed')
            inner = Path(directory) / 'products.zip'
            with archive.open('tests-products.zip') as source, inner.open('xb') as target:
                shutil.copyfileobj(source, target, 1024 * 1024)
        with zipfile.ZipFile(inner) as archive:
            raw = archive_bytes(archive, 'product-receipt.json', 16 * 1024**2)
            require(hashlib.sha256(raw).hexdigest() == selected['receiptSHA256'], 'Original host receipt changed')
            receipt = json.loads(raw)
            host = receipt['state']['xctestHost']
            require(receipt.get('phase') == 'tests' and receipt.get('sourceSHA') == selected['sourceSHA']
                and receipt.get('runID') == selected['runID'] and receipt.get('appSourceSHA') == value['originalAppSourceSHA']
                and receipt['state'].get('compileComplete') is True and receipt['state'].get('linkComplete') is True
                and host.get('signedSHA256') == value['sha256'] and host.get('unsignedSHA256') == value['unsignedSHA256']
                and host.get('supportObjectSHA256') == value['supportObjectSHA256']
                and all(host.get('inputs', {}).get(name) == sha for name, sha in value['compiledInputs'].items()),
                'Retained host compiler, source or completed image differs')
            image = archive_bytes(archive, value['member'], 4 * 1024**2)
            require(hashlib.sha256(image).hexdigest() == value['sha256'], 'Retained host image changed')
            (folder / 'NexGenVideoXCTestHost').write_bytes(image)
            os.chmod(folder / 'NexGenVideoXCTestHost', 0o755)
            (folder / 'product-receipt.json').write_bytes(raw)
            retain_signed_whisper(archive, receipt, folder)
    write(folder / 'origin.json', {'schema': 'retained-xctest-host-input/v1', 'selected': selected,
        'artifact': artifact, 'run': run, 'job': native[0], 'host': host, 'currentCompilerExecutions': 0})


def install_host(source_root, bundle, prepared):
    value = verify_context(prepared['cohortV2'])['retainedXCTestHost']
    for name, sha in value['compiledInputs'].items():
        require(checksum(Path(name)) == sha, 'Retained host compiler input changed')
    folder = source_root / 'retained-xctest-host'
    source = folder / 'NexGenVideoXCTestHost'
    require(source.is_file() and not source.is_symlink() and checksum(source) == value['sha256'], 'Retained host transfer changed')
    target = bundle / 'Contents/Helpers/NexGenVideoXCTestHost'
    require(not target.parent.is_symlink() and not target.is_symlink(), 'Retained host destination is linked')
    target.parent.mkdir(exist_ok=True)
    if target.exists():
        require(target.is_file() and checksum(target) == value['sha256']
            and stat.S_IMODE(target.stat().st_mode) == 0o755, 'Partial host restore differs from its qualified bytes')
    else:
        shutil.copyfile(source, target); os.chmod(target, 0o755)
    origin = json.loads((folder / 'origin.json').read_bytes())
    require(origin.get('selected') == value['producer'] and origin.get('host', {}).get('signedSHA256') == value['sha256'],
        'Retained host origin changed during transfer')
    return {'schema': 'native-xctest-host-reuse/v1', 'original': origin['host'], 'selected': origin['selected'],
        'hostSHA256': value['sha256'], 'appSourceSHA': prepared['appSourceSHA'], 'compilerExecutions': 0}


def framework_inventory(root):
    result = {}
    for path in sorted(root.rglob('*')):
        relative = path.relative_to(root).as_posix()
        if path.is_symlink():
            require(path.resolve().is_relative_to(root.resolve()), 'Retained framework link escapes its root')
            result[relative] = {'kind': 'symlink', 'target': os.readlink(path), 'mode': stat.S_IMODE(path.lstat().st_mode)}
        elif path.is_file():
            result[relative] = {'kind': 'file', 'sha256': checksum(path), 'bytes': path.stat().st_size,
                'mode': stat.S_IMODE(path.stat().st_mode)}
        else:require(path.is_dir(), 'Retained framework contains a special file')
    return result


def signed_whisper_files(receipt):
    files = {name.removeprefix(WHISPER_PREFIX): item for name, item in receipt['files'].items() if name.startswith(WHISPER_PREFIX)}
    image = files.get('Versions/A/whisper', {})
    require(files and image.get('sha256') == WHISPER_SIGNED_SHA256 and image.get('mode') == 0o755
        and 'Versions/A/_CodeSignature/CodeResources' in files, 'Qualified signed Whisper product differs')
    for name, item in files.items():
        relative = PurePosixPath(name)
        require(str(relative) == name and not relative.is_absolute() and '..' not in relative.parts and '\\' not in name
            and item.get('kind') in {'file', 'symlink'}, 'Invalid retained framework path')
        if item['kind'] == 'symlink':
            target = PurePosixPath(item['target'])
            require(not target.is_absolute() and '..' not in target.parts,
                'Invalid retained framework link')
    return files


def retain_signed_whisper(archive, receipt, folder):
    files = signed_whisper_files(receipt)
    with zipfile.ZipFile(folder / 'whisper-framework.zip', 'x', compression=zipfile.ZIP_DEFLATED) as transport:
        for name, item in files.items():
            if item['kind'] == 'symlink':raw = item['target'].encode()
            else:
                raw = archive_bytes(archive, 'outputs/' + WHISPER_PREFIX + name, 16 * 1024**2)
                require(len(raw) == item['bytes'] and hashlib.sha256(raw).hexdigest() == item['sha256'], 'Retained framework bytes differ')
            transport.writestr(name, raw)


def restore_signed_whisper(folder, files):
    transport = folder / 'whisper-framework.zip'
    require(transport.is_file() and not transport.is_symlink(), 'Retained framework transport is missing or linked')
    root = folder / 'whisper.framework'
    if root.exists():
        require(root.is_dir() and not root.is_symlink() and framework_inventory(root) == files,
            'Existing native framework materialization differs')
        return root
    root.mkdir()
    with zipfile.ZipFile(transport) as archive:
        entries = archive.infolist()
        require(len(entries) == len(files) and {entry.filename for entry in entries} == set(files)
            and sum(entry.file_size for entry in entries) <= 16 * 1024**2, 'Retained framework transport inventory differs')
        for name, item in files.items():
            if item['kind'] == 'symlink':continue
            raw = archive_bytes(archive, name, 16 * 1024**2)
            require(len(raw) == item['bytes'] and hashlib.sha256(raw).hexdigest() == item['sha256'], 'Retained framework transfer bytes differ')
            target = root / name;target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(raw);os.chmod(target, item['mode'])
        for name, item in files.items():
            if item['kind'] != 'symlink':continue
            require(archive_bytes(archive, name, 4096) == item['target'].encode(), 'Retained framework transfer link differs')
            target = root / name;target.parent.mkdir(parents=True, exist_ok=True);target.symlink_to(item['target'])
    require(framework_inventory(root) == files, 'Retained framework tree differs from its qualified receipt')
    return root


def install_signed_whisper(source_root, bundle, prepared):
    selected = verify_context(prepared['cohortV2'])['retainedXCTestHost']['producer']
    folder = source_root / 'retained-xctest-host'
    receipt_path = folder / 'product-receipt.json'
    require(receipt_path.is_file() and not receipt_path.is_symlink() and checksum(receipt_path) == selected['receiptSHA256'],
        'Retained framework original receipt changed')
    receipt = json.loads(receipt_path.read_bytes())
    require(receipt.get('sourceSHA') == selected['sourceSHA'] and receipt.get('runID') == selected['runID']
        and receipt.get('attempt') == 1 and receipt.get('phase') == 'tests' and receipt['state'].get('linkComplete') is True,
        'Retained framework producer differs')
    expected = signed_whisper_files(receipt)
    source = restore_signed_whisper(folder, expected)
    target = bundle / 'Contents/Frameworks/whisper.framework'
    require(target.is_dir() and not target.is_symlink() and not target.parent.is_symlink(), 'Current test framework is missing or linked')
    current = framework_inventory(target)
    if current != expected:
        unsigned = {name:item for name,item in expected.items() if '/_CodeSignature/' not in name}
        unsigned['Versions/A/whisper'] = dict(unsigned['Versions/A/whisper'], sha256=WHISPER_UNSIGNED_SHA256, bytes=WHISPER_UNSIGNED_BYTES)
        require(current == unsigned, 'Current framework differs from the original unsigned or qualified signed product')
        preserved = folder / 'original-unsigned-whisper.framework'
        require(not preserved.exists() and not preserved.is_symlink(), 'Unsigned framework preservation already consumed')
        target.rename(preserved)
        shutil.copytree(source, target, symlinks=True)
    require(framework_inventory(target) == expected, 'Installed signed framework differs from the original qualified bytes')
    return {'schema': 'native-test-framework-reuse/v1', 'framework': 'whisper.framework', 'producer': selected,
        'originalReceiptSHA256': selected['receiptSHA256'], 'imageSHA256': WHISPER_SIGNED_SHA256,
        'filesSHA256': hashlib.sha256(encoded(expected)).hexdigest(),
        'transportSHA256': checksum(folder / 'whisper-framework.zip'), 'compilerExecutions': 0, 'signingExecutions': 0}
