"""Build once and transfer the exact external XCTest products between CI jobs."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import posixpath
import re
import shutil
import stat
import tarfile
import tempfile
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
import zipfile

import acceptance as journey

REPOSITORY = 'iret77/nexgenvideo'
ARTIFACT = 'external-gui-tests'
MEMBERS = {'tests.tar.gz', 'tests-input.json'}
WORKFLOWS = {'.github/workflows/external-gui-acceptance.yml', '.github/workflows/ci-batch.yml',
             '.github/workflows/release.yml', '.github/workflows/diagnostic-acceptance.yml'}


def require(value, message):
    journey.require(value, message)


def api(path):
    request = urllib.request.Request('https://api.github.com/repos/' + REPOSITORY + path,
        headers={'Authorization': 'Bearer ' + os.environ['GH_TOKEN'], 'Accept': 'application/vnd.github+json',
                 'X-GitHub-Api-Version': '2022-11-28'})
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def items(path, key):
    page = 1
    while True:
        batch = api(path + f'?per_page=100&page={page}')[key]
        yield from batch
        if len(batch) < 100:
            return
        page += 1


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, target):
        return None


def download(artifact, destination):
    request = urllib.request.Request(
        f'https://api.github.com/repos/{REPOSITORY}/actions/artifacts/{artifact["id"]}/zip',
        headers={'Authorization': 'Bearer ' + os.environ['GH_TOKEN'], 'Accept': 'application/vnd.github+json'})
    try:
        response = urllib.request.build_opener(NoRedirect()).open(request, timeout=30)
    except urllib.error.HTTPError as error:
        if error.code != 302:
            raise ValueError('GitHub refused the exact UI test artifact') from None
        location = error.headers.get('Location', '')
        error.close()
        target = urllib.parse.urlsplit(location)
        require(target.scheme == 'https' and target.hostname and not target.username and not target.password,
                'Invalid artifact redirect')
        response = urllib.request.urlopen(location, timeout=120)
    with response, destination.open('xb') as sink:
        shutil.copyfileobj(response, sink)
    require('sha256:' + journey.sha256(destination) == artifact['digest'], 'UI test GitHub artifact digest changed')


def unpack_transfer(archive, destination):
    with zipfile.ZipFile(archive) as bundle:
        entries = bundle.infolist()
        require(len(entries) == len(MEMBERS) and {entry.filename for entry in entries} == MEMBERS,
                'Unexpected UI test transfer members')
        for entry in entries:
            require(not entry.is_dir() and stat.S_IFMT(entry.external_attr >> 16) in {0, stat.S_IFREG},
                    'UI test transfer contains a link or special member')
            with bundle.open(entry) as source, (destination / entry.filename).open('xb') as sink:
                shutil.copyfileobj(source, sink)


def require_origin(run, artifact, source_sha, run_id):
    require(run.get('id') == run_id and run.get('repository', {}).get('full_name') == REPOSITORY
            and run.get('head_sha') == source_sha and run.get('event') in {'workflow_dispatch', 'workflow_call'}
            and run.get('path') in WORKFLOWS, 'UI test producer has a different source or workflow')
    require(artifact.get('name') == ARTIFACT and artifact.get('expired') is False
            and artifact.get('workflow_run', {}).get('id') == run_id
            and artifact.get('workflow_run', {}).get('head_sha') == source_sha
            and type(artifact.get('id')) is int and artifact['id'] > 0
            and re.fullmatch(r'sha256:[a-f0-9]{64}', artifact.get('digest', '')),
            'UI test artifact has a different producer or expired identity')


def require_receipt(receipt, source_sha, source_files):
    require(receipt.get('schema') == 'nexgenvideo/external-tests-input/1'
            and receipt.get('sourceSHA') == source_sha and receipt.get('testFiles') == source_files
            and receipt.get('architecture') == 'arm64' and receipt.get('deploymentTarget') == '26.0'
            and isinstance(receipt.get('xcode'), str) and receipt['xcode'].startswith('Xcode ')
            and type(receipt.get('runID')) is int and receipt['runID'] > 0
            and type(receipt.get('attempt')) is int and receipt['attempt'] > 0
            and all(re.fullmatch('[a-f0-9]{64}', receipt.get(key, ''))
                    for key in ('archiveSHA256', 'productsSHA256')),
            'UI test receipt does not bind the current test inputs')
    path = receipt.get('xctestrun', '')
    require(isinstance(path, str) and PurePosixPath(path).name == path and path.endswith('.xctestrun'),
            'Invalid xctestrun location')


def require_job(job, run_id, source_sha, attempt):
    require(job.get('run_id') == run_id and job.get('head_sha') == source_sha
            and job.get('run_attempt') == attempt and job.get('status') == 'completed'
            and job.get('conclusion') == 'success' and type(job.get('id')) is int and job['id'] > 0
            and job.get('name', '').split(' / ')[-1] == 'Build external UI tests'
            and 'macrunner' in job.get('labels', []), 'UI test build job did not finish successfully')


def _test_builder_view(text, *, workflow=False, shared_guard=False):
    import ast
    if workflow:
        prefix, jobs = text.split('\njobs:\n', 1)
        matches = list(re.finditer(r'(?m)^  ([A-Za-z0-9_-]+):\n', jobs))
        require([match[1] for match in matches] == ['cases', 'test-build', 'test-runtime', 'acceptance'],
                'Unrecognized UI test build workflow')
        return prefix + '\njobs:\n' + ''.join(jobs[match.start():matches[index + 1].start() if index + 1 < len(matches) else len(jobs)]
            for index, match in enumerate(matches) if match[1] not in {'test-runtime', 'acceptance'})
    module = ast.parse(text)
    if shared_guard:
        assignments = [node for node in module.body if isinstance(node, ast.Assign) and len(node.targets) == 1
                       and isinstance(node.targets[0], ast.Name) and node.targets[0].id == 'SIGNED_TRANSPORT_HARNESS_PATHS']
        require(len(assignments) == 1, 'Unsupported transport-only guard change')
        original = ast.parse('SIGNED_ACCEPTANCE_EVIDENCE_PATHS', mode='eval').body
        extended = ast.parse('SIGNED_ACCEPTANCE_EVIDENCE_PATHS | {"scripts/external-gui/test_bundle.py"}', mode='eval').body
        require(ast.dump(assignments[0].value) in {ast.dump(original), ast.dump(extended)}, 'Unsupported transport-only guard change')
        assignments[0].value = original
        return ast.dump(module, include_attributes=False)
    consumers = {'resolve', 'verify_input', 'consume', '_test_builder_view', '_source_snapshot', '_transport_compatibility'}
    for node in module.body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name in consumers:
            require(not node.decorator_list and node.returns is None
                    and all(argument.annotation is None for argument in (*node.args.posonlyargs, *node.args.args, *node.args.kwonlyargs))
                    and node.args.vararg is None and node.args.kwarg is None, 'Consumer declaration changes module execution')
            for value in [*node.args.defaults, *filter(None, node.args.kw_defaults)]:
                require(isinstance(ast.literal_eval(value), (bool, type(None))), 'Consumer default changes module execution')
    module.body = [node for node in module.body if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) or node.name not in consumers]
    return ast.dump(module, include_attributes=False)


def _source_snapshot(source_sha, paths):
    import base64
    require(re.fullmatch('[a-f0-9]{40}', source_sha), 'Invalid original test source')
    files = {}
    texts = {}
    for name in [*paths, '.github/workflows/external-gui-acceptance.yml']:
        response = api('/contents/' + name + '?ref=' + source_sha)
        require(response.get('type') == 'file' and response.get('encoding') == 'base64', 'Original test input is not a regular source file')
        raw = base64.b64decode(response['content'], validate=False)
        files[name] = hashlib.sha256(raw).hexdigest()
        if name in {'scripts/external-gui/test_bundle.py', '.github/workflows/external-gui-acceptance.yml'}:
            texts[name] = raw.decode()
    return files, texts


def _transport_compatibility(producer_sha, producer_files, current_sha, current_files, builder, workflow, comparison):
    from verify_diagnostic_candidate import SIGNED_TRANSPORT_HARNESS_PATHS
    require(re.fullmatch('[a-f0-9]{40}', producer_sha) and producer_sha != current_sha
            and set(producer_files) == set(current_files), 'Different or incomplete original UI test inputs')
    require(comparison.get('base_commit', {}).get('sha') == producer_sha
            and comparison.get('merge_base_commit', {}).get('sha') == producer_sha
            and comparison.get('status') == 'ahead'
            and 0 < len(comparison.get('commits', [])) == comparison.get('total_commits') <= 250
            and comparison['commits'][-1].get('sha') == current_sha
            and len(comparison.get('files', [])) < 300
            and all(item.get('status') == 'modified' and not item.get('previous_filename') for item in comparison['files'])
            and not {item['filename'] for item in comparison['files']} - SIGNED_TRANSPORT_HARNESS_PATHS,
            'UI test reuse is outside the retained transport harness')
    git = ['git', '-C', journey.REPOSITORY]
    require(journey.output([*git, 'rev-parse', 'HEAD']).decode().strip() == current_sha,
            'UI test consumer is not the declared checkout')
    require(journey.output([*git, 'merge-base', producer_sha, current_sha]).decode().strip() == producer_sha,
            'Original UI test producer is not an ancestor')
    commits = journey.output([*git, 'rev-list', producer_sha + '..' + current_sha]).decode().splitlines()
    require(len(commits) == len(set(commits)) == comparison['total_commits']
            and set(commits) == {item['sha'] for item in comparison['commits']}, 'Original UI test commit graph changed')
    changes = journey.output([*git, 'diff', '--no-renames', '--name-status', '-z', producer_sha, current_sha]).decode().split('\0')
    require(changes[-1] == '' and len(changes[:-1]) % 2 == 0, 'Incomplete original UI test source diff')
    changes = list(zip(changes[:-1:2], changes[1:-1:2]))
    require(all(status == 'M' and name in SIGNED_TRANSPORT_HARNESS_PATHS for status, name in changes)
            and len(changes) == len(comparison['files'])
            and {name for _, name in changes} == {item['filename'] for item in comparison['files']},
            'Original UI test source diff changed')
    original_blobs = {name: journey.output([*git, 'show', producer_sha + ':' + name]) for name in producer_files}
    require({name: hashlib.sha256(raw).hexdigest() for name, raw in original_blobs.items()} == producer_files,
            'Original UI test input map differs from its Git objects')
    helper = 'scripts/external-gui/test_bundle.py'
    runtime = 'scripts/external-gui/transport.py'
    guard = 'scripts/verify_diagnostic_candidate.py'
    require(all(producer_files[name] == value for name, value in current_files.items() if name not in {helper, runtime, guard}),
            'Compiled UI test inputs or shared build helpers changed')
    current_guard = (journey.REPOSITORY / guard).read_bytes()
    require(hashlib.sha256(current_guard).hexdigest() == current_files[guard], 'Current UI test build guard bytes changed')
    guard_recipe = _test_builder_view(original_blobs[guard].decode(), shared_guard=True)
    require(guard_recipe == _test_builder_view(current_guard.decode(), shared_guard=True), 'UI test build guard changed outside the transport declaration')
    current_builder = Path(__file__).read_bytes().decode()
    require(hashlib.sha256(current_builder.encode()).hexdigest() == current_files[helper]
            and builder.encode() == original_blobs[helper], 'UI test build source bytes changed')
    recipe = _test_builder_view(builder)
    require(recipe == _test_builder_view(current_builder), 'UI test build recipe, imports or constants changed')
    workflow_path = '.github/workflows/external-gui-acceptance.yml'
    require(workflow.encode() == journey.output([*git, 'show', producer_sha + ':' + workflow_path]),
            'Original UI test workflow differs from its Git object')
    current_workflow = journey.output(['git', '-C', journey.REPOSITORY, 'show', current_sha + ':' + workflow_path]).decode()
    require((journey.REPOSITORY / workflow_path).read_bytes().decode() == current_workflow, 'Current UI test workflow is uncommitted')
    workflow_recipe = _test_builder_view(workflow, workflow=True)
    require(workflow_recipe == _test_builder_view(current_workflow, workflow=True), 'UI test build workflow changed')
    return {'schema': 'nexgenvideo/external-tests-transport-compatibility/1', 'kind': 'transport',
        'producerSourceSHA': producer_sha, 'consumerSourceSHA': current_sha,
        'producerFiles': producer_files, 'consumerFiles': current_files, 'producerBuilder': builder,
        'producerWorkflow': workflow, 'comparison': comparison,
        'buildRecipeSHA256': hashlib.sha256(recipe.encode()).hexdigest(),
        'buildGuardSHA256': hashlib.sha256(guard_recipe.encode()).hexdigest(),
        'buildWorkflowSHA256': hashlib.sha256(workflow_recipe.encode()).hexdigest()}


def resolve(args):
    source_sha, source_files = journey.test_source_identity(os.environ['GITHUB_SHA'])
    run = api(f'/actions/runs/{args.run_id}')
    current = int(os.environ['GITHUB_RUN_ID'])
    require(run.get('status') == 'completed' or args.run_id == current,
            'A reused UI test producer must have finished')
    candidates = [api(f'/actions/artifacts/{args.artifact_id}')] if args.artifact_id else [
        artifact for artifact in items(f'/actions/runs/{args.run_id}/artifacts', 'artifacts')
        if artifact.get('name') == ARTIFACT and artifact.get('expired') is False]
    require(len(candidates) == 1, 'Exactly one original UI test artifact is required')
    artifact = candidates[0]
    producer_sha = run.get('head_sha')
    compatibility = None
    producer_files = source_files
    if producer_sha != source_sha:
        require(os.environ.get('NGV_TRANSPORT_TEST_BUNDLE_REUSE') == '1', 'UI test producer has a different source')
        snapshot, texts = _source_snapshot(producer_sha, source_files)
        producer_files = {name: snapshot[name] for name in source_files}
        compatibility = _transport_compatibility(producer_sha, producer_files, source_sha, source_files,
            texts['scripts/external-gui/test_bundle.py'], texts['.github/workflows/external-gui-acceptance.yml'],
            api('/compare/' + producer_sha + '...' + source_sha))
    require_origin(run, artifact, producer_sha, args.run_id)
    destination = Path(args.destination)
    destination.mkdir(parents=True, exist_ok=False)
    archive = destination.parent / 'external-tests-transfer.zip'
    download(artifact, archive)
    unpack_transfer(archive, destination)
    receipt = journey.read_json(destination / 'tests-input.json')
    require_receipt(receipt, producer_sha, producer_files)
    require(receipt['runID'] == args.run_id, 'UI test receipt has another producer')
    jobs = [job for job in items(f'/actions/runs/{args.run_id}/attempts/{receipt["attempt"]}/jobs', 'jobs')
            if job.get('name', '').split(' / ')[-1] == 'Build external UI tests']
    require(len(jobs) == 1, 'Expected one original UI test build job')
    require_job(jobs[0], args.run_id, producer_sha, receipt['attempt'])
    require(journey.sha256(destination / 'tests.tar.gz') == receipt['archiveSHA256'], 'UI test archive changed')
    journey.write_json(destination / 'tests-producer.json', {
        'schema': 'nexgenvideo/external-tests-producer/1', 'run': run, 'artifact': artifact, 'job': jobs[0],
        'receiptSHA256': journey.sha256(destination / 'tests-input.json'),
        **({'transportCompatibility': compatibility} if compatibility else {})})
    with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
        output.write('producer_sha256=' + journey.sha256(destination / 'tests-producer.json') + '\n')


def unpack_products(archive, destination):
    require(not destination.exists(), 'Refusing to replace UI test products')
    with tarfile.open(archive, 'r:gz') as bundle:
        entries = bundle.getmembers()
        names = set()
        links = set()
        canonical = lambda name: unicodedata.normalize('NFD', name).casefold()
        for entry in entries:
            path = PurePosixPath(entry.name)
            require(entry.name and not path.is_absolute() and all(part not in {'', '.', '..'}
                    for part in entry.name.split('/')) and canonical(entry.name) not in names,
                    'Unsafe or duplicate UI test product path')
            names.add(canonical(entry.name))
            require(entry.isdir() or entry.isfile() or entry.issym(), 'Unsupported UI test product member')
            require(not entry.mode & 0o7000, 'Privileged UI test product mode')
            if entry.issym():
                target = posixpath.normpath(posixpath.join(str(path.parent), entry.linkname))
                require(entry.linkname and not PurePosixPath(entry.linkname).is_absolute()
                        and target != '..' and not target.startswith('../'), 'UI test product symlink escapes')
                links.add(canonical(entry.name))
        require(all(not any(canonical(str(parent)) in links for parent in PurePosixPath(name).parents)
                    for name in names), 'UI test archive writes through a symlink')
        destination.mkdir(parents=True)
        for entry in entries:
            path = destination / entry.name
            parent = destination
            for part in PurePosixPath(entry.name).parts[:-1]:
                parent = parent / part
                require(not parent.is_symlink(), 'UI test product parent is a symlink')
                parent.mkdir(exist_ok=True)
                require(parent.resolve().is_relative_to(destination.resolve()), 'UI test product parent escapes')
            if entry.isdir():
                path.mkdir(exist_ok=True)
            elif entry.isfile():
                with bundle.extractfile(entry) as source, path.open('xb') as sink:
                    shutil.copyfileobj(source, sink)
            else:
                path.symlink_to(entry.linkname)
        for entry in reversed(entries):
            path = destination / entry.name
            if not entry.issym():
                path.chmod(entry.mode)
            else:
                require(path.resolve(strict=True).is_relative_to(destination.resolve()),
                        'UI test product symlink does not resolve inside the products')


def products_sha256(root):
    records = []
    for path in sorted(root.rglob('*')):
        mode = path.lstat().st_mode
        relative = path.relative_to(root).as_posix()
        if path.is_symlink():
            require(path.resolve(strict=True).is_relative_to(root.resolve()), 'UI test product symlink escapes')
            record = [relative, 'symlink', os.readlink(path)]
        elif path.is_file():
            record = [relative, stat.S_IMODE(mode), 'file', journey.sha256(path)]
        else:
            require(path.is_dir(), 'Unsupported UI test product')
            record = [relative, stat.S_IMODE(mode), 'directory']
        records.append(record)
    return hashlib.sha256(json.dumps(records, ensure_ascii=True, separators=(',', ':')).encode()).hexdigest()


def check_test_paths(xctestrun, products):
    data = plistlib.loads(xctestrun.read_bytes())
    found = set()

    def walk(value, key='', host=None):
        if isinstance(value, dict):
            host = value.get('TestHostPath', host)
            for name, child in value.items():
                walk(child, name, host)
        elif isinstance(value, list):
            for child in value:
                walk(child, key, host)
        elif isinstance(value, str) and key in {'TestBundlePath', 'TestHostPath', 'DependentProductPaths'}:
            if value.startswith('__TESTHOST__/'):
                require(isinstance(host, str) and host.startswith('__TESTROOT__/'), 'Missing relative UI test host')
                value = host + value.removeprefix('__TESTHOST__')
            require(value.startswith('__TESTROOT__/'), 'Test bundle paths must be relative to __TESTROOT__')
            relative = value.removeprefix('__TESTROOT__/')
            require('..' not in PurePosixPath(relative).parts, 'Test bundle path escapes its products')
            path = products / relative
            require(path.exists() and path.resolve().is_relative_to(products.resolve()), 'Missing relocated test product')
            found.add(key)
    walk(data)
    require({'TestBundlePath', 'TestHostPath'} <= found, 'Missing UI test bundle or test host path')


def verify_input(directory, source_sha, source_files, *, transport_reuse=False):
    receipt = journey.read_json(directory / 'tests-input.json')
    producer = journey.read_json(directory / 'tests-producer.json')
    producer_sha = source_sha
    producer_files = source_files
    compatibility = producer.get('transportCompatibility')
    if compatibility is not None:
        require(transport_reuse and compatibility.get('schema') == 'nexgenvideo/external-tests-transport-compatibility/1'
                and compatibility.get('kind') == 'transport', 'UI test compatibility requires explicit public transport')
        producer_sha = compatibility.get('producerSourceSHA')
        producer_files = compatibility.get('producerFiles')
        require(compatibility == _transport_compatibility(producer_sha, producer_files, source_sha, source_files,
            compatibility['producerBuilder'], compatibility['producerWorkflow'], compatibility['comparison']),
            'UI test transport compatibility changed')
    require_receipt(receipt, producer_sha, producer_files)
    require(producer.get('schema') == 'nexgenvideo/external-tests-producer/1'
            and producer.get('receiptSHA256') == journey.sha256(directory / 'tests-input.json'),
            'UI test producer receipt changed')
    require_origin(producer['run'], producer['artifact'], producer_sha, receipt['runID'])
    require_job(producer['job'], receipt['runID'], producer_sha, receipt['attempt'])
    require(journey.sha256(directory / 'tests.tar.gz') == receipt['archiveSHA256'], 'UI test archive changed')
    return receipt


def consume(directory, destination, source_sha, source_files, *, transport_reuse=False):
    receipt = verify_input(directory, source_sha, source_files, transport_reuse=transport_reuse)
    unpack_products(directory / 'tests.tar.gz', destination)
    require(products_sha256(destination) == receipt['productsSHA256'], 'UI test product tree changed')
    xctestrun = destination / receipt['xctestrun']
    check_test_paths(xctestrun, destination)
    return xctestrun, receipt


def require_runner_access(products, log):
    runners = list(products.rglob('*-Runner.app'))
    require(len(runners) == 1 and not runners[0].is_symlink(), 'Expected one independent UI test runner')
    raw = journey.output(['codesign', '-d', '--entitlements', ':-', runners[0]])
    entitlements = plistlib.loads(raw) if raw.strip() else {}
    with log.open('ab') as stream:
        stream.write(b'\nIndependent UI test runner entitlements:\n' + plistlib.dumps(entitlements) + b'\n')
    require(isinstance(entitlements, dict) and not entitlements.get('com.apple.security.app-sandbox'),
            'Independent UI test runner cannot access its project and evidence directory')


def build(args):
    require(os.environ.get('GITHUB_ACTIONS') == 'true', 'Build external UI tests only in GitHub Actions')
    source_sha, source_files = journey.test_source_identity(os.environ['GITHUB_SHA'])
    destination = Path(args.destination)
    destination.mkdir(parents=True, exist_ok=False)
    with tempfile.TemporaryDirectory(prefix='ngv-external-build-') as temporary:
        work = Path(temporary)
        for name in journey.TEST_INPUTS:
            target = work / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(journey.ROOT / name, target)
        _, staged_files = journey.test_source_identity(source_sha, input_root=work)
        require(staged_files == source_files, 'Staged UI test inputs differ from the committed bytes')
        journey.command(['xcodegen', 'generate', '--spec', work / 'project.yml'], destination / 'build.log')
        journey.command(['xcodebuild', 'build-for-testing', '-project', work / 'NexGenVideoExternalGUI.xcodeproj',
                         '-scheme', 'NexGenVideoExternalGUI', '-destination', 'platform=macOS,arch=arm64',
                         '-derivedDataPath', work / 'build', 'MACOSX_DEPLOYMENT_TARGET=26.0', 'ARCHS=arm64',
                         'ONLY_ACTIVE_ARCH=YES'], destination / 'build.log', timeout=240)
        products = work / 'build/Build/Products'
        require_runner_access(products, destination / 'build.log')
        paths = list(products.glob('*.xctestrun'))
        require(len(paths) == 1, 'Expected one external xctestrun bundle')
        check_test_paths(paths[0], products)
        with tarfile.open(destination / 'tests.tar.gz', 'w:gz') as archive:
            for path in sorted(products.rglob('*')):
                info = archive.gettarinfo(path, arcname=path.relative_to(products).as_posix())
                if path.is_file() and not path.is_symlink():
                    info.type = tarfile.REGTYPE
                    info.linkname = ''
                    info.size = path.stat().st_size
                    with path.open('rb') as content:
                        archive.addfile(info, content)
                else:
                    archive.addfile(info)
        journey.write_json(destination / 'tests-input.json', {
            'schema': 'nexgenvideo/external-tests-input/1', 'sourceSHA': source_sha, 'testFiles': source_files,
            'runID': int(os.environ['GITHUB_RUN_ID']), 'attempt': int(os.environ['GITHUB_RUN_ATTEMPT']),
            'architecture': 'arm64', 'deploymentTarget': '26.0',
            'xcode': journey.output(['xcodebuild', '-version']).decode().strip(),
            'xctestrun': paths[0].name, 'archiveSHA256': journey.sha256(destination / 'tests.tar.gz'),
            'productsSHA256': products_sha256(products)})


def main():
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest='command', required=True)
    builder = commands.add_parser('build')
    builder.add_argument('--destination', required=True)
    resolver = commands.add_parser('resolve')
    resolver.add_argument('--run-id', type=int, required=True)
    resolver.add_argument('--artifact-id', type=int)
    resolver.add_argument('--destination', required=True)
    args = parser.parse_args()
    if args.command == 'build':
        build(args)
    else:
        resolve(args)


if __name__ == '__main__':
    main()
