import copy
import hashlib
import io
import json
import os
from pathlib import Path
import stat
import tempfile
import unittest
from unittest import mock
import zipfile

import app_cohort_v2
import app_release_v2
import compiled_app_release
import release_checkpoint
import signed_component_carrier as carrier


class SignedComponentCarrierTests(unittest.TestCase):
    def setUp(self):
        self.value = json.loads(app_cohort_v2.MANIFEST.read_text())
        self.selected = carrier.origin(self.value)
        self.components = {'Contents/Frameworks/image': {'kind': 'file', 'mode': 0o755, 'sha256': 'a' * 64},
            'Contents/Helpers/link': {'kind': 'symlink', 'mode': 0o777, 'target': 'image'}}
        self.source = b'{"sourceSHA":"original semantic source"}'
        self.selected.update(componentRecordCount=2, componentMapSHA256=carrier.canonical_sha(self.components),
            originalSourceReceiptSHA256=hashlib.sha256(self.source).hexdigest())
        self.manifest = {'identity': {'build': '120'}, 'appTreeSHA256': self.selected['appTreeSHA256'],
            'files': self.selected['files'], 'nativeEvidence': {'cohortV2': {
                'componentSourceObjects': self.selected['componentSourceObjects']}},
            'componentAssembly': {'signedBase': self.value['signedBase'], 'componentCompilerExecutions': 0,
                'unchangedSignedComponents': self.components, 'sourceHandoff': {
                    'schema': 'compiled-component-source-handoff/v2', 'state': 'REUSED',
                    'semanticSourceValidationPerformed': False, 'originalReceipt': self.source.decode(),
                    'originalReceiptSHA256': hashlib.sha256(self.source).hexdigest()}}}
        self.manifest['componentAssembly']['cohortV2'] = self.manifest['nativeEvidence']['cohortV2']
        self.raw = json.dumps(self.manifest).encode()
        self.selected['manifestSHA256'] = hashlib.sha256(self.raw).hexdigest()

    def test_semantic_base_sources_and_fixture_are_immutable(self):
        for key in ('signedBase', 'componentSourceObjects'):
            value = copy.deepcopy(self.value)
            value[key][next(iter(value[key]))] = 'changed'
            with self.subTest(key=key), self.assertRaises(ValueError):
                carrier.origin(value)
        replacement = copy.deepcopy(self.value)
        replacement['componentSourceObjects'][carrier.REBUILT_SUPERVISOR] = 'f' * 40
        self.assertEqual(carrier.origin(replacement)['componentSourceObjects'], self.selected['componentSourceObjects'])
        replacement['componentSourceObjects'][carrier.REBUILT_SUPERVISOR] = 'invalid'
        with self.assertRaises(ValueError):
            carrier.origin(replacement)
        with mock.patch.object(carrier, 'FIXTURE_SHA256', '0' * 64), self.assertRaises(ValueError):
            carrier.origin(self.value)

    def test_transport_record_rejects_rebinding_and_additional_fields(self):
        original = carrier.record(self.value)
        carrier.verify_record(original, self.value)
        for key in original:
            changed = copy.deepcopy(original)
            changed[key] = None
            with self.subTest(key=key), self.assertRaises(ValueError):
                carrier.verify_record(changed, self.value)
        with self.assertRaises(ValueError):
            carrier.verify_record(dict(original, ignored='unreviewed'), self.value)

    def test_component_modes_links_bytes_and_inventory_cannot_change(self):
        variants = [dict(self.components, extra={}), {}]
        for path, key, value in [('Contents/Frameworks/image', 'mode', 0o700),
                ('Contents/Frameworks/image', 'sha256', 'b' * 64),
                ('Contents/Helpers/link', 'target', '../foreign')]:
            changed = copy.deepcopy(self.components)
            changed[path][key] = value
            variants.append(changed)
        with mock.patch.object(carrier, 'origin', return_value=self.selected):
            carrier.verify_components(self.components, self.value)
            for changed in variants:
                with self.subTest(changed=changed), self.assertRaises(ValueError):
                    carrier.verify_components(changed, self.value)

    def test_original_source_bytes_are_distinct_from_the_carrier_receipt(self):
        with mock.patch.object(carrier, 'origin', return_value=self.selected):
            self.assertEqual(carrier.original_source_receipt(self.manifest, self.value), self.source)
            for key, value in [('originalReceipt', 'reissued carrier receipt'), ('originalReceipt', None),
                    ('originalReceiptSHA256', '0' * 64), ('state', 'REBUILT'),
                    ('semanticSourceValidationPerformed', True)]:
                changed = copy.deepcopy(self.manifest)
                changed['componentAssembly']['sourceHandoff'][key] = value
                with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                    carrier.original_source_receipt(changed, self.value)

    def test_manifest_keeps_physical_identity_and_semantic_components_separate(self):
        with mock.patch.object(carrier, 'origin', return_value=self.selected), \
                mock.patch.object(release_checkpoint, 'verify_manifest') as verify:
            self.assertEqual(carrier.verify_manifest(self.raw, self.value), self.manifest)
            verify.assert_called_once_with(self.manifest, self.selected['sourceSHA'], self.selected['runID'])
        for defect in ('physical-tree', 'app-bytes', 'semantic-base', 'component-source', 'component-bytes', 'compiler'):
            changed, selected = copy.deepcopy(self.manifest), copy.deepcopy(self.selected)
            if defect == 'physical-tree': changed['appTreeSHA256'] = self.value['signedBase']['appTreeSHA256']
            elif defect == 'app-bytes': changed['files'] = {}
            elif defect == 'semantic-base': changed['componentAssembly']['signedBase'] = {}
            elif defect == 'component-source': changed['nativeEvidence']['cohortV2']['componentSourceObjects'] = {}
            elif defect == 'component-bytes': changed['componentAssembly']['unchangedSignedComponents'] = {}
            elif defect == 'compiler': changed['componentAssembly']['componentCompilerExecutions'] = 1
            raw = json.dumps(changed).encode()
            selected['manifestSHA256'] = hashlib.sha256(raw).hexdigest()
            with self.subTest(defect=defect), mock.patch.object(carrier, 'origin', return_value=selected), \
                    mock.patch.object(release_checkpoint, 'verify_manifest'), self.assertRaises(ValueError):
                carrier.verify_manifest(raw, self.value)
        with mock.patch.object(carrier, 'origin', return_value=self.selected), self.assertRaises(ValueError):
            carrier.verify_manifest(self.raw + b' ', self.value)

    def metadata_fixture(self):
        selected = self.selected
        run = {'id': selected['runID'], 'head_sha': selected['sourceSHA'], 'run_attempt': 1,
            'event': 'workflow_dispatch', 'workflow_id': 303346287, 'path': '.github/workflows/release.yml',
            'repository': {'full_name': 'iret77/nexgenvideo'}, 'actor': {'login': 'iret77'}, 'status': 'completed'}
        job = {'id': selected['jobID'], 'run_id': selected['runID'], 'head_sha': selected['sourceSHA'],
            'run_attempt': 1, 'name': 'release-build', 'labels': ['macrunner'], 'status': 'completed',
            'conclusion': 'success', 'started_at': '2020-01-01T00:00:00Z', 'completed_at': '2020-01-01T01:00:00Z'}
        rows = {'actions/runs/' + str(run['id']): run, 'actions/jobs/' + str(job['id']): job}
        for role in ('proof', 'payload'):
            item = selected[role + 'Artifact']
            rows['actions/artifacts/' + str(item['id'])] = dict(item, expired=False,
                workflow_run={'id': run['id'], 'head_sha': run['head_sha']},
                created_at='2020-01-01T00:30:00Z', updated_at='2020-01-01T00:30:00Z', expires_at='2099-01-01T00:00:00Z')
        return rows

    def test_live_metadata_rejects_foreign_failed_expired_or_substituted_carriers(self):
        rows = self.metadata_fixture()
        run = 'actions/runs/' + str(self.selected['runID'])
        job = 'actions/jobs/' + str(self.selected['jobID'])
        proof = 'actions/artifacts/' + str(self.selected['proofArtifact']['id'])
        payload = 'actions/artifacts/' + str(self.selected['payloadArtifact']['id'])
        changes = [(run, 'id', 1), (run, 'head_sha', '0' * 40), (run, 'actor', {'login': 'foreign'}),
            (job, 'conclusion', 'failure'), (job, 'name', 'release'), (proof, 'digest', 'sha256:' + '0' * 64),
            (proof, 'size_in_bytes', 1), (proof, 'expired', True), (payload, 'expired', True),
            (payload, 'id', 13769391943), (payload, 'workflow_run', {'id': 1, 'head_sha': '0' * 40})]
        for change in (None, *changes):
            selected = copy.deepcopy(rows)
            if change: selected[change[0]][change[1]] = change[2]
            with self.subTest(change=change), mock.patch.dict(os.environ, GITHUB_SHA='c' * 40), \
                    mock.patch.object(carrier, 'origin', return_value=self.selected), \
                    mock.patch.object(carrier, 'api', side_effect=lambda route: selected[route]) as api, \
                    mock.patch.object(app_cohort_v2, 'objects', side_effect=lambda _source, inputs: inputs):
                if change:
                    with self.assertRaises(ValueError): carrier.metadata(self.value)
                else:
                    carrier.metadata(self.value)
                    self.assertNotIn('actions/artifacts/13769391943', [call.args[0] for call in api.call_args_list])
                    self.assertNotIn('actions/artifacts/13769367412', [call.args[0] for call in api.call_args_list])

    def test_proof_archive_refuses_duplicates_links_and_escaping_names(self):
        for name, duplicate, linked in [('manifest.json', False, False), ('manifest.json', True, False),
                ('../manifest.json', False, False), ('manifest.json', False, True)]:
            stream = io.BytesIO()
            with zipfile.ZipFile(stream, 'w') as archive:
                item = zipfile.ZipInfo(name)
                item.external_attr = (stat.S_IFLNK | 0o777 if linked else stat.S_IFREG | 0o644) << 16
                archive.writestr(item, self.raw)
                if duplicate: archive.writestr(name, self.raw)
            raw = stream.getvalue()
            selected = copy.deepcopy(self.selected)
            selected['proofArtifact'].update(size_in_bytes=len(raw), digest='sha256:' + hashlib.sha256(raw).hexdigest())
            with self.subTest(name=name, duplicate=duplicate, linked=linked), \
                    mock.patch.object(carrier, 'origin', return_value=selected), \
                    mock.patch.object(release_checkpoint, 'verify_manifest'):
                if name != 'manifest.json' or duplicate or linked:
                    with self.assertRaises(ValueError): carrier.proof_manifest(raw, self.value)
                else: self.assertEqual(carrier.proof_manifest(raw, self.value), self.manifest)

    def test_real_payload_consumer_retains_exact_files_and_rejects_member_substitution(self):
        files = {name: ('transport-' + name).encode() for name in release_checkpoint.FILES}
        for defect in (None, 'bytes', 'size', 'extra', 'linked'):
            manifest, selected = copy.deepcopy(self.manifest), copy.deepcopy(self.selected)
            manifest['files'] = {name: {'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()}
                for name, raw in files.items()}
            if defect == 'size': manifest['files']['NexGenVideo.zip']['bytes'] += 1
            selected['files'] = manifest['files']
            raw_manifest = json.dumps(manifest).encode()
            selected['manifestSHA256'] = hashlib.sha256(raw_manifest).hexdigest()
            proof, payload = io.BytesIO(), io.BytesIO()
            with zipfile.ZipFile(proof, 'w') as archive: archive.writestr('manifest.json', raw_manifest)
            with zipfile.ZipFile(payload, 'w') as archive:
                archive.writestr('manifest.json', raw_manifest)
                for name, raw in files.items():
                    item = zipfile.ZipInfo(name)
                    item.external_attr = (stat.S_IFLNK | 0o777 if defect == 'linked' else stat.S_IFREG | 0o644) << 16
                    archive.writestr(item, b'changed component bytes' if defect == 'bytes' else raw)
                if defect == 'extra': archive.writestr('unreviewed', b'extra')
            data = {'proof': proof.getvalue(), 'payload': payload.getvalue()}
            for role, raw in data.items():
                selected[role + 'Artifact'].update(size_in_bytes=len(raw), digest='sha256:' + hashlib.sha256(raw).hexdigest())
            artifacts = {role: selected[role + 'Artifact'] for role in data}
            def download(item, path):
                path.write_bytes(data['proof' if item['id'] == selected['proofArtifact']['id'] else 'payload'])
            with self.subTest(defect=defect), tempfile.TemporaryDirectory() as directory, \
                    mock.patch.object(carrier, 'origin', return_value=selected), \
                    mock.patch.object(carrier, 'metadata', return_value=({}, {}, artifacts)), \
                    mock.patch.object(carrier, 'download', side_effect=download), \
                    mock.patch.object(release_checkpoint, 'verify_manifest'):
                root = Path(directory)
                if defect:
                    with self.assertRaises(ValueError): app_release_v2.original_signed_input(root, self.value)
                else:
                    folder, actual = app_release_v2.original_signed_input(root, self.value)
                    self.assertEqual(actual, manifest)
                    self.assertEqual({path.name: path.read_bytes() for path in folder.iterdir()}, files)
                    with mock.patch.object(carrier, 'download', side_effect=AssertionError('Duplicate download')):
                        self.assertEqual(app_release_v2.original_signed_input(root, self.value), (folder, manifest))
                        (folder / 'NexGenVideo.zip').write_bytes(b'substituted')
                        with self.assertRaises(ValueError):
                            app_release_v2.original_signed_input(root, self.value)

