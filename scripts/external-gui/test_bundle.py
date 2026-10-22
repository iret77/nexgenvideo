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
             '.github/workflows/release.yml'}


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
    require_origin(run, artifact, source_sha, args.run_id)
    destination = Path(args.destination)
    destination.mkdir(parents=True, exist_ok=False)
    archive = destination.parent / 'external-tests-transfer.zip'
    download(artifact, archive)
    unpack_transfer(archive, destination)
    receipt = journey.read_json(destination / 'tests-input.json')
    require_receipt(receipt, source_sha, source_files)
    require(receipt['runID'] == args.run_id, 'UI test receipt has another producer')
    jobs = [job for job in items(f'/actions/runs/{args.run_id}/attempts/{receipt["attempt"]}/jobs', 'jobs')
            if job.get('name', '').split(' / ')[-1] == 'Build external UI tests']
    require(len(jobs) == 1, 'Expected one original UI test build job')
    require_job(jobs[0], args.run_id, source_sha, receipt['attempt'])
    require(journey.sha256(destination / 'tests.tar.gz') == receipt['archiveSHA256'], 'UI test archive changed')
    journey.write_json(destination / 'tests-producer.json', {
        'schema': 'nexgenvideo/external-tests-producer/1', 'run': run, 'artifact': artifact, 'job': jobs[0],
        'receiptSHA256': journey.sha256(destination / 'tests-input.json')})
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


def verify_input(directory, source_sha, source_files):
    receipt = journey.read_json(directory / 'tests-input.json')
    producer = journey.read_json(directory / 'tests-producer.json')
    require_receipt(receipt, source_sha, source_files)
    require(producer.get('schema') == 'nexgenvideo/external-tests-producer/1'
            and producer.get('receiptSHA256') == journey.sha256(directory / 'tests-input.json'),
            'UI test producer receipt changed')
    require_origin(producer['run'], producer['artifact'], source_sha, receipt['runID'])
    require_job(producer['job'], receipt['runID'], source_sha, receipt['attempt'])
    require(journey.sha256(directory / 'tests.tar.gz') == receipt['archiveSHA256'], 'UI test archive changed')
    return receipt


def consume(directory, destination, source_sha, source_files):
    receipt = verify_input(directory, source_sha, source_files)
    unpack_products(directory / 'tests.tar.gz', destination)
    require(products_sha256(destination) == receipt['productsSHA256'], 'UI test product tree changed')
    xctestrun = destination / receipt['xctestrun']
    check_test_paths(xctestrun, destination)
    return xctestrun, receipt


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
