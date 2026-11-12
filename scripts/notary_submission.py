"""Checkpoint an Apple request before upload and resume only its saved identity."""
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

UUID = re.compile(r'[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}')
WAIT_BUDGET_SECONDS = 3600
QUERY_TIMEOUT_SECONDS = 60


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
        def unique(pairs):
            value = dict(pairs)
            require(len(value) == len(pairs), 'Duplicate Apple response keys')
            return value
        value = json.loads(result.stdout, object_pairs_hook=unique)
    except (ValueError, UnicodeError):
        value = {}
    return result.returncode, value if isinstance(value, dict) else {}


def execute(artifact, env):
    require(artifact.is_file() and not artifact.is_symlink(), 'Notary artifact is missing or linked')
    credentials = [env.get(name, '') for name in ('NOTARY_KEY_FILE', 'NOTARY_KEY_ID', 'NOTARY_ISSUER')]
    require(all(credentials), 'NOTARY_KEY_FILE, NOTARY_KEY_ID and NOTARY_ISSUER are required')
    attempts = env.get('NOTARY_ATTEMPTS', '3')
    delay = env.get('NOTARY_RETRY_DELAY_SECONDS', '5')
    budget = env.get('NOTARY_WAIT_BUDGET_SECONDS', str(WAIT_BUDGET_SECONDS))
    interval = env.get('NOTARY_POLL_INTERVAL_SECONDS', '30')
    require(re.fullmatch(r'[1-9][0-9]*', attempts) is not None, 'NOTARY_ATTEMPTS must be a positive integer')
    require(re.fullmatch(r'[0-9]+', delay) is not None, 'NOTARY_RETRY_DELAY_SECONDS must be non-negative')
    require(re.fullmatch(r'[1-9][0-9]*', budget) is not None, 'NOTARY_WAIT_BUDGET_SECONDS must be a positive integer')
    require(re.fullmatch(r'[0-9]+', interval) is not None, 'NOTARY_POLL_INTERVAL_SECONDS must be non-negative')
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
    failures = 0
    query = 0
    apple_status = None
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        query += 1
        status, reply = invoke(tool + ['info', submission, *auth], min(QUERY_TIMEOUT_SECONDS, remaining))
        apple_status = reply.get('status') if status == 0 and reply.get('id') == submission else None
        if not isinstance(apple_status, str) or apple_status not in {'Accepted', 'In Progress', 'Invalid', 'Rejected'}:
            apple_status = None
        observation = {'schema': 'release-notary-status-observation/v1', 'sha256': sha256,
                       'sourceSHA': source, 'producerSourceSHA': env.get('GITHUB_SHA', ''),
                       'runID': env.get('GITHUB_RUN_ID', ''), 'attempt': env.get('GITHUB_RUN_ATTEMPT', ''),
                       'submissionID': submission, 'role': role, 'query': query, 'exitCode': status,
                       'appleStatus': apple_status, 'at': datetime.datetime.now(datetime.timezone.utc).isoformat()}
        persist(state / 'status-observations' / (sha256 + '-' + str(time.time_ns()) + '.json'), observation, exclusive=True)
        if apple_status == 'Accepted':
            print('Notarization accepted: ' + submission, flush=True)
            return
        if apple_status in {'Invalid', 'Rejected'}:
            invoke(tool + ['log', submission, *auth], 30)
            raise ValueError('Notarization ' + submission + ' finished with status: ' + apple_status)
        failures = 0 if apple_status == 'In Progress' else failures + 1
        require(failures < int(attempts), 'Apple status query failed; resume saved submission ' + submission)
        time.sleep(min(int(interval) if apple_status else int(delay) * failures,
                       max(0, deadline - time.monotonic())))
    state_name = 'still In Progress' if apple_status == 'In Progress' else 'status unknown'
    raise ValueError('Apple processing ' + state_name + '; resume saved submission ' + submission)


if __name__ == '__main__':
    try:
        require(len(sys.argv) == 2, 'usage: scripts/notarize.sh <artifact>')
        execute(Path(sys.argv[1]), os.environ)
    except (ValueError, OSError, KeyError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
