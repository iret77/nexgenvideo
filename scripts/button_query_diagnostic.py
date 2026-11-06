"""Bind one failed native query and observe its unchanged framework source subset."""
import argparse
import datetime
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = '5ae7eb0d4a1569928ba8dcf895e33b6eca68535d'
QUERY = 'Sources/NexGenVideo/App/NativeButtonAccessibility.swift'
FIXTURE = 'Tests/NexGenVideoTests/UI/NativeButtonInteractionTests.swift'
FILES = (QUERY, FIXTURE, 'Sources/NexGenVideo/UI/CapsuleButton.swift',
         'Sources/NexGenVideo/UI/AppTheme.swift', 'Sources/NexGenVideo/UI/DesignSystem.swift',
         'Sources/NexGenVideo/UI/PackAccent.swift')
HARNESS = {'.github/workflows/diagnostic-acceptance.yml', 'scripts/test_diagnostic_acceptance.py',
           'scripts/button_query_diagnostic.py', 'scripts/button_query_diagnostic.swift',
           'scripts/test_button_query_diagnostic.py'}
FAILED = {'actualSwiftUIButtonIsDiscoveredWithoutAnExternalReader', 'actualDisabledSwiftUIButtonIsExcluded',
          'actualDuplicateButtonsCannotBecomeAUniqueTarget', 'actualTraversalBudgetCannotQualifyAPartialTree',
          'cancellationDuringTheLastChildMessageCannotQualifyATree', 'theLastChildMessageUsesItsOwnRemainingTimeout'}
MODES = ('enabled', 'disabled', 'duplicate', 'slow-cancel', 'slow-timeout')
CRASH_MODES = ('slow-cancel', 'slow-timeout')
CRASH_KIND = 'native-button-query-crash'
PRIOR_RUN = 42143760159
PRIOR_SOURCE = '82a04f37e0a11fbefae1890d91c7691b8b8b9b45'
PRIOR_JOB = 127650280110


def require(value, message):
    if not value:
        raise ValueError(message)


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def write(path, value):
    require(not path.exists(), 'Diagnostic output already exists')
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')


def git(*args):
    return subprocess.check_output(['git', '-C', str(ROOT), *args], stdin=subprocess.DEVNULL, timeout=30)


def validate_inputs(env):
    require(env['KIND'] in ('native-button-query', CRASH_KIND), 'Incorrect button query diagnostic mode')
    for key in ('CANDIDATE_RUN', 'CANDIDATE_ARTIFACT', 'VERIFIED_PR'):
        require(re.fullmatch('[1-9][0-9]*', env[key]), 'Positive original producer and current Source IDs required')
    require(env['CANDIDATE_SOURCE'] == SOURCE and re.fullmatch('[a-f0-9]{64}', env['CANDIDATE_DIGEST']),
            'Exact failed query source and artifact digest required')
    require(env['SCALE'] == '1' and not any(env.get(key, '') for key in (
        'DMG_DIGEST', 'JOURNEY_JOB', 'JOURNEY_ARTIFACT', 'JOURNEY_DIGEST', 'EXTRA_SOURCE', 'EXTRA_PRODUCTS',
        'EXTRA_PRODUCTS_SHA',
        'PACKAGING_PRODUCER_SOURCE', 'PACKAGING_PROVENANCE_ARTIFACT_ID', 'PACKAGING_PROVENANCE_ARTIFACT_SHA256')),
        'Unconsumed diagnostic selectors cannot be ignored')
    if env['KIND'] == CRASH_KIND:
        crash_request(env)
    else:
        require(not any(env.get(key, '') for key in ('EXTRA_FAILURE', 'EXTRA_FAILURE_SHA', 'RUNTIME_FAILURE_BINDING')),
                'Original observations cannot ignore crash selectors')


def crash_request(env):
    require(env['CANDIDATE_RUN'] == '42121681154' and env['CANDIDATE_ARTIFACT'] == '13461467380'
            and env['CANDIDATE_DIGEST'] == 'a14ad1c9fbcc0feb712ca93ec8ea3e354591be5e7834ae2b7a94bd2bf28a73f7',
            'The crash investigation must retain its exact original native failure')
    require(re.fullmatch('[1-9][0-9]*', env.get('EXTRA_FAILURE', ''))
            and re.fullmatch('[a-f0-9]{64}', env.get('EXTRA_FAILURE_SHA', '')), 'Exact prior crash evidence required')
    try:
        value = json.loads(env.get('RUNTIME_FAILURE_BINDING', ''))
    except (ValueError, TypeError) as error:
        raise ValueError('Explicit prior crash binding required') from error
    require(isinstance(value, dict) and set(value) == {'schema', 'producer_run_id', 'producer_source_sha',
            'job_id', 'source_binding_artifact_id', 'source_binding_artifact_sha256'}, 'Unknown crash binding fields')
    require(value['schema'] == 'nexgenvideo/button-query-crash-request/1'
            and type(value['producer_run_id']) is int and value['producer_run_id'] == PRIOR_RUN
            and value['producer_source_sha'] == PRIOR_SOURCE and type(value['job_id']) is int and value['job_id'] == PRIOR_JOB
            and type(value['source_binding_artifact_id']) is int and value['source_binding_artifact_id'] > 0
            and isinstance(value['source_binding_artifact_sha256'], str)
            and re.fullmatch('[a-f0-9]{64}', value['source_binding_artifact_sha256']), 'Prior crash identity differs')
    return value


def zip_members(path):
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        require(len(names) == len(set(names)) and archive.testzip() is None, 'Crash evidence archive is ambiguous or corrupt')
        return {name: archive.read(name) for name in names}


def verify_crash_payload(observations, source_archive, source_files, qualified_original):
    require(source_archive.get('original-evidence.zip') == qualified_original and qualified_original,
            'Prior source archive does not contain the exact freshly qualified original payload')
    receipt = json.loads(observations['receipt.json'])
    binding_raw = source_archive['binding.json']
    binding = json.loads(binding_raw)
    require(receipt['schema'] == 'nexgenvideo/button-query-observation/1'
            and receipt['sourceSHA'] == PRIOR_SOURCE and receipt['runID'] == str(PRIOR_RUN) and receipt['attempt'] == '1'
            and receipt['bindingSHA256'] == digest(binding_raw) and receipt['measurementComplete'] is False
            and receipt['appAcceptance'] is False and type(receipt['appBuilds']) is int
            and type(receipt['nativeUnitExecutions']) is int and receipt['appBuilds'] == receipt['nativeUnitExecutions'] == 0
            and receipt['originalFailureResolved'] is False, 'Prior failure receipt differs')
    require(binding['schema'] == 'nexgenvideo/button-query-binding/1' and binding['sourceSHA'] == PRIOR_SOURCE
            and binding['runID'] == str(PRIOR_RUN) and binding['attempt'] == '1'
            and binding['originalRun']['id'] == 42121681154 and binding['originalRun']['head_sha'] == SOURCE
            and binding['originalArtifact']['id'] == 13461467380
            and binding['originalArtifact']['digest'] == 'sha256:a14ad1c9fbcc0feb712ca93ec8ea3e354591be5e7834ae2b7a94bd2bf28a73f7',
            'Prior observation does not bind the original failed query')
    require(binding['sourceFiles'] == source_files and binding['sourceTree'] == '4b944c7fd973270c072160f48b243b64f9de3567'
            and binding['sourceProof']['schema'] == 'core-pr-source-composition/v1'
            and binding['sourceProof']['sourceSHA'] == PRIOR_SOURCE and binding['sourceProof']['runID'] == str(PRIOR_RUN)
            and binding['sourceProof']['attempt'] == '1' and binding['sourceProof']['originalRun']['id'] == 42140974612,
            'Prior observation source objects or Source receipt differ')
    results = receipt['results']
    require(len(results) == len(MODES) and {item['mode'] for item in results} == set(MODES), 'Prior observations are incomplete')
    selected = []
    for mode in CRASH_MODES:
        result = next(item for item in results if item['mode'] == mode)
        process = json.loads(observations[mode + '.process.json'])
        require(result['status'] == 'failed-observation' and result['process'] == process
                and type(process['pid']) is int and process['pid'] > 0 and process['exitCode'] == -signal.SIGTRAP
                and process['processReaped'] is True and process['timedOut'] is False
                and mode + '.json' not in observations and observations[mode + '.log'] == b'', 'Prior Slow crash branch differs')
        selected.append({'mode': mode, 'process': process})
    require(len({item['process']['pid'] for item in selected}) == len(CRASH_MODES), 'Prior crashes did not use fresh processes')
    return {'receiptSHA256': digest(observations['receipt.json']), 'bindingSHA256': digest(binding_raw),
            'embeddedOriginalSHA256': digest(qualified_original), 'cases': selected}


def bind_prior_crashes(evidence, env, api, download, source_files, qualified_original):
    request = crash_request(env)
    run = api('/actions/runs/' + str(PRIOR_RUN))
    jobs = api('/actions/runs/' + str(PRIOR_RUN) + '/jobs?per_page=100')
    require(run['id'] == PRIOR_RUN and run['head_sha'] == PRIOR_SOURCE and run['run_attempt'] == 1
            and run['actor']['login'] == 'iret77' and run['repository']['full_name'] == 'iret77/nexgenvideo'
            and run['path'] == '.github/workflows/diagnostic-acceptance.yml' and run['event'] == 'workflow_dispatch'
            and run['status'] == 'completed' and run['conclusion'] == 'failure', 'Prior diagnostic producer differs')
    require(jobs['total_count'] == len(jobs['jobs']), 'Prior diagnostic job inventory is incomplete')
    selected = [job for job in jobs['jobs'] if job['id'] == PRIOR_JOB]
    require(len(selected) == 1, 'Prior diagnostic job is ambiguous')
    job = selected[0]
    require(job['name'] == 'native-button-query' and job['run_id'] == PRIOR_RUN and job['head_sha'] == PRIOR_SOURCE
            and job['run_attempt'] == 1 and job['status'] == 'completed' and job['conclusion'] == 'failure'
            and job['labels'] == ['macrunner'], 'Prior diagnostic runner or failure differs')
    archives, artifacts = [], []
    for artifact_id, checksum, name, filename in (
            (int(env['EXTRA_FAILURE']), env['EXTRA_FAILURE_SHA'], f'native-button-query-{PRIOR_RUN}-a1', 'prior-observations.zip'),
            (request['source_binding_artifact_id'], request['source_binding_artifact_sha256'],
             'native-button-query-source-binding', 'prior-source-binding.zip')):
        artifact = api('/actions/artifacts/' + str(artifact_id))
        require(artifact['id'] == artifact_id and artifact['name'] == name and artifact['expired'] is False
                and artifact['digest'] == 'sha256:' + checksum and artifact['workflow_run']['id'] == PRIOR_RUN
                and artifact['workflow_run']['head_sha'] == PRIOR_SOURCE, 'Prior crash archive provenance differs')
        target = evidence / filename
        download(artifact, target)
        require(target.stat().st_size == artifact['size_in_bytes'] and digest(target.read_bytes()) == checksum,
                'Prior crash archive transfer changed')
        archives.append(zip_members(target)); artifacts.append(artifact)
    verified = verify_crash_payload(*archives, source_files, qualified_original)
    verified.update(request=request, run=run, job=job, artifacts=artifacts)
    return verified


def failure_archive(path):
    prefix = '_temp/release-test-evidence/'
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        require(len(names) == len(set(names)) and archive.testzip() is None, 'Original archive is ambiguous or corrupt')
        members = {name: digest(archive.read(name)) for name in names}
        suite = json.loads(archive.read(prefix + 'suite.json'))
        host = json.loads(archive.read(prefix + 'app-swift-testing/host-receipt.json'))
        retained = json.loads(archive.read(prefix + 'retained-engine-receipt.json'))
        records = [json.loads(line) for line in archive.read(prefix + 'app-swift-testing/events.jsonl').split(b'\n') if line]
    require(suite['sourceSHA'] == host['sourceSHA'] == SOURCE and suite['completed'] is False
            and suite['scope'] == 'all' and suite['filter'] == '', 'Original native suite differs')
    require([phase['name'] for phase in suite['phases']] == ['xctest', 'engine-swift-testing', 'app-swift-testing']
            and [phase['exitCode'] for phase in suite['phases']] == [0, 0, 1], 'Original failure backend differs')
    require(host['started'] is True and host['completed'] is True and host['abiSucceeded'] is False
            and host['mainThread'] is True and host['runReturnedAfterCompletion'] is True, 'Original host lifetime differs')
    issues = [record['payload'] for record in records if record['kind'] == 'event'
              and record['payload']['kind'] == 'issueRecorded' and record['payload']['issue']['isFailure']
              and not record['payload']['issue']['isKnown']]
    require(len(issues) == 14 and {item['testID'].split('/')[1].split('(')[0] for item in issues} == FAILED
            and all(item['testID'].startswith('NexGenVideoTests.NativeButtonInteractionTests/') for item in issues),
            'The recorded original query failure branch changed')
    return {'members': members, 'host': host, 'toolchain': retained['toolchain'], 'issues': issues}


def verify_producer(run, jobs, artifact, env):
    run_id, artifact_id = int(env['CANDIDATE_RUN']), int(env['CANDIDATE_ARTIFACT'])
    require(run['id'] == run_id and run['head_sha'] == SOURCE and run['run_attempt'] == 1
            and run['actor']['login'] == 'iret77' and run['repository']['full_name'] == 'iret77/nexgenvideo'
            and run['path'] == '.github/workflows/release.yml' and run['event'] == 'workflow_dispatch'
            and run['status'] == 'completed' and run['conclusion'] == 'failure', 'Original producer differs')
    require(jobs['total_count'] == len(jobs['jobs']), 'Original job list is incomplete')
    selected = [job for job in jobs['jobs'] if job['name'] == 'release-build']
    require(len(selected) == 1, 'Original native builder is ambiguous')
    job = selected[0]
    require(job['run_id'] == run_id and job['head_sha'] == SOURCE and job['run_attempt'] == 1
            and job['labels'] == ['macrunner'] and job['status'] == 'completed' and job['conclusion'] == 'failure',
            'Original native builder identity differs')
    steps = {step['name']: step['conclusion'] for step in job['steps']}
    require(steps.get('Build the exact release test configuration') == 'success'
            and steps.get('Test the exact release configuration') == 'failure', 'Original compile or failed test step differs')
    require(artifact['id'] == artifact_id and artifact['name'] == 'release-test-evidence'
            and artifact['expired'] is False and artifact['digest'] == 'sha256:' + env['CANDIDATE_DIGEST']
            and artifact['workflow_run']['id'] == run_id and artifact['workflow_run']['head_sha'] == SOURCE,
            'Original native evidence identity differs')
    return job


def source_subset(originals):
    theme, design, accent = (originals['Sources/NexGenVideo/UI/' + name] for name in (
        'AppTheme.swift', 'DesignSystem.swift', 'PackAccent.swift'))
    theme_end = b'// MARK: - ClipType color mapping'
    project_start, project_end = b'struct ProjectInterface<Content: View>: View {', b'\nextension View {'
    color_start, color_end = b'extension Color {', b'\nextension EditorViewModel {'
    require(theme.count(theme_end) == 1 and design.count(project_start) == design.count(project_end) == 1
            and accent.count(color_start) == accent.count(color_end) == 1, 'Framework source subset boundaries changed')
    start, end = design.index(project_start), design.index(project_end)
    require(start < end, 'Framework source subset order changed')
    ui = 'Sources/NexGenVideo/UI/'
    import_start = accent.index(b'import SwiftUI\n')
    ranges = {
        'NativeButtonAccessibility.swift': [(QUERY, 0, len(originals[QUERY]))],
        'CapsuleButton.swift': [(ui + 'CapsuleButton.swift', 0, len(originals[ui + 'CapsuleButton.swift']))],
        'AppTheme.swift': [(ui + 'AppTheme.swift', 0, theme.index(theme_end))],
        'DesignSystem.swift': [(ui + 'DesignSystem.swift', 0, start), (ui + 'DesignSystem.swift', end, len(design))],
        'Color.swift': [(ui + 'PackAccent.swift', import_start, import_start + len(b'import SwiftUI\n')),
                        (ui + 'PackAccent.swift', accent.index(color_start), accent.index(color_end))],
    }
    return {name: b''.join(originals[path][left:right] for path, left, right in pieces)
            for name, pieces in ranges.items()}, ranges


def bind(args):
    env = os.environ
    validate_inputs(env)
    require(env['GITHUB_ACTIONS'] == 'true' and env['GITHUB_REPOSITORY'] == 'iret77/nexgenvideo', 'Use repository CI only')
    require(git('rev-parse', 'HEAD').decode().strip() == env['GITHUB_SHA']
            and not git('status', '--porcelain', '--untracked-files=no').strip(), 'Tracked diagnostic source is dirty or substituted')
    require(set(git('diff', '--no-renames', '--name-only', SOURCE, env['GITHUB_SHA']).decode().splitlines()) <= HARNESS,
            'Product or unrelated verification source changed')
    git('merge-base', '--is-ancestor', SOURCE, env['GITHUB_SHA'])
    proof = json.loads((args.source_proof / 'receipt.json').read_text())
    require(proof['schema'] == 'core-pr-source-composition/v1' and proof['sourceSHA'] == env['GITHUB_SHA']
            and proof['runID'] == env['GITHUB_RUN_ID'] and proof['attempt'] == '1'
            and proof['originalRun']['id'] == int(env['VERIFIED_PR']), 'Current Source receipt binding differs')
    sys.path.insert(0, str(ROOT / 'scripts/external-gui'))
    import test_bundle
    run = test_bundle.api('/actions/runs/' + env['CANDIDATE_RUN'])
    jobs = test_bundle.api('/actions/runs/' + env['CANDIDATE_RUN'] + '/jobs?per_page=100')
    artifact = test_bundle.api('/actions/artifacts/' + env['CANDIDATE_ARTIFACT'])
    job = verify_producer(run, jobs, artifact, env)
    args.evidence.mkdir(parents=True, exist_ok=False)
    original = args.evidence / 'original-evidence.zip'
    test_bundle.download(artifact, original)
    require(original.stat().st_size == artifact['size_in_bytes'] and digest(original.read_bytes()) == env['CANDIDATE_DIGEST'],
            'Original evidence transfer changed')
    observed = failure_archive(original)
    originals = {path: git('show', SOURCE + ':' + path) for path in FILES}
    require(all((ROOT / path).read_bytes() == raw for path, raw in originals.items()), 'Framework or fixture bytes changed')
    source_files = {path: {'SHA256': digest(raw), 'gitBlob': git('rev-parse', SOURCE + ':' + path).decode().strip()}
                    for path, raw in originals.items()}
    crash = bind_prior_crashes(args.evidence, env, test_bundle.api, test_bundle.download, source_files,
                               original.read_bytes()) if env['KIND'] == CRASH_KIND else None
    write(args.evidence / 'binding.json', {'schema': 'nexgenvideo/button-query-crash-binding/1' if crash else 'nexgenvideo/button-query-binding/1',
        'sourceSHA': env['GITHUB_SHA'], 'sourceTree': git('rev-parse', 'HEAD^{tree}').decode().strip(),
        'runID': env['GITHUB_RUN_ID'], 'attempt': env['GITHUB_RUN_ATTEMPT'],
        'originalRun': run, 'originalJob': job, 'originalArtifact': artifact, 'originalEvidence': observed,
        'sourceProof': proof, 'sourceFiles': source_files,
        'harnessFiles': {path: digest((ROOT / path).read_bytes()) for path in sorted(HARNESS)},
        'diagnosticMode': env['KIND'], 'priorCrashes': crash,
        'appAcceptance': False, 'appBuilds': 0, 'nativeUnitExecutions': 0})


def owned_command(command, log, timeout):
    timed_out = False
    started_wall = datetime.datetime.now(datetime.timezone.utc).isoformat()
    started = time.monotonic()
    with log.open('xb') as stream:
        child = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=stream, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = child.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            try:
                os.killpg(child.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                code = child.wait(timeout=2)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(child.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                code = child.wait()
    write(log.with_suffix('.process.json'), {'pid': child.pid, 'command': command, 'exitCode': code,
        'startedWall': started_wall, 'finishedWall': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'startedMonotonic': started, 'finishedMonotonic': time.monotonic(),
        'executableSHA256': digest(Path(command[0]).read_bytes()) if Path(command[0]).is_file() else None,
        'timedOut': timed_out, 'processReaped': True})
    require(not timed_out, 'Owned framework process timed out; original log retained')
    require(code == 0, 'Owned framework process failed; original log retained')
    return child.pid


def rectangle(values, *, positive=False):
    require(isinstance(values, list) and len(values) == 4 and all(type(value) in (int, float)
            and math.isfinite(value) for value in values) and all(value > 0 if positive else value >= 0 for value in values[2:]),
            'Unknown native frame geometry')
    return values


def same_frame(left, right):
    return all(abs(a - b) <= .5 for a, b in zip(rectangle(left), rectangle(right)))


def node_frame(node):
    require(isinstance(node['AXPosition'], list) and len(node['AXPosition']) == 2
            and isinstance(node['AXSize'], list) and len(node['AXSize']) == 2, 'Raw position or size is malformed')
    return rectangle([*node['AXPosition'], *node['AXSize']])


def known_window(node, pid):
    require(node['pid'] == pid and node['AXRole'] == 'AXWindow'
            and all(type(node['statuses'].get(key)) is int and node['statuses'][key] == 0
                    for key in ('pid', 'AXRole', 'AXPosition', 'AXSize')),
            'Unknown or foreign AX window')
    return node_frame(node)


def cg_binding(geometry, pid, window, frame):
    require(geometry['window'] == window and same_frame(geometry['frame'], frame), 'NS window request changed')
    inventory = geometry['CGWindows']
    require(inventory and all(item['pid'] == pid and type(item['number']) is int and item['number'] > 0
            and item['onscreen'] is True for item in inventory), 'Unknown CG window owner or visibility')
    matches = [item for item in inventory if same_frame(item['frame'], frame)]
    require(len(matches) == 1 and matches[0]['number'] == window, 'CG window identity is not unique')


def validate_observation(result, mode, pid):
    try:
        _validate_observation(result, mode, pid)
    except (KeyError, TypeError, IndexError) as error:
        raise ValueError('Incomplete native observation structure: ' + str(error)) from None


def _validate_observation(result, mode, pid):
    require(result['schema'] == 'nexgenvideo/button-query-framework-control/1' and result['mode'] == mode
            and result['pid'] == pid and result['mainLoopRunning'] is True and result['mainThread'] is True
            and result['originalQueryBeforeAdditionalAX'] is True and result['appAcceptance'] is False
            and result['sourceSubsetFrameworkFixture'] is True and result['parallelAppTestHost'] is False,
            'Framework observation provenance is incomplete')
    raw = result['rawAttributesAfterOriginalQueries']
    frame, window = rectangle(raw['requestFrame'], positive=True), raw['window']
    require(type(window) is int and window > 0, 'Missing actual target window number')
    for key in ('originalFirstQuery', 'originalQueryAfterCGStability', 'queryAfterAdditionalAX'):
        require(result[key]['pid'] == pid and result[key]['readOnMainThread'] is False
                and result[key]['plane'] == 'public-AX' and result[key]['window'] == window,
                'Original query is not bound to its own background window')
    for query, geometry in [('originalFirstQuery', 'beforeFirstQuery'),
                            ('originalQueryAfterCGStability', 'beforeWarmQuery'), ('queryAfterAdditionalAX', 'beforeLastQuery')]:
        require(result[geometry]['window'] == window
                and same_frame(result[query]['expectedWindowFrame'], result[geometry]['frame']), 'Original NS query geometry differs')
    cg_binding(result['beforeRawAttributes'], pid, window, frame)
    cg_binding(result['afterRawAttributes'], pid, window, frame)
    require(raw['pid'] == pid and raw['readOnMainThread'] is False
            and raw['hierarchyEnumerationEnded'] is True and raw['hierarchyComplete'] is True
            and raw['targetStillPresentByCFEqual'] is True and raw['errors'] == [],
            'Raw hierarchy is incomplete, over budget, timed out or changed')
    require(type(raw['CFArrayTypeID']) is int and raw['CFArrayTypeID'] > 0
            and type(raw['AXUIElementTypeID']) is int and raw['AXUIElementTypeID'] > 0
            and raw['CFArrayTypeID'] != raw['AXUIElementTypeID'], 'Actual native type identifiers are absent')
    for key in ('applicationStatuses', 'applicationStatusesAfter'):
        require(all(type(raw[key].get(name)) is int and raw[key][name] == 0 for name in ('pid', 'AXWindows')),
                'Unknown AX application window inventory')
    for key in ('windows', 'windowsAfter'):
        require(raw[key] and sum(same_frame(known_window(node, pid), frame) for node in raw[key]) == 1,
                'Actual AX target window is missing or ambiguous')
    nodes = raw['nodes']
    require(nodes and nodes[0]['parent'] is None and same_frame(known_window(nodes[0], pid), frame),
            'Raw traversal does not start at the actual target window')
    leaves = {'AXButton', 'AXCheckBox', 'AXRadioButton', 'AXStaticText', 'AXTextField', 'AXTextArea', 'AXImage',
              'AXSlider', 'AXProgressIndicator', 'AXScrollBar', 'AXPopUpButton'}
    buttons = []
    for index, node in enumerate(nodes):
        require(node['pid'] == pid and all(type(node['statuses'].get(key)) is int and node['statuses'][key] == 0
                for key in ('pid', 'AXRole')),
                'Foreign or unreadable raw element')
        names = node['attributeNames']
        require(type(node['statuses'].get('attributeNames')) is int and node['statuses']['attributeNames'] == 0 and isinstance(names, list)
                and node['attributeNamesType'] == raw['CFArrayTypeID'] and 'AXRole' in names
                and all(isinstance(name, str) for name in names) and len(names) == len(set(names)) <= 256,
                'Supported attribute names were not read completely')
        if index:
            require(type(node['parent']) is int and 0 <= node['parent'] < index, 'Raw node ancestry escapes the target window')
        children = [other for other in nodes if other['parent'] == index]
        status = node['statuses'].get('AXChildren')
        require(type(status) is int, 'Actual child response status is absent')
        require(node['advertised:AXChildren'] is ('AXChildren' in names), 'Child advertisement changed')
        if status == 0:
            count = node['count:AXChildren']
            require(type(count) is int and count == len(children) == len(node['childTypes:AXChildren'])
                    and node['type:AXChildren'] == raw['CFArrayTypeID']
                    and all(kind == raw['AXUIElementTypeID'] for kind in node['childTypes:AXChildren']),
                    'Raw child types, count or traversal coverage changed')
        else:
            require(status in (-25205, -25212) and node['AXRole'] in leaves and not children
                    and node['type:AXChildren'] is None and node['count:AXChildren'] is None,
                    'A failed child message cannot become an empty or complete branch')
        if node['AXRole'] == 'AXButton':
            rectangle(node_frame(node))
            require(node['statuses'].get('AXPosition') == node['statuses'].get('AXSize') == 0,
                    'Raw button frame is unknown')
            buttons.append(node)
    require(buttons, 'No bound native button attributes were observed')
    warm = result['originalQueryAfterCGStability']
    if (warm.get('failure') or '').startswith('AX-read-AXChildren:') and warm.get('nodes'):
        failed = warm['nodes'][-1]
        matches = [node for node in nodes if node['AXRole'] == failed['role'] and node['pid'] == failed['pid']
                   and same_frame(node_frame(node), failed['publicScreenFrame'])]
        require(len(matches) == 1, 'The actual failing query node is not uniquely bound in the target subtree')
    if mode.startswith('slow-'):
        slow = result['slowObservation']
        require(slow['status'] in ('observed-after-complete-warmup', 'not-reached-warmup-unqualified', 'not-reached-getter-entry'),
                'Slow fixture must record its actual warmup boundary')
        require(slow['status'] != 'observed-after-complete-warmup'
                or warm['truncated'] is False and warm.get('failure') is None and slow['enabledUndoCount'] == 1
                and slow['getterEntered'] is True,
                'Slow getter observation cannot bypass an incomplete original warmup')
        if slow['status'] == 'observed-after-complete-warmup':
            enabled = [node for node in warm['nodes'] if node['pid'] == pid and node['role'] == 'AXButton'
                and node['enabled'] is True and 'Undo' in (node['title'], node['label'])
                and all(node['statuses'].get(key) == 0 for key in ('pid', 'AXRole', 'AXEnabled', 'AXPosition', 'AXSize'))]
            require(len(enabled) == 1 and rectangle(enabled[0]['publicScreenFrame'], positive=True)
                    and warm['windowCandidates'] == 1, 'Actual warmup did not qualify one enabled Undo button')
            cg_binding(result['beforeWarmQuery'], pid, window, warm['expectedWindowFrame'])
            cg_binding(result['afterWarmQuery'], pid, window, warm['expectedWindowFrame'])


def validate_slow_normal(result, mode, pid):
    validate_observation(result, mode, pid)
    require(mode in CRASH_MODES, 'Only the two failed Slow cases can replace a crash capture')
    slow, warm = result['slowObservation'], result['originalQueryAfterCGStability']
    require(slow['status'] == 'observed-after-complete-warmup' and slow['getterEntered'] is True
            and warm['truncated'] is False and warm['failure'] is None
            and type(slow['enabledUndoCount']) is int and slow['enabledUndoCount'] == 1,
            'A getter or warmup that was not reached cannot replace crash evidence')
    query = slow['query']
    fields = [slow['enteredAt'], slow['returnedAt'], query['startedUptime'], query['finishedUptime']]
    require(all(type(value) in (int, float) and math.isfinite(value) and value > 0 for value in fields),
            'Actual getter and query timestamps are required')
    entered, returned, started, finished = fields
    require(type(slow['requestedSeconds']) in (int, float) and math.isfinite(slow['requestedSeconds']),
            'The actual query deadline is missing')
    require(started <= entered < returned and started <= finished < returned and query['truncated'] is True
            and query['windowCandidates'] == 1 and query['pid'] == pid and query['window'] == warm['window']
            and query['readOnMainThread'] is False, 'Original Slow timing or owned window assertion failed')
    if mode == 'slow-cancel':
        cancel = slow['cancelRequestedAt']
        require(type(cancel) in (int, float) and math.isfinite(cancel) and entered <= cancel <= finished
                and query['failure'] == 'cancelled' and slow['requestedSeconds'] == 1,
                'Actual cancellation during the last child message was not proven')
    else:
        require(slow['requestedSeconds'] == 0.2 and type(slow['cancelRequestedAt']) in (int, float)
                and slow['cancelRequestedAt'] == 0 and query['failure'],
                'The timeout case must use its original deadline without cancellation')
        children = [node for node in query['nodes'] if node['label'] == 'Bounded child']
        require(children and type(children[-1]['statuses'].get('AXChildren')) is int
                and children[-1]['statuses']['AXChildren'] != 0
                and type(children[-1]['statuses'].get('timeout:AXChildren')) is int
                and children[-1]['statuses']['timeout:AXChildren'] == 0,
                'The actual final child message did not record its remaining timeout')


def instant(value):
    require(isinstance(value, str), 'Crash timestamps must be explicit strings')
    result = datetime.datetime.fromisoformat(value.replace('Z', '+00:00'))
    require(result.tzinfo is not None, 'Crash timestamps need an explicit timezone')
    return result


def decode_crash(raw):
    text = raw.decode('utf-8')
    decoder = json.JSONDecoder()
    metadata, position = decoder.raw_decode(text.lstrip())
    rest = text.lstrip()[position:].lstrip()
    report, position = decoder.raw_decode(rest)
    require(not rest[position:].strip() and isinstance(metadata, dict) and isinstance(report, dict),
            'A crash report must contain exactly the two documented IPS JSON objects')
    return metadata, report


def owned_crash_identity(report, process):
    binary = Path(process['command'][0])
    require(type(report['pid']) is int and report['pid'] == process['pid'] and report['procName'] == binary.name
            and isinstance(report['procPath'], str) and tuple(Path(report['procPath']).parts[-2:]) == tuple(binary.parts[-2:]),
            'Crash report belongs to another process or executable')
    start, end = instant(process['startedWall']), instant(process['finishedWall'])
    launch, capture = instant(report['procLaunch']), instant(report['captureTime'])
    slack = datetime.timedelta(seconds=2)
    require(start <= end and start - slack <= launch <= capture <= end + slack and launch <= end,
            'Crash report is stale or outside the owned process lifetime')


def validate_crash(raw, process, executable_sha):
    metadata, report = decode_crash(raw)
    require(metadata.get('bug_type') == '309', 'IPS metadata does not identify a crash report')
    owned_crash_identity(report, process)
    require(process['exitCode'] == -signal.SIGTRAP and process['processReaped'] is True and process['timedOut'] is False
            and process['executableSHA256'] == executable_sha and re.fullmatch('[a-f0-9]{64}', executable_sha),
            'The owned process or executable differs from the captured crash')
    require(report['exception']['signal'] == 'SIGTRAP' and report['exception']['type'] == 'EXC_BREAKPOINT',
            'Crash report does not describe the actual Slow SIGTRAP')
    threads, fault = report['threads'], report['faultingThread']
    require(isinstance(threads, list) and type(fault) is int and 0 <= fault < len(threads), 'Faulting thread is unknown')
    frames = threads[fault]['frames']
    images = report['usedImages']
    require(isinstance(frames, list) and frames and isinstance(images, list) and images
            and all(isinstance(frame, dict) and type(frame.get('imageIndex')) is int
                    and 0 <= frame['imageIndex'] < len(images) and type(frame.get('imageOffset')) is int
                    and frame['imageOffset'] >= 0 for frame in frames), 'The actual faulting stack is missing or unusable')
    resolved = []
    for frame in frames:
        image = images[frame['imageIndex']]
        require(isinstance(image, dict), 'A faulting frame refers to an unknown binary image')
        base, size, image_uuid = image.get('base'), image.get('size'), image.get('uuid')
        locator = image.get('path') or image.get('name')
        require(type(base) is int and 0 < base < 2 ** 64 and type(size) is int and size > 0
                and base + size <= 2 ** 64 and frame['imageOffset'] < size
                and isinstance(image_uuid, str) and re.fullmatch(r'[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}', image_uuid)
                and int(image_uuid.replace('-', ''), 16) != 0
                and isinstance(locator, str) and locator.strip() and locator not in ('???', '<unknown>'),
                'A faulting frame lacks an addressable image, build UUID or symbolication identity')
        resolved.append({'imageIndex': frame['imageIndex'], 'imageUUID': image_uuid,
                         'image': locator, 'runtimeAddress': base + frame['imageOffset'], 'imageOffset': frame['imageOffset']})
    return {'pid': report['pid'], 'procName': report['procName'], 'procLaunch': report['procLaunch'],
            'captureTime': report['captureTime'], 'exception': report['exception'], 'faultingThread': fault,
            'faultingFrames': frames, 'resolvedFaultingFrames': resolved, 'usedImages': images,
            'metadata': metadata, 'SHA256': digest(raw)}


def validate_breadcrumbs(path, process, mode):
    records = [json.loads(line) for line in path.read_bytes().split(b'\n') if line]
    require(records and records[0]['stage'] == 'observe-entered', 'Owned process startup breadcrumb is absent')
    previous = 0
    for record in records:
        require(record['schema'] == 'nexgenvideo/button-query-stage/1' and record['pid'] == process['pid']
                and record['mode'] == mode and record['mainThread'] is True
                and type(record['uptime']) in (int, float) and math.isfinite(record['uptime'])
                and record['uptime'] >= previous and isinstance(record['stage'], str), 'Stage identity or ordering differs')
        previous = record['uptime']
    return {'file': path.name, 'SHA256': digest(path.read_bytes()), 'records': records}


def collect_crash_reports(evidence, process, executable_sha, seconds=10):
    binary = Path(process['command'][0])
    roots = (Path.home() / 'Library/Logs/DiagnosticReports', Path('/Library/Logs/DiagnosticReports'))
    deadline, seen, candidates, qualified = time.monotonic() + seconds, set(), [], []
    while True:
        for root in roots:
            if not root.is_dir():
                continue
            for path in sorted(root.glob(binary.name + '*.ips')):
                if path.is_symlink() or not path.is_file() or path.stat().st_mtime < instant(process['startedWall']).timestamp() - 2:
                    continue
                require(path.stat().st_size <= 8 * 1024 * 1024, 'Owned crash candidate exceeds the evidence budget')
                raw = path.read_bytes()
                key = (str(path), digest(raw))
                if key in seen:
                    continue
                seen.add(key)
                require(len(seen) <= 32, 'Too many owned-name crash candidates')
                try:
                    _, candidate = decode_crash(raw)
                except (ValueError, TypeError, UnicodeError):
                    candidate = None
                if candidate is not None:
                    try:
                        owned_crash_identity(candidate, process)
                    except (ValueError, KeyError, TypeError, IndexError) as error:
                        candidates.append({'SHA256': digest(raw), 'qualified': False, 'excludedIdentity': str(error)})
                        continue
                target = evidence / f"{process['pid']}-crash-candidate-{len(seen)}.ips"
                target.write_bytes(raw)
                entry = {'file': target.name, 'SHA256': digest(raw), 'qualified': False}
                try:
                    entry['identity'] = validate_crash(raw, process, executable_sha)
                    entry['qualified'] = True
                    qualified.append(entry)
                except (ValueError, KeyError, TypeError, IndexError, UnicodeError) as error:
                    entry['error'] = str(error)
                candidates.append(entry)
        if qualified or time.monotonic() >= deadline:
            break
        time.sleep(0.2)
    record = {'pid': process['pid'], 'candidates': candidates, 'qualifiedCount': len(qualified)}
    write(evidence / f"{process['pid']}-crash-acquisition.json", record)
    require(len(qualified) == 1, 'No unique fresh owned SIGTRAP report with a complete faulting stack was captured')
    return qualified[0]


def observe(args):
    args.evidence.mkdir(parents=True, exist_ok=False)
    binding = json.loads((args.binding / 'binding.json').read_text())
    crashes = getattr(args, 'capture_crashes', False)
    require(binding['schema'] == ('nexgenvideo/button-query-crash-binding/1' if crashes else 'nexgenvideo/button-query-binding/1')
            and binding.get('diagnosticMode', 'native-button-query') == (CRASH_KIND if crashes else 'native-button-query'),
            'Diagnostic mode and transferred binding differ')
    require(binding['sourceSHA'] == os.environ['GITHUB_SHA'] and binding['runID'] == os.environ['GITHUB_RUN_ID']
            and binding['attempt'] == os.environ['GITHUB_RUN_ATTEMPT'] == '1', 'Transferred binding belongs to another execution')
    require(git('rev-parse', 'HEAD').decode().strip() == os.environ['GITHUB_SHA']
            and git('rev-parse', 'HEAD^{tree}').decode().strip() == binding['sourceTree']
            and not git('status', '--porcelain', '--untracked-files=no').strip()
            and set(binding['harnessFiles']) == HARNESS
            and all(digest((ROOT / path).read_bytes()) == value for path, value in binding['harnessFiles'].items()),
            'Actual diagnostic harness bytes changed')
    original = args.binding / 'original-evidence.zip'
    require(digest(original.read_bytes()) == binding['originalArtifact']['digest'].removeprefix('sha256:')
            and failure_archive(original) == binding['originalEvidence'], 'Original failure bytes changed after source validation')
    originals = {path: git('show', SOURCE + ':' + path) for path in FILES}
    require(all(digest(raw) == binding['sourceFiles'][path]['SHA256'] and (ROOT / path).read_bytes() == raw
                for path, raw in originals.items()), 'Actual framework source bytes changed')
    if crashes:
        prior = binding['priorCrashes']
        for filename, artifact in zip(('prior-observations.zip', 'prior-source-binding.zip'), prior['artifacts'], strict=True):
            require(digest((args.binding / filename).read_bytes()) == artifact['digest'].removeprefix('sha256:'),
                    'Prior crash archive changed after the source gate')
        verified = verify_crash_payload(zip_members(args.binding / 'prior-observations.zip'),
                                        zip_members(args.binding / 'prior-source-binding.zip'), binding['sourceFiles'], original.read_bytes())
        require(all(prior[key] == value for key, value in verified.items()), 'Prior crash qualification changed after transfer')
    toolchain = binding['originalEvidence']['toolchain']
    require(subprocess.check_output(['uname', '-m'], text=True).strip() == 'arm64', 'Unexpected framework architecture')
    commands = {'xcode': ['xcodebuild', '-version'], 'osVersion': ['sw_vers', '-productVersion'],
                'osBuild': ['sw_vers', '-buildVersion'], 'swift': ['swift', '--version']}
    actual = {key: subprocess.check_output(command, text=True, stdin=subprocess.DEVNULL, timeout=20).strip()
              for key, command in commands.items()}
    write(args.evidence / 'toolchain.json', {'actual': actual, 'original': toolchain})
    require(all(actual[key] == toolchain[key] for key in commands), 'Framework toolchain differs from original failure')
    sources = args.evidence / 'sources'; sources.mkdir()
    selected, ranges = source_subset(originals)
    for name, raw in selected.items(): (sources / name).write_bytes(raw)
    write(args.evidence / 'source-subsets.json', {'originals': binding['sourceFiles'],
        'subsets': {name: {'SHA256': digest(raw), 'bytes': len(raw), 'originalByteRanges': ranges[name]} for name, raw in selected.items()},
        'omissions': ['unreferenced ClipType color extension', 'unreferenced ProjectInterface', 'unreferenced EditorViewModel extension and Engine import'],
        'context': 'Isolated NSApplication with exact active CapsuleStyle definitions; not the parallel full AppKit test host.'})
    if crashes:
        owned = args.evidence / f"owned-{os.environ['GITHUB_RUN_ID']}-a1"
        owned.mkdir()
        binary = owned / f"nbq{int(os.environ['GITHUB_RUN_ID']) % 10_000_000_000:010d}"
    else:
        binary = args.evidence / 'button-query-probe'
    owned_command(['xcrun', 'swiftc', '-swift-version', '6', *(['-g'] if crashes else []), '-parse-as-library', '-target', 'arm64-apple-macos26.0',
        *[str(sources / name) for name in selected], str(ROOT / 'scripts/button_query_diagnostic.swift'), '-o', str(binary)],
        args.evidence / 'compiler.log', 90)
    executable_sha = digest(binary.read_bytes())
    pids, results = [], []
    modes = CRASH_MODES if crashes else MODES
    for mode in modes:
        target = args.evidence / (mode + '.json')
        log = args.evidence / (mode + '.log')
        outcome = {'mode': mode, 'status': 'failed-observation'}
        breadcrumbs = args.evidence / (mode + '.stages.jsonl')
        program = binary
        if crashes:
            program = binary.with_name(binary.name + ('c' if mode == 'slow-cancel' else 't'))
            shutil.copyfile(binary, program)
            program.chmod(binary.stat().st_mode & 0o777)
        try:
            pid = owned_command([str(program), mode, str(target), *(['--breadcrumbs', str(breadcrumbs)] if crashes else [])], log, 18)
            result = json.loads(target.read_text())
            (validate_slow_normal if crashes else validate_observation)(result, mode, pid)
            outcome.update(status='observed', file=target.name, SHA256=digest(target.read_bytes()))
        except (ValueError, OSError, KeyError, TypeError, IndexError) as error:
            outcome['error'] = str(error)
            if target.exists(): outcome.update(file=target.name, SHA256=digest(target.read_bytes()))
        process = json.loads(log.with_suffix('.process.json').read_text())
        require(process['processReaped'] is True and process['pid'] > 0, 'Owned framework process is not reaped')
        if crashes:
            errors = []
            try:
                require(process['executableSHA256'] == executable_sha and digest(binary.read_bytes()) == executable_sha,
                        'Owned diagnostic executable changed during observation')
            except (ValueError, OSError) as error:
                errors.append(str(error))
            try:
                outcome['stages'] = validate_breadcrumbs(breadcrumbs, process, mode)
            except (ValueError, OSError, KeyError, TypeError, IndexError) as error:
                errors.append(str(error))
            if process['exitCode'] < 0:
                try:
                    outcome['crash'] = collect_crash_reports(args.evidence, process, executable_sha)
                    if not errors:
                        outcome['status'] = 'captured-crash'
                except (ValueError, OSError, KeyError, TypeError, IndexError) as error:
                    errors.append(str(error))
            if errors:
                outcome.update(status='failed-observation', evidenceErrors=errors)
        pids.append(process['pid']); outcome['process'] = process
        results.append(outcome)
    require(len(set(pids)) == len(modes), 'Framework controls did not execute in fresh processes')
    complete = all(result['status'] in ('observed', 'captured-crash') for result in results)
    write(args.evidence / 'receipt.json', {'schema': 'nexgenvideo/button-query-crash-observation/1' if crashes else 'nexgenvideo/button-query-observation/1',
        'sourceSHA': os.environ['GITHUB_SHA'], 'runID': os.environ['GITHUB_RUN_ID'], 'attempt': os.environ['GITHUB_RUN_ATTEMPT'],
        'bindingSHA256': digest((args.binding / 'binding.json').read_bytes()), 'results': results,
        'measurementComplete': complete,
        'appAcceptance': False, 'appBuilds': 0, 'nativeUnitExecutions': 0, 'originalFailureResolved': False})
    require(complete, 'Framework observations incomplete; all actual outputs retained')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('action', choices=('bind', 'observe'))
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--source-proof', type=Path)
    parser.add_argument('--binding', type=Path)
    parser.add_argument('--capture-crashes', action='store_true')
    args = parser.parse_args()
    if args.capture_crashes and args.action != 'observe':
        parser.error('--capture-crashes applies only to native observation')
    bind(args) if args.action == 'bind' else observe(args)
