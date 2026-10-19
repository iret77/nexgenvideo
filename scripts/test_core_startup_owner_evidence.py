import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from core_startup_owner_evidence import validate


def core_startup_fixture(directory, scale=1, gates=None):
    directory.mkdir(parents=True, exist_ok=True)
    phases = ['project_init', 'brief', 'production_design', 'treatment']
    if gates is None:
        gates = [dict(phase=p, nextPhase=n, approvedPersisted=True, handoffHidden=True,
                      gatesBeforeSHA256='a' * 64, gatesAfterSHA256='b' * 64)
                 for p, n in zip(phases, phases[1:] + ['script'])]
    identity = '00000000-0000-4000-8000-000000000007'
    before = json.dumps({'id': identity}).encode()
    after = json.dumps({'id': identity, 'productionContract': {'id': 'core.production.v2', 'version': '2.0.0'}}).encode()
    (directory / 'core-before-enrollment-ngv.json').write_bytes(before)
    (directory / 'core-enrolled-ngv.json').write_bytes(after)
    viewport = {'width': 960, 'height': 640, 'textScale': scale}
    new = {'progress': 'core-new-project.json', 'interactions': [
        {'kind': 'pointer', 'id': 'home.new'}, {'kind': 'pointer', 'id': 'home.format.generic'},
        {'kind': 'pointer', 'id': 'home.format.create'}, {'kind': 'save-panel', 'filename': 'Native Core Film.ngv',
         'nativeDirectoryAndFilenameTyped': True, 'exactURLVerified': True},
        {'kind': 'verified-state', 'label': 'native Generic New remains outside production', 'evidence': {
            'projectID': identity, 'settingsSHA256': hashlib.sha256(before).hexdigest(), 'viewport': viewport}}],
        'screenshots': ['core-format.png', 'core-save-panel.png', 'core-save-selected.png']}
    selection = json.dumps({'schema': 'story-source-selection/v1', 'workflowID': 'core.production.v2', 'projectID': 'Native Core Film'}).encode()
    receipt = 'brief/source-selections/00000000-0000-4000-8000-000000000008.v1.json'
    artifacts = {'project.yaml': b'project: Native Core Film\n', 'brief.yaml': b'project_mode: generic\n',
        'production_design/production_design.yaml': b'refs: []\n', 'treatment/current.md': b'Two abstract compositions.\n',
        'script/current.v1.json': b'{}',
        'brief/story-source.v1.json': json.dumps({'schema': 'story-source/v1', 'header': {'projectID': 'Native Core Film'},
            'declineReceipt': {'path': receipt, 'sha256': hashlib.sha256(selection).hexdigest()}}).encode(),
        'gates.yaml': b'phases: []\n', receipt: selection, 'brief/story-source-selection.v1.json': selection}
    retained = []
    for i, (path, data) in enumerate(artifacts.items()):
        name = f'core-start-artifact-{i}.json'; (directory / name).write_bytes(data)
        retained.append({'path': path, 'retained': name, 'sha256': hashlib.sha256(data).hexdigest()})
    actions = [{'kind': 'pointer', 'id': 'editor.workspace.production'}, {'kind': 'pointer', 'id': 'dock.start'},
        {'kind': 'verified-state', 'label': 'native-dialog-pointer', 'evidence': {'title': 'Start Production'}}]
    for i, gate in enumerate(gates):
        if i == 1: actions.append({'kind': 'pointer', 'id': 'story-source.greenfield'})
        actions += [{'kind': 'pointer', 'id': 'agent.gate.approve'}, {'kind': 'verified-state', 'label': 'native approval ' + gate['phase'], 'evidence': gate}]
    actions.append({'kind': 'verified-state', 'label': 'native Core startup reached Script', 'evidence': {
        'projectID': identity, 'enrolledProjectID': identity, 'settingsSHA256': hashlib.sha256(after).hexdigest(), 'viewport': viewport,
        'sourceDisposition': 'greenfield', 'liveAgent': False, 'fixtureCanonicalWrites': True,
        'phaseRequests': phases + ['script'], 'artifacts': retained}})
    start = {'progress': 'core-enrollment.json', 'interactions': actions, 'screenshots': [
        'core-before-start.png', 'core-explicit-greenfield-selection.png', 'core-approve-project.png', 'core-approve-brief.png',
        'core-approve-design.png', 'core-approve-treatment.png']}
    for record, name in ((new, 'core-new-project-result.json'), (start, 'core-enrollment-result.json')):
        for image in record['screenshots']: (directory / image).write_bytes(b'\x89PNG\r\n\x1a\n' + b'unit fixture' * 100)
        write_result(directory, record, name)
    return {'coreStartup': 'core-enrollment-result.json', 'nativeGateApprovals': gates}


def write_result(directory, record, name='core-enrollment-result.json'):
    (directory / name).write_text(json.dumps(record))
    (directory / record['progress']).write_text(json.dumps({**record, 'failure': None}))


class CoreStartupEvidenceTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(); self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name); self.owner = core_startup_fixture(self.directory)

    def test_actual_early_decisions_and_full_gate_join(self):
        self.assertEqual(len(validate(self.directory, self.owner, 1)), 9)
        record = json.loads((self.directory / 'core-enrollment-result.json').read_text())
        for index in range(len(record['interactions'])):
            changed = copy.deepcopy(record); changed['interactions'].pop(index); write_result(self.directory, changed)
            with self.subTest(index=index), self.assertRaises((ValueError, KeyError)): validate(self.directory, self.owner, 1)
        write_result(self.directory, record)
        self.assertRaises(ValueError, validate, self.directory, {}, 1)
        self.assertRaises(ValueError, validate, self.directory, self.owner, 1.25)

    def test_actual_source_and_saved_binding_bytes_required(self):
        for name in ['core-before-enrollment-ngv.json', 'core-enrolled-ngv.json', 'core-start-artifact-6.json', 'core-start-artifact-8.json']:
            path = self.directory / name; original = path.read_bytes(); path.write_bytes(b'{}')
            with self.subTest(name=name), self.assertRaises((ValueError, KeyError)): validate(self.directory, self.owner, 1)
            path.write_bytes(original)
        owner = copy.deepcopy(self.owner); owner['nativeGateApprovals'] = owner['nativeGateApprovals'][1:]
        self.assertRaises(ValueError, validate, self.directory, owner, 1)

    def test_enrollment_must_observe_actual_working_copy_identity(self):
        record = json.loads((self.directory / 'core-enrollment-result.json').read_text())
        record['interactions'][-1]['evidence']['enrolledProjectID'] = '00000000-0000-4000-8000-000000000099'
        write_result(self.directory, record)
        with self.assertRaisesRegex(ValueError, 'Core enrollment changed identity'):
            validate(self.directory, self.owner, 1)

    def test_observation_cannot_precede_approval_click(self):
        record = json.loads((self.directory / 'core-enrollment-result.json').read_text())
        i = next(i for i, a in enumerate(record['interactions']) if a.get('label') == 'native approval project_init')
        record['interactions'][i - 1:i + 1] = list(reversed(record['interactions'][i - 1:i + 1]))
        write_result(self.directory, record)
        with self.assertRaisesRegex(ValueError, 'Core approval observations'):
            validate(self.directory, self.owner, 1)
