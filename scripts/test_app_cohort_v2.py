import copy
import hashlib
import json
import unittest
from unittest import mock

import app_cohort_v2 as cohort


class RoleReuseTests(unittest.TestCase):
    def setUp(self):
        self.previous = {'appSourceSHA': 'a' * 40, 'nativeSourceObjects': {'Sources': 'b' * 40},
            'roleSourceObjects': {'production': {'Sources/App.swift': 'c' * 40},
                'testable': {'Sources/App.swift': 'c' * 40}, 'tests': {'Tests': 'd' * 40}},
            'compilerSHA256': 'e' * 64, 'ciPaths': ['scripts/previous.py']}
        self.current = copy.deepcopy(self.previous)
        self.current.update(appSourceSHA='f' * 40, nativeSourceObjects={'Sources': '1' * 40}, ciPaths=['scripts/current.py'])
        self.current['roleSourceObjects']['tests'] = {'Tests': '2' * 40}
        self.prepared = {'cohortV2': {'schema': 'verified-native-app-cohort/v2'}, 'compilerSHA256': 'e' * 64,
            'plans': {phase: {'driver': {'argv': ['swiftc', '-c']}, 'operations': {'arena': '/owned'}} for phase in cohort.ROLES}}

    def recipe(self, value, phase):
        with mock.patch.object(cohort, 'verify_context', return_value=value):
            return cohort.recipe_identity(self.prepared, phase)

    def test_test_and_ci_changes_preserve_production_but_invalidate_test_recipe(self):
        self.assertEqual(self.recipe(self.previous, 'production'), self.recipe(self.current, 'production'))
        self.assertEqual(self.recipe(self.previous, 'testable'), self.recipe(self.current, 'testable'))
        self.assertNotEqual(self.recipe(self.previous, 'tests'), self.recipe(self.current, 'tests'))

    def test_pack_or_unlinked_helper_change_does_not_recompile_app(self):
        prior = self.recipe(self.current, 'production')
        self.current['componentSourceObjects'] = {'Sources/MusicvideoPlugin': '3' * 40}
        self.assertEqual(prior, self.recipe(self.current, 'production'))

    def test_actual_app_source_or_link_recipe_change_invalidates_production(self):
        prior = self.recipe(self.current, 'production')
        self.current['roleSourceObjects']['production']['Sources/App.swift'] = '3' * 40
        self.assertNotEqual(prior, self.recipe(self.current, 'production'))
        prior = self.recipe(self.current, 'production')
        self.prepared['plans']['production']['driver']['argv'].append('-O')
        self.assertNotEqual(prior, self.recipe(self.current, 'production'))
        prior = self.recipe(self.current, 'production')
        self.prepared['plans']['production']['operations']['links'] = [{'argv': ['clang', '-lDifferentEngine']}]
        self.assertNotEqual(prior, self.recipe(self.current, 'production'))

    def product(self):
        raw = (json.dumps(self.previous) + '\n').encode()
        receipt = {'sourceSHA': '4' * 40, 'appSourceSHA': self.previous['appSourceSHA'],
            'nativeSourceObjects': self.previous['nativeSourceObjects'], 'compilerSHA256': 'e' * 64,
            'recipeSHA256': self.recipe(self.previous, 'production'),
            'cohortV2': {'schema': 'verified-native-app-cohort/v2', 'manifestSHA256': hashlib.sha256(raw).hexdigest(),
                'appSourceSHA': self.previous['appSourceSHA'], 'nativeSourceObjects': self.previous['nativeSourceObjects'],
                'roleSourceObjects': self.previous['roleSourceObjects']}}
        return raw, receipt

    def check_product(self, raw, receipt):
        with mock.patch.object(cohort, 'verify_context', return_value=self.current), \
                mock.patch.object(cohort.subprocess, 'check_output', return_value=raw), \
                mock.patch.object(cohort, 'objects', side_effect=lambda source, paths:
                    self.previous['nativeSourceObjects'] if tuple(paths) == cohort.NATIVE_OBJECTS else dict(paths)):
            return cohort.compatible_product(receipt, self.prepared, 'production')

    def test_original_product_survives_changed_test_and_ci_cohort_without_relabeling(self):
        raw, receipt = self.product()
        prior = copy.deepcopy(receipt)
        self.assertTrue(self.check_product(raw, receipt))
        self.assertEqual(receipt, prior)
        self.assertNotEqual(receipt['appSourceSHA'], self.current['appSourceSHA'])

    def test_changed_production_source_rejects_old_product(self):
        raw, receipt = self.product()
        self.current['roleSourceObjects']['production']['Sources/App.swift'] = '5' * 40
        with self.assertRaises(ValueError):
            self.check_product(raw, receipt)

    def test_changed_compiler_or_old_manifest_bytes_reject_product(self):
        raw, receipt = self.product()
        receipt['compilerSHA256'] = '6' * 64
        with self.assertRaises(ValueError):
            self.check_product(raw, receipt)
        _, receipt = self.product()
        with self.assertRaises(ValueError):
            self.check_product(raw + b' ', receipt)

    def test_git_batch_reader_rejects_symbolic_or_escaped_source_inputs(self):
        with mock.patch.object(cohort.subprocess, 'run') as run:
            for source, names in [('HEAD', ['Sources']), ('a' * 40, ['../outside']), ('a' * 40, ['/outside']),
                    ('a' * 40, ['Sources\nHEAD:secret'])]:
                with self.subTest(source=source, names=names), self.assertRaises(ValueError):
                    cohort.objects(source, names)
            run.assert_not_called()


if __name__ == '__main__':
    unittest.main()


class RetainedTestFrameworkTests(unittest.TestCase):
    def test_signed_framework_reuse_preserves_original_host_and_skips_all_signing_and_compilation(self):
        from pathlib import Path
        import os
        import tempfile
        import zipfile
        for defect in ('none', 'transferred-header', 'unsigned-image', 'foreign-receipt', 'unexpected-file'):
            with self.subTest(defect=defect), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary);source_root = root / 'source';folder = source_root / 'retained-xctest-host'
                folder.mkdir(parents=True);original = root / 'qualified/whisper.framework';(original / 'Versions/A/_CodeSignature').mkdir(parents=True)
                (original / 'Versions/A/Headers').mkdir();(original / 'Versions/A/whisper').write_bytes(b'SIGNED')
                (original / 'Versions/A/whisper').chmod(0o755)
                (original / 'Versions/A/Headers/whisper.h').write_bytes(b'qualified header')
                (original / 'Versions/A/_CodeSignature/CodeResources').write_bytes(b'qualified signature')
                (original / 'Versions/Current').symlink_to('A');(original / 'whisper').symlink_to('Versions/Current/whisper')
                files = cohort.framework_inventory(original)
                receipt = {'sourceSHA': 'a' * 40, 'runID': 10, 'attempt': 1, 'phase': 'tests', 'state': {'linkComplete': True},
                    'files': {cohort.WHISPER_PREFIX + name:item for name,item in files.items()}}
                raw = (json.dumps(receipt) + '\n').encode();(folder / 'product-receipt.json').write_bytes(raw)
                selected = {'sourceSHA': 'a' * 40, 'runID': 10, 'receiptSHA256': hashlib.sha256(raw).hexdigest()}
                value = {'retainedXCTestHost': {'producer': selected}}
                archive_path = root / 'original.zip'
                with zipfile.ZipFile(archive_path, 'w') as archive:
                    for name,item in files.items():
                        if item['kind'] == 'file':archive.writestr('outputs/' + cohort.WHISPER_PREFIX + name, (original / name).read_bytes())
                bundle = root / 'New.xctest';(bundle / 'Contents/Frameworks').mkdir(parents=True);(bundle / 'Contents/Helpers').mkdir()
                host = bundle / 'Contents/Helpers/NexGenVideoXCTestHost';host.write_bytes(b'qualified original host')
                import shutil
                target = bundle / 'Contents/Frameworks/whisper.framework';shutil.copytree(original, target, symlinks=True)
                shutil.rmtree(target / 'Versions/A/_CodeSignature');(target / 'Versions/A/whisper').write_bytes(b'UNSIGNED')
                with mock.patch.object(cohort, 'WHISPER_SIGNED_SHA256', hashlib.sha256(b'SIGNED').hexdigest()), \
                        mock.patch.object(cohort, 'WHISPER_UNSIGNED_SHA256', hashlib.sha256(b'UNSIGNED').hexdigest()), \
                        mock.patch.object(cohort, 'WHISPER_UNSIGNED_BYTES', 8), mock.patch.object(cohort, 'verify_context', return_value=value), \
                        mock.patch.object(cohort.subprocess, 'run') as native, mock.patch.object(cohort.subprocess, 'check_output') as compiler:
                    with zipfile.ZipFile(archive_path) as archive:cohort.retain_signed_whisper(archive, receipt, folder)
                    transfer = root / 'downloaded/retained-xctest-host';transfer.mkdir(parents=True)
                    for name in ('whisper-framework.zip', 'product-receipt.json'):
                        shutil.copyfile(folder / name, transfer / name);(transfer / name).chmod(0o644)
                    folder = transfer;source_root = transfer.parent
                    if defect == 'transferred-header':
                        transport = folder / 'whisper-framework.zip'
                        with zipfile.ZipFile(transport) as archive:blobs = {name:archive.read(name) for name in archive.namelist()}
                        blobs['Versions/A/Headers/whisper.h'] = b'changed'
                        with zipfile.ZipFile(transport, 'w') as archive:
                            for name, raw in blobs.items():archive.writestr(name, raw)
                    elif defect == 'unsigned-image':(target / 'Versions/A/whisper').write_bytes(b'changed')
                    elif defect == 'foreign-receipt':selected['receiptSHA256'] = 'f' * 64
                    elif defect == 'unexpected-file':(target / 'unexpected').write_bytes(b'extra')
                    if defect == 'none':
                        proof = cohort.install_signed_whisper(source_root, bundle, {'cohortV2': {}})
                        self.assertEqual(cohort.framework_inventory(target), files)
                        self.assertEqual((target / 'Versions/A/whisper').stat().st_mode & 0o777, 0o755)
                        self.assertTrue((target / 'Versions/Current').is_symlink())
                        self.assertEqual((proof['compilerExecutions'], proof['signingExecutions']), (0, 0))
                        self.assertEqual(host.read_bytes(), b'qualified original host')
                        self.assertEqual((folder / 'original-unsigned-whisper.framework/Versions/A/whisper').read_bytes(), b'UNSIGNED')
                        self.assertEqual(cohort.install_signed_whisper(source_root, bundle, {'cohortV2': {}}), proof)
                    else:
                        with self.assertRaises(ValueError):cohort.install_signed_whisper(source_root, bundle, {'cohortV2': {}})
                    native.assert_not_called();compiler.assert_not_called()

    def test_qualified_framework_cannot_contain_escaping_original_paths(self):
        from pathlib import Path
        import tempfile
        for path, link in [('../outside', None), ('Versions/Current', '/outside'), ('Versions/Current', '../../outside')]:
            with self.subTest(path=path, link=link), tempfile.TemporaryDirectory() as temporary:
                receipt = {'files': {cohort.WHISPER_PREFIX + 'Versions/A/whisper': {'kind': 'file', 'sha256': cohort.WHISPER_SIGNED_SHA256, 'mode': 0o755},
                    cohort.WHISPER_PREFIX + 'Versions/A/_CodeSignature/CodeResources': {'kind': 'file'},
                    cohort.WHISPER_PREFIX + path: {'kind': 'symlink', 'target': link} if link else {'kind': 'file'}}}
                with self.assertRaises(ValueError):cohort.signed_whisper_files(receipt)
