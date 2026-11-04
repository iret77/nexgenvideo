import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import tempfile
import unittest
from unittest.mock import patch

import release_acceptance_identity as identity


class ReleaseAcceptanceIdentityTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.app = self.root / 'input/NexGenVideo.app'
        self.executable = self.app / 'Contents/MacOS/NexGenVideo'
        self.executable.parent.mkdir(parents=True)
        self.executable.write_bytes(b'actual executable fixture')
        self.executable.chmod(0o755)
        info = {'CFBundleIdentifier': 'de.h5ventures.nexgenvideo', 'CFBundleExecutable': 'NexGenVideo',
                'CFBundleShortVersionString': '1.8.0', 'CFBundleVersion': '105',
                'NGVSourceCommit': 'a' * 40, 'LSMinimumSystemVersion': '26.0'}
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        (self.app / 'Contents/Resources').mkdir()
        (self.app / 'Contents/Resources/data').write_bytes(b'original resources')
        (self.app / 'Contents/_CodeSignature').mkdir()
        (self.app / 'Contents/_CodeSignature/CodeResources').write_bytes(b'original signature')
        self.pack = self.root / 'input/musicvideo.ngvpack'
        (self.pack / 'Contents/MacOS').mkdir(parents=True)
        (self.pack / 'Contents/Info.plist').write_bytes(b'unchanged pack Info.plist')
        (self.pack / 'Contents/MacOS/PackEntry').write_bytes(b'original pack code')
        self.binding = {'schema': 'nexgenvideo/release-acceptance-binding/1', 'sourceSHA': 'a' * 40,
                        'runID': 123, 'attempt': 1, 'runtimeArtifactID': 456, 'runtimeArtifactSHA256': 'b' * 64,
                        'producerArtifactID': 789, 'producerArtifactSHA256': 'c' * 64, 'dmgSHA256': 'd' * 64,
                        'appTreeSHA256': identity.tree_sha256(self.app), 'packTreeSHA256': identity.tree_sha256(self.pack)}
        self.app_metadata = identity.gui_tools().metadata(self.app, self.binding['sourceSHA'])
        self.producer = {'schema': 'nexgenvideo/release-workspace-producer/1', 'sourceSHA': 'a' * 40,
                         'runID': '123', 'runAttempt': '1', 'dmgSHA256': 'd' * 64,
                         'mountedAppTreeSHA256': self.binding['appTreeSHA256'], 'app': self.app_metadata,
                         'packTreeSHA256': self.binding['packTreeSHA256'], 'archiveSHA256': 'e' * 64}

    def test_complete_binding_and_final_producer_reject_substituted_bytes_or_origins(self):
        self.assertEqual(identity.declared_binding(self.binding), self.binding)
        identity.validate_producer(self.producer, self.binding)
        for key, changed in [('sourceSHA', 'f' * 40), ('runID', 999), ('attempt', 2), ('dmgSHA256', '0' * 64),
                             ('appTreeSHA256', '0' * 64), ('packTreeSHA256', '0' * 64)]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                identity.validate_producer(self.producer, self.binding | {key: changed})
        for key in identity.FIELDS:
            with self.subTest(missing=key), self.assertRaises(ValueError):
                identity.declared_binding({name: value for name, value in self.binding.items() if name != key})
        for changed in [self.binding | {'extra': 1}, self.binding | {'runtimeArtifactID': True},
                        self.binding | {'attempt': True}, self.binding | {'runtimeArtifactSHA256': 'short'}]:
            with self.assertRaises(ValueError):
                identity.declared_binding(changed)

    def test_runtime_receipt_must_match_the_same_final_producer(self):
        receipt = {'sourceSHA': 'a' * 40, 'archiveSHA256': 'e' * 64, 'appTreeSHA256': self.binding['appTreeSHA256']}
        identity.validate_producer(self.producer, self.binding, receipt)
        for key in receipt:
            with self.subTest(key=key), self.assertRaises(ValueError):
                identity.validate_producer(self.producer, self.binding, receipt | {key: '0' * len(receipt[key])})

    def test_unchanged_whole_bundles_pass_before_and_after(self):
        before = identity.before_case(self.executable, self.pack)
        identity.validate_snapshot(before['before'], self.binding)
        after = identity.after_case(self.executable, self.pack, before)
        self.assertTrue(after['unchanged'])
        self.assertEqual(after['before'], after['after'])

    def test_app_binary_resource_signature_and_mode_mutations_fail_with_after_evidence(self):
        paths = [self.executable, self.app / 'Contents/Resources/data', self.app / 'Contents/_CodeSignature/CodeResources']
        for path in paths:
            original = path.read_bytes()
            before = identity.before_case(self.executable, self.pack)
            path.write_bytes(original + b'mutated')
            output = self.root / 'after.json'
            with self.subTest(path=path.relative_to(self.app)), self.assertRaises(ValueError):
                identity.after_case(self.executable, self.pack, before, output)
            self.assertFalse(json.loads(output.read_text())['unchanged'])
            path.write_bytes(original)
        before = identity.before_case(self.executable, self.pack)
        self.executable.chmod(0o644)
        with self.assertRaises(ValueError):
            identity.after_case(self.executable, self.pack, before)

    def test_installed_target_rejects_changed_code_with_identical_info_plist(self):
        home = self.root / 'isolated-user'; home.mkdir()
        installed = home / 'packs/musicvideo/0.6.0.ngvpack'
        shutil.copytree(self.pack, installed)
        expected = self.binding['packTreeSHA256']
        result = identity.installed_target(home, {'version': '0.6.0'}, expected)
        self.assertEqual(result['treeSHA256'], expected)
        (installed / 'Contents/MacOS/PackEntry').write_bytes(b'another binary with the same Info.plist')
        self.assertEqual((installed / 'Contents/Info.plist').read_bytes(), (self.pack / 'Contents/Info.plist').read_bytes())
        with self.assertRaises(ValueError):
            identity.installed_target(home, {'version': '0.6.0'}, expected)

    def test_missing_duplicate_or_external_installed_target_fails(self):
        home = self.root / 'isolated-user'; home.mkdir()
        with self.assertRaises(ValueError):
            identity.installed_target(home, {'version': '0.6.0'}, self.binding['packTreeSHA256'])
        external_home = self.root / 'another-isolated-user'; external_home.mkdir()
        external = self.root / 'external/0.6.0.ngvpack'
        shutil.copytree(self.pack, external)
        (external_home / '0.6.0.ngvpack').symlink_to(external, target_is_directory=True)
        with self.assertRaises(ValueError):
            identity.installed_target(external_home, {'version': '0.6.0'}, self.binding['packTreeSHA256'])
        shutil.copytree(self.pack, home / 'one/0.6.0.ngvpack')
        shutil.copytree(self.pack, home / 'two/0.6.0.ngvpack')
        with self.assertRaises(ValueError):
            identity.installed_target(home, {'version': '0.6.0'}, self.binding['packTreeSHA256'])

    def restore_input(self):
        directory = self.root / 'preflight'; directory.mkdir()
        source = directory / 'source-proof'; source.mkdir()
        (source / 'receipt.json').write_text('{"complete":"source proof"}')
        retained = {'productSourceSHA': 'a' * 40, 'harnessSourceSHA': 'f' * 40}
        artifact = {'id': 456, 'digest': 'sha256:' + 'b' * 64}
        receipt = {'schema': 'nexgenvideo/workspace-ui-input/1', 'sourceSHA': 'a' * 40,
                   'archiveSHA256': 'e' * 64, 'appTreeSHA256': self.binding['appTreeSHA256']}
        raw_receipt = json.dumps(receipt).encode()
        producer = self.producer | {'runtimeInputSHA256': hashlib.sha256(raw_receipt).hexdigest(),
                                    'bpySourceReceiptSHA256': hashlib.sha256(b'{}').hexdigest()}
        record = {'schema': 'nexgenvideo/retained-settings-input/1', 'harnessSourceSHA': 'f' * 40,
                  'executionRunID': '900', 'attempt': '1', 'binding': self.binding, 'producer': producer,
                  'retainedRuntime': retained, 'runtimeArtifact': artifact, 'sourceRunID': 800,
                  'sourceProofSHA256': identity.digest(source / 'receipt.json'),
                  'files': {'source-proof/receipt.json': identity.digest(source / 'receipt.json')}}
        path = directory / 'identity.json'; path.write_text(json.dumps(record))
        return directory, record, artifact, retained, raw_receipt

    def test_real_restore_composition_checks_bundle_bytes_and_metadata(self):
        directory, record, artifact, retained, raw_receipt = self.restore_input()
        destination = self.root / 'runtime'

        def restore(artifact_arg, retained_arg, output):
            self.assertEqual((artifact_arg, retained_arg), (artifact, retained))
            output.mkdir(); shutil.copytree(self.app, output / 'NexGenVideo.app')
            shutil.copytree(self.pack, output / 'plugins/musicvideo.ngvpack')
            payload = output.parent / (output.name + '-retained-transfer') / 'payload'; payload.mkdir(parents=True)
            (payload / 'workspace-ui-input.json').write_bytes(raw_receipt)
            (payload / 'bpy-source-receipt.json').write_bytes(b'{}')

        environment = {'GITHUB_ACTIONS': 'true', 'RUNNER_ENVIRONMENT': 'self-hosted', 'GITHUB_SHA': 'f' * 40,
                       'GITHUB_RUN_ID': '900', 'GITHUB_RUN_ATTEMPT': '1'}
        with patch.dict(os.environ, environment), patch.object(identity.sys, 'platform', 'darwin'), \
                patch('workspace_native_ci.source_composition') as source, \
                patch('retained_release_runtime.bind', return_value=(artifact, retained)), \
                patch('retained_release_runtime.restore', side_effect=restore), \
                patch('consume_bpy_distributable_source.consume') as corresponding_source:
            result = identity.restore(directory, identity.digest(directory / 'identity.json'), destination)
        source.assert_called_once_with(directory / 'source-proof', record['sourceProofSHA256'], 800)
        corresponding_source.assert_called_once()
        identity.validate_snapshot(result['actualBefore'], self.binding)
        self.assertEqual(json.loads((destination / 'acceptance-input.json').read_text())['binding'], self.binding)

    def test_wrong_execution_or_changed_source_evidence_stops_before_runtime_restore(self):
        directory, record, artifact, retained, raw_receipt = self.restore_input()
        path = directory / 'identity.json'
        environment = {'GITHUB_ACTIONS': 'true', 'RUNNER_ENVIRONMENT': 'self-hosted', 'GITHUB_SHA': 'f' * 40,
                       'GITHUB_RUN_ID': '900', 'GITHUB_RUN_ATTEMPT': '1'}
        with patch.dict(os.environ, environment), patch.object(identity.sys, 'platform', 'darwin'), \
                patch('retained_release_runtime.restore') as restore:
            for key, changed in [('executionRunID', '901'), ('attempt', '2'), ('harnessSourceSHA', '0' * 40)]:
                path.write_text(json.dumps(record | {key: changed}))
                with self.subTest(key=key), self.assertRaises(ValueError):
                    identity.restore(directory, identity.digest(path), self.root / 'runtime')
            path.write_text(json.dumps(record))
            (directory / 'source-proof/receipt.json').write_text('changed after preflight')
            with self.assertRaises(ValueError):
                identity.restore(directory, identity.digest(path), self.root / 'runtime')
        restore.assert_not_called()


if __name__ == '__main__':
    unittest.main()
