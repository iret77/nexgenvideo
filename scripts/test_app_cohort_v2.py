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
