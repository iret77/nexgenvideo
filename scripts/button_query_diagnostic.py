"""Bind one failed native query and observe its unchanged framework source subset."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
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
    require(env['KIND'] == 'native-button-query', 'Incorrect button query diagnostic mode')
    for key in ('CANDIDATE_RUN', 'CANDIDATE_ARTIFACT', 'VERIFIED_PR'):
        require(re.fullmatch('[1-9][0-9]*', env[key]), 'Positive original producer and current Source IDs required')
    require(env['CANDIDATE_SOURCE'] == SOURCE and re.fullmatch('[a-f0-9]{64}', env['CANDIDATE_DIGEST']),
            'Exact failed query source and artifact digest required')
    require(env['SCALE'] == '1' and not any(env.get(key, '') for key in (
        'DMG_DIGEST', 'JOURNEY_JOB', 'JOURNEY_ARTIFACT', 'JOURNEY_DIGEST', 'EXTRA_SOURCE', 'EXTRA_PRODUCTS',
        'EXTRA_FAILURE', 'EXTRA_PRODUCTS_SHA', 'EXTRA_FAILURE_SHA', 'RUNTIME_FAILURE_BINDING',
        'PACKAGING_PRODUCER_SOURCE', 'PACKAGING_PROVENANCE_ARTIFACT_ID', 'PACKAGING_PROVENANCE_ARTIFACT_SHA256')),
        'Unconsumed diagnostic selectors cannot be ignored')


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
    write(args.evidence / 'binding.json', {'schema': 'nexgenvideo/button-query-binding/1',
        'sourceSHA': env['GITHUB_SHA'], 'sourceTree': git('rev-parse', 'HEAD^{tree}').decode().strip(),
        'runID': env['GITHUB_RUN_ID'], 'attempt': env['GITHUB_RUN_ATTEMPT'],
        'originalRun': run, 'originalJob': job, 'originalArtifact': artifact, 'originalEvidence': observed,
        'sourceProof': proof, 'sourceFiles': {path: {'SHA256': digest(raw), 'gitBlob': git('rev-parse', SOURCE + ':' + path).decode().strip()}
            for path, raw in originals.items()}, 'harnessFiles': {path: digest((ROOT / path).read_bytes()) for path in sorted(HARNESS)},
        'appAcceptance': False, 'appBuilds': 0, 'nativeUnitExecutions': 0})


def owned_command(command, log, timeout):
    timed_out = False
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


def observe(args):
    args.evidence.mkdir(parents=True, exist_ok=False)
    binding = json.loads((args.binding / 'binding.json').read_text())
    require(binding['sourceSHA'] == os.environ['GITHUB_SHA'] and binding['runID'] == os.environ['GITHUB_RUN_ID']
            and binding['attempt'] == os.environ['GITHUB_RUN_ATTEMPT'] == '1', 'Transferred binding belongs to another execution')
    require(git('rev-parse', 'HEAD').decode().strip() == os.environ['GITHUB_SHA']
            and git('rev-parse', 'HEAD^{tree}').decode().strip() == binding['sourceTree']
            and not git('status', '--porcelain', '--untracked-files=no').strip()
            and all(digest((ROOT / path).read_bytes()) == value for path, value in binding['harnessFiles'].items()),
            'Actual diagnostic harness bytes changed')
    original = args.binding / 'original-evidence.zip'
    require(digest(original.read_bytes()) == binding['originalArtifact']['digest'].removeprefix('sha256:')
            and failure_archive(original) == binding['originalEvidence'], 'Original failure bytes changed after source validation')
    originals = {path: git('show', SOURCE + ':' + path) for path in FILES}
    require(all(digest(raw) == binding['sourceFiles'][path]['SHA256'] and (ROOT / path).read_bytes() == raw
                for path, raw in originals.items()), 'Actual framework source bytes changed')
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
    binary = args.evidence / 'button-query-probe'
    owned_command(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', '-target', 'arm64-apple-macos26.0',
        *[str(sources / name) for name in selected], str(ROOT / 'scripts/button_query_diagnostic.swift'), '-o', str(binary)],
        args.evidence / 'compiler.log', 90)
    pids, results = [], []
    for mode in MODES:
        target = args.evidence / (mode + '.json')
        log = args.evidence / (mode + '.log')
        outcome = {'mode': mode, 'status': 'failed-observation'}
        try:
            pid = owned_command([str(binary), mode, str(target)], log, 18)
            result = json.loads(target.read_text())
            validate_observation(result, mode, pid)
            outcome.update(status='observed', file=target.name, SHA256=digest(target.read_bytes()))
        except (ValueError, OSError, KeyError, TypeError, IndexError) as error:
            outcome['error'] = str(error)
            if target.exists(): outcome.update(file=target.name, SHA256=digest(target.read_bytes()))
        process = json.loads(log.with_suffix('.process.json').read_text())
        require(process['processReaped'] is True and process['pid'] > 0, 'Owned framework process is not reaped')
        pids.append(process['pid']); outcome['process'] = process
        results.append(outcome)
    require(len(set(pids)) == len(MODES), 'Framework controls did not execute in fresh processes')
    write(args.evidence / 'receipt.json', {'schema': 'nexgenvideo/button-query-observation/1',
        'sourceSHA': os.environ['GITHUB_SHA'], 'runID': os.environ['GITHUB_RUN_ID'], 'attempt': os.environ['GITHUB_RUN_ATTEMPT'],
        'bindingSHA256': digest((args.binding / 'binding.json').read_bytes()), 'results': results,
        'measurementComplete': all(result['status'] == 'observed' for result in results),
        'appAcceptance': False, 'appBuilds': 0, 'nativeUnitExecutions': 0, 'originalFailureResolved': False})
    require(all(result['status'] == 'observed' for result in results), 'Framework observations incomplete; all actual outputs retained')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('action', choices=('bind', 'observe'))
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--source-proof', type=Path)
    parser.add_argument('--binding', type=Path)
    args = parser.parse_args()
    bind(args) if args.action == 'bind' else observe(args)
