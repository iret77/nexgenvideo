import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import zipfile

from reuse_bpy_binary_evidence import (REPOSITORY, SOURCE_LIMIT, NoRedirect, api, download,
                                      pages, request, require_source_producer)
from verify_bpy_distributable_source import LOCK_PATH, digest, validate


RECEIPT = 'bpy-source-receipt.json'
SCHEMA = 'nexgenvideo/bpy-source-receipt/1'
SHA = re.compile(r'[0-9a-f]{64}')
COMMIT = re.compile(r'[0-9a-f]{40}')
QUALIFIED_HANDOFF = {
    'originalReceiptSHA256': 'e28a77d6f63e7c7a6a5282428c202cd5027ae1684949a60e78d9b90dec840a53',
    'publicSourceAssetSHA256': '8e3f678144da89beccf5fbc6a379c4fec8cef25f40a2c5cbf351f7b5baed37ea',
    'validationSHA256': 'fdbcc4dcc4e978041a799f8ce2d90cfa9475a178d37aa3714c292551438e3730'}


def canonical_sha(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':'),
        ensure_ascii=True, allow_nan=False).encode()).hexdigest()


def qualified_handoff(receipt, public, source_sha):
    require_receipt(receipt, public, source_sha)
    if (canonical_sha(public) != QUALIFIED_HANDOFF['publicSourceAssetSHA256']
        or canonical_sha(receipt['validation']) != QUALIFIED_HANDOFF['validationSHA256']
        or receipt['origin'] != {'kind': 'actions', 'producer': public['producer']}):
        raise ValueError('Source receipt lacks the exact qualified original validation and producer')
    return receipt


def physical_directory(directory, *, create=False):
    from compiled_app_release import source_directory_identity
    path = directory.absolute()
    bases = [Path(os.environ[key]).absolute() for key in ('RUNNER_TEMP', 'GITHUB_WORKSPACE')
        if os.environ.get(key) and path.is_relative_to(Path(os.environ[key]).absolute())
        and path != Path(os.environ[key]).absolute()]
    if not bases:
        raise ValueError('Source reuse directory has no owned CI root')
    base = max(bases, key=lambda item: len(item.parts))
    if not base.is_dir() or base.is_symlink() or '..' in path.relative_to(base).parts:
        raise ValueError('Source reuse root is missing, linked or escaping')
    cursor = base
    for part in path.relative_to(base).parts:
        cursor = cursor / part
        if create and not cursor.exists() and not cursor.is_symlink(): cursor.mkdir()
        if not cursor.is_dir() or cursor.is_symlink():
            raise ValueError('Source reuse directory has a missing or linked ancestor')
    return base, source_directory_identity(path, base)


def persist_raw(path, raw):
    from compiled_app_release import source_directory_identity
    base, anchor = physical_directory(path.parent, create=True)
    descriptor = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        info = os.fstat(descriptor)
        if (info.st_dev, info.st_ino) != anchor[1:]:
            raise ValueError('Source reuse output parent changed')
        target = os.open(path.name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644, dir_fd=descriptor)
        with os.fdopen(target, 'wb') as stream:
            stream.write(raw); stream.flush(); os.fsync(stream.fileno())
        os.fsync(descriptor)
    finally: os.close(descriptor)
    source_directory_identity(path.parent, base, anchor)


def persist(path, value):
    persist_raw(path, (json.dumps(value, indent=2, allow_nan=False) + '\n').encode())


def verify_reuse(directory, source_sha, evidence=None):
    public = public_asset(json.loads(LOCK_PATH.read_text()))
    path = directory / 'bpy-source-consumer-reused.json'
    if path.is_symlink() or not path.is_file():
        raise ValueError('Source reuse proof is missing or linked')
    proof = json.loads(path.read_text())
    receipt_path = directory / RECEIPT
    if receipt_path.is_symlink() or not receipt_path.is_file():
        raise ValueError('Source reuse receipt is missing or linked')
    raw = receipt_path.read_bytes()
    receipt = qualified_handoff(json.loads(raw), public, source_sha)
    require_pair(directory, public)
    if (proof.get('schema') != 'qualified-bpy-source-handoff-reuse/v1' or proof.get('state') != 'REUSED'
        or proof.get('consumerSourceSHA') != source_sha or proof.get('qualification') != QUALIFIED_HANDOFF
        or proof.get('validation') != receipt['validation'] or proof.get('publicSourceAsset') != public
        or proof.get('receiptSHA256') != hashlib.sha256(raw).hexdigest()
        or proof.get('semanticSourceValidationPerformed') is not False
        or proof.get('runID') != os.environ.get('GITHUB_RUN_ID')
        or proof.get('attempt') != os.environ.get('GITHUB_RUN_ATTEMPT')
        or proof.get('job') != os.environ.get('GITHUB_JOB')
        or proof.get('sourceDirectory') != str(directory.resolve())
        or proof.get('freshOrigin') != receipt['origin']):
        raise ValueError('Source reuse proof lost its original qualification or current consumer')
    from compiled_app_release import source_directory_identity, verify_source_origin
    base, _ = physical_directory(directory)
    source_directory_identity(directory, base, tuple(proof.get('directoryAnchor', ())))
    verify_source_origin(proof.get('originEvidence', {}), public, proof['acquiredAt'])
    if evidence is not None:
        if evidence.exists() or evidence.is_symlink():
            raise ValueError('Source reuse evidence destination is occupied')
        persist(evidence, proof)
    return proof


def public_asset(lock):
    public = lock['distributionClosure']['publicSourceAsset']
    producer = public['producer']
    if (lock.get('distributionStatus') != 'ready'
        or public.get('filename') != 'NexGenVideo-bpy-5.2.2-corresponding-source.tar'
        or public.get('manifestFilename') != 'NexGenVideo-bpy-5.2.2-corresponding-source.manifest.json'
        or not SHA.fullmatch(public.get('sha256', ''))
        or not SHA.fullmatch(public.get('manifestSHA256', ''))
        or type(public.get('size')) is not int or not 0 < public['size'] <= SOURCE_LIMIT
        or not re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?', public.get('releaseTag', ''))
        or producer.get('repository') != REPOSITORY
        or producer.get('workflowPath') not in {'.github/workflows/bpy-source-closure.yml', '.github/workflows/ci-batch.yml'}
        or not COMMIT.fullmatch(producer.get('sourceSHA', ''))
        or producer.get('artifactName') != 'managed-bpy-source-' + producer['sourceSHA']
        or not re.fullmatch(r'sha256:[0-9a-f]{64}', producer.get('artifactDigest', ''))
        or any(type(producer.get(key)) is not int or producer[key] <= 0
               for key in ('runID', 'jobID', 'jobAttempt', 'artifactID', 'artifactSize'))
        or producer['artifactSize'] > SOURCE_LIMIT):
        raise ValueError('Current distributable source pins and complete original producer are required')
    return public


def require_receipt(receipt, public, source_sha):
    if (not COMMIT.fullmatch(source_sha)
        or not isinstance(receipt, dict)
        or set(receipt) != {'schema', 'sourceSHA', 'publicSourceAsset', 'origin', 'validation'}
        or receipt.get('schema') != SCHEMA or receipt.get('sourceSHA') != source_sha
        or receipt.get('publicSourceAsset') != public
        or not isinstance(receipt.get('origin'), dict)
        or receipt['origin'].get('kind') not in {'actions', 'release'}
        or not isinstance(receipt.get('validation'), dict)
        or receipt['validation'].get('archiveSHA256') != public['sha256']
        or receipt['validation'].get('manifestSHA256') != public['manifestSHA256']):
        raise ValueError('Source receipt does not bind this exact consumer commit and current public pins/producer')


def require_pair(directory, public):
    archive, manifest = (directory / public[key] for key in ('filename', 'manifestFilename'))
    if (archive.is_symlink() or manifest.is_symlink() or archive.stat().st_size != public['size']
        or digest(archive) != public['sha256'] or digest(manifest) != public['manifestSHA256']):
        raise ValueError('Original corresponding-source bytes differ from current public pins')
    return archive, manifest


def released(public):
    path = '/releases/tags/' + urllib.parse.quote(public['releaseTag'], safe='')
    try:
        with urllib.request.build_opener(NoRedirect()).open(request(path), timeout=30) as response:
            data = response.read(8 * 1024 * 1024 + 1)
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        raise ValueError('Cannot establish original source release availability') from None
    if len(data) > 8 * 1024 * 1024:
        raise ValueError('Source release metadata exceeds its bound')
    release = json.loads(data)
    if release.get('draft') is True:
        return None
    if (release.get('tag_name') != public['releaseTag'] or release.get('draft') is not False
        or not release.get('published_at') or type(release.get('id')) is not int):
        raise ValueError('Original source release identity is invalid')
    return release


def copy_release(release, public, directory):
    assets = release.get('assets', [])
    for key, bound in (('filename', public['size']), ('manifestFilename', 16 * 1024 * 1024)):
        name = public[key]
        matches = [item for item in assets if item.get('name') == name]
        url = ('https://github.com/' + REPOSITORY + '/releases/download/'
               + urllib.parse.quote(public['releaseTag'], safe='') + '/' + urllib.parse.quote(name, safe=''))
        if (len(matches) != 1 or matches[0].get('browser_download_url') != url
            or type(matches[0].get('size')) is not int or not 0 < matches[0]['size'] <= bound
            or (key == 'filename' and matches[0]['size'] != bound)):
            raise ValueError('Original release source asset is missing or has a different identity')
        size = 0
        # Public release redirects never receive a repository credential.
        with urllib.request.urlopen(url, timeout=120) as response, (directory / name).open('xb') as sink:
            for block in iter(lambda: response.read(1024 * 1024), b''):
                size += len(block)
                if size > matches[0]['size']:
                    raise ValueError('Source release asset exceeds its size pin')
                sink.write(block)
        if size != matches[0]['size']:
            raise ValueError('Source release asset is truncated')
    return {'kind': 'release', 'tag': public['releaseTag'], 'releaseID': release['id']}


def require_original_producer(public, run, artifacts, jobs):
    producer = public['producer']
    artifact, job = require_source_producer(producer['runID'], run, artifacts, jobs)
    actual = {'repository': REPOSITORY, 'workflowPath': run['path'], 'runID': run['id'],
              'sourceSHA': run['head_sha'], 'jobID': job['id'], 'jobAttempt': job['run_attempt'],
              'artifactID': artifact['id'], 'artifactName': artifact['name'],
              'artifactDigest': artifact['digest'], 'artifactSize': artifact['size_in_bytes']}
    if actual != producer or job.get('conclusion') != 'success':
        raise ValueError('Source artifact is not the exact pinned successful original producer')
    return artifact


def extract_original(archive, directory, public):
    wanted = {public['filename'], public['manifestFilename']}
    metadata = {'assembly-progress.json', 'validation.json', 'distribution-validation.json', 'evidence.json',
                'reused-binary-evidence.json', 'binary-evidence-reuse.json', 'source-reuse.json'}
    with zipfile.ZipFile(archive) as bundle:
        names = set()
        for member in bundle.infolist():
            if (member.filename in names or member.filename not in wanted | metadata or member.is_dir()
                or stat.S_IFMT(member.external_attr >> 16) not in {0, stat.S_IFREG}
                or member.file_size > (public['size'] if member.filename == public['filename'] else 16 * 1024 * 1024)):
                raise ValueError('Original source artifact contains unexpected, duplicate or unsafe files')
            names.add(member.filename)
            if member.filename in wanted:
                with bundle.open(member) as source, (directory / member.filename).open('xb') as sink:
                    shutil.copyfileobj(source, sink, 1024 * 1024)
        if not wanted <= names:
            raise ValueError('Original source artifact lacks the complete source pair')


def copy_actions(public, directory):
    producer = public['producer']
    run_id = producer['runID']
    run = api(f'/actions/runs/{run_id}')
    artifacts = pages(f'/actions/runs/{run_id}/artifacts', 'artifacts')
    if not any(item.get('id') == producer['artifactID'] and item.get('expired') is False for item in artifacts):
        raise ValueError('Original source artifact expired or is unavailable before publication; run an explicit source qualification rebuild and review new pins')
    jobs = pages(f'/actions/runs/{run_id}/jobs?filter=all', 'jobs')
    artifact = require_original_producer(public, run, artifacts, jobs)
    with tempfile.TemporaryDirectory(prefix='bpy-source-download-') as temporary:
        archive = Path(temporary) / 'source.zip'
        download(artifact, archive)
        extract_original(archive, directory, public)
    return {'kind': 'actions', 'producer': producer}


def consume(directory, source_sha, receipt_path=None):
    if not COMMIT.fullmatch(source_sha):
        raise ValueError('An exact consumer source commit is required')
    public = public_asset(json.loads(LOCK_PATH.read_text()))
    handoff = None
    if receipt_path is not None:
        if receipt_path.is_symlink() or not receipt_path.is_file():
            raise ValueError('Source handoff receipt is missing or linked')
        handoff_raw = receipt_path.read_bytes()
        handoff = qualified_handoff(json.loads(handoff_raw), public, source_sha)
    if handoff is not None:
        base, anchor = physical_directory(directory, create=True)
        output_receipt = directory / RECEIPT
        if output_receipt.is_symlink() or (output_receipt.exists()
                and output_receipt.absolute() != receipt_path.absolute()):
            raise ValueError('Source handoff output receipt is occupied or linked')
    else:
        directory.mkdir(parents=True, exist_ok=True)
    if any((directory / public[key]).exists() for key in ('filename', 'manifestFilename')):
        raise ValueError('Source output already exists; refusing to replace or trust partial bytes')
    if handoff is None:
        release = released(public)
        origin = copy_release(release, public, directory) if release else copy_actions(public, directory)
    else:
        from compiled_app_release import acquire_source_pair, commit_source_pair, source_directory_identity
        with tempfile.TemporaryDirectory(prefix='qualified-bpy-handoff-') as temporary:
            stage = Path(temporary)
            origin_evidence = acquire_source_pair(public, stage)
            commit_source_pair(stage, directory, public, base, anchor)
        source_directory_identity(directory, base, anchor)
        origin = {'kind': 'actions', 'producer': public['producer']}
    archive, manifest = require_pair(directory, public)
    if handoff is not None and receipt_path.read_bytes() != handoff_raw:
        raise ValueError('Source handoff receipt changed during acquisition')
    validation = handoff['validation'] if handoff is not None else validate(archive, manifest)
    receipt = {'schema': SCHEMA, 'sourceSHA': source_sha, 'publicSourceAsset': public,
               'origin': origin, 'validation': validation}
    encoded = (json.dumps(receipt, indent=2, sort_keys=True) + '\n').encode()
    if handoff is None:
        (directory / RECEIPT).write_bytes(encoded)
    else:
        source_directory_identity(directory, base, anchor)
        replacement = directory / 'bpy-source-handoff-current.json'
        persist_raw(replacement, encoded)
        if output_receipt.is_symlink():
            raise ValueError('Source handoff output receipt became linked')
        replacement.replace(output_receipt)
        descriptor = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try: os.fsync(descriptor)
        finally: os.close(descriptor)
    if handoff is not None:
        persist(directory / 'bpy-source-consumer-reused.json', {
            'schema': 'qualified-bpy-source-handoff-reuse/v1', 'state': 'REUSED',
            'consumerSourceSHA': source_sha, 'qualification': QUALIFIED_HANDOFF,
            'inputReceiptSHA256': hashlib.sha256(handoff_raw).hexdigest(),
            'receiptSHA256': digest(directory / RECEIPT), 'publicSourceAsset': public,
            'validation': validation, 'freshOrigin': origin, 'semanticSourceValidationPerformed': False,
            'originEvidence': origin_evidence, 'directoryAnchor': anchor,
            'runID': os.environ.get('GITHUB_RUN_ID'), 'attempt': os.environ.get('GITHUB_RUN_ATTEMPT'),
            'job': os.environ.get('GITHUB_JOB'), 'sourceDirectory': str(directory.resolve()),
            'acquiredAt': datetime.datetime.now(datetime.timezone.utc).isoformat()})
    return receipt


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output-directory', required=True, type=Path)
    parser.add_argument('--source-sha', required=True)
    parser.add_argument('--receipt', type=Path)
    parser.add_argument('--verify-reuse', action='store_true')
    parser.add_argument('--reuse-evidence', type=Path)
    args = parser.parse_args()
    if args.verify_reuse:
        verify_reuse(args.output_directory, args.source_sha, args.reuse_evidence)
    else:
        consume(args.output_directory, args.source_sha, args.receipt)


if __name__ == '__main__':
    try:
        main()
    except (AttributeError, KeyError, TypeError, ValueError, OSError, zipfile.BadZipFile) as error:
        raise SystemExit(f'Cannot consume qualified bpy source: {error}')
