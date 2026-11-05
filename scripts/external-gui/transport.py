"""Verify public transport cursor actions using an unchanged completed-journey project."""
import argparse
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

import acceptance as journey


TEST = 'NexGenVideoExternalUITests/UserJourneyTests/testTimelineTransportThroughInstalledApp'
SURFACES = ('maximized-timeline-preview', 'theater-timeline')
PROJECT_FILES = {'project.json', 'media.json', 'ngv.json'}


def require(condition, message):
    journey.require(condition, message)


def project_files(root):
    return {name: journey.sha256(root / name) for name in sorted(PROJECT_FILES)}


def fixture_identity(project, source, expected):
    require(expected.get('schema') in {'nexgenvideo/transport-fixture/1', 'nexgenvideo/transport-fixture/2'}, 'Missing completed journey fixture binding')
    if expected['schema'] == 'nexgenvideo/transport-fixture/2':
        record = journey.retained_packaging.consumer_record(expected.get('packaging'), expected['sourceSHA'], expected['journeyRunID'])
        require(expected.get('journeyProducerSourceSHA') == record['producerSourceSHA']
                and expected.get('dmgSHA256') == record['final']['dmgSHA256']
                and expected.get('appTreeSHA256') == record['final']['appTreeSHA256'], 'Transport fixture lost canonical packaging identity')
    else:
        require('packaging' not in expected and 'journeyProducerSourceSHA' not in expected,
                'Packaging fixture requires its explicit schema')
    require(project.is_dir() and not project.is_symlink(), 'Expected a real unchanged project directory')
    require(project_files(project) == expected.get('projectFiles')
            and journey.tree_sha256(project) == expected.get('projectTreeSHA256'), 'Transport project bytes changed')
    require(source.is_file() and source.resolve(strict=True).is_relative_to(project.resolve(strict=True))
            and journey.sha256(source) == expected.get('sourceSHA256'), 'Transport source is not the original project-local media')
    timeline = journey.read_json(project / 'project.json')
    clips = journey.clips(timeline)
    require(len(clips) == 1 and timeline.get('fps') == 30
            and timeline.get('width') == 320 and timeline.get('height') == 180, 'Unexpected transport project format')
    clip = clips[0]
    require(clip.get('startFrame') == 0 and clip.get('durationFrames') == 120
            and clip.get('trimStartFrame', 0) == 0 and clip.get('trimEndFrame', 0) == 0
            and clip.get('speed', 1) == 1 and not timeline.get('markers'), 'Transport project has a different endpoint')
    declaration = journey.read_json(project / 'ngv.json')
    require(all(declaration.get(key) is None for key in ('activePlugin', 'activePluginVersion', 'activePluginProjectSchema')),
            'The public transport fixture must remain a generic project')
    require(expected.get('fps') == 30 and expected.get('endFrame') == 120 and expected.get('sourceFrames') == 120,
            'Transport oracle is not the predeclared 120-frame fixture')
    return expected


def project_observation(project, fixture):
    return {'projectTreeSHA256': journey.tree_sha256(project),
            'sourceSHA256': journey.sha256(project / fixture['sourceRelativePath']),
            'projectFiles': project_files(project)}


def verify_working_project(project, fixture, before, after):
    expected = {key: fixture[key] for key in ('projectTreeSHA256', 'sourceSHA256', 'projectFiles')}
    require(before == expected and after == expected, 'Transport changed the complete working project or source bytes')
    fixture_identity(project, project / fixture['sourceRelativePath'], fixture)
    require(project_observation(project, fixture) == after, 'Working project differs from its retained after observation')


def rectangle(value):
    require(type(value) is list and len(value) == 4
            and all(type(n) in (int, float) and math.isfinite(n) for n in value)
            and value[2] > 0 and value[3] > 0, 'Missing finite public element rectangle')
    return value


def timecodes(value):
    if not isinstance(value, str):
        return None
    parts = [part.strip() for part in value.split('/')]
    if not 1 <= len(parts) <= 2:
        return None
    frames = []
    for part in parts:
        if not re.fullmatch(r'[0-9]{2}:[0-9]{2}:[0-9]{2}:[0-9]{2}', part):
            return None
        h, m, s, f = map(int, part.split(':'))
        if m >= 60 or s >= 60 or f >= 30:
            return None
        frames.append(((h * 60 + m) * 60 + s) * 30 + f)
    return frames


def cursor(record, *, stable=False):
    require(record.get('role') == 'left-current-cursor', 'Duration text cannot stand in for the cursor')
    candidates = record.get('candidates')
    require(type(candidates) is list and 1 <= len(candidates) <= 2, 'Cursor field is ambiguous')
    start = rectangle(record['startControl']['frame'])
    require(record['startControl'].get('label') == 'Go to Start'
            and record['startControl'].get('enabled') is True and record['startControl'].get('hittable') is True,
            'Public cursor anchor is not the visible Start control')
    previous = None
    decoded = []
    for candidate in candidates:
        element = candidate['element']
        frame = rectangle(element['frame'])
        require(element.get('hittable') is True and frame[0] + frame[2] <= start[0]
                and abs(frame[1] + frame[3] / 2 - start[1] - start[3] / 2) <= max(frame[3], start[3]) / 2,
                'Cursor field is outside the public transport layout')
        require(previous is None or previous[0] + previous[2] <= frame[0], 'Cursor and duration fields overlap')
        values = [timecodes(element.get(name)) for name in ('label', 'value')]
        values = [value for value in values if value is not None]
        require(values and all(value == values[0] for value in values)
                and candidate.get('tokens') == values[0], 'Public cursor text and recorded tokens differ')
        decoded.append(values[0]); previous = frame
    require(record.get('field') == candidates[0]['element'], 'Cursor role changed after value selection')
    require(decoded[0] in ([decoded[0][0]], [decoded[0][0], 120]), 'Combined cursor has another duration')
    if len(decoded) == 2:
        require(len(decoded[0]) == 1 and decoded[1] == [120], 'Independent duration field is incorrect')
    require(type(record.get('frame')) is int and record['frame'] == decoded[0][0], 'Cursor frame was not decoded from its public field')
    if stable:
        require(type(record.get('observations')) is int and record['observations'] >= 2
                and type(record.get('stableSeconds')) in (int, float)
                and math.isfinite(record['stableSeconds']) and record['stableSeconds'] >= .5, 'Cursor never became stably observable')
    return record['frame']


def verify_capture(evidence, record):
    for kind in ('screenshot', 'accessibility'):
        name = record[kind]
        require(isinstance(name, str) and Path(name).name == name, 'Capture escaped its evidence root')
        path = evidence / name
        require(path.is_file() and not path.is_symlink() and journey.sha256(path) == record[kind + 'SHA256'], 'Public capture bytes changed')
        if kind == 'screenshot':
            require(path.read_bytes().startswith(b'\x89PNG\r\n\x1a\n'), 'Missing actual public screenshot')
        else:
            require('Application' in path.read_text(), 'Missing public XCTest accessibility tree')


def contains_frame(outer, inner):
    outer = rectangle(outer); inner = rectangle(inner)
    return outer[0] <= inner[0] and outer[1] <= inner[1] and inner[0] + inner[2] <= outer[0] + outer[2] and inner[1] + inner[3] <= outer[1] + outer[3]


def geometry_selection(observation, *, viewport_path=None):
    rows = observation.get('nodes')
    require(type(rows) is list and 1 < len(rows) <= 3000, 'Missing bounded public hierarchy')
    nodes = {row['path']: row for row in rows}
    require(len(nodes) == len(rows) and nodes.get('w', {}).get('type') == 'window', 'Duplicate or absent document root')
    for path, row in nodes.items():
        require(re.fullmatch(r'w(?:/[0-9]+){0,40}', path) is not None, 'Invalid public hierarchy path')
        parent = None if path == 'w' else path.rsplit('/', 1)[0]
        require(row.get('parent') == parent and (parent is None or parent in nodes), 'Public parent relation differs')
    window = nodes['w']; window_frame = rectangle(window['frame'])
    require(window.get('title') == 'NexGenVideo — External GUI', 'Geometry came from another document')
    def below(path, ancestor):
        return path.startswith(ancestor + '/')
    def exposed(kind, predicate):
        return [row for row in rows if row.get('type') == kind and predicate(row.get('label', ''))
                and row.get('hittable') is True]
    def unique(kind, predicate):
        found = exposed(kind, predicate)
        require(len(found) == 1 and found[0].get('enabled') is True, 'Public semantic anchor is absent, disabled or ambiguous')
        require(contains_frame(window_frame, found[0]['frame']), 'Public anchor escaped the document')
        return found[0]
    header = unique('staticText', lambda label: label == 'Film Preview')
    start = unique('button', lambda label: label == 'Go to Start')
    end = unique('button', lambda label: label == 'Go to End')
    title = unique('staticText', lambda label: label == 'Project External GUI')
    budget = unique('button', lambda label: label == 'Budget' or label.startswith('Budget ·'))
    anchors = [header, start, end]
    candidates = [row for row in rows if all(below(anchor['path'], row['path']) for anchor in anchors)]
    minimal = [row for row in candidates if not any(below(other['path'], row['path']) for other in candidates)]
    require(len(minimal) == 1 and minimal[0]['path'] != 'w', 'No unique minimal public preview container')
    preview = minimal[0]
    require(observation.get('selectedPreviewPath') == preview['path'], 'Client selected another common container')
    peers = [exposed('button', lambda label: label == value) for value in ('Assets', 'Pointer (V)')]
    if viewport_path is None:
        require(all(len(found) == 1 and found[0].get('enabled') is True for found in peers), 'Normal layout lacks two distinct peer panes')
        all_anchors = anchors + [found[0] for found in peers]
        splits = [row for row in rows if row.get('type') == 'splitGroup'
                  and all(below(anchor['path'], row['path']) for anchor in all_anchors)]
        outermost = [row for row in splits if not any(below(row['path'], other['path']) for other in splits)]
        require(len(outermost) == 1, 'No unique independent outer editor split')
        viewport_path = outermost[0]['path']
    viewport = nodes.get(viewport_path)
    require(viewport and viewport['type'] == 'splitGroup' and viewport_path != 'w', 'The independent editor root disappeared')
    require(preview['path'] != viewport_path and below(preview['path'], viewport_path), 'Preview is the editor root or whole window')
    require(not below(title['path'], viewport_path) and not below(budget['path'], viewport_path), 'Editor viewport includes title or status chrome')
    viewport_frame = rectangle(viewport['frame'])
    require(contains_frame(window_frame, viewport_frame) and contains_frame(viewport_frame, preview['frame']), 'Preview or viewport escaped its parent')
    require(title['frame'][1] + title['frame'][3] <= viewport_frame[1]
            and viewport_frame[1] + viewport_frame[3] <= budget['frame'][1], 'Editor root is not between title and footer')
    for anchor in anchors:
        require(contains_frame(preview['frame'], anchor['frame']), 'Preview anchors escaped their common container')
    for found in peers:
        require(all(contains_frame(viewport_frame, row['frame']) for row in found), 'A peer pane escaped the editor viewport')
        require(not any(below(row['path'], preview['path']) for row in found), 'Preview includes another visible pane')
    return {'window': window, 'viewport': viewport, 'preview': preview, 'title': title, 'budget': budget,
            'anchors': anchors, 'peers': peers}


def validate_geometry(evidence, record):
    geometry = journey.read_json(evidence / 'geometry.json')
    samples = journey.read_json(evidence / 'geometry-samples.json')
    require(geometry.get('schema') == 'nexgenvideo/public-preview-geometry/1'
            and samples.get('schema') == 'nexgenvideo/public-preview-geometry-samples/1', 'Missing actual public geometry observations')
    phases = geometry.get('phases')
    require(type(phases) is dict and set(phases) == {'before', 'maximized', 'restored'}, 'Missing measured maximize or restore transition')
    selected = {}; viewport_path = None; captures = set()
    for phase in ('before', 'maximized', 'restored'):
        pair = phases[phase]
        require(type(pair) is list and len(pair) == 2 and pair[0]['nodes'] == pair[1]['nodes'], 'Public hierarchy did not settle')
        require(all(type(obs.get('time')) in (int, float) and math.isfinite(obs['time']) for obs in pair)
                and pair[1]['time'] - pair[0]['time'] >= .5, 'Geometry lacks two temporally distinct observations')
        for obs in pair:
            require(obs.get('phase') == phase and obs in samples['samples'], 'Geometry sample was substituted')
            require(obs.get('modalCounts') == {'sheets': 0, 'alerts': 0, 'dialogs': 0}, 'A modal surface blocked public geometry')
            for kind in ('screenshot', 'accessibility'):
                require(obs['evidence'][kind] not in captures, 'Geometry reused a screenshot or AX capture')
                captures.add(obs['evidence'][kind])
            verify_capture(evidence, obs['evidence'])
        selected[phase] = geometry_selection(pair[0], viewport_path=viewport_path)
        viewport_path = selected['before']['viewport']['path']
    baseline, maximized, restored = (selected[phase] for phase in ('before', 'maximized', 'restored'))
    for phase in (maximized, restored):
        for key in ('window', 'viewport', 'title', 'budget'):
            require(all(phase[key][field] == baseline[key][field] for field in ('path', 'type', 'identifier', 'title', 'label', 'frame')),
                    'Maximize resized the window or replaced the independent editor/chrome')
    before = rectangle(baseline['preview']['frame']); after = rectangle(maximized['preview']['frame'])
    viewport = rectangle(baseline['viewport']['frame'])
    require(before[2] * before[3] <= .75 * viewport[2] * viewport[3], 'Baseline preview was already maximized')
    require(after[2] * after[3] >= 1.2 * before[2] * before[3]
            and after[2] >= .95 * viewport[2] and after[3] >= .95 * viewport[3], 'The actual preview did not maximize')
    insets = (after[0] - viewport[0], after[1] - viewport[1],
              viewport[0] + viewport[2] - after[0] - after[2], viewport[1] + viewport[3] - after[1] - after[3])
    require(all(0 <= gap <= .025 * viewport[axis] for gap, axis in zip(insets, (2, 3, 2, 3))), 'Maximized preview leaves a visible sibling-sized inset')
    require(all(not found for found in maximized['peers']), 'A previous peer pane remains hittable after maximize')
    require(restored['preview']['frame'] == before and all(len(found) == 1 for found in restored['peers']), 'Escape did not restore the measured normal layout')
    for normal, returned in zip(baseline['peers'], restored['peers']):
        require(all(normal[0][key] == returned[0][key] for key in ('path', 'frame', 'label')), 'Restore changed a peer pane')
    actions = record['actions']
    before_count = phases['before'][-1]['actionCount']; max_count = phases['maximized'][0]['actionCount']
    restore_count = phases['restored'][0]['actionCount']
    require(type(before_count) is int and type(max_count) is int and type(restore_count) is int
            and 0 < before_count < max_count < restore_count <= len(actions), 'Geometry action order is incomplete')
    require(actions[before_count - 1].get('target') == 'Default layout'
            and actions[max_count - 1].get('target') == 'Maximize Focused Panel'
            and any(action.get('target') == 'Film Preview focus' for action in actions[before_count:max_count])
            and actions[restore_count - 1].get('kind') == 'key' and actions[restore_count - 1].get('modifiers') == 0,
            'Public default/focus/maximize/restore actions are missing')
    require(all(type(action.get('time')) in (int, float) and math.isfinite(action['time']) for action in actions), 'Public actions lack timestamps')
    require(all(a['time'] <= b['time'] for a, b in zip(actions, actions[1:])), 'Public action timestamps are reversed')
    require(phases['before'][-1]['time'] <= actions[max_count - 1]['time'] <= phases['maximized'][0]['time']
            and phases['maximized'][-1]['time'] <= actions[restore_count - 1]['time'] <= phases['restored'][0]['time'],
            'Public maximize/restore actions do not precede their observed layouts')
    for row in record['stages']:
        if row.get('surface') == 'maximized-timeline-preview':
            require(max_count < row['actionCount'] < restore_count, 'Transport actions were outside the measured maximized state')
            anchor = maximized['anchors'][2 if row.get('targetFrame') == 120 else 1]
            require(row['control']['frame'] == anchor['frame']
                    and row['before']['startControl']['frame'] == maximized['anchors'][1]['frame']
                    and row['window']['frame'] == maximized['window']['frame'], 'Endpoint controls differ from the measured preview')
        else:
            require(row['actionCount'] > restore_count, 'Theater preceded normal-layout restoration')
    return selected


def validate_actions(evidence):
    record = journey.read_json(evidence / 'journey.json')
    require(record.get('schema') == 'nexgenvideo/external-transport/1', 'A normal journey is not a transport result')
    expected = [(surface, ordinal, target) for surface in SURFACES for ordinal, target in enumerate((0, 120, 0))]
    require(type(record.get('stages')) is list and len(record['stages']) == 6, 'All six native endpoint actions are required')
    validate_geometry(evidence, record)
    previous_count = 0
    captures = set()
    for row, (surface, ordinal, target) in zip(record['stages'], expected):
        require(row.get('stage') == surface + '-' + str(ordinal) and row.get('surface') == surface
                and row.get('endpointOrdinal') == ordinal and row.get('targetFrame') == target and row.get('paused') is True,
                'Transport scope, order or endpoint changed')
        before = cursor(row['before']); after = cursor(row['after'], stable=True)
        require(before != target and after == target and (ordinal != 0 or 0 < before < 120), 'Native endpoint action was a no-op or reached the wrong boundary')
        require(ordinal == 0 or before == (0 if ordinal == 1 else 120), 'Cursor changed between the declared endpoint actions')
        require(row['before']['startControl'] == row['after']['startControl'], 'Cursor layout anchor changed during an endpoint action')
        control = row['control']; rectangle(control['frame'])
        window = rectangle(row['window']['frame']); bounds = control['frame']
        require(window[0] <= bounds[0] and window[1] <= bounds[1]
                and bounds[0] + bounds[2] <= window[0] + window[2]
                and bounds[1] + bounds[3] <= window[1] + window[3], 'Endpoint control escaped the exact document window')
        label = 'Go to End' if target == 120 else 'Go to Start'
        require(control.get('label') == label and control.get('enabled') is True and control.get('hittable') is True,
                'The endpoint was not a visible enabled public control')
        count = row.get('actionCount'); actions = record.get('actions')
        require(type(count) is int and previous_count < count <= len(actions)
                and actions[count - 1].get('kind') == 'click' and actions[count - 1].get('target') == label,
                'The endpoint has no corresponding native pointer action')
        previous_count = count
        for proof in (row['beforeEvidence'], row['evidence']):
            for kind in ('screenshot', 'accessibility'):
                require(proof[kind] not in captures, 'An endpoint reused another action capture')
                captures.add(proof[kind])
            verify_capture(evidence, proof)
    return record


def run(args):
    import test_bundle
    from verify_diagnostic_candidate import SIGNED_TRANSPORT_HARNESS_PATHS

    require(os.environ.get('GITHUB_ACTIONS') == 'true' and os.environ.get('RUNNER_ENVIRONMENT') == 'self-hosted',
            'Run public transport acceptance only on macrunner in GitHub Actions')
    require(not any(name.startswith('NGV_') and any(term in name for term in ('ACCEPTANCE', 'SELFTEST', 'EXAMPLE')) for name in os.environ),
            'Internal acceptance flags must not reach the public client')
    original = Path(args.fixture).resolve(strict=True)
    require(re.fullmatch('[a-f0-9]{64}', args.fixture_sha256)
            and journey.sha256(original / 'fixture.json') == args.fixture_sha256, 'Completed fixture handoff changed')
    fixture = journey.read_json(original / 'fixture.json')
    packaging = journey.retained_packaging.file_binding(args)
    require(fixture.get('packaging') == packaging, 'Transport fixture and selected packaging provenance differ')
    require(fixture.get('sourceSHA') == args.source_sha and fixture.get('dmgSHA256') == args.dmg_sha256,
            'Fixture came from another app or DMG')
    project = original / 'External GUI.ngv'; source = project / fixture['sourceRelativePath']
    fixture_identity(project, source, fixture)
    evidence = Path(args.evidence).resolve(); evidence.mkdir(parents=True, exist_ok=False)
    require(not journey.CONFIG.exists(), 'Another public XCTest configuration exists')
    result = {'schema': 'nexgenvideo/external-transport-result/1', 'completed': False, 'sourceSHA': args.source_sha,
              'dmgSHA256': args.dmg_sha256, 'fixtureSHA256': journey.sha256(original / 'fixture.json')}
    app = None
    try:
        journey.runtime_environment(evidence)
        app, identity = journey.install(args, evidence, allowed_paths=SIGNED_TRANSPORT_HARNESS_PATHS)
        require(identity['app']['treeSHA256'] == fixture.get('appTreeSHA256'), 'Completed fixture belongs to different DMG app bytes')
        test_input = Path(args.test_runtime).resolve(strict=True)
        require(journey.sha256(test_input / 'tests-producer.json') == args.test_producer_sha256, 'Transport test producer changed')
        for name in ('tests.tar.gz', 'tests-input.json', 'tests-producer.json'):
            shutil.copy2(test_input / name, evidence / name)
        work = Path(tempfile.mkdtemp(prefix='ngv-public-transport-tests-'))
        xctestrun, tests = test_bundle.consume(evidence, work / 'Products', identity['testSourceSHA'], identity['testFiles'])
        (evidence / 'test-bundle.sha256').write_text(journey.sha256(xctestrun) + '\n')
        working = evidence / 'External GUI.ngv'
        shutil.copytree(project, working, symlinks=True)
        fixture_identity(working, working / fixture['sourceRelativePath'], fixture)
        before = project_observation(working, fixture)
        journey.write_json(evidence / 'project-before.json', before)
        journey.write_json(evidence / 'fixture.json', fixture)
        config = {'scenario': 'transport', 'app': str(app), 'evidence': str(evidence), 'project': str(working),
                  'source': str(working / fixture['sourceRelativePath']), 'scaleLabel': journey.SCALES[args.scale],
                  'transportFixture': fixture}
        with journey.CONFIG.open('x') as handle:
            json.dump(config, handle)
        journey.write_json(evidence / 'configuration.json', config)
        identity['testBundle'] = {key: tests[key] for key in ('runID', 'attempt', 'archiveSHA256', 'productsSHA256', 'xctestrun', 'xcode')}
        identity['testBundle'].update(receiptSHA256=journey.sha256(evidence / 'tests-input.json'), producerSHA256=args.test_producer_sha256)
        journey.write_json(evidence / 'identity.json', identity)
        result['mode'] = identity['mode']
        code = journey.command(['xcodebuild', 'test-without-building', '-xctestrun', xctestrun, '-only-testing:' + TEST,
            '-destination', 'platform=macOS,arch=arm64', '-parallel-testing-enabled', 'NO',
            '-resultBundlePath', evidence / 'tests.xcresult'], evidence / 'tests.log', timeout=360, check=False)
        result['exitCode'] = code
        bundle = evidence / 'tests.xcresult'
        journey.command(['xcrun', 'xcresulttool', 'export', 'attachments', '--path', bundle,
                         '--output-path', evidence / 'attachments'], evidence / 'results.log')
        summary = json.loads(journey.output(['xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', bundle]))
        journey.write_json(evidence / 'summary.json', summary)
        require(code == 0 and summary.get('passedTests') == 1 and summary.get('failedTests') == 0 and summary.get('skippedTests') == 0,
                'Exactly the targeted public transport test must pass')
        validate_actions(evidence)
        require(journey.metadata(app, args.source_sha) == identity['app'], 'Transport changed the signed app bytes')
        after = project_observation(working, fixture)
        journey.write_json(evidence / 'project-after.json', after)
        verify_working_project(working, fixture, before, after)
        require(journey.tree_sha256(project) == fixture['projectTreeSHA256'], 'The original passed journey fixture changed')
        result.update(completed=True, identitySHA256=journey.sha256(evidence / 'identity.json'),
                      runtimeSHA256=journey.sha256(evidence / 'runtime.json'), journeySHA256=journey.sha256(evidence / 'journey.json'),
                      projectBeforeSHA256=before['projectTreeSHA256'], projectAfterSHA256=after['projectTreeSHA256'],
                      sourceBeforeSHA256=before['sourceSHA256'], sourceAfterSHA256=after['sourceSHA256'],
                      projectBeforeProofSHA256=journey.sha256(evidence / 'project-before.json'),
                      projectAfterProofSHA256=journey.sha256(evidence / 'project-after.json'),
                      geometrySHA256=journey.sha256(evidence / 'geometry.json'),
                      geometrySamplesSHA256=journey.sha256(evidence / 'geometry-samples.json'),
                      endpointActions=6, expectedEndCursor=120, lastSampleFrame=119, independentVisualReviewPending=True)
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        result['error'] = str(error)
        raise
    finally:
        try:
            journey.stop_owned_app(evidence)
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            result.update(completed=False, cleanupError=str(error))
        journey.write_json(evidence / 'result.json', result)
    require(result['completed'], 'Public transport cleanup failed')


def validate(args):
    import test_bundle

    evidence = Path(args.evidence).resolve(strict=True)
    result = journey.read_json(evidence / 'result.json')
    identity = journey.read_json(evidence / 'identity.json')
    fixture = journey.read_json(evidence / 'fixture.json')
    require(result.get('schema') == 'nexgenvideo/external-transport-result/1' and result.get('completed') is True
            and result.get('exitCode') == 0 and result.get('sourceSHA') == args.source_sha
            and result.get('dmgSHA256') == args.dmg_sha256 and result.get('endpointActions') == 6
            and result.get('expectedEndCursor') == 120 and result.get('lastSampleFrame') == 119,
            'Incomplete public transport evidence')
    journey.validate_app_identity(evidence, result, identity, args.source_sha, args.scale, args.dmg_sha256)
    for key, name in [('identitySHA256', 'identity.json'), ('runtimeSHA256', 'runtime.json'),
                      ('journeySHA256', 'journey.json'), ('fixtureSHA256', 'fixture.json'),
                      ('geometrySHA256', 'geometry.json'), ('geometrySamplesSHA256', 'geometry-samples.json'),
                      ('projectBeforeProofSHA256', 'project-before.json'), ('projectAfterProofSHA256', 'project-after.json')]:
        require(result.get(key) == journey.sha256(evidence / name), 'Transport evidence changed: ' + name)
    journey.validate_runtime(evidence)
    from verify_diagnostic_candidate import SIGNED_TRANSPORT_HARNESS_PATHS
    packaging = journey.retained_packaging.file_binding(args)
    require(packaging == identity.get('packaging') == fixture.get('packaging'), 'Transport packaging selectors changed')
    revision, files = journey.test_source_identity(args.source_sha, allowed_paths=SIGNED_TRANSPORT_HARNESS_PATHS, packaging=packaging)
    require(identity.get('testSourceSHA') == revision and identity.get('testFiles') == files, 'Transport client source changed')
    tests = test_bundle.verify_input(evidence, revision, files)
    expected = {key: tests[key] for key in ('runID', 'attempt', 'archiveSHA256', 'productsSHA256', 'xctestrun', 'xcode')}
    expected.update(receiptSHA256=journey.sha256(evidence / 'tests-input.json'), producerSHA256=journey.sha256(evidence / 'tests-producer.json'))
    require(identity.get('testBundle') == expected, 'Transport test products changed')
    with tempfile.TemporaryDirectory(prefix='ngv-transport-validate-') as temporary:
        xctestrun, _ = test_bundle.consume(evidence, Path(temporary) / 'Products', revision, files)
        require(journey.sha256(xctestrun) == (evidence / 'test-bundle.sha256').read_text().strip(), 'Transport test launch description changed')
    summary = journey.read_json(evidence / 'summary.json')
    require(summary.get('passedTests') == 1 and summary.get('failedTests') == 0 and summary.get('skippedTests') == 0,
            'Exactly one public transport test must execute')
    log = (evidence / 'tests.log').read_text()
    test = re.escape('NexGenVideoExternalUITests.UserJourneyTests testTimelineTransportThroughInstalledApp')
    for end in ('started', 'passed'):
        require(len(re.findall(r"Test Case '-\[" + test + r"\]' " + end, log)) == 1, 'Wrong or duplicate public XCTest method')
    require(not re.search(r"Test Case '-\[[^\n]* testGenericEditingThroughInstalledApp\]' started", log), 'Normal journey was unnecessarily repeated')
    validate_actions(evidence)
    project = evidence / 'External GUI.ngv'
    before = journey.read_json(evidence / 'project-before.json')
    after = journey.read_json(evidence / 'project-after.json')
    verify_working_project(project, fixture, before, after)
    require(result.get('projectBeforeSHA256') == before['projectTreeSHA256']
            and result.get('projectAfterSHA256') == after['projectTreeSHA256']
            and result.get('sourceBeforeSHA256') == before['sourceSHA256']
            and result.get('sourceAfterSHA256') == after['sourceSHA256'], 'Project byte observations changed')
    print(json.dumps({'completed': True, 'sourceSHA': args.source_sha, 'dmgSHA256': args.dmg_sha256,
                      'endpointActions': 6, 'independentVisualReviewPending': True}))


def main():
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument('mode', choices=('run', 'validate'))
    parser.add_argument('--dmg')
    parser.add_argument('--dmg-sha256', required=True)
    parser.add_argument('--source-sha', required=True)
    parser.add_argument('--fixture')
    parser.add_argument('--fixture-sha256')
    parser.add_argument('--evidence', required=True)
    parser.add_argument('--scale', choices=('1.5',), default='1.5')
    parser.add_argument('--test-runtime')
    parser.add_argument('--test-producer-sha256')
    parser.add_argument('--packaging-binding', type=Path)
    args = parser.parse_args(); args.app = None; args.app_tree_sha256 = None
    if args.mode == 'run':
        require(all((args.dmg, args.fixture, args.fixture_sha256, args.test_runtime, args.test_producer_sha256)), 'Missing exact transport execution inputs')
        run(args)
    else:
        require(not any((args.dmg, args.fixture, args.fixture_sha256, args.test_runtime, args.test_producer_sha256)), 'Posthoc validation cannot replace runtime inputs')
        validate(args)


if __name__ == '__main__':
    main()
