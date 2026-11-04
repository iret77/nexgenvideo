import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest


DIRECTORY = Path(__file__).parent / 'external-gui'
sys.path.insert(0, str(DIRECTORY))
try:
    import transport
finally:
    sys.path.pop(0)


class ExternalTransportTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def element(self, label, frame, **extra):
        return {'title': '', 'label': label, 'value': '', 'identifier': '', 'enabled': True, 'hittable': True,
                'frame': frame} | extra

    def clock(self, frame):
        return f'{frame // 108000:02}:{frame // 1800 % 60:02}:{frame // 30 % 60:02}:{frame % 30:02}'

    def cursor(self, frame, *, combined=False, duration=True, stable=False):
        text = self.clock(frame) + (' / 00:00:04:00' if combined else '')
        field = self.element(text, [20, 100, 180 if combined else 110, 20])
        candidates = [{'element': field, 'tokens': [frame, 120] if combined else [frame]}]
        if duration and not combined:
            candidates.append({'element': self.element('00:00:04:00', [200, 100, 110, 20]), 'tokens': [120]})
        result = {'frame': frame, 'role': 'left-current-cursor', 'field': field,
                  'startControl': self.element('Go to Start', [400, 100, 20, 20]), 'candidates': candidates}
        if stable:
            result.update(observations=6, stableSeconds=.6)
        return result

    def capture(self, label):
        image = self.root / (label + '.png'); image.write_bytes(b'\x89PNG\r\n\x1a\n' + label.encode())
        tree = self.root / (label + '.txt'); tree.write_text('Application public XCTest tree ' + label)
        return {'screenshot': image.name, 'screenshotSHA256': transport.journey.sha256(image),
                'accessibility': tree.name, 'accessibilitySHA256': transport.journey.sha256(tree)}

    def sequence(self):
        rows = []; actions = [{'kind': 'text', 'text': '/actual/project/path', 'identifier': 'goTo', 'label': '', 'time': 995},
                              {'kind': 'click', 'target': 'visible timeline canvas', 'x': 24, 'y': 500, 'time': 996},
                              {'kind': 'click', 'target': 'Default layout', 'time': 999},
                              {'kind': 'click', 'target': 'Film Preview focus', 'time': 1002},
                              {'kind': 'click', 'target': 'View', 'time': 1002.5},
                              {'kind': 'click', 'target': 'Maximize Focused Panel', 'time': 1003}]
        for surface in transport.SURFACES:
            if surface == 'theater-timeline':
                actions += [{'kind': 'key', 'key': 'escape', 'modifiers': 0, 'time': 1010},
                            {'kind': 'click', 'target': 'Theater', 'time': 1013}]
            for ordinal, target in enumerate((0, 120, 0)):
                before = 1 if ordinal == 0 else 0 if ordinal == 1 else 120
                label = 'Go to End' if target == 120 else 'Go to Start'
                actions.append({'kind': 'click', 'target': label,
                                'time': (1006 if surface == 'maximized-timeline-preview' else 1014) + ordinal})
                name = surface + '-' + str(ordinal)
                rows.append({'stage': name, 'surface': surface, 'endpointOrdinal': ordinal, 'targetFrame': target,
                             'paused': True, 'before': self.cursor(before), 'after': self.cursor(target, stable=True),
                             'control': self.element(label, [560 if target == 120 else 400, 100, 20, 20]),
                             'window': self.element('NexGenVideo — External GUI', [0, 0, 1024, 768]),
                             'actionCount': len(actions), 'beforeEvidence': self.capture(name + '-before'),
                             'evidence': self.capture(name + '-after')})
        self.geometry_fixture()
        return {'schema': 'nexgenvideo/external-transport/1', 'stages': rows, 'actions': actions}

    def geometry_fixture(self):
        phases = {}
        for phase, instant, count in [('before', 1000, 3), ('maximized', 1004, 6), ('restored', 1011, 10)]:
            large = phase == 'maximized'
            def node(path, kind, label, frame, **extra):
                return self.element(label, frame, **extra) | {'path': path,
                    'parent': path.rsplit('/', 1)[0] if '/' in path else None, 'type': kind}
            nodes = [node('w', 'window', '', [0, 0, 1024, 768], title='NexGenVideo — External GUI'),
                     node('w/0', 'group', '', [0, 0, 1024, 768]),
                     node('w/0/0', 'staticText', 'Project External GUI', [20, 10, 200, 20]),
                     node('w/0/1', 'splitGroup', '', [0, 40, 1024, 680]),
                     node('w/0/2', 'button', 'Budget', [10, 740, 120, 20]),
                     node('w/0/1/0', 'group', '', [2, 42, 1020, 676] if large else [310, 45, 400, 400]),
                     node('w/0/1/0/0', 'staticText', 'Film Preview', [320, 50, 100, 20]),
                     node('w/0/1/0/1', 'button', 'Go to Start', [400, 100 if large else 400, 20, 20]),
                     node('w/0/1/0/2', 'button', 'Go to End', [560, 100 if large else 400, 20, 20]),
                     node('w/0/1/1', 'group', '', [5, 45, 295, 400]),
                     node('w/0/1/1/0', 'button', 'Assets', [10, 50, 80, 20], hittable=not large),
                     node('w/0/1/2', 'group', '', [5, 450, 1014, 260]),
                     node('w/0/1/2/0', 'button', 'Pointer (V)', [10, 460, 80, 20], hittable=not large)]
            phases[phase] = [{'phase': phase, 'time': instant + index, 'nodes': copy.deepcopy(nodes),
                              'selectedPreviewPath': 'w/0/1/0', 'modalCounts': {'sheets': 0, 'alerts': 0, 'dialogs': 0},
                              'evidence': self.capture('geometry-' + phase + '-' + str(index)), 'actionCount': count}
                             for index in range(2)]
        self.write_geometry(phases)
        return phases

    def write_geometry(self, phases):
        (self.root / 'geometry.json').write_text(json.dumps({'schema': 'nexgenvideo/public-preview-geometry/1', 'phases': phases}))
        (self.root / 'geometry-samples.json').write_text(json.dumps({'schema': 'nexgenvideo/public-preview-geometry-samples/1',
            'samples': [observation for pair in phases.values() for observation in pair]}))

    def write(self, record):
        (self.root / 'journey.json').write_text(json.dumps(record))

    def test_six_nontrivial_public_actions_require_both_surfaces(self):
        record = self.sequence(); self.write(record)
        self.assertEqual(transport.validate_actions(self.root), record)
        record['stages'][3]['surface'] = 'regular-preview'
        self.write(record)
        with self.assertRaises(ValueError):
            transport.validate_actions(self.root)

    def test_noop_reversed_callbacks_and_last_sample_instead_of_end_fail(self):
        original = self.sequence()
        for target in (0, 119):
            record = copy.deepcopy(original)
            record['stages'][1]['after'] = self.cursor(target, stable=True)
            self.write(record)
            with self.subTest(end=target), self.assertRaises(ValueError):
                transport.validate_actions(self.root)
        record = copy.deepcopy(original); record['stages'][0]['before'] = self.cursor(0)
        self.write(record)
        with self.assertRaises(ValueError):
            transport.validate_actions(self.root)

    def test_cursor_binding_cannot_substitute_static_duration_or_conflicting_value(self):
        for record in [self.cursor(7), self.cursor(7, combined=True), self.cursor(7, duration=False)]:
            self.assertEqual(transport.cursor(record), 7)
        record = self.cursor(7); record['field'] = record['candidates'][1]['element']
        with self.assertRaises(ValueError):
            transport.cursor(record)
        record = self.cursor(7); record['field']['value'] = '00:00:04:00'
        with self.assertRaises(ValueError):
            transport.cursor(record)
        record = self.cursor(120, duration=False); record['candidates'][0]['element']['frame'][0] = 500
        with self.assertRaises(ValueError):
            transport.cursor(record)

    def test_incomplete_unstable_disabled_hidden_and_off_window_actions_fail(self):
        original = self.sequence()
        mutations = [lambda r: r['stages'].pop(),
                     lambda r: r['stages'][0]['after'].update(observations=1),
                     lambda r: r['stages'][0]['after'].update(stableSeconds=.49),
                     lambda r: r['stages'][0]['control'].update(enabled=False),
                     lambda r: r['stages'][0]['control'].update(hittable=False),
                     lambda r: r['stages'][0]['control'].update(frame=[1100, 100, 20, 20]),
                     lambda r: r['stages'][0]['control'].update(label='Go to End'),
                     lambda r: r['stages'][1]['before'].update(frame=3),
                     lambda r: r['stages'][0]['after']['field'].update(frame=[float('nan'), 0, 10, 10])]
        for mutation in mutations:
            record = copy.deepcopy(original); mutation(record); self.write(record)
            with self.subTest(mutation=mutations.index(mutation)), self.assertRaises(ValueError):
                transport.validate_actions(self.root)

    def test_missing_real_action_or_reused_changed_capture_fails(self):
        original = self.sequence()
        record = copy.deepcopy(original); record['actions'][record['stages'][0]['actionCount'] - 1]['target'] = 'unrelated control'; self.write(record)
        with self.assertRaises(ValueError):
            transport.validate_actions(self.root)
        record = copy.deepcopy(original); record['stages'][1]['evidence'] = record['stages'][0]['evidence']; self.write(record)
        with self.assertRaises(ValueError):
            transport.validate_actions(self.root)
        self.write(original)
        (self.root / original['stages'][0]['evidence']['screenshot']).write_bytes(b'replaced')
        with self.assertRaises(ValueError):
            transport.validate_actions(self.root)

    def fixture(self):
        project = self.root / 'External GUI.ngv'; project.mkdir()
        source = project / 'media/source.mp4'; source.parent.mkdir(); source.write_bytes(b'original actual source fixture')
        timeline = {'fps': 30, 'width': 320, 'height': 180,
                    'tracks': [{'clips': [{'startFrame': 0, 'durationFrames': 120, 'trimStartFrame': 0, 'trimEndFrame': 0, 'speed': 1}]}]}
        (project / 'project.json').write_text(json.dumps(timeline))
        (project / 'media.json').write_text('{"entries":[]}')
        (project / 'ngv.json').write_text('{"id":"fixture-only"}')
        expected = {'schema': 'nexgenvideo/transport-fixture/1', 'projectFiles': transport.project_files(project),
                    'projectTreeSHA256': transport.journey.tree_sha256(project), 'sourceSHA256': transport.journey.sha256(source),
                    'sourceRelativePath': 'media/source.mp4',
                    'fps': 30, 'endFrame': 120, 'sourceFrames': 120}
        return project, source, expected, timeline

    def test_fixed_oracle_comes_from_unchanged_project_and_local_media(self):
        project, source, expected, timeline = self.fixture()
        self.assertEqual(transport.fixture_identity(project, source, expected), expected)
        source.write_bytes(b'changed media')
        with self.assertRaises(ValueError):
            transport.fixture_identity(project, source, expected)

    def test_new_project_truth_or_another_endpoint_cannot_replace_the_declared_fixture(self):
        project, source, expected, timeline = self.fixture()
        for key, value in [('startFrame', 1), ('durationFrames', 119), ('trimStartFrame', 1), ('speed', 2)]:
            changed = copy.deepcopy(timeline); changed['tracks'][0]['clips'][0][key] = value
            (project / 'project.json').write_text(json.dumps(changed))
            binding = expected | {'projectFiles': transport.project_files(project), 'projectTreeSHA256': transport.journey.tree_sha256(project)}
            with self.subTest(key=key), self.assertRaises(ValueError):
                transport.fixture_identity(project, source, binding)

    def test_completed_working_project_cannot_adopt_changed_media_or_added_resources(self):
        project, source, expected, _ = self.fixture()
        before = transport.project_observation(project, expected)
        transport.verify_working_project(project, expected, before, dict(before))
        original = source.read_bytes()
        source.write_bytes(b'changed working medium with the same canonical JSON')
        after = transport.project_observation(project, expected)
        self.assertEqual(after['projectFiles'], before['projectFiles'])
        with self.assertRaises(ValueError):
            transport.verify_working_project(project, expected, before, after)
        with self.assertRaises(ValueError):
            transport.verify_working_project(project, expected, before, before)
        source.write_bytes(original)
        resource = project / 'extra-resource.bin'; resource.write_bytes(b'unexpected project bytes')
        after = transport.project_observation(project, expected)
        self.assertEqual(after['sourceSHA256'], before['sourceSHA256'])
        with self.assertRaises(ValueError):
            transport.verify_working_project(project, expected, before, after)

    def test_public_maximize_requires_measured_growth_restoration_and_independent_viewport(self):
        record = self.sequence()
        selected = transport.validate_geometry(self.root, record)
        self.assertEqual(selected['before']['viewport']['path'], 'w/0/1')
        self.assertGreater(selected['maximized']['preview']['frame'][2], selected['before']['preview']['frame'][2])
        phases = self.geometry_fixture()
        for pair in phases.values():
            for observation in pair:
                observation['nodes'][0]['label'] = 'A distinct accessibility label'
        self.write_geometry(phases)
        transport.validate_geometry(self.root, record)
        phases = self.geometry_fixture()
        for observation in phases['maximized']:
            for node in observation['nodes']:
                if node['path'] == 'w/0/1/0':
                    node['frame'] = [310, 45, 400, 400]
                if node['path'] in ('w/0/1/0/1', 'w/0/1/0/2'):
                    node['frame'][1] = 400
        self.write_geometry(phases)
        with self.assertRaisesRegex(ValueError, 'did not maximize'):
            transport.validate_geometry(self.root, record)
        phases = self.geometry_fixture()
        for observation in phases['restored']:
            for node in observation['nodes']:
                if node['path'] == 'w/0/1/0':
                    node['frame'] = [2, 42, 1020, 676]
        self.write_geometry(phases)
        with self.assertRaisesRegex(ValueError, 'did not restore'):
            transport.validate_geometry(self.root, record)

    def test_public_geometry_rejects_window_fallback_ambiguous_anchors_and_changed_root(self):
        record = self.sequence()
        for mutation in ('window', 'duplicate', 'root', 'modal', 'title'):
            phases = self.geometry_fixture()
            for observation in phases['maximized']:
                if mutation == 'window':
                    observation['selectedPreviewPath'] = 'w'
                elif mutation == 'duplicate':
                    duplicate = copy.deepcopy(next(node for node in observation['nodes'] if node['label'] == 'Film Preview'))
                    duplicate['path'] = 'w/0/1/0/3'; observation['nodes'].append(duplicate)
                elif mutation == 'root':
                    next(node for node in observation['nodes'] if node['path'] == 'w/0/1')['frame'][3] -= 1
                elif mutation == 'modal':
                    observation['modalCounts']['dialogs'] = 1
                else:
                    observation['nodes'][0]['title'] = 'Another actual document'
                    observation['nodes'][0]['label'] = 'NexGenVideo — External GUI'
            self.write_geometry(phases)
            with self.subTest(substitution=mutation), self.assertRaises(ValueError):
                transport.validate_geometry(self.root, record)

    def test_public_geometry_requires_stable_samples_real_menu_order_and_hidden_peer_panes(self):
        record = self.sequence()
        phases = self.geometry_fixture(); phases['maximized'][1]['time'] = phases['maximized'][0]['time'] + .49
        self.write_geometry(phases)
        with self.assertRaisesRegex(ValueError, 'temporally distinct'):
            transport.validate_geometry(self.root, record)
        phases = self.geometry_fixture()
        for observation in phases['maximized']:
            next(node for node in observation['nodes'] if node['label'] == 'Assets')['hittable'] = True
        self.write_geometry(phases)
        with self.assertRaisesRegex(ValueError, 'peer pane remains'):
            transport.validate_geometry(self.root, record)
        self.geometry_fixture()
        record['actions'][5]['target'] = 'another menu item'
        with self.assertRaisesRegex(ValueError, 'actions are missing'):
            transport.validate_geometry(self.root, record)
        for index in (0, 1):
            record = self.sequence(); del record['actions'][index]['time']
            with self.subTest(setupAction=record['actions'][index]['kind']), self.assertRaisesRegex(ValueError, 'lack timestamps'):
                transport.validate_geometry(self.root, record)


if __name__ == '__main__':
    unittest.main()
