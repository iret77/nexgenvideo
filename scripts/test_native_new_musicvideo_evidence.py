import copy
import hashlib
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest import mock
import zipfile

from native_new_musicvideo_evidence import validate


def new_musicvideo_fixture(directory, scale=1):
    directory.mkdir(parents=True, exist_ok=True)
    info = {'NGVPackID': 'musicvideo', 'CFBundleShortVersionString': '0.6.0', 'NGVProjectSchema': 'musicvideo/3.0.0',
            'NGVMigratesFrom': [], 'NGVMinAppVersion': '1.8.0'}
    archive = directory / 'native-new-musicvideo-pack.zip'
    with zipfile.ZipFile(archive, 'w') as pack:
        pack.writestr('musicvideo.ngvpack/Contents/Info.plist', plistlib.dumps(info))
    zip_sha = hashlib.sha256(archive.read_bytes()).hexdigest()
    binding = {'id': 'musicvideo', 'version': '0.6.0', 'projectSchema': 'musicvideo/3.0.0'}
    settings = {'id': '00000000-0000-4000-8000-000000000001', 'activePlugin': 'musicvideo',
                'activePluginVersion': binding['version'], 'activePluginProjectSchema': binding['projectSchema']}
    data = json.dumps(settings).encode(); (directory / 'native-new-project-ngv.json').write_bytes(data)
    (directory / 'native-new-project-started-ngv.json').write_bytes(data)
    (directory / 'intake-project-ngv.json').write_bytes(data)
    catalog = {'plugins': [{**binding, 'sha256': zip_sha, 'url': 'https://native.invalid/musicvideo.zip',
                            'migratesFrom': [], 'minAppVersion': '1.8.0'}]}
    catalog_bytes = json.dumps(catalog).encode(); (directory / 'native-new-project-catalog.json').write_bytes(catalog_bytes)
    observed = {'projectID': settings['id'], 'binding': binding, 'catalogSHA256': hashlib.sha256(catalog_bytes).hexdigest(),
        'settingsSHA256': hashlib.sha256(data).hexdigest(), 'startedSettingsSHA256': hashlib.sha256(data).hexdigest(),
        'activation': 'already-loaded-same-CI-pack', 'unexpectedRequests': [], 'zipSHA256': zip_sha, 'catalogRequests': 1, 'zipRequests': 1,
        'freshCatalogGate': True, 'realInstallerAndSignature': True, 'pipelineAbsentBeforeStart': True,
        'nextIntake': 'Track', 'viewport': {'width': 960, 'height': 640, 'textScale': scale}, 'liveCatalog': False, 'runtimeFixture': True}
    actions = [{'kind': 'pointer', 'id': k} for k in ['home.new', 'home.format.musicvideo', 'home.format.create']]
    actions += [{'kind': 'save-panel', 'filename': 'Native Music Video.ngv', 'nativeDirectoryAndFilenameTyped': True, 'exactURLVerified': True},
                {'kind': 'pointer', 'id': 'dock.start'}, {'kind': 'verified-state', 'label': 'native New Music Video completed', 'evidence': observed}]
    images = [f'owner-{label}.png' for label in ['native-musicvideo-format', 'native-musicvideo-before-start', 'save-panel', 'save-selected']]
    for name in images: (directory / name).write_bytes(b'\x89PNG\r\n\x1a\n' + b'unit oracle png' * 100)
    record = {'progress': 'hostflow-new-project.json', 'interactions': actions, 'screenshots': images}
    write_new_result(directory, record)
    intake_path = directory / 'hostflow-track-lyrics-result.json'
    intake = json.loads(intake_path.read_bytes()) if intake_path.exists() else {'interactions': [
        {'kind': 'verified-state', 'label': 'native Track and optional Lyrics intake', 'evidence': {}}], 'screenshots': [], 'progress': 'new-fixture-intake.json'}
    for event in intake['interactions']:
        if event.get('label') == 'native Track and optional Lyrics intake':
            event['evidence'].update(projectKey=settings['id'], settingsSHA256=hashlib.sha256(data).hexdigest())
    intake_path.write_text(json.dumps(intake))
    (directory / intake['progress']).write_text(json.dumps({**intake, 'failure': None}))
    return {'nativeProjectCreation': 'hostflow-new-project-result.json'}, record


def write_new_result(directory, record):
    (directory / 'hostflow-new-project-result.json').write_text(json.dumps(record))
    (directory / record['progress']).write_text(json.dumps({**record, 'failure': None}))


class NativeNewMusicvideoEvidenceTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(); self.addCleanup(temp.cleanup)
        self.directory = Path(temp.name); self.report, self.record = new_musicvideo_fixture(self.directory)

    def test_exact_native_route_and_retained_bytes_required(self):
        self.assertEqual(len(validate(self.directory, self.report, 1)), 4)
        for index in range(len(self.record['interactions'])):
            changed = copy.deepcopy(self.record); changed['interactions'].pop(index); write_new_result(self.directory, changed)
            with self.subTest(index=index), self.assertRaises(ValueError): validate(self.directory, self.report, 1)
        write_new_result(self.directory, self.record)
        self.assertRaises(ValueError, validate, self.directory, self.report, 1.5)
        self.assertRaises(ValueError, validate, self.directory, {}, 1)

    def test_catalog_pin_and_page_order_cannot_be_self_asserted(self):
        for key, value in [('freshCatalogGate', False), ('realInstallerAndSignature', False), ('catalogRequests', 0),
                           ('zipRequests', 2), ('pipelineAbsentBeforeStart', False), ('settingsSHA256', 'a' * 64)]:
            changed = copy.deepcopy(self.record); changed['interactions'][-1]['evidence'][key] = value
            write_new_result(self.directory, changed)
            with self.subTest(key=key), self.assertRaises(ValueError): validate(self.directory, self.report, 1)
        changed = copy.deepcopy(self.record); changed['interactions'][3], changed['interactions'][4] = changed['interactions'][4], changed['interactions'][3]
        write_new_result(self.directory, changed); self.assertRaises(ValueError, validate, self.directory, self.report, 1)

    def test_wrong_actual_pack_or_saved_format_fails(self):
        for filename in ['native-new-project-ngv.json', 'native-new-project-catalog.json', 'native-new-musicvideo-pack.zip']:
            path = self.directory / filename; original = path.read_bytes(); path.write_bytes(b'wrong bytes')
            with self.subTest(filename=filename), self.assertRaises(ValueError): validate(self.directory, self.report, 1)
            path.write_bytes(original)
        for name in self.record['screenshots']:
            path = self.directory / name; original = path.read_bytes(); path.write_bytes(b'missing screenshot')
            self.assertRaises(ValueError, validate, self.directory, self.report, 1); path.write_bytes(original)

    def test_actual_new_completion_must_follow_start(self):
        changed = copy.deepcopy(self.record)
        changed['interactions'].insert(0, changed['interactions'].pop())
        write_new_result(self.directory, changed)
        with self.assertRaisesRegex(ValueError, 'completion did not follow'):
            validate(self.directory, self.report, 1)

    def test_different_valid_intake_project_is_not_native_creation(self):
        path = self.directory / 'intake-project-ngv.json'
        value = json.loads(path.read_bytes()); value['id'] = '00000000-0000-4000-8000-000000000099'
        data = json.dumps(value).encode(); path.write_bytes(data)
        intake_path = self.directory / 'hostflow-track-lyrics-result.json'
        intake = json.loads(intake_path.read_bytes())
        intake['interactions'][0]['evidence'].update(projectKey=value['id'], settingsSHA256=hashlib.sha256(data).hexdigest())
        intake_path.write_text(json.dumps(intake))
        with self.assertRaisesRegex(ValueError, 'different projects'):
            validate(self.directory, self.report, 1)

    def test_archive_member_read_eof_is_a_refusal(self):
        with mock.patch.object(zipfile.ZipFile, 'read', side_effect=EOFError('fixture member read ended early')):
            with self.assertRaisesRegex(ValueError, 'Invalid actual pack metadata'):
                validate(self.directory, self.report, 1)
        self.assertEqual(len(validate(self.directory, self.report, 1)), 4)

    def test_malformed_xml_plist_is_a_refusal(self):
        with zipfile.ZipFile(self.directory / 'native-new-musicvideo-pack.zip', 'w') as pack:
            pack.writestr('musicvideo.ngvpack/Contents/Info.plist', b'<?xml version="1.0"?><plist><dict>')
        with self.assertRaisesRegex(ValueError, 'Invalid actual pack metadata'):
            validate(self.directory, self.report, 1)
