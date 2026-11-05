import ast
import base64
import copy
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
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

    def source_identity_fixture(self, changed=(), ancestor=True, dirty=False):
        revision = 'c' * 40
        payloads = {}
        for name in journey.TEST_INPUTS:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            content = name.encode()
            path.write_bytes(content + (b'dirty' if dirty else b''))
            relative = (journey.ROOT / name).relative_to(journey.REPOSITORY).as_posix()
            payloads[relative] = content
        for shared in journey.SHARED_INPUTS:
            payloads[shared] = (journey.REPOSITORY / shared).read_bytes()

        def output(arguments, **kwargs):
            if arguments[-1] == 'HEAD': return revision.encode()
            if 'merge-base' in arguments:
                if not ancestor: raise subprocess.CalledProcessError(1, arguments)
                return b''
            if 'diff' in arguments: return '\0'.join(changed).encode()
            if 'show' in arguments:
                commit, relative = arguments[-1].split(':', 1)
                self.assertEqual(commit, revision)
                return payloads[relative]
            self.fail('Unexpected source identity command: ' + str(arguments))

        return revision, payloads, output

    def test_retained_product_accepts_committed_independent_harness(self):
        revision, payloads, output = self.source_identity_fixture(journey.SIGNED_JOURNEY_HARNESS_PATHS)
        with patch.object(journey, 'output', side_effect=output):
            actual, fingerprints = journey.test_source_identity(self.sha, input_root=self.root)
        self.assertEqual(actual, revision)
        self.assertEqual(fingerprints, {name: hashlib.sha256(value).hexdigest() for name, value in payloads.items()})

    def test_retained_product_rejects_product_changes_and_unrelated_history(self):
        for path in ('Sources/NexGenVideo/App/NexGenVideoApp.swift', 'Package.resolved', 'scripts/bundle.sh',
                     'musicvideo/manifest.json', '.github/workflows/release.yml'):
            _, _, output = self.source_identity_fixture([path])
            with self.subTest(path=path), patch.object(journey, 'output', side_effect=output), self.assertRaises(ValueError):
                journey.test_source_identity(self.sha, input_root=self.root)
        _, _, output = self.source_identity_fixture(ancestor=False)
        with patch.object(journey, 'output', side_effect=output), self.assertRaises(subprocess.CalledProcessError):
            journey.test_source_identity(self.sha, input_root=self.root)

    def test_test_identity_rejects_uncommitted_harness_inputs(self):
        _, _, output = self.source_identity_fixture(dirty=True)
        with patch.object(journey, 'output', side_effect=output), self.assertRaises(ValueError):
            journey.test_source_identity(self.sha, input_root=self.root)
        _, payloads, output = self.source_identity_fixture()
        payloads[journey.COLOR_HELPER] = b'other committed color helper'
        with patch.object(journey, 'output', side_effect=output), self.assertRaises(ValueError):
            journey.test_source_identity(self.sha, input_root=self.root)

    def color_report(self):
        report = {'schema': 'nexgenvideo/export-color-diagnostic/1',
                  'classification': 'native-decoder-color-observation-only', 'readFailures': {},
                  'commonRec709ComparisonAvailable': True, 'commonOutputColorSpace': 'kCGColorSpaceITUR_709',
                  'nativeCommonRec709RGBMAE': 2.978622685185185, 'nativeUnmanagedRGBMAE': 15.078940972222222}
        for role, name, profile in [('source', 'GUI acceptance source.mp4', 'Composite NTSC'),
                                    ('export', 'user-export.mp4', 'HDTV')]:
            report[role] = {'filename': name, 'sampleTimeSeconds': 1, 'dimensions': [320, 180],
                            'hasEffectiveCIColorSpace': True, 'commonRec709Available': True,
                            'effectiveCIColorSpace': profile}
        return report

    def test_color_comparison_accepts_same_color_in_distinct_profiles(self):
        report = self.color_report()
        self.assertGreater(report['nativeUnmanagedRGBMAE'], 15)
        self.assertEqual(journey.color_error(report), 2.978622685185185)

    def test_color_comparison_rejects_unavailable_or_inconsistent_measurements(self):
        for key, value in [('commonRec709ComparisonAvailable', False), ('readFailures', {'source': 'missing'}),
                           ('commonOutputColorSpace', 'kCGColorSpaceSRGB'), ('schema', 'unbound'),
                           ('nativeCommonRec709RGBMAE', 15), ('nativeCommonRec709RGBMAE', -1),
                           ('nativeCommonRec709RGBMAE', float('nan')), ('nativeCommonRec709RGBMAE', float('inf')),
                           ('nativeCommonRec709RGBMAE', True)]:
            report = self.color_report()
            report[key] = value
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                journey.color_error(report)
        for role in ['source', 'export']:
            for key, value in [('sampleTimeSeconds', 0.5), ('sampleTimeSeconds', True), ('filename', 'other.mp4'),
                               ('dimensions', [1920, 1080]), ('hasEffectiveCIColorSpace', False),
                               ('commonRec709Available', False), ('effectiveCIColorSpace', '')]:
                report = self.color_report()
                report[role][key] = value
                with self.subTest(role=role, key=key), self.assertRaises(ValueError):
                    journey.color_error(report)

    def test_color_comparison_evidence_binds_helper_report_and_video_bytes(self):
        (self.root / 'GUI acceptance source.mp4').write_bytes(b'source')
        (self.root / 'user-export.mp4').write_bytes(b'export')
        (self.root / 'native-color-check').write_bytes(b'native executable')
        (self.root / 'native-color.json').write_text(json.dumps(self.color_report()))
        files = {journey.COLOR_HELPER: 'd' * 64}
        movie = {'sourceSHA256': journey.sha256(self.root / 'GUI acceptance source.mp4'),
                 'sha256': journey.sha256(self.root / 'user-export.mp4'), 'sampleTimeSeconds': 1,
                 'meanAbsoluteChannelError': 2.978622685185185, 'maximumMeanAbsoluteChannelError': 15}
        movie['colorComparison'] = {'sourceSHA256': movie['sourceSHA256'], 'exportSHA256': movie['sha256'],
                                    'helperSHA256': files[journey.COLOR_HELPER],
                                    'reportSHA256': journey.sha256(self.root / 'native-color.json'),
                                    'executableSHA256': journey.sha256(self.root / 'native-color-check')}
        journey.validate_color_evidence(self.root, movie, files)
        changed = copy.deepcopy(movie)
        changed['colorComparison'].pop('helperSHA256')
        with self.assertRaises(ValueError):
            journey.validate_color_evidence(self.root, changed, {})
        for key in movie['colorComparison']:
            changed = copy.deepcopy(movie)
            changed['colorComparison'][key] = 'e' * 64
            with self.subTest(key=key), self.assertRaises(ValueError):
                journey.validate_color_evidence(self.root, changed, files)
        for name in ['GUI acceptance source.mp4', 'user-export.mp4', 'native-color-check', 'native-color.json']:
            original = (self.root / name).read_bytes()
            (self.root / name).write_bytes(original + b'changed')
            with self.subTest(file=name), self.assertRaises(ValueError):
                journey.validate_color_evidence(self.root, movie, files)
            (self.root / name).write_bytes(original)

    def test_external_continuation_gates_mac_jobs_and_keeps_product_and_test_identity(self):
        workflow = (journey.REPOSITORY / '.github/workflows/external-gui-acceptance.yml').read_text()
        source, build = workflow.split('  test-build:\n', 1)
        binding = source.split('      - name: Bind the retained signed DMG and unchanged product inputs\n', 1)[1]
        self.assertIn("CANDIDATE_KIND: ${{ inputs.scenario == 'transport' && 'signed-transport' || 'signed-journey' }}", binding)
        self.assertIn('--candidate-kind "$CANDIDATE_KIND"', binding)
        self.assertIn('needs: cases', build)
        self.assertIn('if: inputs.product_source_sha != \'\'', source)
        self.assertIn('artifact.get(\'digest\') != \'sha256:\' + os.environ[\'ORIGINAL_DIGEST\']', workflow)
        self.assertIn('--dmg-sha256 "$EXPECTED_DMG_SHA256" --source-sha "$PRODUCT_SOURCE"', workflow)
        self.assertNotIn('bundle.sh', workflow)
        registered = (journey.REPOSITORY / '.github/workflows/diagnostic-acceptance.yml').read_text()
        entry = registered.split('  signed-journey:\n', 1)[1].split('\n  ci-bpy-resource-diagnostic:', 1)[0]
        for binding in ('needs: source', "if: inputs.candidate_kind == 'signed-journey'",
                        'uses: ./.github/workflows/external-gui-acceptance.yml', 'artifact_mode: dmg',
                        'runtime_run_id: ${{ inputs.run_id }}', 'product_source_sha: ${{ inputs.source_sha }}',
                        'runtime_artifact_id: ${{ inputs.artifact_id }}',
                        'runtime_artifact_sha256: ${{ inputs.artifact_sha256 }}',
                        'expected_dmg_sha256: ${{ inputs.expected_dmg_sha256 }}'):
            self.assertIn(binding, entry)

    def test_registered_continuation_can_produce_exact_ui_tests(self):
        run = {**self.run, 'path': '.github/workflows/diagnostic-acceptance.yml', 'event': 'workflow_dispatch'}
        bundle.require_origin(run, self.artifact, self.sha, 12)
        run['path'] = '.github/workflows/untrusted.yml'
        with self.assertRaises(ValueError):
            bundle.require_origin(run, self.artifact, self.sha, 12)
        revision, _, output = self.source_identity_fixture(['scripts/external-gui/test_bundle.py'])
        with patch.object(journey, 'output', side_effect=output):
            self.assertEqual(journey.test_source_identity(self.sha, input_root=self.root)[0], revision)

    def test_transport_input_guard_preserves_journey_and_requires_exact_complete_fixture(self):
        text = (journey.REPOSITORY / '.github/workflows/external-gui-acceptance.yml').read_text()
        step = text.split('      - name: Select independent user journeys\n', 1)[1].split('      - name:', 1)[0]
        code = step.split("          python3 - <<'PY'\n", 1)[1].split('          PY', 1)[0]
        code = '\n'.join(line[10:] for line in code.splitlines())
        defaults = {'INTERFACE_SCALE': 'all', 'ARTIFACT_MODE': 'app', 'EXPECTED_DMG_SHA256': '',
                    'TEST_BUNDLE_RUN_ID': '', 'TEST_BUNDLE_ARTIFACT_ID': '', 'TEST_BUNDLE_ARTIFACT_SHA256': '',
                    'RETAINED_SOURCE': '', 'RETAINED_RUN': '',
                    'RETAINED_ARTIFACT': '', 'RETAINED_DIGEST': '', 'SCENARIO': 'journey',
                    'VERIFIED_PR_RUN': '', 'FIXTURE_ARTIFACT': '', 'FIXTURE_SHA': ''}
        signed = {'ARTIFACT_MODE': 'dmg', 'EXPECTED_DMG_SHA256': '1' * 64,
                  'RETAINED_SOURCE': self.sha, 'RETAINED_RUN': '12', 'RETAINED_ARTIFACT': '34', 'RETAINED_DIGEST': '2' * 64}
        transport = signed | {'SCENARIO': 'transport', 'INTERFACE_SCALE': '1.5',
                              'VERIFIED_PR_RUN': '56', 'FIXTURE_ARTIFACT': '78', 'FIXTURE_SHA': '3' * 64}
        output = self.root / 'guard-output'
        for values, expected in [({}, ['1', '1.25', '1.5']), (signed, ['1', '1.25', '1.5']), (transport, ['1.5'])]:
            output.write_text('')
            result = subprocess.run([sys.executable, '-c', code], capture_output=True,
                                    env=os.environ | defaults | values | {'GITHUB_OUTPUT': str(output)})
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            self.assertEqual(json.loads(output.read_text().removeprefix('scales=')), expected)
        invalid = [transport | {key: ''} for key in ('EXPECTED_DMG_SHA256', 'RETAINED_SOURCE', 'RETAINED_RUN',
                   'RETAINED_ARTIFACT', 'RETAINED_DIGEST', 'VERIFIED_PR_RUN', 'FIXTURE_ARTIFACT', 'FIXTURE_SHA')]
        invalid += [transport | {'INTERFACE_SCALE': scale} for scale in ('all', '1', '1.25')]
        invalid += [transport | {key: value} for key, value in [('ARTIFACT_MODE', 'app'), ('SCENARIO', 'other'),
                    ('VERIFIED_PR_RUN', '0'), ('FIXTURE_ARTIFACT', '-1'), ('FIXTURE_SHA', 'invalid')]]
        invalid += [signed | {key: '1'} for key in ('FIXTURE_ARTIFACT', 'FIXTURE_SHA')]
        invalid += [{'TEST_BUNDLE_ARTIFACT_ID': '34'}, {'TEST_BUNDLE_ARTIFACT_SHA256': 'a' * 64},
                    {'TEST_BUNDLE_RUN_ID': '12', 'TEST_BUNDLE_ARTIFACT_ID': '34'},
                    {'TEST_BUNDLE_RUN_ID': '12', 'TEST_BUNDLE_ARTIFACT_ID': '0', 'TEST_BUNDLE_ARTIFACT_SHA256': 'a' * 64},
                    {'TEST_BUNDLE_RUN_ID': '12', 'TEST_BUNDLE_ARTIFACT_ID': '34', 'TEST_BUNDLE_ARTIFACT_SHA256': 'invalid'}]
        for values in invalid:
            output.write_text('')
            result = subprocess.run([sys.executable, '-c', code], capture_output=True,
                                    env=os.environ | defaults | values | {'GITHUB_OUTPUT': str(output)})
            with self.subTest(invalid=values):
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(output.read_text(), '')

    def test_independent_runner_rejects_the_observed_file_access_sandbox(self):
        products = self.root / 'Products'
        (products / 'Debug/UITests-Runner.app').mkdir(parents=True)
        entitlements = {'com.apple.security.app-sandbox': True, 'com.apple.security.network.client': True}
        with patch.object(journey, 'output', return_value=plistlib.dumps(entitlements)), self.assertRaises(ValueError):
            bundle.require_runner_access(products, self.root / 'build.log')
        self.assertIn(plistlib.dumps(entitlements), (self.root / 'build.log').read_bytes())

    def test_independent_runner_preserves_its_automation_entitlements(self):
        products = self.root / 'Products'
        (products / 'Debug/UITests-Runner.app').mkdir(parents=True)
        entitlements = {'com.apple.security.get-task-allow': True, 'com.apple.security.network.client': True}
        raw = plistlib.dumps(entitlements)
        for record in (raw, plistlib.dumps({**entitlements, 'com.apple.security.app-sandbox': False}), b''):
            with self.subTest(record=record), patch.object(journey, 'output', return_value=record) as inspect:
                bundle.require_runner_access(products, self.root / 'build.log')
            self.assertEqual(inspect.call_args.args[0][:4], ['codesign', '-d', '--entitlements', ':-'])
        self.assertIn(raw, (self.root / 'build.log').read_bytes())

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
                   'runnerEnvironment': 'self-hosted', 'platform': 'darwin', 'architecture': 'arm64',
                   'osVersion': '27.0.1', 'osBuild': '27A-test', 'runnerName': 'macrunner-test', 'jobUID': 501, 'consoleUID': 501, 'aquaSession': True,
                   'developerSecurity': 'Developer mode is currently enabled.', 'xcode': 'Xcode 27.0',
                   'desktopSHA256': journey.sha256(screenshot)}
        journey.write_json(self.root / 'runtime.json', runtime)
        journey.validate_runtime(self.root)
        journey.write_json(self.root / 'runtime.json', {**runtime, 'osVersion': '26.6.2'})
        journey.validate_runtime(self.root)
        for key, value in (('osVersion', '25.7.2'), ('osVersion', ''), ('osVersion', None),
                           ('osVersion', 'invalid.0'), ('githubActions', False), ('osBuild', ''), ('runnerName', ''), ('architecture', 'x86_64'), ('consoleUID', 0),
                           ('aquaSession', False), ('runnerEnvironment', 'github-hosted')):
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


    def compiled_client_fixture(self):
        current = 'd' * 40
        payloads = {(journey.ROOT / name).relative_to(journey.REPOSITORY).as_posix(): (journey.ROOT / name).read_bytes()
                    for name in journey.TEST_INPUTS}
        payloads.update({name: (journey.REPOSITORY / name).read_bytes() for name in journey.SHARED_INPUTS})
        files = {name: hashlib.sha256(raw).hexdigest() for name, raw in payloads.items()}
        original = dict(payloads)
        helper = 'scripts/external-gui/test_bundle.py'
        added = {'_safe_function', '_builder_view', '_workflow_build_view', '_guard_import_view',
                 '_source_snapshot', '_compiled_compatibility', 'validate_client_selectors', 'validate_client_source'}
        lines = original[helper].decode().splitlines(keepends=True)
        excluded = set()
        for node in ast.parse(original[helper]).body:
            if isinstance(node, ast.FunctionDef) and node.name in added:
                excluded.update(range(node.lineno - 1, node.end_lineno))
        original[helper] = ''.join(line for index, line in enumerate(lines) if index not in excluded).encode()
        original[helper] = original[helper].replace(b"    resolver.add_argument('--artifact-sha256')\n", b'')
        guard = 'scripts/verify_diagnostic_candidate.py'
        lines = original[guard].decode().splitlines(keepends=True)
        excluded = set()
        for node in ast.parse(original[guard]).body:
            if isinstance(node, ast.FunctionDef) and node.name == 'verify_scene_history_hierarchy':
                excluded.update(range(node.lineno - 1, node.end_lineno))
        original[guard] = ''.join(line for index, line in enumerate(lines) if index not in excluded).encode()
        workflow = '.github/workflows/external-gui-acceptance.yml'
        current_workflow = (journey.REPOSITORY / workflow).read_bytes()
        action = '.github/actions/setup-xcode-27/action.yml'
        original[action] = (journey.REPOSITORY / action).read_bytes()
        original[workflow] = re.sub(rb'(?m)^      test_bundle_artifact_(?:id|sha256):\n(?:        [^\n]+\n)+',
                                    b'', current_workflow)
        original_files = {name: hashlib.sha256(original[name]).hexdigest() for name in files}
        xctestrun = plistlib.dumps({'Test': {'TestHostPath': '__TESTROOT__/Runner.app',
            'TestBundlePath': '__TESTHOST__/Contents/PlugIns/Test.xctest'}})
        entries = [('Runner.app/Contents/PlugIns/Test.xctest/binary', 'file', b'original native client'),
                   ('Tests.xctestrun', 'file', xctestrun)]
        archive = self.archive(entries)
        products = self.root / 'original-products'
        for name, _, content in entries:
            path = products / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content)
        receipt = {'schema': 'nexgenvideo/external-tests-input/1', 'sourceSHA': self.sha,
            'testFiles': original_files, 'architecture': 'arm64', 'deploymentTarget': '26.0',
            'xcode': 'Xcode 27.2\nBuild version 27B52', 'runID': 12, 'attempt': 1,
            'archiveSHA256': journey.sha256(archive), 'productsSHA256': bundle.products_sha256(products),
            'xctestrun': 'Tests.xctestrun'}
        raw_receipt = (json.dumps(receipt, indent=2) + '\n').encode()
        transfer = self.root / 'transfer.zip'
        with zipfile.ZipFile(transfer, 'w') as handle:
            handle.write(archive, 'tests.tar.gz')
            handle.writestr('tests-input.json', raw_receipt)
        artifact = self.artifact | {'digest': 'sha256:' + journey.sha256(transfer)}
        comparison = {'base_commit': {'sha': self.sha}, 'merge_base_commit': {'sha': self.sha},
            'status': 'ahead', 'total_commits': 1, 'commits': [{'sha': current}],
            'files': [{'filename': helper, 'status': 'modified'}, {'filename': guard, 'status': 'modified'},
                      {'filename': workflow, 'status': 'modified'},
                      {'filename': 'Sources/NexGenVideo/App/NativeButtonAccessibility.swift', 'status': 'added'}]}
        history = copy.deepcopy(comparison)

        def git_output(arguments, **kwargs):
            if arguments == ['xcodebuild', '-version']: return receipt['xcode'].encode()
            if arguments[-2:] == ['rev-parse', 'HEAD']: return current.encode()
            if 'merge-base' in arguments: return history['merge_base_commit']['sha'].encode()
            if 'rev-list' in arguments: return '\n'.join(item['sha'] for item in history['commits']).encode()
            if 'diff' in arguments:
                statuses = {'added': 'A', 'modified': 'M', 'removed': 'D', 'renamed': 'R100'}
                return ''.join(statuses[item['status']] + '\0' + item['filename'] + '\0'
                               for item in history['files']).encode()
            if 'show' in arguments:
                commit, name = arguments[-1].split(':', 1)
                if commit == current and name in {workflow, action}: return (journey.REPOSITORY / name).read_bytes()
                self.assertEqual(commit, self.sha)
                return original[name]
            self.fail('Unexpected compiled-client command: ' + str(arguments))

        def api(route):
            if route == '/actions/runs/12': return copy.deepcopy(self.run)
            if route == '/actions/artifacts/34': return copy.deepcopy(artifact)
            if route.startswith('/contents/'):
                name, ref = route.removeprefix('/contents/').split('?ref=')
                self.assertEqual(ref, self.sha)
                return {'type': 'file', 'encoding': 'base64', 'content': base64.b64encode(original[name]).decode()}
            if route == '/compare/' + self.sha + '...' + current: return copy.deepcopy(comparison)
            self.fail('Unexpected compiled-client API route: ' + route)

        def download(item, destination):
            self.assertEqual(item, artifact)
            destination.write_bytes(transfer.read_bytes())

        return SimpleNamespace(current=current, files=files, original=original, original_files=original_files,
            current_workflow=current_workflow, receipt=receipt, raw_receipt=raw_receipt, artifact=artifact,
            comparison=comparison, history=history, git_output=git_output, api=api, download=download,
            destination=self.root / 'resolved')

    def resolve_compiled_fixture(self, fixture, *, artifact_id=34, digest=None):
        if digest is None: digest = fixture.artifact['digest'].removeprefix('sha256:')
        with patch.dict(os.environ, {'GITHUB_SHA': fixture.current, 'GITHUB_RUN_ID': '78',
                                    'GITHUB_OUTPUT': str(self.root / 'output')}), \
                patch.object(journey, 'test_source_identity', return_value=(fixture.current, fixture.files)), \
                patch.object(journey, 'output', side_effect=fixture.git_output), \
                patch.object(bundle, 'api', side_effect=fixture.api), \
                patch.object(bundle, 'items', side_effect=lambda route, key: [fixture.artifact] if key == 'artifacts' else [self.job]), \
                patch.object(bundle, 'download', side_effect=fixture.download):
            bundle.resolve(SimpleNamespace(run_id=12, artifact_id=artifact_id, artifact_sha256=digest,
                                           destination=str(fixture.destination)))

    def assert_compiled_guard_rejects(self, fixture, reason):
        files = {name: hashlib.sha256(fixture.original[name]).hexdigest() for name in fixture.files}
        with patch.object(journey, 'output', side_effect=fixture.git_output), self.assertRaisesRegex(ValueError, reason):
            bundle._compiled_compatibility(self.sha, files, fixture.current, fixture.files,
                                            fixture.original, fixture.comparison)

    def test_compiled_client_reuse_preserves_original_receipt_products_and_producer(self):
        fixture = self.compiled_client_fixture()
        self.resolve_compiled_fixture(fixture)
        self.assertEqual((fixture.destination / 'tests-input.json').read_bytes(), fixture.raw_receipt)
        producer = journey.read_json(fixture.destination / 'tests-producer.json')
        proof = producer['compiledCompatibility']
        self.assertEqual(proof['producerSourceSHA'], self.sha)
        self.assertEqual(proof['consumerSourceSHA'], fixture.current)
        self.assertEqual(proof['producerFiles'], fixture.original_files)
        self.assertEqual(proof['consumerFiles'], fixture.files)
        self.assertEqual(producer['run'], self.run)
        self.assertEqual(producer['job'], self.job)
        with patch.object(journey, 'output', side_effect=fixture.git_output):
            xctestrun, receipt = bundle.consume(fixture.destination, self.root / 'consumed', fixture.current, fixture.files)
            self.assertEqual(receipt, fixture.receipt)
            self.assertEqual((xctestrun.parent / 'Runner.app/Contents/PlugIns/Test.xctest/binary').read_bytes(),
                             b'original native client')
            self.assertEqual(bundle.products_sha256(xctestrun.parent), fixture.receipt['productsSHA256'])
            self.assertEqual(bundle.verify_input(fixture.destination, fixture.current, fixture.files), fixture.receipt)

    def test_client_selectors_require_positive_complete_immutable_identity(self):
        for values in [('', '', ''), ('12', '', ''), ('12', '34', 'a' * 64)]:
            bundle.validate_client_selectors(*values)
        for values in [('0', '', ''), ('-1', '', ''), ('12', '0', 'a' * 64), ('', '34', 'a' * 64),
                       ('12', '34', ''), ('12', '', 'a' * 64), ('12', '34', 'z' * 64), ('12', '34', 'a' * 63)]:
            with self.subTest(values=values), self.assertRaises(ValueError):
                bundle.validate_client_selectors(*values)
        bundle.validate_client_selectors('12', '34', '', require_pair=False)

    def test_client_run_only_selector_rejects_different_source_before_mac_allocation(self):
        with patch.object(bundle, 'api', return_value=self.run) as api:
            bundle.validate_client_source('12', '', '', self.sha)
            with self.assertRaises(ValueError):
                bundle.validate_client_source('12', '', '', 'd' * 40)
            self.assertEqual(api.call_count, 2)
        with patch.object(bundle, 'api') as api:
            bundle.validate_client_source('12', '34', 'a' * 64, 'd' * 40)
            bundle.validate_client_source('', '', '', self.sha)
            api.assert_not_called()
        with patch.object(bundle, 'api', return_value={**self.run, 'repository': {'full_name': 'other/repository'}}), \
                self.assertRaises(ValueError):
            bundle.validate_client_source('12', '', '', self.sha)

    def test_compiled_client_reuse_rejects_missing_or_wrong_pins_before_download(self):
        fixture = self.compiled_client_fixture()
        for artifact_id, digest in [(None, ''), (34, ''), (34, 'e' * 64)]:
            with self.subTest(artifact_id=artifact_id, digest=digest), self.assertRaises(ValueError):
                self.resolve_compiled_fixture(fixture, artifact_id=artifact_id, digest=digest)
            self.assertFalse(fixture.destination.exists())
            self.assertFalse((self.root / 'external-tests-transfer.zip').exists())

    def test_compiled_client_reuse_rejects_changed_swift_project_and_shared_inputs(self):
        fixture = self.compiled_client_fixture()
        for name in fixture.original_files:
            if name in {'scripts/external-gui/test_bundle.py', 'scripts/external-gui/transport.py',
                        'scripts/release_engine_resume.py', 'scripts/verify_diagnostic_candidate.py'}: continue
            original = fixture.original[name]
            fixture.original[name] += b'\nchanged compilation input'
            with self.subTest(input=name):
                self.assert_compiled_guard_rejects(fixture, 'Compiled UI test source, project or reachable shared helper changed')
            fixture.original[name] = original

    def test_compiled_client_reuse_rejects_changed_builder_imports_constants_and_cli(self):
        fixture = self.compiled_client_fixture()
        helper = 'scripts/external-gui/test_bundle.py'
        original = fixture.original[helper]
        for changed in [original.replace(b"'ARCHS=arm64'", b"'ARCHS=x86_64'"), b'import altered_build_tool\n' + original,
                        original.replace(b"ARTIFACT = 'external-gui-tests'", b"ARTIFACT = 'different-tests'"),
                        original.replace(b"builder.add_argument('--destination', required=True)",
                                         b"builder.add_argument('--destination', required=False)")]:
            self.assertNotEqual(changed, original)
            fixture.original[helper] = changed
            self.assert_compiled_guard_rejects(fixture, 'UI test build closure, imports or constants changed')
        fixture.original[helper] = original

    def test_compiled_client_reuse_rejects_consumer_import_side_effects(self):
        fixture = self.compiled_client_fixture()
        helper = 'scripts/external-gui/test_bundle.py'
        original = fixture.original[helper]
        for declaration in [b'@change_module\ndef resolve(args):', b'def resolve(args=change_module()):',
                            b'def resolve(args: change_module()):', b'def resolve(args) -> change_module():']:
            fixture.original[helper] = original.replace(b'def resolve(args):', declaration)
            self.assertNotEqual(fixture.original[helper], original)
            self.assert_compiled_guard_rejects(fixture, 'Compatibility (declaration|default|annotation)')
        fixture.original[helper] = original

    def test_shared_builder_import_allows_only_unused_lazy_function_additions(self):
        original = 'import os as platform\nVALUE = 1\ndef build():\n    return VALUE\n'
        allowed = original + 'def extra_role(*args, **kwargs):\n    from unexecuted_role import run\n    return run(*args, **kwargs)\n'
        self.assertEqual(bundle._guard_import_view(original, allowed), bundle._guard_import_view(original, original))
        for changed in [original.replace('VALUE = 1', 'VALUE = 2'), original + 'import unexpected\n',
                        original + 'VALUE = 3\n', original + 'extra_role()\n',
                        original + 'def platform():\n    pass\n', original + 'def build():\n    pass\n',
                        original + '@execute\ndef extra_role():\n    pass\n',
                        original + 'def extra_role(value=execute()):\n    pass\n',
                        original + 'def extra_role(value: execute()):\n    pass\n',
                        original + 'def __getattr__(name):\n    raise RuntimeError("import side effect")\n',
                        original + 'def __dir__():\n    return []\n']:
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                bundle._guard_import_view(original, changed)

    def test_compiled_client_reuse_rejects_changed_local_xcode_action(self):
        fixture = self.compiled_client_fixture()
        fixture.original['.github/actions/setup-xcode-27/action.yml'] += b'\n    - run: changed_compiler_setup\n'
        self.assert_compiled_guard_rejects(fixture, 'UI test Xcode setup action changed')

    def test_compiled_client_reuses_with_different_unexecuted_engine_qualification_bytes(self):
        fixture = self.compiled_client_fixture()
        name = 'scripts/release_engine_resume.py'
        fixture.original[name] += b'\ndef old_native_qualification():\n    return "original"\n'
        fixture.original_files[name] = hashlib.sha256(fixture.original[name]).hexdigest()
        change = {'filename': name, 'status': 'modified'}
        fixture.comparison['files'].append(change)
        fixture.history['files'].append(dict(change))
        with patch.object(journey, 'output', side_effect=fixture.git_output):
            proof = bundle._compiled_compatibility(self.sha, fixture.original_files, fixture.current,
                                                   fixture.files, fixture.original, fixture.comparison)
        self.assertNotEqual(proof['producerFiles'][name], proof['consumerFiles'][name])
        self.assertEqual(proof['originalSources'][name].encode(), fixture.original[name])

    def test_compiled_client_workflow_keeps_global_defaults_and_actual_build_job(self):
        workflow = (journey.REPOSITORY / '.github/workflows/external-gui-acceptance.yml').read_text()
        before = re.sub(r'(?m)^      test_bundle_artifact_(?:id|sha256):\n(?:        [^\n]+\n)+', '', workflow)
        self.assertEqual(bundle._workflow_build_view(before), bundle._workflow_build_view(workflow))
        for old, new in [('runs-on: macrunner', 'runs-on: other-runner'),
                         ('python3 scripts/external-gui/test_bundle.py build', 'python3 changed_builder.py build'),
                         ('contents: read', 'contents: write')]:
            changed = workflow.replace(old, new)
            self.assertNotEqual(changed, workflow)
            self.assertNotEqual(bundle._workflow_build_view(changed), bundle._workflow_build_view(workflow))
        changed = workflow.replace("      test_bundle_artifact_id:\n        description:",
                                   "      test_bundle_artifact_id:\n        default: '34'\n        description:", 1)
        self.assertNotEqual(changed, workflow)
        with self.assertRaises(ValueError): bundle._workflow_build_view(changed)

    def test_compiled_client_reuse_rejects_incomplete_or_renamed_source_graph(self):
        fixture = self.compiled_client_fixture()
        original = copy.deepcopy(fixture.comparison)
        for key, value in [('total_commits', 2), ('status', 'diverged'), ('files', []),
                           ('merge_base_commit', {'sha': 'f' * 40}), ('commits', [{'sha': 'f' * 40}])]:
            fixture.comparison[key] = value
            with self.subTest(key=key): self.assert_compiled_guard_rejects(fixture, 'ancestor|graph|comparison')
            fixture.comparison = copy.deepcopy(original)
        fixture.comparison['files'][0]['previous_filename'] = 'renamed-client.py'
        self.assert_compiled_guard_rejects(fixture, 'comparison')
        fixture.comparison = copy.deepcopy(original)
        fixture.history['files'][0]['status'] = 'renamed'
        self.assert_compiled_guard_rejects(fixture, 'status inventory')

    def test_compiled_client_posthoc_rejects_altered_proof_and_consumer_wrong_xcode(self):
        fixture = self.compiled_client_fixture()
        self.resolve_compiled_fixture(fixture)
        path = fixture.destination / 'tests-producer.json'
        producer = journey.read_json(path)
        for mutation in ['missing', 'consumer', 'recipe', 'original']:
            changed = copy.deepcopy(producer)
            if mutation == 'missing': changed.pop('compiledCompatibility')
            elif mutation == 'consumer': changed['compiledCompatibility']['consumerSourceSHA'] = 'f' * 40
            elif mutation == 'recipe': changed['compiledCompatibility']['buildRecipeSHA256'] = 'f' * 64
            else: changed['compiledCompatibility']['originalSources']['scripts/external-gui/project.yml'] += '\nchanged'
            journey.write_json(path, changed)
            with self.subTest(mutation=mutation), patch.object(journey, 'output', side_effect=fixture.git_output), \
                    self.assertRaises(ValueError):
                bundle.verify_input(fixture.destination, fixture.current, fixture.files)
        journey.write_json(path, producer)
        def changed_xcode(arguments, **kwargs):
            if arguments == ['xcodebuild', '-version']: return b'Xcode 27.2\nBuild version other'
            return fixture.git_output(arguments, **kwargs)
        with patch.object(journey, 'output', side_effect=changed_xcode), self.assertRaisesRegex(ValueError, 'actual Xcode'):
            bundle.consume(fixture.destination, self.root / 'wrong-xcode', fixture.current, fixture.files)
        self.assertFalse((self.root / 'wrong-xcode').exists())

    def test_client_artifact_selectors_reach_release_consumer_and_pre_mac_source_guard(self):
        release = (journey.REPOSITORY / '.github/workflows/release.yml').read_text()
        external = (journey.REPOSITORY / '.github/workflows/external-gui-acceptance.yml').read_text()
        for name in ['test_bundle_artifact_id', 'test_bundle_artifact_sha256']:
            self.assertIn(name + ': ${{ inputs.' + name + ' }}', release)
            self.assertEqual(external.count('      ' + name + ':\n'), 2)
        for workflow in [release, external]:
            self.assertIn('validate_client_source(', workflow)
        self.assertIn('TEST_CLIENT_SHA256:', release)
        self.assertIn('TEST_BUNDLE_ARTIFACT_SHA256:', external)
        source, rest = external.split('  test-build:\n', 1)
        self.assertIn('validate_client_source(', source)
        self.assertIn('needs: cases', rest)
        self.assertIn('--artifact-sha256 "$TEST_BUNDLE_ARTIFACT_SHA256"', rest)
        runtime = rest.split('  test-runtime:\n', 1)[1].split('  acceptance:\n', 1)[0]
        self.assertIn('fetch-depth: 0', runtime)


if __name__ == '__main__':
    unittest.main()
