import datetime
import hashlib
import io
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import time
import zipfile

from retained_app_test_products import require


SOURCE = 'a1375966dbe6d2dd7b918c726f09ac5d1f4f16fb'
RUN = 42822598973
ARCHIVE = '251008735347f303055a3931330c2f15375d2717920c0c34bf9b65a9de42b0e1'
SUBMISSION = '7da8e716-304f-4347-85a3-5d35f96bb211'
MAX_SECONDS = 900
JOURNAL_SHA = '1cee057e29e2826a4729f7bb3f2c47fac01d7d85b5ed9f03f5a0d0ab4bd1e928'


def object_pairs(values):
    result = {}
    for key, value in values:
        require(key not in result, 'Duplicate JSON field in Apple continuation evidence')
        result[key] = value
    return result


def strict_json(raw):
    def invalid(value):
        raise ValueError('Nonfinite JSON constant: ' + value)
    return json.loads(raw, object_pairs_hook=object_pairs, parse_constant=invalid)


def digest(path):
    checksum = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            checksum.update(block)
    return checksum.hexdigest()


def persist(path, value):
    from consume_bpy_distributable_source import persist_raw
    persist_raw(path, (json.dumps(value, sort_keys=True, indent=2, allow_nan=False) + '\n').encode())


def validate(artifact, state, binding):
    from compiled_component_reuse import qualified
    from compiled_app_release import source_directory_identity
    require(qualified(binding), 'Existing Apple request lacks its exact qualified component product')
    temporary, workspace = Path(os.environ['RUNNER_TEMP']), Path(os.environ['GITHUB_WORKSPACE'])
    require(state.absolute() == temporary.absolute() / 'release-notary-state'
            and artifact.absolute() == workspace.absolute() / '.build/NexGenVideo.zip',
            'Existing Apple request escaped its exact owned paths')
    state_anchor = source_directory_identity(state, temporary)
    artifact_anchor = source_directory_identity(artifact.parent, workspace)
    require(artifact.is_file() and not artifact.is_symlink() and digest(artifact) == ARCHIVE,
            'Existing Apple request belongs to another archive')
    require(state.is_dir() and not state.is_symlink(), 'Original Apple state directory is missing or linked')
    journal, context = state / (ARCHIVE + '.json'), state / 'context.json'
    require(all(path.is_file() and not path.is_symlink() for path in (journal, context)),
            'Original Apple request or context is missing or linked')
    expected = {'schema': 'release-notary/v1', 'sha256': ARCHIVE,
                'submissionID': SUBMISSION, 'sourceSHA': SOURCE}
    journal_raw = journal.read_bytes()
    require(hashlib.sha256(journal_raw).hexdigest() == JOURNAL_SHA and strict_json(journal_raw) == expected,
            'Original Apple request changed; submitting another request is forbidden')
    current = {'schema': 'release-notary-context/v2', 'repository': 'iret77/nexgenvideo',
               'sourceSHA': SOURCE, 'producerSourceSHA': binding['producerSourceSHA'],
               'buildRunID': RUN, 'runID': binding['runID']}
    require(strict_json(context.read_bytes()) == current
            and binding['producerSourceSHA'] == os.environ.get('GITHUB_SHA')
            and binding['runID'] == int(os.environ['GITHUB_RUN_ID']), 'Apple continuation execution context differs')
    require(binding['previousNotary']['journals'].get(ARCHIVE) == expected,
            'Apple request differs from canonical original evidence')
    packaging_root = Path(os.environ['RETAINED_PACKAGING_ROOT'])
    source_directory_identity(packaging_root, temporary)
    proof = packaging_root / 'input/packaging-provenance.json'
    source_directory_identity(proof.parent, temporary)
    require(proof.is_file() and not proof.is_symlink()
            and digest(proof) == os.environ['RETAINED_PACKAGING_INPUT_SHA256']
            and strict_json(proof.read_bytes()) == binding, 'Apple continuation canonical input changed')
    return (artifact.stat().st_dev, artifact.stat().st_ino, journal_raw, context.read_bytes(), state_anchor, artifact_anchor)


def observe(artifact, state, binding, *, invoke=subprocess.run, monotonic=time.monotonic, sleep=time.sleep):
    from consume_bpy_distributable_source import physical_directory, persist_raw
    from compiled_app_release import source_directory_identity
    from compiled_core_reuse import sync_directory
    began_clock = monotonic()
    deadline = began_clock + MAX_SECONDS
    anchor = validate(artifact, state, binding)
    observations = state / 'observations' / ARCHIVE
    require(not observations.exists() and not observations.is_symlink(), 'Apple continuation starter was already consumed')
    base, proof_anchor = physical_directory(observations, create=True)
    sync_directory(observations.parent)
    sync_directory(observations)
    sync_directory(state)
    context = {'schema': 'existing-app-notary-observations/v1', 'originalSourceSHA': SOURCE,
        'originalRunID': RUN, 'originalManifestSHA256': binding['signedInput']['componentProduct']['original']['manifestSHA256'],
        'originalJournalSHA256': JOURNAL_SHA, 'submissionID': SUBMISSION, 'archiveSHA256': ARCHIVE,
        'productSourceSHA': binding['productSourceSHA'], 'harnessSourceSHA': binding['producerSourceSHA'],
        'runID': binding['runID'], 'attempt': 1, 'job': 'release',
        'packagingInputSHA256': os.environ['RETAINED_PACKAGING_INPUT_SHA256'],
        'currentContextSHA256': hashlib.sha256(anchor[3]).hexdigest(), 'startedMonotonic': began_clock,
        'deadlineMonotonic': deadline, 'budgetSeconds': MAX_SECONDS}
    persist(observations / 'context.json', context)
    persist_raw(observations / 'original-journal.json', anchor[2])
    persist_raw(observations / 'current-notary-context.json', anchor[3])
    credentials = [os.environ[name] for name in ('NOTARY_KEY_FILE', 'NOTARY_KEY_ID', 'NOTARY_ISSUER')]
    require(all(credentials), 'Apple continuation credentials are incomplete')
    command = ['xcrun', 'notarytool', 'info', SUBMISSION, '--key', credentials[0],
               '--key-id', credentials[1], '--issuer', credentials[2], '--output-format', 'json']
    index, queries = 0, []

    def finish(state_name, status=None, exit_code=1):
        source_directory_identity(observations, base, proof_anchor)
        observation = {'schema': 'existing-apple-status-observation/v1', 'submissionID': SUBMISSION,
            'archiveSHA256': ARCHIVE, 'state': state_name, 'appleStatus': status,
            'appleFinalStatusKnown': state_name in {'ACCEPTED', 'REJECTED'}, 'queries': queries,
            'newSubmissionPerformed': False}
        persist(observations / 'observation.json', observation)
        ended = monotonic()
        in_budget = ended <= deadline
        admitted = state_name == 'ACCEPTED' and in_budget
        persist(observations / 'result.json', {'schema': 'existing-notary-observation/v1',
            'contextSHA256': digest(observations / 'context.json'), 'submissionID': SUBMISSION,
            'observationSHA256': digest(observations / 'observation.json'),
            'archiveSHA256': ARCHIVE, 'state': state_name, 'appleStatus': status,
            'appleFinalStatusKnown': state_name in {'ACCEPTED', 'REJECTED'},
            'completionInBudget': in_budget, 'acceptedForContinuation': admitted,
            'newSubmissionPerformed': False, 'queries': queries, 'endedMonotonic': ended,
            'elapsedSeconds': ended - began_clock})
        print('EXISTING_APP_NOTARY_' + state_name, flush=True)
        return 0 if admitted else (75 if not in_budget or state_name == 'PENDING' else exit_code)

    while True:
        if monotonic() >= deadline:
            return finish('PENDING', exit_code=75)
        require(validate(artifact, state, binding) == anchor, 'Apple continuation inputs changed before status query')
        began = datetime.datetime.now(datetime.timezone.utc).isoformat()
        remaining = deadline - monotonic()
        if remaining <= 0:
            return finish('PENDING', exit_code=75)
        index += 1
        try:
            result = invoke(command, stdin=subprocess.DEVNULL, capture_output=True, timeout=min(60, remaining))
            code, stdout, stderr = result.returncode, result.stdout, result.stderr
        except subprocess.TimeoutExpired as error:
            code, stdout, stderr = None, error.stdout or b'', error.stderr or b''
        prefix = observations / ('query-' + str(index))
        source_directory_identity(observations, base, proof_anchor)
        for suffix, raw in (('.stdout', stdout), ('.stderr', stderr)):
            persist_raw(Path(str(prefix) + suffix), raw)
        persist(Path(str(prefix) + '.json'), {'startedAt': began, 'exitCode': code,
            'operation': 'info', 'submissionID': SUBMISSION, 'stdoutSHA256': hashlib.sha256(stdout).hexdigest(),
            'stderrSHA256': hashlib.sha256(stderr).hexdigest(), 'completedMonotonic': monotonic()})
        queries.append({'name': prefix.name, 'recordSHA256': digest(Path(str(prefix) + '.json')),
            'stdoutSHA256': hashlib.sha256(stdout).hexdigest(), 'stderrSHA256': hashlib.sha256(stderr).hexdigest()})
        require(validate(artifact, state, binding) == anchor, 'Apple continuation inputs changed during status query')
        status = None
        if code == 0:
            try:
                response = strict_json(stdout)
            except (ValueError, UnicodeDecodeError):
                response = {}
            if type(response) is dict and response.get('id') == SUBMISSION and type(response.get('status')) is str:
                status = response.get('status')
        if status != 'In Progress':
            accepted = status == 'Accepted'
            state_name = 'ACCEPTED' if accepted else ('REJECTED' if status in {'Invalid', 'Rejected'} else 'UNKNOWN')
            if state_name == 'REJECTED' and monotonic() < deadline:
                log_command = list(command)
                log_command[2] = 'log'
                try:
                    result = invoke(log_command, stdin=subprocess.DEVNULL, capture_output=True,
                        timeout=min(60, deadline - monotonic()))
                    log_code, log_out, log_err = result.returncode, result.stdout, result.stderr
                except subprocess.TimeoutExpired as error:
                    log_code, log_out, log_err = None, error.stdout or b'', error.stderr or b''
                source_directory_identity(observations, base, proof_anchor)
                persist_raw(observations / 'diagnostic.stdout', log_out)
                persist_raw(observations / 'diagnostic.stderr', log_err)
                persist(observations / 'diagnostic.json', {'operation': 'log', 'submissionID': SUBMISSION,
                    'exitCode': log_code, 'stdoutSHA256': hashlib.sha256(log_out).hexdigest(),
                    'stderrSHA256': hashlib.sha256(log_err).hexdigest()})
                require(validate(artifact, state, binding) == anchor, 'Apple continuation inputs changed during diagnostic query')
            return finish(state_name, status)
        sleep(min(30, max(0, deadline - monotonic())))


def main():
    import retained_packaging
    require(len(sys.argv) == 2 and sys.platform == 'darwin' and os.environ.get('GITHUB_ACTIONS') == 'true'
            and os.environ.get('GITHUB_REPOSITORY') == 'iret77/nexgenvideo'
            and os.environ.get('GITHUB_JOB') == 'release' and os.environ.get('GITHUB_RUN_ATTEMPT') == '1',
            'Existing Apple continuation is exclusive to the registered macrunner release job')
    return observe(Path(sys.argv[1]), Path(os.environ['NOTARY_STATE_DIR']), retained_packaging.current_binding())


def observation_members(raw):
    prefix = ARCHIVE + '/'
    fixed = {'context.json', 'result.json', 'observation.json', 'original-journal.json', 'current-notary-context.json',
        'diagnostic.json', 'diagnostic.stdout', 'diagnostic.stderr'}
    require(type(raw) is bytes and 0 < len(raw) <= 512 * 1024, 'App observation archive exceeds its byte bound')
    with zipfile.ZipFile(io.BytesIO(raw)) as archive:
        entries = archive.infolist()
        require(0 < len(entries) <= 101 and len({entry.filename for entry in entries}) == len(entries)
            and sum(entry.file_size for entry in entries) <= 512 * 1024,
            'App observation archive has duplicate or excessive entries')
        members = {}
        for entry in entries:
            name = entry.filename.removeprefix(prefix)
            require(entry.filename.startswith(prefix) and '/' not in name and '\\' not in name
                and (name in fixed or re.fullmatch(r'query-(?:[1-9]|[12][0-9]|3[01])\.(?:json|stdout|stderr)', name))
                and not entry.is_dir() and stat.S_IFMT(entry.external_attr >> 16) in {0, stat.S_IFREG},
                'App observation archive contains a foreign prefix, link or unregistered member')
            members[name] = archive.read(entry)
        return members


def observation_scope(binding):
    import retained_packaging
    original_input = dict(binding)
    for key in ('restoredOriginal', 'originalPackArchives', 'final'):
        original_input.pop(key, None)
    original_input['stage'] = 'input'
    original_input['files'] = {name: value for name, value in binding.get('files', {}).items()
        if name not in {'component-native-checks.reused.json', 'component-notary-observations.zip', 'submitted-dmg-proof.zip',
                        'bpy-source-original-receipt.json', 'bpy-source-receipt.json', 'bpy-source-reuse.json'}}
    return {'productSourceSHA': binding['productSourceSHA'], 'harnessSourceSHA': binding['producerSourceSHA'],
        'runID': binding['runID'], 'packagingInputSHA256': retained_packaging.digest(retained_packaging.encoded(original_input))}


def verify_observations(members, binding):
    from compiled_component_reuse import qualified
    require(qualified(binding), 'App observation has no exact qualified component product')
    prior = binding.get('previousNotary', {}).get('acceptedAppNotary')
    scope = observation_scope(binding)
    if prior is not None:
        require(qualified(binding) and prior.get('schema') == 'component-accepted-app-notary-reuse/v1'
            and prior.get('state') == 'REUSED' and prior.get('newAppleOperationPerformed') is False,
            'Saved accepted App observation changed its reuse scope')
        raw = bytes.fromhex(prior['archiveHex'])
        require(hashlib.sha256(raw).hexdigest() == prior['archiveSHA256']
            and prior['artifact'].get('digest') == 'sha256:' + prior['archiveSHA256']
            and observation_members(raw) == members, 'Saved accepted App observation bytes changed')
        scope = prior.get('originScope')
        require(type(scope) is dict and set(scope) == {'productSourceSHA', 'harnessSourceSHA', 'runID', 'packagingInputSHA256'}
            and scope['productSourceSHA'] == binding['productSourceSHA'], 'Saved App observation lost its original verified execution scope')
    required = {'context.json', 'result.json', 'observation.json', 'original-journal.json', 'current-notary-context.json'}
    require(qualified(binding) and type(members) is dict and required <= set(members),
            'Existing App observations have no qualified canonical product or terminal context')
    context, result = (strict_json(members[name]) for name in ('context.json', 'result.json'))
    require(type(context) is dict and type(result) is dict, 'Existing App observation context or result is malformed')
    require(all(type(context.get(name)) is int for name in ('originalRunID', 'runID', 'attempt', 'budgetSeconds')),
        'Existing App observation numeric identities must be integers')
    require(context.get('schema') == 'existing-app-notary-observations/v1'
        and context.get('originalSourceSHA') == SOURCE and context.get('originalRunID') == RUN
        and context.get('originalManifestSHA256') == binding['signedInput']['componentProduct']['original']['manifestSHA256']
        and context.get('originalJournalSHA256') == JOURNAL_SHA and context.get('submissionID') == SUBMISSION
        and context.get('archiveSHA256') == ARCHIVE and context.get('productSourceSHA') == scope['productSourceSHA']
        and context.get('harnessSourceSHA') == scope['harnessSourceSHA'] and context.get('runID') == scope['runID']
        and context.get('attempt') == 1 and context.get('job') == 'release'
        and context.get('budgetSeconds') == MAX_SECONDS, 'Existing App observation origin or execution differs')
    expected_context = {'schema': 'release-notary-context/v2', 'repository': 'iret77/nexgenvideo',
        'sourceSHA': SOURCE, 'producerSourceSHA': scope['harnessSourceSHA'], 'buildRunID': RUN, 'runID': scope['runID']}
    require(strict_json(members['current-notary-context.json']) == expected_context
        and hashlib.sha256(members['original-journal.json']).hexdigest() == JOURNAL_SHA
        and context.get('currentContextSHA256') == hashlib.sha256(members['current-notary-context.json']).hexdigest()
        and context.get('packagingInputSHA256') == scope['packagingInputSHA256'],
        'Existing App observations changed their exact canonical input or current journal context')
    require(result.get('schema') == 'existing-notary-observation/v1'
        and result.get('observationSHA256') == hashlib.sha256(members['observation.json']).hexdigest()
        and result.get('contextSHA256') == hashlib.sha256(members['context.json']).hexdigest()
        and result.get('submissionID') == SUBMISSION and result.get('archiveSHA256') == ARCHIVE
        and result.get('newSubmissionPerformed') is False
        and result.get('state') == 'ACCEPTED' and result.get('appleStatus') == 'Accepted'
        and result.get('appleFinalStatusKnown') is True and result.get('completionInBudget') is True
        and result.get('acceptedForContinuation') is True, 'Existing App has no accepted bounded Apple observation')
    observation = strict_json(members['observation.json'])
    require(observation == {'schema': 'existing-apple-status-observation/v1', 'submissionID': SUBMISSION,
        'archiveSHA256': ARCHIVE, 'state': result['state'], 'appleStatus': result['appleStatus'],
        'appleFinalStatusKnown': result['appleFinalStatusKnown'], 'queries': result['queries'],
        'newSubmissionPerformed': False}, 'Existing App admission changed its durably retained Apple observation')
    start, end, deadline = (context.get('startedMonotonic'), result.get('endedMonotonic'), context.get('deadlineMonotonic'))
    require(all(type(value) in (int, float) for value in (start, end, deadline))
        and start <= end <= deadline == start + MAX_SECONDS
        and result.get('elapsedSeconds') == end - start, 'Existing App observation exceeded or changed its measured budget')
    queries = result.get('queries')
    require(type(queries) is list and 0 < len(queries) <= 31, 'Existing App terminal query inventory is missing or excessive')
    expected = set(required)
    previous_query = start
    for index, query in enumerate(queries, 1):
        name = 'query-' + str(index)
        require(type(query) is dict and query.get('name') == name, 'Existing App query order differs')
        names = {suffix: name + suffix for suffix in ('.json', '.stdout', '.stderr')}
        require(set(names.values()) <= set(members), 'Existing App query originals are incomplete')
        expected.update(names.values())
        for suffix, field in (('.json', 'recordSHA256'), ('.stdout', 'stdoutSHA256'), ('.stderr', 'stderrSHA256')):
            require(query.get(field) == hashlib.sha256(members[names[suffix]]).hexdigest(), 'Existing App query bytes changed')
        metadata = strict_json(members[names['.json']])
        require(type(metadata) is dict and metadata.get('operation') == 'info' and metadata.get('submissionID') == SUBMISSION
            and metadata.get('stdoutSHA256') == query['stdoutSHA256'] and metadata.get('stderrSHA256') == query['stderrSHA256'],
            'Existing App query metadata changed its original operation or outputs')
        completed = metadata.get('completedMonotonic')
        require(type(completed) in (int, float) and previous_query <= completed <= end <= deadline,
            'Existing App query completion escaped its measured execution budget')
        previous_query = completed
        response = strict_json(members[names['.stdout']])
        status = 'Accepted' if index == len(queries) else 'In Progress'
        require(type(metadata.get('exitCode')) is int and metadata.get('exitCode') == 0
            and type(response) is dict and response.get('id') == SUBMISSION
            and response.get('status') == status, 'Existing App query does not prove the declared status sequence')
    require(set(members) == expected, 'Existing App observation artifact contains unbound originals')
    return result


if __name__ == '__main__':
    raise SystemExit(main())
