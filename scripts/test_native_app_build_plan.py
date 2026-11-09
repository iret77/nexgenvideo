import copy
import hashlib
import json
from pathlib import Path
import unittest

import native_app_build_plan as plan


class NativeAppBuildPlanTests(unittest.TestCase):
    def inputs(self):
        return {'KIND': 'native-app-build-plan', 'PRODUCER_RUN': '401', 'PRODUCER_SHA': 'a' * 40,
            'DIAGNOSTIC_ID': '501', 'DIAGNOSTIC_DIGEST': 'b' * 64, 'VERIFIED_PR': '601',
            'PRODUCT_SHA': 'c' * 40, 'SCALE': '1'}

    def test_source_selectors_are_complete_and_do_not_ignore_other_runtime_roles(self):
        self.assertEqual(plan.validate_inputs(self.inputs()), {'runID': 401, 'sourceSHA': 'a' * 40,
            'artifactID': 501, 'artifactSHA256': 'b' * 64, 'verifiedPRRunID': 601, 'appSourceSHA': 'c' * 40})
        for key in ('PRODUCER_RUN', 'PRODUCER_SHA', 'DIAGNOSTIC_ID', 'DIAGNOSTIC_DIGEST', 'VERIFIED_PR', 'PRODUCT_SHA'):
            values = self.inputs(); values[key] = ''
            with self.subTest(missing=key), self.assertRaises(ValueError): plan.validate_inputs(values)
        for key in ('FAILURE_ID', 'EXTRA_PRODUCTS', 'DMG_DIGEST', 'RUNTIME_FAILURE_BINDING', 'PACKAGING_PRODUCER_SOURCE'):
            values = self.inputs(); values[key] = 'unexpected'
            with self.subTest(ignored=key), self.assertRaises(ValueError): plan.validate_inputs(values)

    def test_metadata_process_environment_excludes_credentials_and_rejects_ambient_override(self):
        env = {'PATH': '/tools', 'HOME': '/home/worker', 'GH_TOKEN': 'secret', 'ACTIONS_RUNTIME_TOKEN': 'secret', 'NO_COLOR': ''}
        self.assertEqual(plan.probe_environment(env), {'PATH': '/tools', 'HOME': '/home/worker', 'NO_COLOR': ''})
        for key in ('XCODE_XCCONFIG_FILE', 'SWIFT_EXEC', 'CC', 'CXX', 'TOOLCHAINS'):
            with self.subTest(key=key), self.assertRaises(ValueError): plan.probe_environment(dict(env, **{key: 'ambient'}))

    def test_production_and_testable_contexts_preserve_swiftpm_flag_forwarding(self):
        production, testable = plan.settings('production', False), plan.settings('testable', True)
        self.assertEqual(production['OTHER_SWIFT_FLAGS'], '$(inherited)')
        self.assertEqual(testable['OTHER_SWIFT_FLAGS'], '$(inherited) -enable-testing')
        self.assertEqual(testable['OTHER_LDFLAGS_SWIFTC_LINKER_DRIVER_swiftc'], '$(inherited) -enable-testing')
        self.assertEqual(production['OTHER_LDFLAGS'], '$(inherited) $(OTHER_LDFLAGS_SWIFTC_LINKER_DRIVER_$(LINKER_DRIVER))')
        self.assertEqual([production['COLOR_DIAGNOSTICS'], testable['COLOR_DIAGNOSTICS']], ['NO', 'YES'])
        for values in (production, testable):
            self.assertEqual(values['GENERATE_TEST_ENTRYPOINTS_FOR_BUNDLES'], 'YES')
            self.assertEqual(values['ONLY_ACTIVE_ARCH'], 'YES')
            self.assertEqual(values['STRIP_INSTALLED_PRODUCT'], 'NO')
            for key in ('ENABLE_TESTABILITY', 'DEBUG_INFORMATION_FORMAT', 'SWIFT_OPTIMIZATION_LEVEL', 'LLVM_LTO'):
                self.assertNotIn(key, values)

    def test_request_binds_target_parameters_and_owned_arena_without_postload_cli_override(self):
        request = plan.build_request('testable', 'actual-test-guid', Path('/owned/testable'), Path('/sdk'), 'measured-toolchain', False)
        self.assertEqual(request['configuredTargets'], [{'guid': 'actual-test-guid', 'parameters': request['parameters']}])
        self.assertEqual(request['parameters']['configurationName'], 'Release')
        self.assertEqual(request['parameters']['arenaInfo']['buildProductsPath'], '/owned/testable/Products')
        self.assertEqual(request['parameters']['activeRunDestination']['targetArchitecture'], 'arm64')
        self.assertEqual(request['buildCommand'], {'command': 'build', 'style': 'buildOnly', 'skipDependencies': False})
        self.assertEqual(request['schedulerLaneWidthOverride'], 1)
        self.assertFalse(request['useDryRun'])
        with self.assertRaises(ValueError): plan.build_request('debug', 'actual-test-guid', Path('/owned'), Path('/sdk'), 't', False)
        with self.assertRaises(ValueError): plan.build_request('production', 'guid', Path('relative'), Path('/sdk'), 't', False)

    def test_unique_actual_pif_products_are_required_instead_of_substring_or_all_target_fallback(self):
        pif = [{'type': 'target', 'contents': {'name': 'NexGenVideo-product', 'guid': 'prod'}},
            {'type': 'target', 'contents': {'name': 'NexGenVideoTests-product', 'guid': 'tests'}},
            {'type': 'target', 'contents': {'name': 'NexGenVideo-actual-hash-testable', 'guid': 'never-guess'}}]
        self.assertEqual(plan.target_guids(pif), {'production': 'prod', 'testable': 'tests'})
        for value in (pif[:1], pif + [copy.deepcopy(pif[0])], [{'type': 'target', 'contents': {'name': 'NexGenVideo', 'guid': 'wrong'}}]):
            with self.subTest(pif=value), self.assertRaises(ValueError): plan.target_guids(value)

    def test_declared_plugin_target_or_usage_cannot_enter_description_only_probe(self):
        packages = [{'targets': [{'name': 'regular', 'type': 'regular', 'pluginUsages': []}]} for _ in range(19)]
        plan.no_plugins(packages)
        for plugin in ({'type': 'plugin'}, {'type': 'regular', 'pluginUsages': ['generator']}):
            changed = copy.deepcopy(packages); changed[9]['targets'].append(plugin)
            with self.subTest(plugin=plugin), self.assertRaises(ValueError): plan.no_plugins(changed)
        with self.assertRaises(ValueError): plan.no_plugins(packages[:18])

    def test_incomplete_or_empty_description_cannot_become_captured_plan(self):
        self.assertEqual(plan.planned_commands({'commands': {'driver': {'args': ['actual-driver']}}}),
            {'driver': {'args': ['actual-driver']}})
        for value in ({}, {'commands': {}}, {'commands': []}):
            with self.subTest(value=value), self.assertRaises(ValueError): plan.planned_commands(value)

    def test_profile_namespace_rejects_unreviewed_context_and_nonboolean_color(self):
        for profile, color in (('debug', False), ('production', 'YES'), ('testable', 1)):
            with self.subTest(profile=profile, color=color), self.assertRaises(ValueError): plan.settings(profile, color)

    def test_actual_path_arguments_round_trip_both_complete_requests(self):
        for profile in ('production', 'testable'):
            with self.subTest(profile=profile):
                request = plan.build_request(profile, 'measured-guid', Path('/owned/arena'),
                    Path('/SDKs/MacOSX.sdk'), 'measured-toolchain', False)
                raw = json.dumps(request, allow_nan=False)
                decoded = json.loads(raw)
                self.assertEqual(decoded, request)
                self.assertEqual(decoded['parameters']['activeRunDestination']['sdk'], '/SDKs/MacOSX.sdk')
                self.assertEqual(decoded['configuredTargets'][0]['parameters'], decoded['parameters'])

    def test_resume_selectors_require_matching_complete_artifact_pair_in_both_callers(self):
        for keys in (('EXTRA_FAILURE', 'EXTRA_FAILURE_SHA'), ('FAILURE_ID', 'FAILURE_DIGEST')):
            values = self.inputs(); values.update({keys[0]: '701', keys[1]: 'd' * 64})
            self.assertEqual(plan.validate_inputs(values)['resumeArtifactID'], 701)
            self.assertEqual(plan.validate_inputs(values)['resumeArtifactSHA256'], 'd' * 64)
            for key in keys:
                incomplete = dict(values); incomplete[key] = ''
                with self.subTest(missing=key), self.assertRaises(ValueError): plan.validate_inputs(incomplete)
        conflict = self.inputs(); conflict.update(EXTRA_FAILURE='701', EXTRA_FAILURE_SHA='d' * 64,
            FAILURE_ID='702', FAILURE_DIGEST='d' * 64)
        with self.assertRaises(ValueError): plan.validate_inputs(conflict)
        conflict['FAILURE_ID'] = '701'; conflict['FAILURE_DIGEST'] = 'e' * 64
        with self.assertRaises(ValueError): plan.validate_inputs(conflict)

    def test_retained_metadata_requires_complete_exact_graph_pif_and_original_context(self):
        def raw(value): return json.dumps(value).encode()
        packages = [{'targets': [{'type': 'regular', 'pluginUsages': []} for _ in range(146)],
            'packageKind': {'root': ['/owned/source']}}]
        packages += [{'targets': [{'type': 'regular', 'pluginUsages': []}]} for _ in range(18)]
        pins = [{'identity': 'pin-' + str(i), 'revision': 'a' * 40,
            'metadataSHA256': hashlib.sha256(raw(packages[i + 1])).hexdigest()} for i in range(18)]
        graph = {'packages': packages, 'pins': pins, 'buildToolPlugins': 0,
            'localEngineManifestSHA256': plan.MANIFEST_HASHES['Engine/Package.swift']}
        pif = [{'type': 'project', 'contents': {'projectDirectory': '/owned/source'}},
            {'type': 'target', 'contents': {'name': 'NexGenVideo-product', 'guid': 'prod'}},
            {'type': 'target', 'contents': {'name': 'NexGenVideoTests-product', 'guid': 'tests'}}]
        labels = ['developer', 'compiler', 'sdk', 'xcode', 'swift', 'os', 'architecture', 'sdk-version',
            'find-swbuild', 'console-help-1', 'console-version', 'resolve', 'package-root']
        labels += ['package-' + str(i) for i in range(18)] + ['production-pif']
        files = {'pinned-graph.json': raw(graph), 'package-root.stdout': raw(packages[0]),
            'production/workspace.pif': raw(pif), 'production-pif.stdout': raw(pif),
            'resolve.argv.json': raw(['swift', 'package', '--cache-path', '/owned/cache', '--scratch-path', '/owned/prior', 'resolve']),
            'commands.json': raw([{'label': label, 'exitCode': 72 if label == 'find-swbuild' else 0} for label in labels]),
            'toolchain.json': raw({'developer': '/Xcode/Developer', 'compiler': '/Xcode/swiftc', 'compilerSHA256': 'a' * 64,
                'sdk': '/Xcode/SDK', 'toolchainID': 'measured', 'console': '/Xcode/swbuild', 'consoleSHA256': 'b' * 64,
                'NO_COLOR_present': False, 'appCompilerProducts': 0, 'printedJobsExecuted': False})}
        files.update({'package-' + str(i) + '.stdout': raw(packages[i + 1]) for i in range(18)})
        snapshot = plan.metadata_snapshot(files)
        self.assertEqual(snapshot['workspace'], '/owned/source')
        self.assertEqual(snapshot['scratch'], '/owned/prior')
        self.assertEqual(snapshot['productionPIFSHA256'], hashlib.sha256(raw(pif)).hexdigest())
        for name in ('production/workspace.pif', 'package-8.stdout', 'toolchain.json', 'resolve.argv.json'):
            broken = dict(files); broken.pop(name)
            with self.subTest(missing=name), self.assertRaises(ValueError): plan.metadata_snapshot(broken)
        for name in ('result.json', 'production-description.argv.json', 'testable/workspace.pif'):
            broken = dict(files); broken[name] = b'{}'
            with self.subTest(unreviewed_stage=name), self.assertRaises(ValueError): plan.metadata_snapshot(broken)
        for key, value in (('buildToolPlugins', 1), ('localEngineManifestSHA256', '0' * 64)):
            broken = dict(files); changed = copy.deepcopy(graph); changed[key] = value; broken['pinned-graph.json'] = raw(changed)
            with self.subTest(graph_field=key), self.assertRaises(ValueError): plan.metadata_snapshot(broken)
        broken = dict(files); broken['production-pif.stdout'] = b'[]'
        with self.assertRaises(ValueError): plan.metadata_snapshot(broken)
        broken = dict(files); changed = copy.deepcopy(packages[0]); changed['packageKind']['root'] = ['/other/source']
        altered = copy.deepcopy(graph); altered['packages'][0] = changed
        broken.update({'pinned-graph.json': raw(altered), 'package-root.stdout': raw(changed)})
        with self.assertRaises(ValueError): plan.metadata_snapshot(broken)
