import argparse
import json
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
    if receipt_path is not None:
        require_receipt(json.loads(receipt_path.read_text()), public, source_sha)
    directory.mkdir(parents=True, exist_ok=True)
    if any((directory / public[key]).exists() for key in ('filename', 'manifestFilename')):
        raise ValueError('Source output already exists; refusing to replace or trust partial bytes')
    release = released(public)
    origin = copy_release(release, public, directory) if release else copy_actions(public, directory)
    archive, manifest = require_pair(directory, public)
    validation = validate(archive, manifest)
    receipt = {'schema': SCHEMA, 'sourceSHA': source_sha, 'publicSourceAsset': public,
               'origin': origin, 'validation': validation}
    (directory / RECEIPT).write_text(json.dumps(receipt, indent=2, sort_keys=True) + '\n')
    return receipt


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output-directory', required=True, type=Path)
    parser.add_argument('--source-sha', required=True)
    parser.add_argument('--receipt', type=Path)
    args = parser.parse_args()
    consume(args.output_directory, args.source_sha, args.receipt)


if __name__ == '__main__':
    try:
        main()
    except (AttributeError, KeyError, TypeError, ValueError, OSError, zipfile.BadZipFile) as error:
        raise SystemExit(f'Cannot consume qualified bpy source: {error}')
