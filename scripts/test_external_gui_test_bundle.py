import copy
import io
import os
from pathlib import Path
import plistlib
import sys
import tarfile
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).parent / 'external-gui'))
import acceptance as journey
import test_bundle as bundle
sys.path.pop(0)


class ExternalTestBundleTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.sha = 'a' * 40
        self.files = {'scripts/external-gui/test_bundle.py': 'b' * 64}
        self.run = {'id': 12, 'head_sha': self.sha, 'event': 'workflow_dispatch',
                    'path': '.github/workflows/ci-batch.yml', 'repository': {'full_name': bundle.REPOSITORY},
                    'status': 'completed', 'conclusion': 'failure'}
        self.artifact = {'id': 34, 'name': bundle.ARTIFACT, 'expired': False, 'digest': 'sha256:' + 'c' * 64,
                         'workflow_run': {'id': 12, 'head_sha': self.sha}}
        self.job = {'id': 56, 'name': 'external-gui-acceptance / Build external UI tests', 'run_id': 12,
                    'head_sha': self.sha, 'run_attempt': 1, 'status': 'completed', 'conclusion': 'success',
                    'labels': ['self-hosted', 'macrunner']}

    def archive(self, entries):
        archive = self.root / 'tests.tar.gz'
        with tarfile.open(archive, 'w:gz') as handle:
            for name, kind, content in entries:
                entry = tarfile.TarInfo(name)
                entry.mode = 0o755 if kind == 'directory' else 0o644
                if kind == 'file':
                    entry.size = len(content)
                    handle.addfile(entry, io.BytesIO(content))
                else:
                    entry.type = {'symlink': tarfile.SYMTYPE, 'hardlink': tarfile.LNKTYPE,
                                  'directory': tarfile.DIRTYPE}[kind]
                    entry.linkname = content
                    handle.addfile(entry)
        return archive

    def test_original_failed_journey_can_reuse_its_successful_build(self):
        bundle.require_origin(self.run, self.artifact, self.sha, 12)
        bundle.require_job(self.job, 12, self.sha, 1)
        for target, key, value in ((self.run, 'head_sha', 'd' * 40),
                                   (self.run, 'path', '.github/workflows/untrusted.yml'),
                                   (self.artifact, 'expired', True), (self.artifact, 'digest', 'unbound'),
                                   (self.artifact, 'id', 0)):
            changed_run, changed_artifact = copy.deepcopy(self.run), copy.deepcopy(self.artifact)
            (changed_run if target is self.run else changed_artifact)[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                bundle.require_origin(changed_run, changed_artifact, self.sha, 12)
        for key, value in (('conclusion', 'failure'), ('run_attempt', 2), ('head_sha', 'd' * 40),
                           ('labels', ['macos-26']), ('status', 'in_progress')):
            with self.subTest(key=key), self.assertRaises(ValueError):
                bundle.require_job({**self.job, key: value}, 12, self.sha, 1)

    def test_products_relocate_with_internal_framework_symlinks_and_modes(self):
        archive = self.archive([('Framework/Versions/A/binary', 'file', b'original'),
                                ('Framework/Versions/Current', 'symlink', 'A'),
                                ('Framework/binary', 'symlink', 'Versions/Current/binary')])
        target = self.root / 'Products'
        bundle.unpack_products(archive, target)
        self.assertEqual((target / 'Framework/binary').read_bytes(), b'original')
        before = bundle.products_sha256(target)
        path = target / 'Framework/Versions/A/binary'
        os.utime(path, (0, 0))
        self.assertEqual(before, bundle.products_sha256(target))
        path.chmod(0o755)
        self.assertNotEqual(before, bundle.products_sha256(target))

    def test_product_hash_ignores_only_platform_dependent_symlink_modes(self):
        target = self.root / 'Products'
        target.mkdir()
        (target / 'binary').write_bytes(b'original')
        (target / 'link').symlink_to('binary')
        expected = bundle.products_sha256(target)
        original_lstat = Path.lstat

        def mac_lstat(path):
            value = original_lstat(path)
            if path.name == 'link':
                return os.stat_result((value.st_mode & ~0o777 | 0o755, *value[1:]))
            return value

        with patch.object(Path, 'lstat', mac_lstat):
            self.assertEqual(expected, bundle.products_sha256(target))
        (target / 'link').unlink()
        (target / 'other').write_bytes(b'original')
        (target / 'link').symlink_to('other')
        self.assertNotEqual(expected, bundle.products_sha256(target))

    def test_archive_rejects_traversal_links_duplicates_and_special_members(self):
        cases = [ [('..' + '/escape', 'file', b'x')], [('/absolute', 'file', b'x')],
                  [('link', 'symlink', '../outside')], [('link', 'symlink', '/outside')],
                  [('file', 'file', b'x'), ('file', 'file', b'y')],
                  [('link', 'symlink', 'inside'), ('link/file', 'file', b'x')],
                  [('Link', 'symlink', 'inside'), ('link/file', 'file', b'x')],
                  [('Folder', 'directory', ''), ('folder', 'directory', '')],
                  [('caf\u00e9', 'file', b'x'), ('cafe\u0301', 'file', b'y')],
                  [('link', 'hardlink', 'file')] ]
        for index, entries in enumerate(cases):
            with self.subTest(entries=entries), self.assertRaises(ValueError):
                bundle.unpack_products(self.archive(entries), self.root / str(index))

    def test_staged_source_drift_fails_before_any_build_command(self):
        args = SimpleNamespace(destination=str(self.root / 'build-output'))
        with patch.dict(os.environ, {'GITHUB_ACTIONS': 'true', 'GITHUB_SHA': self.sha}), \
                patch.object(journey, 'test_source_identity', side_effect=[(self.sha, self.files),
                                                                         ValueError('staged source drift')]) as identity, \
                patch.object(journey, 'command') as command:
            with self.assertRaisesRegex(ValueError, 'staged source drift'):
                bundle.build(args)
            self.assertEqual(identity.call_count, 2)
            self.assertIn('input_root', identity.call_args.kwargs)
            command.assert_not_called()

    def test_zip_transfer_rejects_duplicate_unknown_and_symlink_members(self):
        for index, case in enumerate(('extra', 'duplicate', 'symlink')):
            archive = self.root / f'{case}.zip'
            with zipfile.ZipFile(archive, 'w') as handle:
                handle.writestr('tests.tar.gz', b'archive')
                if case == 'symlink':
                    entry = zipfile.ZipInfo('tests-input.json')
                    entry.external_attr = 0o120777 << 16
                    handle.writestr(entry, b'outside')
                else:
                    handle.writestr('tests-input.json', b'{}')
                    handle.writestr('tests-input.json' if case == 'duplicate' else 'outside', b'x')
            destination = self.root / f'zip-{index}'
            destination.mkdir()
            with self.subTest(case=case), self.assertRaises(ValueError):
                bundle.unpack_transfer(archive, destination)

    def test_relative_testroot_and_testhost_are_required(self):
        products = self.root / 'Products'
        test = products / 'Runner.app/Contents/PlugIns/Test.xctest'
        test.mkdir(parents=True)
        path = products / 'Tests.xctestrun'
        entry = {'TestHostPath': '__TESTROOT__/Runner.app',
                 'TestBundlePath': '__TESTHOST__/Contents/PlugIns/Test.xctest'}
        path.write_bytes(plistlib.dumps({'Test': entry}))
        bundle.check_test_paths(path, products)
        for invalid in ('/old/build/Test.xctest', '__TESTROOT__/../outside', '__TESTROOT__/missing'):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                path.write_bytes(plistlib.dumps({'Test': {**entry, 'TestBundlePath': invalid}}))
                bundle.check_test_paths(path, products)

    def test_receipt_requires_exact_source_inputs_archive_and_original_job(self):
        archive = self.archive([('binary', 'file', b'original')])
        receipt = {'schema': 'nexgenvideo/external-tests-input/1', 'sourceSHA': self.sha,
                   'testFiles': self.files, 'architecture': 'arm64', 'deploymentTarget': '26.0',
                   'xcode': 'Xcode 27\nBuild version 18A123', 'runID': 12, 'attempt': 1,
                   'archiveSHA256': journey.sha256(archive), 'productsSHA256': 'f' * 64,
                   'xctestrun': 'Tests.xctestrun'}
        journey.write_json(self.root / 'tests-input.json', receipt)
        producer = {'schema': 'nexgenvideo/external-tests-producer/1', 'run': self.run,
                    'artifact': self.artifact, 'job': self.job,
                    'receiptSHA256': journey.sha256(self.root / 'tests-input.json')}
        journey.write_json(self.root / 'tests-producer.json', producer)
        bundle.verify_input(self.root, self.sha, self.files)
        for key, value in (('sourceSHA', 'd' * 40), ('testFiles', {}), ('architecture', 'x86_64'),
                           ('deploymentTarget', '27.0'), ('archiveSHA256', 'z' * 64)):
            with self.subTest(key=key), self.assertRaises(ValueError):
                bundle.require_receipt({**receipt, key: value}, self.sha, self.files)
        archive.write_bytes(b'substituted')
        with self.assertRaises(ValueError):
            bundle.verify_input(self.root, self.sha, self.files)

    def test_posthoc_validation_rejects_wrong_runtime_even_with_fresh_record_hashes(self):
        screenshot = self.root / 'desktop.png'
        screenshot.write_bytes(b'\x89PNG\r\n\x1a\noriginal')
        runtime = {'schema': 'nexgenvideo/external-gui-runtime/1', 'githubActions': True,
                   'runnerEnvironment': 'github-hosted', 'platform': 'darwin', 'architecture': 'arm64',
                   'osVersion': '26.6.2', 'jobUID': 501, 'consoleUID': 501, 'aquaSession': True,
                   'developerSecurity': 'Developer mode is currently enabled.', 'xcode': 'Xcode 26.6',
                   'desktopSHA256': journey.sha256(screenshot)}
        journey.write_json(self.root / 'runtime.json', runtime)
        journey.validate_runtime(self.root)
        for key, value in (('osVersion', '27.0'), ('architecture', 'x86_64'), ('consoleUID', 0),
                           ('aquaSession', False), ('runnerEnvironment', 'self-hosted')):
            with self.subTest(key=key), self.assertRaises(ValueError):
                journey.write_json(self.root / 'runtime.json', {**runtime, key: value})
                journey.validate_runtime(self.root)

    def test_posthoc_app_binding_rejects_substitution_and_wrong_scale_or_mode(self):
        receipt = {'schema': 'nexgenvideo/workspace-ui-input/1', 'sourceSHA': self.sha,
                   'appTreeSHA256': 'c' * 64}
        journey.write_json(self.root / 'runtime-input.json', receipt)
        identity = {'schema': 'nexgenvideo/external-gui-input/1', 'mode': 'app-artifact', 'scale': '1.5',
                    'app': {'NGVSourceCommit': self.sha, 'treeSHA256': 'c' * 64}}
        result = {'mode': 'app-artifact'}
        journey.validate_app_identity(self.root, result, identity, self.sha, '1.5', None)
        mutations = [('mode', 'dmg'), ('scale', '1'), ('schema', 'unknown'),
                     ('app', {**identity['app'], 'NGVSourceCommit': 'd' * 40}),
                     ('app', {**identity['app'], 'treeSHA256': 'd' * 64})]
        for key, value in mutations:
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                journey.validate_app_identity(self.root, result, {**identity, key: value}, self.sha, '1.5', None)
        for key, value in (('schema', 'unknown'), ('sourceSHA', 'd' * 40), ('appTreeSHA256', 'd' * 64)):
            journey.write_json(self.root / 'runtime-input.json', {**receipt, key: value})
            with self.subTest(receipt_key=key), self.assertRaises(ValueError):
                journey.validate_app_identity(self.root, result, identity, self.sha, '1.5', None)
        dmg = 'e' * 64
        identity.update(mode='dmg', dmgSHA256=dmg)
        result.update(mode='dmg', dmgSHA256=dmg)
        journey.validate_app_identity(self.root, result, identity, self.sha, '1.5', dmg)
        for changed_result, changed_identity, expected in (
                ({**result, 'mode': 'app-artifact'}, identity, dmg),
                (result, {**identity, 'app': {**identity['app'], 'NGVSourceCommit': 'd' * 40}}, dmg),
                (result, identity, 'f' * 64)):
            with self.subTest(expected=expected, identity=changed_identity), self.assertRaises(ValueError):
                journey.validate_app_identity(self.root, changed_result, changed_identity, self.sha, '1.5', expected)


if __name__ == '__main__':
    unittest.main()
