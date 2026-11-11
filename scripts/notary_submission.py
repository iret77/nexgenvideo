"""Checkpoint an Apple request before upload and resume only its saved identity."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

UUID = re.compile(r'[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}')


def require(condition, message):
    if not condition:
        raise ValueError(message)


def persist(path, value, *, exclusive=False):
    path.parent.mkdir(parents=True, exist_ok=True)
    target = path if exclusive else path.with_suffix('.pending-' + str(os.getpid()))
    with target.open('x', encoding='utf-8') as stream:
        json.dump(value, stream, sort_keys=True, indent=2)
        stream.write('\n'); stream.flush(); os.fsync(stream.fileno())
    if not exclusive:
        os.replace(target, path)
    descriptor = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def payload_sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def invoke(command, timeout):
    try:
        result = subprocess.run(command, stdin=subprocess.DEVNULL, capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired as error:
        result = subprocess.CompletedProcess(command, 124, error.stdout or b'', error.stderr or b'')
    sys.stdout.buffer.write(result.stdout); sys.stdout.buffer.flush()
    sys.stderr.buffer.write(result.stderr); sys.stderr.buffer.flush()
    try:
        value = json.loads(result.stdout)
    except (ValueError, UnicodeError):
        value = {}
    return result.returncode, value if isinstance(value, dict) else {}


def execute(artifact, env):
    require(artifact.is_file() and not artifact.is_symlink(), 'Notary artifact is missing or linked')
    credentials = [env.get(name, '') for name in ('NOTARY_KEY_FILE', 'NOTARY_KEY_ID', 'NOTARY_ISSUER')]
    require(all(credentials), 'NOTARY_KEY_FILE, NOTARY_KEY_ID and NOTARY_ISSUER are required')
    attempts = env.get('NOTARY_ATTEMPTS', '3')
    delay = env.get('NOTARY_RETRY_DELAY_SECONDS', '5')
    budget = env.get('NOTARY_WAIT_BUDGET_SECONDS', '900')
    require(re.fullmatch(r'[1-9][0-9]*', attempts) is not None, 'NOTARY_ATTEMPTS must be a positive integer')
    require(re.fullmatch(r'[0-9]+', delay) is not None, 'NOTARY_RETRY_DELAY_SECONDS must be non-negative')
    require(re.fullmatch(r'[1-9][0-9]*', budget) is not None, 'NOTARY_WAIT_BUDGET_SECONDS must be a positive integer')
    source = env.get('GITHUB_SHA', '')
    if env.get('RETAINED_PACKAGING_ROOT') or env.get('RETAINED_PACKAGING_INPUT_SHA256'):
        from retained_packaging import notary_product_source
        checkpoint = env.get('RETAINED_PACKAGING_DMG_CHECKPOINT')
        source = notary_product_source(artifact, Path(checkpoint) if checkpoint else None)
    sha256 = payload_sha(artifact)
    if artifact.name == 'NexGenVideo.zip' and env.get('NGV_SIGNED_APP_ARCHIVE_SHA256'):
        require(sha256 == env['NGV_SIGNED_APP_ARCHIVE_SHA256'], 'Signed App archive differs from its verified input')
    state = Path(env.get('NOTARY_STATE_DIR') or artifact.parent / '.notary-state')
    state.mkdir(parents=True, exist_ok=True)
    journal = state / (sha256 + '.json')
    pending = state / (sha256 + '.intent')
    prepare = env.get('NOTARY_PREPARE_ONLY') == 'true'
    submit_only = env.get('NOTARY_SUBMIT_ONLY') == 'true'
    record = journal if journal.exists() else pending
    new_record = not record.exists()
    if not new_record:
        require(record.is_file() and not record.is_symlink(), 'Notary journal is linked or invalid')
        receipt = json.loads(record.read_bytes())
        require(isinstance(receipt, dict) and receipt.get('schema') == 'release-notary/v1' and receipt.get('sha256') == sha256
                and receipt.get('sourceSHA') == source, 'Notary receipt belongs to another payload or source')
    else:
        receipt = {'schema': 'release-notary/v1', 'sha256': sha256, 'sourceSHA': source,
                   'submissionID': '', 'phase': 'prepared' if prepare else 'submitting'}
        persist(pending, receipt, exclusive=True)
    submission = receipt.get('submissionID')
    require(isinstance(submission, str), 'Invalid saved Apple identity')
    require(not submission or UUID.fullmatch(submission), 'Invalid saved Apple identity')
    role = {'NexGenVideo.zip': 'app', 'NexGenVideo.dmg': 'dmg'}.get(artifact.name, 'pack')
    intent = {'schema': 'release-notary-intent/v1', 'repository': env.get('GITHUB_REPOSITORY', ''),
              'sourceSHA': source, 'producerSourceSHA': env.get('GITHUB_SHA', ''),
              'runID': env.get('GITHUB_RUN_ID', ''), 'attempt': env.get('GITHUB_RUN_ATTEMPT', ''),
              'role': role, 'sha256': sha256, 'existingSubmissionID': submission}
    if prepare:
        require(submission or receipt.get('phase') == 'prepared',
                'Notary upload outcome is unknown; no resubmission')
        require(env.get('NOTARY_INTENT_ROOT'), 'NOTARY_INTENT_ROOT is required before Apple submission')
        persist(Path(env['NOTARY_INTENT_ROOT']) / 'intent.json', intent, exclusive=True)
        print('Saved notary intent: ' + sha256, flush=True)
        return
    tool = [env['NOTARYTOOL_BIN']] if env.get('NOTARYTOOL_BIN') else ['xcrun', 'notarytool']
    auth = ['--key', credentials[0], '--key-id', credentials[1], '--issuer', credentials[2], '--output-format', 'json']
    if not submission:
        if receipt.get('phase') == 'prepared':
            require(submit_only and env.get('NOTARY_INTENT_ROOT'), 'Prepared Apple request has no bound submission stage')
            require(json.loads((Path(env['NOTARY_INTENT_ROOT']) / 'intent.json').read_bytes()) == intent,
                    'Prepared Apple intent changed')
        else:
            require(new_record, 'Notary upload outcome is unknown; no resubmission')
        journal.with_suffix('.claim').mkdir()
        receipt['phase'] = 'submitting'
        persist(pending, receipt)
        status, reply = invoke(tool + ['submit', str(artifact), *auth], 600)
        submission = reply.get('id', '')
        require(isinstance(submission, str) and UUID.fullmatch(submission),
                'Notary upload outcome is unknown; reconcile the original Apple request; no resubmission')
        receipt.update(submissionID=submission, phase='submitted')
        persist(journal, receipt, exclusive=True)
        require(payload_sha(artifact) == sha256, 'Notary payload changed during upload; its Apple identity was retained')
        if status:
            print('Upload returned an error; continuing only saved submission ' + submission, file=sys.stderr, flush=True)
    if submit_only:
        print('Saved notarization submission: ' + submission, flush=True)
        return
    deadline = time.monotonic() + int(budget)
    for attempt in range(int(attempts)):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        status, reply = invoke(tool + ['wait', submission, *auth], min(300, remaining))
        if status == 0:
            if reply.get('status') == 'Accepted':
                print('Notarization accepted: ' + submission, flush=True)
                return
            invoke(tool + ['log', submission, *auth], 30)
            raise ValueError('Notarization ' + submission + ' finished with status: ' + str(reply.get('status', 'unknown')))
        if attempt + 1 < int(attempts):
            time.sleep(min(int(delay) * (attempt + 1), max(0, deadline - time.monotonic())))
    invoke(tool + ['log', submission, *auth], 30)
    raise ValueError('Apple wait did not complete within its budget; resume saved submission ' + submission)


if __name__ == '__main__':
    try:
        require(len(sys.argv) == 2, 'usage: scripts/notarize.sh <artifact>')
        execute(Path(sys.argv[1]), os.environ)
    except (ValueError, OSError, KeyError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
