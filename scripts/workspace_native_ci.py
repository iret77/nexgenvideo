"""Plan, bind and preserve independently resumable native qualifications."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import tarfile
import tempfile
import urllib.request
import urllib.error
import urllib.parse
import zipfile

from workspace_native_case import atomic_json, validate_processes
from workspace_native_evidence import validate_case
from workspace_ui_acceptance import ALL_CASES, ACCEPTANCE_SCOPES, SCALES, parse_events

ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = 'iret77/nexgenvideo'


def sha(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def fingerprint():
    paths = sorted((ROOT / 'scripts').glob('*.py')) + [ROOT / '.github/workflows/workspace-ui-acceptance.yml',
            ROOT / '.github/actions/prepare-native-runtime/action.yml']
    value = hashlib.sha256()
    for path in paths:
        value.update(str(path.relative_to(ROOT)).encode() + b'\0' + bytes.fromhex(sha(path)))
    return value.hexdigest()


def outputs(values):
    if target := os.environ.get('GITHUB_OUTPUT'):
        with open(target, 'a') as stream:
            for key, value in values.items():
                stream.write(key + '=' + (value if isinstance(value, str) else json.dumps(value, separators=(',', ':'))) + '\n')


def selection(scope, case='', scale='all'):
    choices = {'generationbatch': (), **ACCEPTANCE_SCOPES, **{name: (name,) for name in ALL_CASES}}
    if scope not in choices or (case and case not in choices[scope]):
        raise ValueError('Unknown native scope or case outside the selected scope')
    scales = SCALES if scale == 'all' else (float(scale),)
    if not scales or any(value not in SCALES for value in scales):
        raise ValueError('Unknown native interface scale')
    cases = (case,) if case else choices[scope]
    entries = [{'id': name + '-' + str(round(value * 100)), 'case': name, 'scale': value}
               for name in cases for value in scales]
    return {'matrix': {'include': entries}, 'batch': scope == 'generationbatch' or (scope == 'all' and not case and scale == 'all'),
            'fullWorkspaceRequested': scope == 'all' and not case and scale == 'all',
            'scope': scope, 'cases': list(cases), 'scales': list(scales)}


def api(path):
    request = urllib.request.Request('https://api.github.com/repos/' + REPOSITORY + path,
        headers={'Accept': 'application/vnd.github+json', 'Authorization': 'Bearer ' + os.environ['GH_TOKEN'],
                 'X-GitHub-Api-Version': '2022-11-28'})
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def require_artifact(run, artifact, source_sha, run_id, name):
    if (run.get('id') != run_id or run.get('repository', {}).get('full_name') != REPOSITORY
        or run.get('head_sha') != source_sha or run.get('event') not in {'workflow_dispatch', 'workflow_call'}
        or run.get('path') not in {'.github/workflows/ci-batch.yml', '.github/workflows/ci.yml',
                                  '.github/workflows/workspace-ui-acceptance.yml'}
        or artifact.get('name') != name or artifact.get('expired') is not False
        or artifact.get('workflow_run', {}).get('id') != run_id
        or artifact.get('workflow_run', {}).get('head_sha') != source_sha
        or not re.fullmatch(r'sha256:[0-9a-f]{64}', artifact.get('digest', ''))
        or type(artifact.get('id')) is not int or artifact['id'] <= 0):
        raise ValueError('Native runtime artifact has a different source, repository or producer')


def resolve(run_id, name, artifact_id, destination):
    source_sha = os.environ['GITHUB_SHA']
    if not re.fullmatch(r'[0-9a-f]{40}', source_sha):
        raise ValueError('Invalid source commit')
    run = api('/actions/runs/' + str(run_id))
    if artifact_id:
        artifact = api('/actions/artifacts/' + str(artifact_id))
    else:
        artifacts = []
        page = 1
        while True:
            batch = api(f'/actions/runs/{run_id}/artifacts?per_page=100&page={page}')['artifacts']
            artifacts += [item for item in batch if item['name'] == name and not item['expired']]
            if len(batch) < 100:
                break
            page += 1
        if len(artifacts) != 1:
            raise ValueError('An exact, unexpired runtime artifact is required')
        artifact = artifacts[0]
    require_artifact(run, artifact, source_sha, run_id, name)
    identity = {'schema': 'nexgenvideo/native-input/1', 'sourceSHA': source_sha, 'runtimeRunID': run_id,
                'runtimeArtifactID': artifact['id'], 'runtimeArtifactDigest': artifact['digest'],
                'runtimeArtifactName': name, 'validatorSHA256': fingerprint()}
    atomic_json(destination, identity)
    outputs({'artifact_id': str(artifact['id']), 'runtime_run_id': str(run_id)})


class ArtifactRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, target):
        return None


def download_artifact(artifact_id, expected_digest, archive):
    request = urllib.request.Request(f'https://api.github.com/repos/{REPOSITORY}/actions/artifacts/{artifact_id}/zip',
        headers={'Authorization': 'Bearer ' + os.environ['GH_TOKEN'], 'Accept': 'application/vnd.github+json'})
    opener = urllib.request.build_opener(ArtifactRedirect())
    try:
        response = opener.open(request, timeout=30)
    except urllib.error.HTTPError as error:
        if error.code != 302:
            raise ValueError('GitHub refused the exact artifact download') from None
        location = error.headers.get('Location', '')
        error.close()
        target = urllib.parse.urlsplit(location)
        if target.scheme != 'https' or not target.hostname or target.username or target.password:
            raise ValueError('GitHub returned an invalid artifact redirect')
        # Signed blob requests must never receive the GitHub token.
        try:
            response = urllib.request.urlopen(location, timeout=120)
        except urllib.error.URLError:
            raise ValueError('The exact artifact download failed') from None
    digest = hashlib.sha256()
    with response, archive.open('xb') as sink:
        for block in iter(lambda: response.read(1024 * 1024), b''):
            sink.write(block); digest.update(block)
    if 'sha256:' + digest.hexdigest() != expected_digest:
        raise ValueError('The GitHub artifact digest does not match its exact bytes')


def extract_transfer(archive, directory, expected):
    with zipfile.ZipFile(archive) as bundle:
        members = bundle.infolist()
        if len(members) != len(expected) or {item.filename for item in members} != expected:
            raise ValueError('The artifact transfer contains unexpected files')
        for member in members:
            if member.is_dir() or stat.S_IFMT(member.external_attr >> 16) not in {0, stat.S_IFREG}:
                raise ValueError('The artifact transfer contains a link or special member')
            with bundle.open(member) as source, (directory / member.filename).open('xb') as sink:
                for block in iter(lambda: source.read(1024 * 1024), b''):
                    sink.write(block)


def download_runtime(identity_file, directory):
    identity = json.loads(identity_file.read_text())
    directory.mkdir(parents=True, exist_ok=True)
    archive = directory.parent / 'native-runtime-transfer.zip'
    download_artifact(identity['runtimeArtifactID'], identity['runtimeArtifactDigest'], archive)
    extract_transfer(archive, directory, {'workspace-ui.tar.gz', 'NexGenVideo-bpy-5.2.2-corresponding-source.tar',
                                        'NexGenVideo-bpy-5.2.2-corresponding-source.manifest.json'})


def prepare(directory, identity_file):
    from verify_bpy_distributable_source import validate
    archive = directory / 'NexGenVideo-bpy-5.2.2-corresponding-source.tar'
    manifest = directory / 'NexGenVideo-bpy-5.2.2-corresponding-source.manifest.json'
    validation = validate(archive, manifest)
    identity = json.loads(identity_file.read_text())
    identity.update(planSHA256=sha(identity_file.parent / 'plan.json'),
                    archiveSHA256=sha(directory / 'workspace-ui.tar.gz'),
                    sourceArchiveSHA256=sha(archive), sourceManifestSHA256=sha(manifest), sourceClosure=validation)
    atomic_json(identity_file, identity)
    outputs({'identity_sha256': sha(identity_file)})


def verify_runtime(directory, identity_file, expected_identity_sha):
    if sha(identity_file) != expected_identity_sha:
        raise ValueError('The runtime qualification identity changed')
    identity = json.loads(identity_file.read_text())
    if identity['sourceSHA'] != os.environ['GITHUB_SHA'] or identity['validatorSHA256'] != fingerprint():
        raise ValueError('The runtime or validator input changed')
    if sha(directory / 'workspace-ui.tar.gz') != identity['archiveSHA256']:
        raise ValueError('The immutable native runtime changed')


def relative(name):
    value = PurePosixPath(name)
    if not name or name == '.' or value.is_absolute() or '..' in value.parts or '\\' in name or str(value) != name:
        raise ValueError('Evidence path is not a canonical relative path')
    return value


def archive_evidence(directory, identity_file, case, scale, destination):
    if any(name.startswith('NGV_EXAMPLE_') for name in os.environ):
        raise ValueError('Private example inputs cannot be published with synthetic native evidence')
    identity = json.loads(identity_file.read_text())
    directory.mkdir(parents=True, exist_ok=True)
    destination.mkdir(parents=True, exist_ok=True)
    if destination.resolve().is_relative_to(directory.resolve()):
        raise ValueError('The publication directory must be outside the evidence root')
    record = directory / 'case-result.json'
    if not record.exists():
        atomic_json(record, {'schema': 'nexgenvideo/native-case/1', 'case': case, 'scale': scale,
                            'identity': identity, 'completed': False, 'exitCode': None, 'error': 'Native process did not finish'})
    manifest = {'schema': 'nexgenvideo/native-evidence/1', 'identity': identity, 'case': case, 'scale': scale,
                'runID': int(os.environ['GITHUB_RUN_ID']), 'attempt': int(os.environ['GITHUB_RUN_ATTEMPT']), 'files': []}
    archive = destination / 'evidence.tar.gz'
    with tarfile.open(archive, 'w:gz', compresslevel=1) as bundle:
        for path in sorted(directory.rglob('*')):
            info = path.lstat()
            if stat.S_ISDIR(info.st_mode):
                continue
            if not stat.S_ISREG(info.st_mode) or not path.resolve().is_relative_to(directory.resolve()):
                raise ValueError('Evidence contains a link or special file: ' + path.name)
            name = str(path.relative_to(directory))
            relative(name)
            with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW), 'rb') as stream:
                current = os.fstat(stream.fileno())
                if (current.st_ino, current.st_dev, current.st_size) != (info.st_ino, info.st_dev, info.st_size):
                    raise ValueError('Evidence file changed during publication')
                digest = hashlib.sha256()
                for block in iter(lambda: stream.read(1024 * 1024), b''):
                    digest.update(block)
                stream.seek(0)
                entry = tarfile.TarInfo(name); entry.size = info.st_size; entry.mode = 0o644
                bundle.addfile(entry, stream)
                after = os.fstat(stream.fileno())
                if (after.st_size, after.st_mtime_ns) != (current.st_size, current.st_mtime_ns):
                    raise ValueError('Evidence bytes changed during publication')
            manifest['files'].append({'path': name, 'size': info.st_size, 'sha256': digest.hexdigest()})
    manifest['archiveSHA256'] = sha(archive)
    atomic_json(destination / 'evidence-manifest.json', manifest)


def unpack_evidence(directory, destination):
    manifest = json.loads((directory / 'evidence-manifest.json').read_text())
    archive = directory / 'evidence.tar.gz'
    if sha(archive) != manifest['archiveSHA256']:
        raise ValueError('Evidence archive hash mismatch')
    expected = {item['path']: item for item in manifest['files']}
    if len(expected) != len(manifest['files']):
        raise ValueError('Duplicated evidence file')
    destination.mkdir(parents=True, exist_ok=False)
    seen = set()
    with tarfile.open(archive, 'r:gz') as bundle:
        for member in bundle:
            name = str(relative(member.name))
            if not member.isfile() or name in seen or name not in expected or member.size != expected[name]['size']:
                raise ValueError('Unexpected evidence archive member')
            target = destination / name
            target.parent.mkdir(parents=True, exist_ok=True)
            digest = hashlib.sha256()
            with bundle.extractfile(member) as stream, target.open('xb') as sink:
                for block in iter(lambda: stream.read(1024 * 1024), b''):
                    sink.write(block); digest.update(block)
            if digest.hexdigest() != expected[name]['sha256']:
                raise ValueError('Evidence file hash mismatch')
            seen.add(name)
    if seen != set(expected):
        raise ValueError('Incomplete evidence archive')
    return manifest


def verify_result(record, root, expected_identity, case, scale):
    if (record.get('schema') != 'nexgenvideo/native-case/1' or record.get('identity') != expected_identity
        or record.get('case') != case or record.get('scale') != scale
        or record.get('exitCode') != 0 or record.get('completed') is not True):
        return False
    if case == 'generationbatch':
        return (root / 'generation-batch-review.log').read_text().splitlines().count('SELFTEST_GENERATION_BATCH_REVIEW_OK') == 1
    rows = parse_events((root / f'scale-{round(scale * 100)}.log').read_text())
    return (rows == record.get('events') and validate_processes(case, rows, scale)
            and validate_case(case, rows, root, scale)[0])


def latest_native_jobs(expected):
    names = {('Native generationbatch' if case == 'generationbatch'
              else f'Native {case}-{round(scale * 100)}'): (case, scale) for case, scale in expected}
    latest = {}
    for attempt in range(1, int(os.environ['GITHUB_RUN_ATTEMPT']) + 1):
        page = 1
        seen = set()
        while True:
            jobs = api(f'/actions/runs/{os.environ["GITHUB_RUN_ID"]}/attempts/{attempt}/jobs?per_page=100&page={page}')['jobs']
            for job in jobs:
                name = job.get('name', '').split(' / ')[-1]
                if name not in names:
                    continue
                key = names[name]
                if key in seen:
                    raise ValueError('Duplicate native job for one case and scale')
                seen.add(key); latest[key] = (attempt, job)
            if len(jobs) < 100:
                break
            page += 1
    return latest


def summarize(artifacts, output, plan_file, identity_file, expected_identity_sha, remote=False):
    if sha(identity_file) != expected_identity_sha:
        raise ValueError('The expected qualification identity changed')
    plan = json.loads(plan_file.read_text()); identity = json.loads(identity_file.read_text())
    if sha(plan_file) != identity.get('planSHA256'):
        raise ValueError('The expected case/scale plan changed')
    expected = {(entry['case'], entry['scale']) for entry in plan['matrix']['include']}
    if plan['batch']:
        expected.add(('generationbatch', 0))
    latest = {}
    errors = []
    output.mkdir(parents=True, exist_ok=True)
    names = {('native-evidence-generationbatch' if case == 'generationbatch'
              else f'native-evidence-{case}-{round(scale * 100)}'): (case, scale) for case, scale in expected}
    if remote:
        sources = []
        page = 1
        while True:
            batch = api(f'/actions/runs/{os.environ["GITHUB_RUN_ID"]}/artifacts?per_page=100&page={page}')['artifacts']
            sources += [item for item in batch if item['name'].startswith('native-evidence-')]
            if len(batch) < 100:
                break
            page += 1
    else:
        sources = [{'name': path.name, 'path': path} for path in sorted(artifacts.iterdir()) if path.is_dir()]
    for source in sources:
        match = re.fullmatch(r'(.+)-a([1-9][0-9]*)', source['name'])
        if match is None or match[1] not in names or int(match[2]) > int(os.environ['GITHUB_RUN_ATTEMPT']):
            errors.append('Unexpected evidence artifact: ' + source['name'])
            continue
        key, attempt = names[match[1]], int(match[2])
        if key in latest and latest[key][0] == attempt:
            errors.append('Duplicate qualification: ' + source['name'])
        elif key not in latest or latest[key][0] < attempt:
            latest[key] = (attempt, source)
    jobs = latest_native_jobs(expected) if remote else {}
    results = []
    for case, scale in sorted(expected):
        item = latest.get((case, scale))
        valid = False
        job = jobs.get((case, scale))
        try:
            if remote and (not job or not item or job[0] != item[0]
                or job[1].get('run_id') != int(os.environ['GITHUB_RUN_ID'])
                or job[1].get('head_sha') != identity['sourceSHA'] or job[1].get('status') != 'completed'
                or job[1].get('conclusion') != 'success'):
                raise ValueError('The latest native job did not pass with this exact evidence attempt')
            if item:
                with tempfile.TemporaryDirectory(prefix='native-case-', dir=output) as temporary:
                    temporary = Path(temporary)
                    source = item[1]
                    if remote:
                        if (source.get('expired') is not False
                            or source.get('workflow_run', {}).get('id') != int(os.environ['GITHUB_RUN_ID'])
                            or source.get('workflow_run', {}).get('head_sha') != identity['sourceSHA']
                            or type(source.get('id')) is not int or source['id'] <= 0
                            or not re.fullmatch(r'sha256:[0-9a-f]{64}', source.get('digest', ''))):
                            raise ValueError('Evidence artifact has a different source or is expired')
                        archive = temporary / 'transfer.zip'
                        download_artifact(source['id'], source['digest'], archive)
                        publication = temporary / 'publication'; publication.mkdir()
                        extract_transfer(archive, publication, {'evidence.tar.gz', 'evidence-manifest.json'})
                    else:
                        publication = source['path']
                    target = temporary / 'extracted'
                    manifest = unpack_evidence(publication, target)
                    if (manifest['case'] != case or manifest['scale'] != scale or manifest['identity'] != identity
                        or manifest['runID'] != int(os.environ['GITHUB_RUN_ID']) or manifest['attempt'] != item[0]):
                        raise ValueError('Evidence has a different case, runtime or origin attempt')
                    record = json.loads((target / 'case-result.json').read_text())
                    valid = verify_result(record, target, identity, case, scale)
        except (KeyError, ValueError, OSError, TypeError, tarfile.TarError, zipfile.BadZipFile) as error:
            errors.append(f'{case}/{scale}: {error}')
        results.append({'case': case, 'scale': scale, 'completed': valid,
                        'originAttempt': item[0] if item else None, 'originRunID': int(os.environ['GITHUB_RUN_ID']),
                        'originJobID': job[1].get('id') if job else None})
    complete = not errors and len(results) == len(expected) and all(row['completed'] for row in results)
    report = {'schema': 'nexgenvideo/native-summary/1', 'identity': identity, 'completed': complete,
              'fullWorkspaceAcceptance': plan['fullWorkspaceRequested'] and complete, 'results': results, 'errors': errors}
    atomic_json(output / 'result.json', report)
    if target := os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(target, 'a') as stream:
            stream.write('| Native case | Scale | Result | Origin attempt |\n|---|---:|---|---:|\n')
            for row in results:
                stream.write(f"| {row['case']} | {row['scale']} | {'PASS' if row['completed'] else 'FAIL / missing'} | {row['originAttempt']} |\n")
    return 0 if complete else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    plan = sub.add_parser('plan'); plan.add_argument('--scope', default='all'); plan.add_argument('--case', default='')
    plan.add_argument('--scale', default='all'); plan.add_argument('--output', type=Path, required=True)
    resolver = sub.add_parser('resolve'); resolver.add_argument('--run-id', type=int, required=True)
    resolver.add_argument('--artifact', default='workspace-ui-app'); resolver.add_argument('--artifact-id', type=int)
    resolver.add_argument('--identity', type=Path, required=True)
    for name in ('prepare', 'verify-runtime', 'download-runtime'):
        command = sub.add_parser(name); command.add_argument('directory', type=Path); command.add_argument('identity', type=Path)
        if name == 'verify-runtime': command.add_argument('identity_sha')
    pack = sub.add_parser('archive'); pack.add_argument('directory', type=Path); pack.add_argument('identity', type=Path)
    pack.add_argument('case'); pack.add_argument('scale', type=float); pack.add_argument('destination', type=Path)
    summary = sub.add_parser('summary'); summary.add_argument('artifacts', type=Path); summary.add_argument('output', type=Path)
    summary.add_argument('plan', type=Path); summary.add_argument('identity', type=Path); summary.add_argument('identity_sha'); summary.add_argument('--remote', action='store_true')
    args = parser.parse_args()
    if args.command == 'plan':
        value = selection(args.scope, args.case, args.scale); atomic_json(args.output, value)
        outputs({'matrix': value['matrix'], 'native': bool(value['matrix']['include']), 'batch': value['batch']})
    elif args.command == 'resolve': resolve(args.run_id, args.artifact, args.artifact_id, args.identity)
    elif args.command == 'prepare': prepare(args.directory, args.identity)
    elif args.command == 'verify-runtime': verify_runtime(args.directory, args.identity, args.identity_sha)
    elif args.command == 'download-runtime': download_runtime(args.identity, args.directory)
    elif args.command == 'archive': archive_evidence(args.directory, args.identity, args.case, args.scale, args.destination)
    else: return summarize(args.artifacts, args.output, args.plan, args.identity, args.identity_sha, args.remote)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
