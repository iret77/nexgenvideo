import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import compiled_app_release as release


class CompiledAppReleaseTests(unittest.TestCase):
    def test_acquisition_reads_only_the_authenticated_runtime_bank_manifest_without_requiring_it_in_metadata(self):
        class RestoreReached(Exception):
            pass

        for case in ('valid', 'metadata-decoy', 'tampered-bank-manifest', 'missing-bank-root-record', 'changed-bank-metadata'):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as temporary:
                base = Path(temporary)
                runner = base / 'runner'
                roles, event = self.inputs()
                native = {'Sources': 'd' * 40}
                bank_id, bank_digest, bank_name = release.retained.ARTIFACTS['runtime']
                bank = {'id': bank_id, 'digest': 'sha256:' + bank_digest, 'name': bank_name, 'expired': False}
                actual_bank = {**bank, 'expired': True} if case == 'changed-bank-metadata' else bank
                binding = {'schema': 'native-app-target-source-binding/v1', 'sourceSHA': roles['metadata']['sourceSHA'],
                    'appSourceSHA': release.APP_SOURCE, 'nativeSourceObjects': native,
                    'metadata': {'artifact': {'id': 13647433566,
                        'digest': 'sha256:b6f5e0ef652fd5996760ce5f59f19239760563216d2504ff6ee056fa4dee74a9'}},
                    'retainedBank': {'runtimeArtifact': bank}}
                prepared = {'schema': 'native-app-target-prepared/v1', 'sourceSHA': roles['metadata']['sourceSHA'],
                    'appSourceSHA': release.APP_SOURCE, 'nativeSourceObjects': native, 'compilerSHA256': release.COMPILER_SHA,
                    'plans': {phase: {'operations': {'arena': str(runner / 'app-build-plan-evidence'
                        / ('production' if phase == 'production' else 'testable') / 'derived-data')}} for phase in release.PHASES}}
                metadata_zip, runtime_zip = base / 'metadata.zip', base / 'bank.zip'
                with zipfile.ZipFile(metadata_zip, 'w') as archive:
                    archive.writestr('binding.json', json.dumps(binding))
                    archive.writestr('prepared.json', json.dumps(prepared))
                    if case == 'metadata-decoy': archive.writestr('bank-runtime-manifest.json', b'untrusted decoy')
                manifest = {'binaryRoot': '/original/Release', 'files': {}}
                raw_manifest = json.dumps(manifest, sort_keys=True).encode()
                with zipfile.ZipFile(runtime_zip, 'w') as archive:
                    member = 'nested/runtime-manifest.json' if case == 'missing-bank-root-record' else 'runtime-manifest.json'
                    archive.writestr(member, b'{}' if case == 'tampered-bank-manifest' else raw_manifest)
                event_path = base / 'event.json'
                event_path.write_text(json.dumps(event))
                root = base / 'acquisition'

                def download(artifact, destination):
                    shutil.copyfile(metadata_zip if artifact['id'] == 201 else runtime_zip, destination)

                with patch.object(release, 'native_guard', return_value=runner), \
                        patch.object(release, 'producer', return_value={'artifact': {'id': 201}}), \
                        patch.object(release, 'source_objects', return_value=native), \
                        patch.object(release, 'download', side_effect=download), \
                        patch.object(release, 'api', return_value=actual_bank) as api, \
                        patch.object(release.retained, 'MANIFEST_SHA', hashlib.sha256(raw_manifest).hexdigest()), \
                        patch.object(release.retained, 'restore_runtime', side_effect=RestoreReached) as restore, \
                        patch.dict(os.environ, COMPILED_APP_TARGETS=json.dumps(roles), GITHUB_EVENT_PATH=str(event_path)):
                    if case in ('valid', 'metadata-decoy'):
                        with self.assertRaises(RestoreReached): release.acquire_products(root)
                        self.assertEqual(restore.call_args.args[:2], (root, manifest))
                        self.assertEqual((root / 'bank-runtime-manifest.json').read_bytes(), raw_manifest)
                    else:
                        with self.assertRaises(ValueError): release.acquire_products(root)
                        restore.assert_not_called()
                api.assert_called_once_with('actions/artifacts/' + str(bank_id))

    def test_failure_retains_signed_app_modes_links_symbols_and_incomplete_archives_without_acceptance(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            root, output, build = base / 'evidence', base / 'signed-input', base / '.build'
            root.mkdir()
            output.mkdir()
            image = build / 'NexGenVideo.app/Contents/MacOS/NexGenVideo'
            image.parent.mkdir(parents=True)
            image.write_bytes(b'new signed executable')
            image.chmod(0o755)
            (image.parent / 'alias').symlink_to('NexGenVideo')
            symbols = build / 'NexGenVideo.dSYM/symbols'
            symbols.parent.mkdir(parents=True)
            symbols.write_bytes(b'new symbols')
            partial = output / 'NexGenVideo.zip'
            partial.write_bytes(b'incomplete zip, not a qualified product')
            with patch.object(release, 'native_guard'), patch.object(release, 'Path',
                    side_effect=lambda value: build if value == '.build' else Path(value)), \
                    patch.dict(os.environ, {'GITHUB_SHA': 'a' * 40, 'GITHUB_RUN_ID': '101'}):
                release.retain_assembly(root, output, 'failure')
            state = json.loads((root / 'assembly-retention.json').read_text())
            self.assertEqual(state['status'], 'RETAINED_UNQUALIFIED_BYTES')
            self.assertFalse(state['functionalRCAccepted'])
            self.assertFalse(state['rawProductsArchive']['qualified'])
            self.assertEqual(state['signedInputFiles']['NexGenVideo.zip']['sha256'],
                hashlib.sha256(partial.read_bytes()).hexdigest())
            self.assertEqual(set(state['products']), {'NexGenVideo.app', 'NexGenVideo.dSYM'})
            entries = state['products']['NexGenVideo.app']['entries']
            self.assertEqual(entries['Contents/MacOS/NexGenVideo']['mode'], 0o755)
            self.assertEqual(entries['Contents/MacOS/alias']['target'], 'NexGenVideo')
            self.assertEqual(entries['Contents/MacOS/NexGenVideo']['sha256'],
                hashlib.sha256(b'new signed executable').hexdigest())
            with tarfile.open(root / 'unqualified-app-products.tar') as archive:
                name = 'NexGenVideo.app/Contents/MacOS/NexGenVideo'
                self.assertEqual(archive.extractfile(name).read(), b'new signed executable')
                self.assertEqual(archive.getmember(name).mode, 0o755)
                self.assertEqual(archive.getmember('NexGenVideo.app/Contents/MacOS/alias').linkname, 'NexGenVideo')
                self.assertEqual(archive.extractfile('NexGenVideo.dSYM/symbols').read(), b'new symbols')
            self.assertEqual(image.read_bytes(), b'new signed executable')
            self.assertEqual(partial.read_bytes(), b'incomplete zip, not a qualified product')

    def test_retained_engine_environment_requires_all_original_context_fields_and_arm64(self):
        original = {'swift': 'measured Swift', 'xcode': 'measured Xcode', 'python': '3.13.17',
            'osVersion': '27.2', 'osBuild': 'measured build'}
        commands = {('swift', '--version'): 'swift', ('xcodebuild', '-version'): 'xcode',
            ('sw_vers', '-productVersion'): 'osVersion', ('sw_vers', '-buildVersion'): 'osBuild'}
        for changed in (None, 'swift', 'xcode', 'python', 'osVersion', 'osBuild', 'architecture'):
            current = dict(original)
            if changed in current: current[changed] = 'different'
            with self.subTest(changed=changed), patch.object(release.engine, 'toolchain', return_value=original), \
                    patch.object(release.engine, 'command', side_effect=lambda *args: current[commands[args]]), \
                    patch.object(release.platform, 'python_version', return_value=current['python']), \
                    patch.object(release.platform, 'machine', return_value='x86_64' if changed == 'architecture' else 'arm64'):
                if changed is None:
                    self.assertEqual(release.engine_environment(b'authenticated log'),
                        {'original': original, 'current': original, 'architecture': 'arm64'})
                else:
                    with self.assertRaisesRegex(ValueError, 'runtime or toolchain differs'):
                        release.engine_environment(b'authenticated log')

    def inputs(self):
        selected = {'runID': 101, 'artifactID': 201, 'sourceSHA': 'a' * 40,
            'artifactSHA256': 'b' * 64, 'receiptSHA256': 'c' * 64}
        roles = {role: dict(selected) for role in release.PHASES}
        roles['metadata'] = {key: value for key, value in selected.items() if key != 'receiptSHA256'}
        event = {'inputs': {'artifact_only': 'true', 'dry_run': 'true', 'version': '1.8.0',
            'verified_pr_run_id': '301'}}
        return roles, event

    def test_compiled_input_roles_are_closed_and_duplicate_json_fields_are_rejected(self):
        roles, event = self.inputs()
        self.assertEqual(release.selectors(json.dumps(roles), event), roles)
        for value in ({}, {**roles, 'other': roles['production']},
                {key: item for key, item in roles.items() if key != 'tests'}):
            with self.subTest(value=value), self.assertRaises(ValueError):
                release.selectors(json.dumps(value), event)
        raw = json.dumps(roles)
        with self.assertRaises(ValueError):
            release.selectors(raw[:-1] + ', "production": ' + json.dumps(roles['production']) + '}', event)

    def test_compiled_rc_cannot_enable_publication_or_mix_other_resume_selectors(self):
        roles, event = self.inputs()
        changes = [('artifact_only', 'false'), ('dry_run', 'false'), ('version', '1.8.1'),
            ('verified_pr_run_id', '')]
        changes += [(name, '101') for name in ('completed_release_tests_run_id', 'completed_engine_tests_run_id',
            'signed_build_run_id', 'notary_progress_run_id', 'retained_product_source_sha',
            'retained_product_source_pr_run_id', 'prior_packaging_producer_source_sha',
            'prior_packaging_provenance_artifact_id', 'prior_packaging_provenance_artifact_sha256')]
        for name, value in changes:
            broken = copy.deepcopy(event)
            broken['inputs'][name] = value
            with self.subTest(name=name), self.assertRaises(ValueError):
                release.selectors(json.dumps(roles), broken)

    def test_compiled_selector_identity_rejects_boolean_ids_and_extra_fields(self):
        roles, event = self.inputs()
        for role, key, value in [('tests', 'runID', True), ('production', 'artifactID', 0),
                ('metadata', 'sourceSHA', 'a' * 39), ('testable', 'receiptSHA256', 'x' * 64),
                ('metadata', 'receiptSHA256', 'c' * 64)]:
            broken = copy.deepcopy(roles)
            broken[role][key] = value
            with self.subTest(role=role, key=key), self.assertRaises(ValueError):
                release.selectors(json.dumps(broken), event)

    def product(self):
        selected = self.inputs()[0]['production']
        prepared = {'plans': {'production': {'operations': {'arena': '/owned/production'}}}}
        receipt = {'schema': 'native-app-target-product/v1', 'phase': 'production',
            'sourceSHA': selected['sourceSHA'], 'runID': selected['runID'], 'attempt': 1,
            'appSourceSHA': release.APP_SOURCE, 'nativeSourceObjects': {'Sources': 'd' * 40},
            'compilerSHA256': release.COMPILER_SHA, 'recipeSHA256': 'e' * 64, 'arena': '/owned/production',
            'files': {'Products/Release/NexGenVideo': {'kind': 'file'}},
            'state': {'compileComplete': True, 'linkComplete': True, 'linkerCommandSucceeded': True,
                'unsignedLinkSHA256': 'f' * 64, 'dsymComplete': True,
                'imageUUID': 'UUID: 12345678-1234-1234-1234-123456789ABC (arm64) /owned/NexGenVideo\n',
                'dsymUUID': 'UUID: 12345678-1234-1234-1234-123456789ABC (arm64) /owned/NexGenVideo.dSYM\n'}}
        return selected, prepared, receipt

    def test_production_uuid_binding_compares_uuid_and_architecture_without_equating_pathnames(self):
        selected, prepared, receipt = self.product()
        with patch.object(release, 'source_objects', return_value=receipt['nativeSourceObjects']), \
                patch.object(release.targets, 'recipe_identity', return_value='e' * 64):
            self.assertIs(release.verify_product(receipt, selected, 'production', prepared), receipt)
            for replacement in ('UUID: 00000000-1234-1234-1234-123456789ABC (arm64) symbols',
                    'UUID: 12345678-1234-1234-1234-123456789ABC (x86_64) symbols', ''):
                broken = copy.deepcopy(receipt)
                broken['state']['dsymUUID'] = replacement
                with self.subTest(replacement=replacement), self.assertRaises(ValueError):
                    release.verify_product(broken, selected, 'production', prepared)

    def test_successful_product_cannot_cross_sources_recipes_targets_or_incomplete_link_boundaries(self):
        selected, prepared, receipt = self.product()
        with patch.object(release, 'source_objects', return_value=receipt['nativeSourceObjects']), \
                patch.object(release.targets, 'recipe_identity', return_value='e' * 64):
            for key, value in [('sourceSHA', 'f' * 40), ('runID', 102), ('attempt', 2),
                    ('phase', 'tests'), ('appSourceSHA', 'f' * 40), ('recipeSHA256', 'f' * 64),
                    ('nativeSourceObjects', {'Sources': 'f' * 40}), ('compilerSHA256', 'f' * 64),
                    ('arena', '/foreign/production')]:
                broken = copy.deepcopy(receipt)
                broken[key] = value
                with self.subTest(key=key), self.assertRaises(ValueError):
                    release.verify_product(broken, selected, 'production', prepared)
            for key in ('compileComplete', 'linkComplete', 'linkerCommandSucceeded', 'dsymComplete'):
                broken = copy.deepcopy(receipt)
                broken['state'][key] = False
                with self.subTest(key=key), self.assertRaises(ValueError):
                    release.verify_product(broken, selected, 'production', prepared)

    def test_independent_inventory_keeps_all_original_failures_and_the_full_app_and_engine_scopes(self):
        value = release.criteria()
        app = value['modules']['app']
        engine = value['modules']['engine']
        self.assertEqual(len(app['exactDiscoveredFunctionIDs']), 3720)
        self.assertEqual(len(app['exactEndedFunctionIDs']), 3712)
        self.assertEqual(len(app['exactSkippedFunctionIDs']), 8)
        self.assertEqual(len(engine['exactEndedFunctionIDs']), 896)
        self.assertEqual(len(engine['exactSkippedFunctionIDs']), 14)
        self.assertEqual(len(value['xctest']['exactIndividualPassedIDs']), 48)
        self.assertEqual(len(value['originalEightAppFailureIDsRequiredToEndWithoutIssues']), 8)
        self.assertLessEqual(set(value['originalEightAppFailureIDsRequiredToEndWithoutIssues']), set(app['exactEndedFunctionIDs']))
        self.assertEqual(sum(app['expectedCaseCountsByFunction'].values()), 371)
        self.assertEqual(sum(engine['expectedCaseCountsByFunction'].values()), 49)


if __name__ == '__main__':
    unittest.main()
