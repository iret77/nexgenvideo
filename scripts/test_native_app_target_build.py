import copy
import json
import os
from pathlib import Path
import unittest
import tempfile
from unittest.mock import patch

import native_app_target_build as build


class NativeAppTargetBuildTests(unittest.TestCase):
    def checkout_pins(self):
        return [{'identity': 'package' + str(i), 'kind': 'remoteSourceControl',
            'location': 'https://github.com/example/package' + str(i) + '.git',
            'state': {'revision': format(i + 1, '040x')}} for i in range(18)]

    def test_source_checkout_restore_never_resolves_or_downloads_binary_targets(self):
        for cache_status in (None, 0, 1, 'wrong-origin'):
            with self.subTest(cache_status=cache_status), tempfile.TemporaryDirectory() as temp:
                root = Path(temp); scratch = root / 'scratch'; cache = root / 'cache'
                cached = cache / 'repositories/package0-cached'
                if cache_status is not None: cached.mkdir(parents=True)
                calls = []
                def logged(folder, label, argv, environment, **options):
                    calls.append(argv)
                    if 'clone' in argv: Path(argv[-1]).mkdir()
                    return ''
                def cached_probe(argv, **options):
                    if 'config' in argv:
                        origin = 'https://github.com/another/package0.git' if cache_status == 'wrong-origin' else self.checkout_pins()[0]['location']
                        return build.subprocess.CompletedProcess(argv, 0, stdout=origin.encode())
                    return build.subprocess.CompletedProcess(argv, cache_status or 0)
                with patch.object(build, 'logged', side_effect=logged), patch.object(build.subprocess, 'run',
                        side_effect=cached_probe) as probe:
                    build.restore_checkouts(root, scratch, cache, self.checkout_pins(), {})
                clones = [argv for argv in calls if 'clone' in argv]
                self.assertEqual(len(clones), 18)
                self.assertEqual(clones[0][-2], str(cached) if cache_status == 0 else self.checkout_pins()[0]['location'])
                self.assertTrue(all(argv[0] == 'git' for argv in calls))
                self.assertTrue(all('--no-checkout' in argv and '--no-hardlinks' in argv for argv in clones))
                detached = [argv[-1] for argv in calls if 'checkout' in argv and '--detach' in argv]
                self.assertEqual(detached, [pin['state']['revision'] for pin in self.checkout_pins()])
                self.assertEqual(sorted(p.name for p in (scratch / 'checkouts').iterdir()),
                    sorted(pin['identity'] for pin in self.checkout_pins()))
                self.assertEqual(probe.call_count, 0 if cache_status is None else 1 if cache_status == 'wrong-origin' else 2)
                receipt = json.loads((root / 'restored-source-checkouts.json').read_text())
                self.assertEqual(receipt['checkouts'][0]['originalCacheOrigin'], self.checkout_pins()[0]['location'] if cache_status == 0 else None)

    def test_source_checkout_restore_rejects_ambiguous_paths_origins_and_unpinned_revisions_before_any_git(self):
        for field, value in [('identity', '../escape'), ('identity', 'package1'), ('kind', 'binaryTarget'),
                ('location', 'http://github.com/example/package0.git'), ('location', 'https://user@github.com/example/package0'),
                ('location', 'https://github.com/../package0'), ('state', {'revision': 'main'}), ('state', None)]:
            with self.subTest(field=field, value=value), tempfile.TemporaryDirectory() as temp:
                root = Path(temp); pins = self.checkout_pins(); pins[0][field] = value
                with patch.object(build, 'logged') as logged, patch.object(build.subprocess, 'run') as probe, self.assertRaises(ValueError):
                    build.restore_checkouts(root, root / 'scratch', root / 'cache', pins, {})
                logged.assert_not_called(); probe.assert_not_called()
                self.assertFalse((root / 'scratch').exists())

    def inputs(self):
        identifier, digest, _ = build.retained.ARTIFACTS['runtime']
        return {'KIND': 'native-app-targets', 'SCALE': '1', 'PRODUCER_RUN': '101', 'PRODUCER_SHA': 'a' * 40,
            'DIAGNOSTIC_ID': '201', 'DIAGNOSTIC_DIGEST': 'b' * 64, 'PRODUCT_SHA': 'c' * 40,
            'VERIFIED_PR': '301', 'FAILURE_ID': '401', 'FAILURE_DIGEST': 'd' * 64,
            'PRODUCTS_ID': str(identifier), 'PRODUCTS_DIGEST': digest}

    def test_compiler_role_requires_all_source_metadata_and_exact_retained_bank_selectors(self):
        selected = build.validate_inputs(self.inputs())
        self.assertEqual(selected['app']['appSourceSHA'], 'c' * 40)
        self.assertEqual(selected['metadata']['artifactID'], 401)
        self.assertEqual(selected['resume'], {})
        for key in self.inputs():
            changed = self.inputs(); changed[key] = ''
            with self.subTest(missing=key), self.assertRaises(ValueError): build.validate_inputs(changed)
        for key in ('DMG_DIGEST', 'JOURNEY_JOB', 'PACKAGING_PRODUCER_SOURCE'):
            changed = self.inputs(); changed[key] = 'unexpected'
            with self.subTest(unrelated=key), self.assertRaises(ValueError): build.validate_inputs(changed)
        changed = self.inputs(); changed['PRODUCTS_ID'] = '999'
        with self.assertRaises(ValueError): build.validate_inputs(changed)

    def test_aliases_cannot_hide_different_app_metadata_or_compiler_bank_inputs(self):
        for original, alias in [('KIND', 'REPLAY_KIND'), ('PRODUCT_SHA', 'EXTRA_SOURCE'),
                ('FAILURE_ID', 'EXTRA_FAILURE'), ('FAILURE_DIGEST', 'EXTRA_FAILURE_SHA'),
                ('PRODUCTS_ID', 'EXTRA_PRODUCTS'), ('PRODUCTS_DIGEST', 'EXTRA_PRODUCTS_SHA')]:
            changed = self.inputs(); changed[alias] = changed[original]
            build.validate_inputs(changed)
            changed[alias] = 'conflict'
            with self.subTest(alias=alias), self.assertRaises(ValueError): build.validate_inputs(changed)
            changed[alias] = False
            with self.subTest(nonstring=alias), self.assertRaises(ValueError): build.validate_inputs(changed)

    def test_resume_requires_exact_known_roles_complete_producer_identity_and_no_duplicate_json_fields(self):
        item = {'runID': 11, 'sourceSHA': 'a' * 40, 'artifactID': 12,
            'artifactSHA256': 'b' * 64, 'receiptSHA256': 'c' * 64}
        self.assertEqual(build.resume_inputs(json.dumps({'production': item})), {'production': item})
        for key in item:
            changed = dict(item); changed.pop(key)
            with self.subTest(missing=key), self.assertRaises(ValueError): build.resume_inputs(json.dumps({'production': changed}))
        for key, value in [('runID', True), ('artifactID', 0), ('sourceSHA', None), ('artifactSHA256', 'bad')]:
            changed = dict(item); changed[key] = value
            with self.subTest(field=key), self.assertRaises(ValueError): build.resume_inputs(json.dumps({'production': changed}))
        with self.assertRaises(ValueError): build.resume_inputs(json.dumps({'engine': item}))
        with self.assertRaises(ValueError): build.resume_inputs('{"production":{},"production":{}}')

    def test_native_guard_rejects_non_actions_wrong_job_or_non_arm64_without_running_commands(self):
        values = {'RUNNER_TEMP': '/owned', 'GITHUB_REPOSITORY': 'iret77/nexgenvideo', 'GITHUB_ACTIONS': 'true',
            'GITHUB_RUN_ATTEMPT': '1', 'GITHUB_JOB': 'app-target-build', 'REPLAY_KIND': 'native-app-targets'}
        with patch.dict(os.environ, values, clear=True), patch.object(build.sys, 'platform', 'linux'), patch.object(build.platform, 'machine', return_value='arm64'):
            with self.assertRaises(ValueError): build.native_guard(Path('/owned/app-target-build'))
        for key, value in [('GITHUB_JOB', 'source'), ('GITHUB_RUN_ATTEMPT', '2'), ('GITHUB_REPOSITORY', 'other/repository')]:
            changed = dict(values); changed[key] = value
            with self.subTest(key=key), patch.dict(os.environ, changed, clear=True), patch.object(build.sys, 'platform', 'darwin'), patch.object(build.platform, 'machine', return_value='arm64'):
                with self.assertRaises(ValueError): build.native_guard(Path('/owned/app-target-build'))

    def test_product_recipe_identity_changes_with_native_inputs_or_arguments_but_not_ci_only_source(self):
        prepared = {'plans': {'production': {'driver': {'argv': ['compiler', '-O']}, 'operations': {'arena': '/owned'}}},
            'nativeSourceObjects': {'Sources': 'a'}, 'appSourceSHA': 'b', 'compilerSHA256': 'c', 'sourceSHA': 'first-ci'}
        original = build.recipe_identity(prepared, 'production')
        changed = copy.deepcopy(prepared); changed['sourceSHA'] = 'second-ci'
        self.assertEqual(build.recipe_identity(changed, 'production'), original)
        for field in ('argv', 'source', 'compiler'):
            changed = copy.deepcopy(prepared)
            if field == 'argv': changed['plans']['production']['driver']['argv'].append('-different')
            elif field == 'source': changed['nativeSourceObjects']['Sources'] = 'changed'
            else: changed['compilerSHA256'] = 'changed'
            with self.subTest(field=field): self.assertNotEqual(build.recipe_identity(changed, 'production'), original)

    def test_clang_header_ingress_uses_the_actual_pinned_root_instead_of_a_checkout_path_segment(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); package = root / 'pinned/package'; headers = package / 'Sources/C/include'
            headers.mkdir(parents=True); workspace = root / 'repository'; workspace.mkdir()
            arena = root / 'arena'
            plan = {'driver': {'argv': ['compiler', '-Xcc', '-I' + str(headers)]}, 'operations': {'arena': str(arena)}}
            with patch.object(build.retained, 'header_inputs', return_value={'Sources/C/include/public.h': 'a' * 64}) as bind:
                found = build.pinned_header_inputs({'production': plan}, [package], workspace)
                self.assertEqual(found, {str(headers / 'public.h'): 'a' * 64})
                bind.assert_called_once_with(package.resolve(), headers.parent, headers)
            altered = copy.deepcopy(plan); altered['driver']['argv'][-1] = '-I' + str(root / 'outside/checkouts/package/include')
            with patch.object(build.retained, 'header_inputs') as bind, self.assertRaises(ValueError):
                build.pinned_header_inputs({'production': altered}, [package], workspace)
            bind.assert_not_called()
