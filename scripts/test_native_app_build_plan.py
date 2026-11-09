import copy
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
