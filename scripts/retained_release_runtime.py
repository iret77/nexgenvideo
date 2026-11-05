import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

from reuse_bpy_binary_evidence import api, download
from verify_diagnostic_candidate import verify_signed_workspace
from workspace_native_ci import extract_transfer, runtime_receipt


def bind(run_id, source_sha, artifact_id, digest, *, verifier=None, packaging=None):
    if (run_id <= 0 or artifact_id <= 0 or not re.fullmatch('[0-9a-f]{40}', source_sha)
            or not re.fullmatch('[0-9a-f]{64}', digest)):
        raise ValueError('A complete original release runtime identity is required')
    from retained_packaging import consumer_binding, consumer_source
    packaging_binding = consumer_binding(run_id, source_sha, packaging)
    producer_source = consumer_source(source_sha, packaging_binding)
    subprocess.run(['git', 'merge-base', '--is-ancestor', producer_source, 'HEAD'], check=True)
    subprocess.run(['git', 'diff', '--exit-code', 'HEAD', '--'], check=True, stdout=subprocess.DEVNULL)
    changed = subprocess.check_output(['git', 'diff', '--no-renames', '--name-only', '-z', producer_source, 'HEAD']).decode()
    run = api('/actions/runs/' + str(run_id))
    attempt = run.get('run_attempt')
    if type(attempt) is not int or attempt <= 0:
        raise ValueError('Original release has no execution attempt')
    jobs = api(f'/actions/runs/{run_id}/attempts/{attempt}/jobs?per_page=100')
    artifact = api('/actions/artifacts/' + str(artifact_id))
    options = {'packaging': packaging} if packaging is not None else {}
    (verifier or verify_signed_workspace)(run, jobs, artifact, run_id, source_sha, artifact_id, digest,
                                         list(filter(None, changed.split('\0'))), **options)
    harness = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
    producer = next(job for job in jobs['jobs'] if job['name'] == 'release')
    proof = dict(schema='nexgenvideo/retained-release-runtime/1', productSourceSHA=source_sha,
                 harnessSourceSHA=harness, producerRunID=run_id, producerAttempt=attempt,
                 producerJobID=producer['id'], runtimeArtifactID=artifact_id,
                 runtimeArtifactSHA256=digest, executionRunID=os.environ.get('GITHUB_RUN_ID'),
                 executionAttempt=os.environ.get('GITHUB_RUN_ATTEMPT'),
                 changedHarnessPaths=sorted(filter(None, changed.split('\0'))))
    if packaging_binding is not None:
        proof.update(schema='nexgenvideo/retained-release-runtime/2', packaging=packaging_binding)
    return artifact, proof


def validate_app(directory, source_sha, receipt):
    sys.path.insert(0, str(Path(__file__).resolve().parent / 'external-gui'))
    try:
        from acceptance import metadata
    finally:
        sys.path.pop(0)
    app = directory / 'NexGenVideo.app'
    identity = metadata(app, source_sha)
    if identity['treeSHA256'] != receipt['appTreeSHA256']:
        raise ValueError('Retained installed App tree differs from its producer receipt')
    pack = directory / 'plugins/musicvideo.ngvpack'
    if not pack.is_dir() or pack.is_symlink():
        raise ValueError('Original external Musicvideo pack is missing')
    for arguments in (['codesign', '--verify', '--deep', '--strict', str(app)],
                      ['xcrun', 'stapler', 'validate', str(app)],
                      ['spctl', '-a', '-t', 'exec', str(app)],
                      ['codesign', '--verify', '--strict', str(pack)]):
        subprocess.run(arguments, check=True, stdin=subprocess.DEVNULL, timeout=120)
    return identity


def restore(artifact, proof, directory):
    if sys.platform != 'darwin' or os.environ.get('GITHUB_ACTIONS') != 'true':
        raise ValueError('Restore signed release runtime only on macrunner in GitHub Actions')
    transfer = directory.parent / (directory.name + '-retained-transfer')
    transfer.mkdir(parents=True, exist_ok=False)
    archive = transfer / 'original.zip'
    download(artifact, archive)
    payload = transfer / 'payload'
    payload.mkdir()
    extract_transfer(archive, payload, {'workspace-ui.tar.gz', 'workspace-ui-input.json', 'bpy-source-receipt.json'})
    receipt = runtime_receipt(payload, {'sourceSHA': proof['productSourceSHA'], **({'packaging': proof['packaging']} if 'packaging' in proof else {})})
    directory.mkdir(parents=True, exist_ok=True)
    if (directory / 'NexGenVideo.app').exists() or (directory / 'plugins').exists():
        raise ValueError('Refusing to replace an existing runtime')
    subprocess.run(['tar', '-xzf', str(payload / 'workspace-ui.tar.gz'), '-C', str(directory)],
                   check=True, stdin=subprocess.DEVNULL, timeout=180)
    identity = validate_app(directory, proof['productSourceSHA'], receipt)
    proof.update(archiveSHA256=receipt['archiveSHA256'], appTreeSHA256=identity['treeSHA256'],
                 executableSHA256=identity['executableSHA256'],
                 runtimeInputSHA256=hashlib.sha256((payload / 'workspace-ui-input.json').read_bytes()).hexdigest())


def main():
    from retained_packaging import consumer_arguments, argument_selectors
    parser = argparse.ArgumentParser()
    parser.add_argument('mode', choices=('bind', 'restore'))
    parser.add_argument('--run-id', type=int, required=True)
    parser.add_argument('--source-sha', required=True)
    parser.add_argument('--artifact-id', type=int, required=True)
    parser.add_argument('--artifact-sha256', required=True)
    parser.add_argument('--receipt', type=Path, required=True)
    parser.add_argument('--destination', type=Path)
    consumer_arguments(parser)
    args = parser.parse_args()
    if (args.mode == 'restore') != (args.destination is not None):
        parser.error('Only restore requires a runtime destination')
    artifact, proof = bind(args.run_id, args.source_sha, args.artifact_id, args.artifact_sha256,
                           packaging=argument_selectors(args))
    if args.mode == 'restore':
        restore(artifact, proof, args.destination.resolve())
    args.receipt.parent.mkdir(parents=True, exist_ok=True)
    args.receipt.write_text(json.dumps(proof, indent=2, sort_keys=True) + '\n')
    print(json.dumps({'mode': args.mode, 'productSourceSHA': proof['productSourceSHA'],
                      'harnessSourceSHA': proof['harnessSourceSHA'], 'runtimeArtifactID': args.artifact_id}))


if __name__ == '__main__':
    main()
