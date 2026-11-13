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

    def test_gui_source_guard_accepts_only_the_exact_component_evidence_repair(self):
        packaging = journey.retained_packaging
        record = {'producerSourceSHA': 'b' * 40, 'runID': 70}
        gap = dict(packaging.COMPONENT_CAPTURE_GAP, recordSHA256=hashlib.sha256(packaging.encoded(record)).hexdigest())
        for variant in ('exact', 'unrelated-proof', 'native-change', 'custom-scope', 'broken-proof'):
            paths = ['scripts/retained_packaging.py']
            if variant == 'native-change': paths += ['Sources/NexGenVideo/App/AppDelegate.swift']
            revision, _, output = self.source_identity_fixture(paths)
            parent = record | ({'runID': 71} if variant == 'unrelated-proof' else {})
            options = {'allowed_paths': set()} if variant == 'custom-scope' else {}
            with self.subTest(variant=variant), patch.object(journey, 'output', side_effect=output), \
                    patch.object(packaging, 'COMPONENT_CAPTURE_GAP', gap), \
                    patch.object(packaging, 'consumer_record', return_value=parent) as proof:
                if variant == 'broken-proof': proof.side_effect = ValueError('Invalid canonical proof')
                if variant in {'exact', 'custom-scope'}:
                    self.assertEqual(journey.test_source_identity(self.sha, input_root=self.root,
                                     packaging={'canonical': 'selectors'}, **options)[0], revision)
                else:
                    with self.assertRaises(ValueError):
                        journey.test_source_identity(self.sha, input_root=self.root, packaging={'canonical': 'selectors'}, **options)

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
                 '_source_snapshot', '_compiled_compatibility', 'validate_client_selectors', 'validate_client_source',
                 '_packaging_import_view', '_metadata_api_import_view'}
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
        cohort = 'scripts/fixtures/app-cohort.json'
        original_cohort = json.loads(original[cohort])
        original_cohort['ciPaths'].remove('.github/workflows/bpy-runtime-acceptance.yml')
        original[cohort] = (json.dumps(original_cohort, indent=2, sort_keys=True) + '\n').encode()
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
                      {'filename': cohort, 'status': 'modified'},
                      {'filename': '.github/workflows/bpy-runtime-acceptance.yml', 'status': 'modified'},
                      {'filename': workflow, 'status': 'modified'},
                      {'filename': 'Sources/NexGenVideo/App/NativeButtonAccessibility.swift', 'status': 'added'}]}
        history = copy.deepcopy(comparison)

        def git_output(arguments, **kwargs):
            if arguments == ['xcodebuild', '-version']: return receipt['xcode'].encode()
            if arguments[-2:] == ['rev-parse', 'HEAD']: return current.encode()
            if 'rev-parse' in arguments and arguments[-1].endswith('^{tree}'):
                declarations = [json.loads(original[cohort]), json.loads((journey.REPOSITORY / cohort).read_bytes())]
                matches = [item['appTreeSHA'] for item in declarations if item['appSourceSHA'] == arguments[-1].removesuffix('^{tree}')]
                self.assertEqual(len(matches), 1)
                return matches[0].encode()
            if 'merge-base' in arguments: return history['merge_base_commit']['sha'].encode()
            if 'rev-list' in arguments: return '\n'.join(item['sha'] for item in history['commits']).encode()
            if 'diff' in arguments:
                statuses = {'added': 'A', 'modified': 'M', 'removed': 'D', 'renamed': 'R100'}
                return ''.join(statuses[item['status']] + '\0' + item['filename'] + '\0'
                               for item in history['files']).encode()
            if 'show' in arguments:
                commit, name = arguments[-1].split(':', 1)
                if commit == current and name in {workflow, action, cohort, 'scripts/fixtures/app-cohort-native-inventory.json',
                        'scripts/compiled_app_release.py', 'scripts/retained_packaging.py', 'scripts/retained_app_test_products.py',
                        'scripts/app_cohort_v2.py', 'scripts/release_checkpoint.py', 'scripts/compiled_current_core_reuse.py'}: return (journey.REPOSITORY / name).read_bytes()
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
            destination=self.root / 'resolved', archive=archive, transfer=transfer)

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

    def test_real_gui968_receipt_accepts_complete_current_verifier_closure(self):
        receipt = {'architecture': 'arm64',
         'archiveSHA256': '6ca373fd9df6bc478d15dfa5be6588cc1a05edd0fdf2b86e517fdaf1361f4663',
         'attempt': 1,
         'deploymentTarget': '26.0',
         'productsSHA256': '25a48374f86f2fcb070cdd4cea71c53cafb40b7d61ec1ba63fa08bd2e62b6540',
         'runID': 42997728675,
         'schema': 'nexgenvideo/external-tests-input/1',
         'sourceSHA': 'a5e000031bcdedcf6df8053e1fc7356a6329e399',
         'testFiles': {'scripts/app_cohort_v2.py': 'd7d45f3ea2e83f2f57c51925db68d613d0b41b3b883662629bc12336947a0e6e',
                       'scripts/app_host_zombie_diagnostic.py': '44836e759a5cbb246debd67888e2ca4c09516da401be8f8d866d63ad1d6072c5',
                       'scripts/app_release_v2.py': '7f8036d85363cdccd7d2c851df8ceb319878083126d7e62abc8511a0747024c5',
                       'scripts/compiled_app_release.py': '3c62229573b4a9bad3960d67c6b9edf2bd1aeab02f2b6bfcb507444879f0dfa2',
                       'scripts/compiled_component_reuse.py': '1310cfc9835de4dde40806c4d2fa38500fdc70116357b6d50b6484df2049a32a',
                       'scripts/compiled_core_reuse.py': '77111b3998be66d1b7944607a8da2667dfe6f44ff136adf5fa089527528a01e6',
                       'scripts/compiled_xctest_reuse.py': '3615f1f6946f54f6a5a937d2a8b21c7e63c2bc09571b17fea4983c998c44c429',
                       'scripts/consume_bpy_distributable_source.py': '1da85daacb99a196a0badbdbbb7c85ea2708beebf4b926a3a637485f0a383619',
                       'scripts/export_color_diagnostic.swift': 'b169fb1f8593348a9237896cf3e77a76eb674291206e2d65ecb91e3ab199f1a5',
                       'scripts/external-gui/NexGenVideoExternalUITests/UserJourneyTests.swift': '91ca32e8cc2b2938917e715fe790c290711f4d60d5144b9c8b927b4f93eaea1a',
                       'scripts/external-gui/acceptance.py': '9b04413c4c238d59868121d57d963159c27951df2bbee3abd4811f3c7b760a42',
                       'scripts/external-gui/project.yml': '2844e486bf846aa8a1d90b303fb381811393ed056b71ae06a9cf8def8af61993',
                       'scripts/external-gui/test_bundle.py': '4d1baa2c7c6fd50af19bb81ccfabd583c45d27b8037b6ca71c8fc7db66c6d1f4',
                       'scripts/external-gui/transport.py': 'b0b4d8718343f63a110c7d11ed0f822a21f010255eb90e1249dcbf6dde1753ec',
                       'scripts/fixtures/app-cohort-native-inventory.json': '1fdbbeb8cc06ffb6f78b34d77384c3db364cc322c1cf08e0046268f3cb9dfd86',
                       'scripts/fixtures/app-cohort.json': '2537b36eda679ca02c538590d5ce8029af2e4415047d808b5ee0d62b55fffe30',
                       'scripts/fixtures/compiled-app-native-inventory.json': '6956a5c338508810a22d7ee4c5ec04adc3f45172c99e329db16f8516c31ed718',
                       'scripts/fixtures/compiled-core-reuse-886.json': 'e8d290a0be18ce7a4fe3527439cfa537f30b951ec197df974844e119c921fe5a',
                       'scripts/fixtures/native-test-entry-point.json': 'bf0ba13f904c7486e202bfe74f600c19d3952f488de4dc20568bfa1747239f8d',
                       'scripts/native_app_build_plan.py': '4e89c8a78b21641a5158a78910fdac7ca0c268329b13db528e1abc4bba9d4085',
                       'scripts/native_app_target_build.py': '92841ec6f76ee02cbf64c9b0be526756b478ed349255fee764a726d95fb7ea78',
                       'scripts/native_app_target_recipe.py': '6a15a75e99d40ec2363f157d0a04a9a0ae01dab902338c6b9e3b18e6cc16c7ac',
                       'scripts/native_current_cohort.py': '5677bd5e91c46e9beffb079173038fa04752efad6df6d2bb7f16bc7ec84f9532',
                       'scripts/native_xctest_host.m': 'ab9cf2bb2af7bbc3f2acaa475b0691c6402aa8dedf49cca6b37ce6d17fcdbe32',
                       'scripts/native_xctest_host.py': 'ee1e326569ab4a32fdf4b26fa75f5a6f0f597f5af3c7ae70eea4acda7efcda5b',
                       'scripts/notary_continuation.py': '2a29d1fbfc924379c41642e1f7631ff71a8801fbf1dddb9575db6a50fac6cc8b',
                       'scripts/release_acceptance_identity.py': 'fae86f57919724997330bd6290f41d605ad72fa1a8243d0324a70d3684da8dbb',
                       'scripts/release_checkpoint.py': '1dfbebcc878e52cce86ff0a7f27c7e659be3a3dac9cea639cf377a39d2d93131',
                       'scripts/release_engine_resume.py': '9a8f414e1500b691530eebdb6b43efdb13183bae47cf0b81240bf321e9ada868',
                       'scripts/release_native_proof.py': '8d3760e821819baa8df62f1a6c4767be652e8207cffed4c3842a883a1894cf89',
                       'scripts/release_test_repair.py': 'dea4fc68ec90deb21c40fe91b720cd62ec1a5efd6054ff235aceabe2d4aa8465',
                       'scripts/retained_app_test_products.py': '1dee490749badfbdc3e4539dd7eee8ad52e2f1f2a8e08bc646c935b9ec9e1326',
                       'scripts/retained_packaging.py': 'd50289efd7eb8ad044afc03b9e54a2dcb6ea3dbc8fb5aaecb657c5cfc3b2fc8c',
                       'scripts/run_macos_tests.py': '50266510da3cc8f81509291a7b1b7065b5cc908732157069d6cc1e0401afe69e',
                       'scripts/verified_pr_source_checks.py': '380ab90d18f9ba8c8f4b338051017515c5ffcbf141375b189a94147978cb7f61',
                       'scripts/verify_diagnostic_candidate.py': '56fe0390e9548296f2cadfb6acf3a3ce52b4fc987f5e0903c95108d9e6df0f7d',
                       'scripts/verify_swift_test_output.py': '8e7106ff980ea72829bc42c36e790e0418071297142d1314c65d631ecfa5382a'},
         'xcode': 'Xcode 27.2\nBuild version 27B52',
         'xctestrun': 'NexGenVideoExternalGUI_macosx27.2-arm64.xctestrun'}
        producer = receipt['sourceSHA']
        git = ['git', '-C', str(journey.REPOSITORY)]
        def output(*args):
            return subprocess.check_output([*git, *args], stdin=subprocess.DEVNULL, timeout=30)
        current = output('rev-parse', 'HEAD').decode().strip()
        originals = {name: output('show', producer + ':' + name) for name in receipt['testFiles']}
        for name in ('.github/workflows/external-gui-acceptance.yml', '.github/actions/setup-xcode-27/action.yml'):
            originals[name] = output('show', producer + ':' + name)
        self.assertEqual({name: hashlib.sha256(originals[name]).hexdigest() for name in receipt['testFiles']},
                         receipt['testFiles'])
        commits = output('rev-list', '--reverse', producer + '..' + current).decode().splitlines()
        changes = output('diff', '--no-renames', '--name-status', '-z', producer, current).decode().split('\0')
        statuses = {'A': 'added', 'M': 'modified', 'D': 'removed'}
        comparison = {'base_commit': {'sha': producer},
            'merge_base_commit': {'sha': output('merge-base', producer, current).decode().strip()},
            'status': 'ahead', 'commits': [{'sha': commit} for commit in commits], 'total_commits': len(commits),
            'files': [{'filename': name, 'status': statuses[status]}
                      for status, name in zip(changes[:-1:2], changes[1:-1:2])]}
        with patch.dict(os.environ, {'GITHUB_SHA': current}):
            _, files = journey.test_source_identity(current)
            proof = bundle._compiled_compatibility(producer, receipt['testFiles'], current, files,
                                                   originals, comparison)
        self.assertEqual(len(proof['producerFiles']), 37)
        self.assertEqual(len(proof['consumerFiles']), 39)
        self.assertEqual(proof['producerFiles'], receipt['testFiles'])
        self.assertEqual(set(proof['consumerFiles']) - set(proof['producerFiles']),
                         {'scripts/compiled_current_core_reuse.py',
                          'scripts/fixtures/compiled-current-core-reuse-1047.json'})
        self.assertTrue(proof['cohortMetadata']['appTransition']['newRuntimeProductProvenanceRequired'])

        archive = self.archive([('original-client', 'file', b'opaque retained client test fixture')])
        input_receipt = receipt | {'archiveSHA256': journey.sha256(archive)}
        raw_receipt = (json.dumps(input_receipt, indent=2) + '\n').encode()
        transfer = self.root / 'historical-transfer.zip'
        with zipfile.ZipFile(transfer, 'w') as handle:
            handle.write(archive, 'tests.tar.gz')
            handle.writestr('tests-input.json', raw_receipt)
        run = self.run | {'id': receipt['runID'], 'head_sha': producer}
        artifact = self.artifact | {'digest': 'sha256:' + journey.sha256(transfer),
            'workflow_run': {'id': receipt['runID'], 'head_sha': producer}}
        job = self.job | {'run_id': receipt['runID'], 'head_sha': producer}
        requested = []

        def api(route):
            if route == '/actions/runs/' + str(receipt['runID']): return run
            if route == '/actions/artifacts/34': return artifact
            if route == '/compare/' + producer + '...' + current: return comparison
            if route.startswith('/contents/'):
                name, ref = route.removeprefix('/contents/').split('?ref=')
                self.assertEqual(ref, producer)
                self.assertIn(name, originals, 'Historical source does not contain this current verifier')
                requested.append(name)
                return {'type': 'file', 'encoding': 'base64',
                        'content': base64.b64encode(originals[name]).decode()}
            self.fail('Unexpected historical-client API route: ' + route)

        destination = self.root / 'historical-resolved'
        with patch.dict(os.environ, {'GITHUB_SHA': current, 'GITHUB_RUN_ID': '78',
                                    'GITHUB_OUTPUT': str(self.root / 'output')}), \
                patch.object(bundle, 'api', side_effect=api), \
                patch.object(bundle, 'items', return_value=[job]), \
                patch.object(bundle, 'download', side_effect=lambda item, path: path.write_bytes(transfer.read_bytes())):
            bundle.resolve(SimpleNamespace(run_id=receipt['runID'], artifact_id=34,
                artifact_sha256=artifact['digest'].removeprefix('sha256:'), destination=str(destination)))
        self.assertEqual(set(requested), set(originals))
        self.assertEqual(len(requested), 39)
        self.assertEqual((destination / 'tests-input.json').read_bytes(), raw_receipt)
        self.assertEqual((destination / 'tests.tar.gz').read_bytes(), archive.read_bytes())
        self.assertEqual(journey.read_json(destination / 'tests-producer.json')['compiledCompatibility'], proof)
        self.assertEqual(bundle.verify_input(destination, current, files), input_receipt)

    def test_resolve_rejects_invalid_historical_receipt_before_source_requests(self):
        fixture = self.compiled_client_fixture()
        invalid = [fixture.receipt | {key: value} for key, value in (
            ('sourceSHA', 'f' * 40), ('runID', 13), ('attempt', 0), ('archiveSHA256', 'invalid'),
            ('testFiles', None), ('testFiles', {}), ('testFiles', []),
            ('testFiles', fixture.original_files | {'../outside': 'a' * 64}),
            ('testFiles', fixture.original_files | {'scripts/external-gui/test_bundle.py': 'invalid'}),
            ('testFiles', {name: value for name, value in fixture.original_files.items()
                           if name != 'scripts/external-gui/project.yml'}))]
        for index, receipt in enumerate(invalid):
            requests = []
            original_api = fixture.api
            def api(route):
                requests.append(route)
                return original_api(route)
            case = SimpleNamespace(**(vars(fixture) | {'api': api, 'destination': self.root / ('invalid-' + str(index))}))
            with self.subTest(index=index), patch.object(journey, 'read_json', return_value=receipt), self.assertRaises(ValueError):
                self.resolve_compiled_fixture(case)
            self.assertFalse(any(route.startswith('/contents/') for route in requests))

    def test_current_core_projection_preserves_build_reachable_code_and_imports(self):
        for name in ('scripts/app_cohort_v2.py', 'scripts/compiled_app_release.py',
                     'scripts/release_checkpoint.py', 'scripts/retained_packaging.py'):
            current = (journey.REPOSITORY / name).read_text()
            baseline = bundle._current_core_import_view(current, name)
            for altered in (current + '\nimport compiled_current_core_reuse\n',
                            current + '\nexecute_at_import()\n',
                            current + '\ndef __getattr__(name):\n    return execute()\n'):
                with self.subTest(path=name, change=altered[-70:]):
                    self.assertNotEqual(bundle._current_core_import_view(altered, name), baseline)
        path = 'scripts/app_cohort_v2.py'
        current = (journey.REPOSITORY / path).read_text()
        altered = current.replace('def manifest(source=None):',
                                  'def manifest(source=None):\n    import compiled_current_core_reuse')
        self.assertNotEqual(current, altered)
        self.assertNotEqual(bundle._current_core_import_view(current, path),
                            bundle._current_core_import_view(altered, path))

    def test_current_core_projection_rejects_executable_declarations_and_changed_v6_guard(self):
        path = 'scripts/compiled_app_release.py'
        current = (journey.REPOSITORY / path).read_text()
        for altered in (current.replace('def run_tests(root):', '@execute()\ndef run_tests(root):'),
                        current.replace('def run_tests(root):', 'def run_tests(root=execute()):'),
                        current.replace('def run_tests(root):', 'def run_tests(root: execute()):')):
            with self.subTest(change=altered[-50:]), self.assertRaises(ValueError):
                bundle._current_core_import_view(altered, path)
        altered = current.replace("type(receipt.get('attempt')) is int and receipt['attempt'] == 1", 'True')
        self.assertNotEqual(current, altered)
        with self.assertRaises(ValueError):
            bundle._current_core_import_view(altered, path, current=True)

    def test_current_core_projection_rejects_missing_and_moved_native_guards(self):
        path = 'scripts/compiled_app_release.py'
        current = (journey.REPOSITORY / path).read_text()
        for mode in ('missing', 'moved'):
            module = ast.parse(current)
            function = next(node for node in module.body if isinstance(node, ast.FunctionDef) and node.name == 'run_tests')
            index = next(index for index, node in enumerate(function.body)
                         if isinstance(node, ast.If) and isinstance(node.test, ast.Name) and node.test.id == 'dynamic')
            guard = function.body.pop(index)
            if mode == 'moved':
                function.body.insert(0, guard)
            with self.subTest(mode=mode), self.assertRaises(ValueError):
                bundle._current_core_import_view(ast.unparse(module), path, current=True)

    def test_compiled_client_rejects_unknown_added_or_removed_verifier(self):
        fixture = self.compiled_client_fixture()
        for files in ({**fixture.files, 'scripts/unknown_verifier.py': 'e' * 64},
                      {name: value for name, value in fixture.files.items() if name != 'scripts/release_checkpoint.py'}):
            with patch.object(journey, 'output', side_effect=fixture.git_output), self.assertRaises(ValueError):
                bundle._compiled_compatibility(self.sha, fixture.original_files, fixture.current,
                                               files, fixture.original, fixture.comparison)

    def test_compiled_client_rejects_changed_current_native_origin(self):
        fixture = self.compiled_client_fixture()
        files = dict(fixture.files)
        files['scripts/fixtures/compiled-current-core-reuse-1047.json'] = 'e' * 64
        with patch.object(journey, 'output', side_effect=fixture.git_output), self.assertRaisesRegex(
                ValueError, 'changed the qualified native origin'):
            bundle._compiled_compatibility(self.sha, fixture.original_files, fixture.current,
                                           files, fixture.original, fixture.comparison)

    def test_gui_native_regressions_reject_stale_duplicate_missing_and_substituted_ids(self):
        inventory = json.loads((journey.REPOSITORY / 'scripts/fixtures/app-cohort-native-inventory.json').read_bytes())
        bundle._current_native_regression_ids(inventory)
        key = 'originalEightAppFailureIDsRequiredToEndWithoutIssues'
        for mode in ('stale', 'duplicate', 'missing', 'substituted', 'skipped'):
            altered = copy.deepcopy(inventory)
            if mode == 'stale':
                altered[key][0] = re.sub(r':\d+:6$', ':1:6', altered[key][0])
            elif mode == 'duplicate':
                altered[key][-1] = altered[key][0]
            elif mode == 'missing':
                altered[key].pop()
            elif mode == 'substituted':
                altered[key][0] = next(identity for identity in altered['modules']['app']['exactEndedFunctionIDs']
                                       if identity not in altered[key])
            else:
                altered['modules']['app']['exactEndedFunctionIDs'].remove(altered[key][0])
                altered['modules']['app']['exactSkippedFunctionIDs'].append(altered[key][0])
            with self.subTest(mode=mode), self.assertRaises(ValueError):
                bundle._current_native_regression_ids(altered)

    def test_metadata_retry_compatibility_preserves_exact_request_and_guards(self):
        current = (journey.REPOSITORY / 'scripts/retained_app_test_products.py').read_text()
        module = ast.parse(current)
        api_source = ast.get_source_segment(current, next(node for node in module.body
                                            if isinstance(node, ast.FunctionDef) and node.name == 'api'))
        legacy = ast.parse('def api(path):\n    with urllib.request.build_opener(NoRedirect()).open(github_request(path), timeout=40) as response:\n        require(response.status == 200, "GitHub metadata request did not succeed")\n        data = response.read(16 * 1024 * 1024 + 1)\n        require(len(data) <= 16 * 1024 * 1024, "GitHub metadata exceeds its bound")\n        return json.loads(data)').body[0]
        module.body = [legacy if isinstance(node, ast.FunctionDef) and node.name == 'api' else node
                       for node in module.body if not (isinstance(node, ast.Import) and node.names[0].name == 'time')]
        original = ast.unparse(module)
        self.assertEqual(bundle._metadata_api_import_view(original), bundle._metadata_api_import_view(current))
        for before, after in [('range(3)', 'range(4)'), ('{502, 503, 504}', '{401, 502, 503, 504}'),
                              ('timeout=40', 'timeout=400'), ('response.status == 200', 'True'),
                              ('return json.loads(data)', 'return {}'), ('import time', 'import time as clock')]:
            with self.subTest(change=after), self.assertRaises(ValueError):
                changed = current.replace(before, after, 1) if before == 'import time' else current.replace(
                    api_source, api_source.replace(before, after, 1), 1)
                bundle._metadata_api_import_view(changed)
        changed_guard = current.replace('return None', 'return request', 1)
        self.assertNotEqual(bundle._metadata_api_import_view(original), bundle._metadata_api_import_view(changed_guard))

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
        cohort = 'scripts/fixtures/app-cohort.json'
        self.assertEqual(proof['cohortMetadata'], {'producerSHA256': fixture.original_files[cohort],
            'consumerSHA256': fixture.files[cohort],
            'addedCIPaths': ['.github/workflows/bpy-runtime-acceptance.yml']})
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
                        'scripts/release_engine_resume.py', 'scripts/verify_diagnostic_candidate.py',
                        'scripts/fixtures/app-cohort.json'}: continue
            original = fixture.original[name]
            fixture.original[name] += (b'\nCHANGED_IMPORT_CONTEXT = 1\n'
                                       if name == 'scripts/compiled_app_release.py' else b'\nchanged compilation input')
            with self.subTest(input=name):
                reason = ('native inventory changes outside an App-only transition'
                          if name == 'scripts/fixtures/app-cohort-native-inventory.json'
                          else 'Engine acquisition helper changes' if name == 'scripts/compiled_app_release.py'
                          else 'Receipt verifier is not valid Python' if name in {'scripts/app_cohort_v2.py', 'scripts/release_checkpoint.py'}
                          else 'Packaging verifier is not valid Python' if name == 'scripts/retained_packaging.py'
                          else 'Metadata transport is not valid Python' if name == 'scripts/retained_app_test_products.py'
                          else 'Compiled UI test source, project or reachable shared helper changed')
                self.assert_compiled_guard_rejects(fixture, reason)
            fixture.original[name] = original
        name = 'scripts/fixtures/app-cohort.json'
        original = fixture.original[name]
        for key, changed in [('build', '999'), ('nativeSourceObjects', {'Sources': 'e' * 40}),
                             ('compilerSHA256', 'e' * 64), ('roleSourceObjects', {})]:
            value = json.loads(original)
            value[key] = changed
            fixture.original[name] = json.dumps(value).encode()
            with self.subTest(cohort_field=key):
                self.assert_compiled_guard_rejects(fixture, 'UI test cohort changes native or compiler identity')
        for paths, reason in [
                (['duplicate', 'duplicate'], 'CI paths are not canonical'),
                (['../outside'], 'non-CI paths or removes'),
                (None, 'CI paths are not canonical')]:
            value = json.loads(original)
            value['ciPaths'] = paths
            fixture.original[name] = json.dumps(value).encode()
            with self.subTest(ci_paths=paths): self.assert_compiled_guard_rejects(fixture, reason)
        for removed in ['scripts/fixtures/app-cohort-native-inventory.json', '.github/workflows/release.yml']:
            value = json.loads(original)
            value['ciPaths'].remove(removed)
            fixture.original[name] = json.dumps(value).encode()
            with self.subTest(undeclared_or_non_ci_addition=removed):
                self.assert_compiled_guard_rejects(fixture, 'non-CI paths or removes')
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

    def test_packaging_client_compatibility_preserves_all_reachable_guards(self):
        current = (journey.REPOSITORY / 'scripts/retained_packaging.py').read_text()
        module = ast.parse(current)
        module.body = [node for node in module.body if not isinstance(node, ast.FunctionDef)
                       or node.name != 'original_cohort_pack_checks']
        for node in module.body:
            if not isinstance(node, ast.FunctionDef):
                continue
            if node.name in {'mode_inputs', 'event_values', 'collect_original_binding'}:
                node.body = [ast.Raise(exc=ast.Call(func=ast.Name(id='RuntimeError', ctx=ast.Load()),
                    args=[ast.Constant(value='original producer')], keywords=[]), cause=None)]
            if node.name == 'validate_binding':
                node.body = [statement for statement in node.body if not (
                    isinstance(statement, ast.Assign) and isinstance(statement.value, ast.Call)
                    and isinstance(statement.value.func, ast.Name) and statement.value.func.id == 'original_cohort_pack_checks')]
        original = ast.unparse(module)
        self.assertEqual(bundle._packaging_import_view(original), bundle._packaging_import_view(current))
        fixture = self.compiled_client_fixture()
        name = 'scripts/retained_packaging.py'
        fixture.original[name] = original.encode()
        fixture.original_files[name] = hashlib.sha256(fixture.original[name]).hexdigest()
        change = {'filename': name, 'status': 'modified'}
        fixture.comparison['files'].append(change); fixture.history['files'].append(dict(change))
        with patch.object(journey, 'output', side_effect=fixture.git_output):
            proof = bundle._compiled_compatibility(self.sha, fixture.original_files, fixture.current,
                                                   fixture.files, fixture.original, fixture.comparison)
        self.assertTrue(proof['packagingRuntimeHelper']['newRuntimeQualificationRequired'])
        self.assertNotEqual(proof['producerFiles'][name], proof['consumerFiles'][name])
        for changed in [current.replace('"Previous notary evidence changed"', '"Changed guard"'),
                        current.replace('previous["journals"] == record.get("previousNotary", {}).get("journals")', 'True'),
                        current.replace('record.get("attempt") == 1', 'True'),
                        current.replace('MAX_CHAIN = 8', 'MAX_CHAIN = 9'), current + '\nimport unexpected\n',
                        current.replace('def original_cohort_pack_checks(mode,', 'def original_cohort_pack_checks(mode: execute(),'),
                        current.replace('def mode_inputs(values):', 'def mode_inputs(values=execute()):'),
                        current.replace('def validate_binding(record, files,', 'def validate_binding(record, files=None,')]:
            self.assertNotEqual(changed, current)
            with self.subTest(changed=changed[-100:]):
                try:
                    observed = bundle._packaging_import_view(changed)
                except ValueError:
                    continue
                self.assertNotEqual(bundle._packaging_import_view(original), observed)

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
        fixture = self.compiled_client_fixture()
        helper = 'scripts/compiled_app_release.py'
        import ast
        module = ast.parse(fixture.original[helper])
        module.body = [node for node in module.body if not isinstance(node, ast.FunctionDef)
                       or node.name not in {'engine_carrier_origin', 'retained_engine_carrier'}]
        for node in module.body:
            if isinstance(node, ast.FunctionDef) and node.name == 'retained_engine_evidence':
                node.body = [ast.Raise(exc=ast.Call(func=ast.Name(id='RuntimeError', ctx=ast.Load()),
                    args=[ast.Constant(value='historical direct origin is expired')], keywords=[]), cause=None)]
        fixture.original[helper] = (ast.unparse(module) + '\n').encode()
        fixture.original_files[helper] = hashlib.sha256(fixture.original[helper]).hexdigest()
        change = {'filename': helper, 'status': 'modified'}
        fixture.comparison['files'].append(change)
        fixture.history['files'].append(dict(change))
        with patch.object(journey, 'output', side_effect=fixture.git_output):
            proof = bundle._compiled_compatibility(self.sha, fixture.original_files, fixture.current,
                                                   fixture.files, fixture.original, fixture.comparison)
        self.assertNotEqual(proof['producerFiles'][helper], proof['consumerFiles'][helper])
        self.assertTrue(proof['engineCarrierRuntimeHelper']['newRuntimeQualificationRequired'])
        baseline = fixture.original[helper]
        for suffix in (b'\nimport unexpected_runtime_import\n', b'\nBUILD_CONTEXT = 999\n',
                       b'\ndef unexpected_callable():\n    return 1\n'):
            fixture.original[helper] = baseline + suffix
            fixture.original_files[helper] = hashlib.sha256(fixture.original[helper]).hexdigest()
            self.assert_compiled_guard_rejects(fixture, 'Engine acquisition helper changes')
        fixture.original[helper] = baseline
        fixture.original_files[helper] = hashlib.sha256(baseline).hexdigest()
        fixture = self.compiled_client_fixture()
        cohort = 'scripts/fixtures/app-cohort.json'
        current = json.loads((journey.REPOSITORY / cohort).read_bytes())
        prior = json.loads(fixture.original[cohort])
        prior.update(build=str(int(current['build']) - 1), appSourceSHA='c' * 40, appTreeSHA='9' * 40)
        prior['nativeSourceObjects']['Sources'] = '8' * 40
        prior['nativeSourceObjects']['Tests'] = '5' * 40
        reader = 'Sources/NexGenVideo/App/NativeButtonAccessibility.swift'
        for role in ('production', 'testable', 'tests'):
            self.assertIn(reader, prior['roleSourceObjects'][role])
            prior['roleSourceObjects'][role][reader] = '7' * 40
        prior['roleSourceObjects']['tests']['Tests/NexGenVideoTests'] = '6' * 40
        inventory_path = 'scripts/fixtures/app-cohort-native-inventory.json'
        inventory = json.loads(fixture.original[inventory_path])
        inventory.update(appSourceSHA=prior['appSourceSHA'], nativeSourceObjects=prior['nativeSourceObjects'])
        additions = {'actualLegacyScrollersKeepTheEnabledUndoDiscoverable',
                     'zeroAreaButtonsWithAbsentEnabledNeverBecomeTargetsOrHideDuplicates',
                     'absentEnabledRequiresProvenZeroAreaAndReadableIdentity',
                     'unnamedButtonsRequireKnownNamesAndCannotHideNamedTargets'}
        ended = inventory['modules']['app']['exactEndedFunctionIDs']
        inventory['modules']['app']['exactEndedFunctionIDs'] = [item for item in ended
            if not any('/' + name + '()/' in item for name in additions)]
        self.assertEqual(len(ended) - len(inventory['modules']['app']['exactEndedFunctionIDs']), 4)
        inventory['expectedActualExecutions'] -= 4
        fixture.original[inventory_path] = (json.dumps(inventory, indent=2, sort_keys=True) + '\n').encode()
        prior['criteria']['sha256'] = hashlib.sha256(fixture.original[inventory_path]).hexdigest()
        fixture.original[cohort] = (json.dumps(prior, indent=2, sort_keys=True) + '\n').encode()
        fixture.original_files = {name: hashlib.sha256(fixture.original[name]).hexdigest() for name in fixture.files}
        fixture.receipt['testFiles'] = fixture.original_files
        fixture.raw_receipt = (json.dumps(fixture.receipt, indent=2) + '\n').encode()
        with zipfile.ZipFile(fixture.transfer, 'w') as handle:
            handle.write(fixture.archive, 'tests.tar.gz')
            handle.writestr('tests-input.json', fixture.raw_receipt)
        fixture.artifact['digest'] = 'sha256:' + journey.sha256(fixture.transfer)
        for comparison in (fixture.comparison, fixture.history):
            comparison['files'] = [item for item in comparison['files']
                                   if item['filename'] != '.github/workflows/external-gui-acceptance.yml']
            for item in comparison['files']:
                if item['filename'] == reader:item['status'] = 'modified'
            comparison['files'].extend([{'filename': 'Tests/NexGenVideoTests/UI/NativeButtonInteractionTests.swift', 'status': 'modified'},
                                        {'filename': inventory_path, 'status': 'modified'}])
        fixture.original['.github/workflows/external-gui-acceptance.yml'] = fixture.current_workflow
        fixture.comparison['commits'].insert(0, {'sha': current['appSourceSHA']})
        fixture.comparison['total_commits'] = 2
        fixture.history['commits'] = copy.deepcopy(fixture.comparison['commits'])
        fixture.history['total_commits'] = 2
        def objects(source, paths):
            declaration = prior if source == prior['appSourceSHA'] else current
            self.assertIn(source, (prior['appSourceSHA'], current['appSourceSHA']))
            candidates = [declaration['nativeSourceObjects'], declaration['componentSourceObjects'], *declaration['roleSourceObjects'].values()]
            matches = [value for value in candidates if set(value) == set(paths)]
            self.assertTrue(matches)
            return dict(matches[0])
        import app_cohort_v2
        with patch.object(app_cohort_v2, 'objects', side_effect=objects):
            self.resolve_compiled_fixture(fixture)
            with patch.object(journey, 'output', side_effect=fixture.git_output):
                xctestrun, receipt = bundle.consume(fixture.destination, self.root / 'app-transition-products',
                    fixture.current, fixture.files)
        self.assertEqual((fixture.destination / 'tests-input.json').read_bytes(), fixture.raw_receipt)
        self.assertEqual(bundle.products_sha256(xctestrun.parent), fixture.receipt['productsSHA256'])
        self.assertEqual(receipt, fixture.receipt)
        transition = journey.read_json(fixture.destination / 'tests-producer.json')['compiledCompatibility']['cohortMetadata']['appTransition']
        self.assertEqual(transition['producerBuild'], prior['build'])
        self.assertEqual(transition['consumerAppSourceSHA'], current['appSourceSHA'])
        self.assertEqual(transition['changedNativeRoots'], ['Sources', 'Tests'])
        self.assertEqual(transition['changedRolePaths']['production'], [reader])
        self.assertEqual(transition['changedRolePaths']['tests'], [reader, 'Tests/NexGenVideoTests'])
        self.assertEqual(transition['consumerCriteriaSHA256'], current['criteria']['sha256'])
        self.assertTrue(transition['newRuntimeProductProvenanceRequired'])
        self.assertEqual(len(transition['additionalNativeAppTests']), 4)
        for target in (prior['nativeSourceObjects'], prior['componentSourceObjects'], prior['roleSourceObjects']['tests']):
            def changed_objects(source, paths):
                result = objects(source, paths)
                if source == prior['appSourceSHA'] and set(paths) == set(target):result[next(iter(result))] = '0' * 40
                return result
            with self.subTest(objectKeys=sorted(target)), patch.object(app_cohort_v2, 'objects', side_effect=changed_objects):
                self.assert_compiled_guard_rejects(fixture, 'actual native Git objects')
        fixture.original[cohort] = json.dumps({**prior,
            'compilerSHA256': '0' * 64}).encode()
        self.assert_compiled_guard_rejects(fixture, 'outside an App-only transition')

    def test_compiled_client_native_additions_preserve_every_existing_criterion(self):
        names = ['actualLegacyScrollersKeepTheEnabledUndoDiscoverable',
                 'zeroAreaButtonsWithAbsentEnabledNeverBecomeTargetsOrHideDuplicates',
                 'absentEnabledRequiresProvenZeroAreaAndReadableIdentity',
                 'unnamedButtonsRequireKnownNamesAndCannotHideNamedTargets']
        additions = ['NexGenVideoTests.NativeButtonInteractionTests/' + name
                     + '()/NativeButtonInteractionTests.swift:SOURCE-LINE:6' for name in names]
        before = {'expectedActualExecutions': 2, 'modules': {'app': {'exactEndedFunctionIDs': ['original'],
                  'exactSkippedFunctionIDs': ['skipped'], 'issuesExpected': 0},
                  'engine': {'exactEndedFunctionIDs': ['engine']}}, 'xctest': ['host']}
        after = copy.deepcopy(before)
        after['expectedActualExecutions'] += 4
        after['modules']['app']['exactEndedFunctionIDs'] += additions
        self.assertEqual(bundle._native_inventory_additions(before, before), [])
        self.assertEqual(bundle._native_inventory_additions(before, after), sorted(additions))
        mutations = [lambda x: x.update(expectedActualExecutions=4),
                     lambda x: x['modules']['app']['exactEndedFunctionIDs'].append('unknown'),
                     lambda x: x['modules']['app']['exactEndedFunctionIDs'].append(additions[0]),
                     lambda x: x['modules']['app']['exactEndedFunctionIDs'].remove('original'),
                     lambda x: x['modules']['app']['exactSkippedFunctionIDs'].clear(),
                     lambda x: x['modules']['app'].update(issuesExpected=1),
                     lambda x: x['modules']['engine']['exactEndedFunctionIDs'].clear(),
                     lambda x: x['xctest'].clear()]
        for mutate in mutations:
            changed = copy.deepcopy(after)
            mutate(changed)
            with self.assertRaises(ValueError):bundle._native_inventory_additions(before, changed)
        with self.assertRaises(ValueError):bundle._native_inventory_additions(after, before)

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

    def test_fresh_catalog_rejects_old_ambiguous_or_rebound_pack_entries(self):
        entry = {'id': 'musicvideo', 'displayName': 'Music Video', 'tagline': 'Music video production',
                 'version': '0.6.0', 'minAppVersion': '1.8.0', 'projectSchema': 'musicvideo/3.0.0',
                 'sha256': 'c' * 64, 'url': journey.CATALOG_URL.removesuffix('catalog.json') + 'musicvideo-0.6.0.ngvpack.zip'}
        def check(entries):
            raw = json.dumps({'schema': 'plugins/v2', 'plugins': entries}).encode()
            return journey.fresh_catalog(raw, hashlib.sha256(raw).hexdigest(), 'c' * 64)
        self.assertEqual(check([entry]), entry)
        for entries in ([{**entry, 'version': '0.5.8'}], [entry, entry],
                        [{**entry, 'projectSchema': 'musicvideo/2.0.0'}], [{**entry, 'sha256': 'd' * 64}],
                        [{**entry, 'url': 'https://example.invalid/substitute.zip'}]):
            with self.subTest(entries=entries), self.assertRaises(ValueError):
                check(entries)
        with self.assertRaises(ValueError):
            journey.fresh_catalog(b'{"schema":"plugins/v2","plugins":[]}', '0' * 64, 'c' * 64)

    def test_fresh_stage_proof_requires_order_actual_150_percent_and_unassigned_track(self):
        screenshot, accessibility = self.root / 'screen.png', self.root / 'screen.ax'
        screenshot.write_bytes(b'\x89PNG\r\n\x1a\nfixture')
        accessibility.write_text('AXWindow Track Choose Attach track disabled')
        visual = {'screenshot': screenshot.name, 'accessibility': accessibility.name,
                  'screenshotSHA256': journey.sha256(screenshot), 'accessibilitySHA256': journey.sha256(accessibility)}
        stages = [{'stage': name, 'evidence': visual.copy()} for name in journey.FRESH_STAGES]
        stages[0]['installedEntries'] = 0
        stages[2].update(scaleLabel=journey.SCALES['1.5'], selectedValue=journey.SCALES['1.5'])
        for index in (4, 5):
            stages[index].update(packID='musicvideo', version='0.6.0', schema='musicvideo/3.0.0')
        stages[-1].update(chooseEnabled=True, attachEnabled=False, trackUploaded=False)
        original = {'schema': 'nexgenvideo/external-fresh-musicvideo/1', 'stages': stages,
                    'actions': [{'target': 'native action ' + str(index)} for index in range(12)]}
        journey.write_json(self.root / 'profile-before-launch.json', {'installedEntries': 0})
        for name in ('bootstrap-binding.json', 'fresh-binding.json'):
            journey.write_json(self.root / name, {'activePlugin': 'musicvideo', 'activePluginVersion': '0.6.0',
                                                 'activePluginProjectSchema': 'musicvideo/3.0.0'})
        journey.write_json(self.root / 'journey.json', original)
        self.assertEqual(journey.validate_fresh_stages(self.root), original)
        mutations = []
        value = copy.deepcopy(original); value['stages'][0], value['stages'][1] = value['stages'][1], value['stages'][0]; mutations.append(value)
        value = copy.deepcopy(original); value['stages'][2]['selectedValue'] = '100%'; mutations.append(value)
        value = copy.deepcopy(original); value['stages'][-1]['attachEnabled'] = True; mutations.append(value)
        value = copy.deepcopy(original); value['stages'][5]['version'] = '0.5.8'; mutations.append(value)
        value = copy.deepcopy(original); value['actions'].append({'target': 'Attach track'}); mutations.append(value)
        value = copy.deepcopy(original); value['stages'][0]['evidence']['accessibilitySHA256'] = 'f' * 64; mutations.append(value)
        for value in mutations:
            with self.subTest(value=value), self.assertRaises(ValueError):
                journey.write_json(self.root / 'journey.json', value)
                journey.validate_fresh_stages(self.root)

    def test_downloaded_normal_pack_requires_exact_installed_files_and_rejects_escapes(self):
        archive = io.BytesIO()
        with zipfile.ZipFile(archive, 'w') as zipped:
            zipped.writestr('musicvideo.ngvpack/Contents/Info.plist', b'exact pinned metadata')
        installed = self.root / 'installed-pack'
        (installed / 'Contents').mkdir(parents=True)
        info = installed / 'Contents/Info.plist'
        info.write_bytes(b'exact pinned metadata')
        self.assertRegex(journey.verify_downloaded_pack(archive.getvalue(), installed), '^[a-f0-9]{64}$')
        info.write_bytes(b'different installed metadata')
        with self.assertRaises(ValueError):
            journey.verify_downloaded_pack(archive.getvalue(), installed)
        bad = io.BytesIO()
        with zipfile.ZipFile(bad, 'w') as zipped:
            zipped.writestr('musicvideo.ngvpack/../outside', b'escape')
        with self.assertRaises(ValueError):
            journey.verify_downloaded_pack(bad.getvalue(), installed)

    def test_fresh_workflow_gates_runner_on_exact_dmg_source_catalog_and_pack(self):
        text = (journey.REPOSITORY / '.github/workflows/external-gui-acceptance.yml').read_text()
        step = text.split('      - name: Select independent user journeys\n', 1)[1].split('      - name:', 1)[0]
        code = step.split("          python3 - <<'PY'\n", 1)[1].split('          PY', 1)[0]
        code = '\n'.join(line[10:] for line in code.splitlines())
        values = {'SCENARIO': 'normal-fresh-musicvideo', 'INTERFACE_SCALE': '1.5', 'ARTIFACT_MODE': 'dmg',
                  'EXPECTED_DMG_SHA256': '1' * 64, 'TEST_BUNDLE_RUN_ID': '', 'TEST_BUNDLE_ARTIFACT_ID': '',
                  'TEST_BUNDLE_ARTIFACT_SHA256': '', 'RETAINED_SOURCE': self.sha, 'RETAINED_RUN': '12',
                  'RETAINED_ARTIFACT': '34', 'RETAINED_DIGEST': '2' * 64, 'VERIFIED_PR_RUN': '56',
                  'FIXTURE_ARTIFACT': '', 'FIXTURE_SHA': '', 'EXPECTED_CATALOG_SHA256': '3' * 64,
                  'EXPECTED_PACK_SHA256': '4' * 64, 'GITHUB_SHA': self.sha, 'GITHUB_OUTPUT': str(self.root / 'fresh-output')}
        variants = [({}, True), ({'INTERFACE_SCALE': 'all'}, False), ({'ARTIFACT_MODE': 'app'}, False),
                    ({'VERIFIED_PR_RUN': ''}, False), ({'EXPECTED_CATALOG_SHA256': ''}, False),
                    ({'EXPECTED_PACK_SHA256': ''}, False), ({'FIXTURE_ARTIFACT': '78'}, False),
                    ({'SCENARIO': 'journey'}, False)]
        variants += [({'SCENARIO': 'normal-fresh-local-musicvideo', 'EXPECTED_PACK_SHA256': journey.LOCAL_PACK_ZIP_SHA}, True),
                     ({'SCENARIO': 'normal-fresh-local-musicvideo'}, False),
                     ({'SCENARIO': 'normal-fresh-local-musicvideo', 'EXPECTED_PACK_SHA256': journey.LOCAL_PACK_ZIP_SHA, 'ARTIFACT_MODE': 'app'}, False)]
        for changes, accepted in variants:
            with self.subTest(changes=changes):
                result = subprocess.run([sys.executable, '-c', code], stdin=subprocess.DEVNULL, capture_output=True,
                                        env=os.environ | values | changes, timeout=20)
                self.assertEqual(result.returncode == 0, accepted, result.stderr.decode())

    def test_local_dmg_case_keeps_the_old_catalog_case_distinct_and_binds_original_pack_lineage(self):
        raw = json.dumps({'schema': 'plugins/v2', 'plugins': [{'id': 'musicvideo', 'version': '0.5.8'}]}).encode()
        digest = hashlib.sha256(raw).hexdigest()
        self.assertEqual(journey.local_catalog(raw, digest, journey.LOCAL_PACK_ZIP_SHA)['plugins'][0]['version'], '0.5.8')
        with self.assertRaises(ValueError): journey.fresh_catalog(raw, digest, journey.LOCAL_PACK_ZIP_SHA)
        for value, expected, pack in [(raw, '0' * 64, journey.LOCAL_PACK_ZIP_SHA), (raw, digest, 'f' * 64),
                (raw.replace(b'0.5.8', b'0.6.0'), hashlib.sha256(raw.replace(b'0.5.8', b'0.6.0')).hexdigest(), journey.LOCAL_PACK_ZIP_SHA)]:
            with self.subTest(value=value), self.assertRaises(ValueError): journey.local_catalog(value, expected, pack)

    def test_local_pack_proofs_require_honest_current_reuse_records_and_their_durable_bytes(self):
        from compiled_app_release import original_pack_proof
        identity = {'runID': '555', 'runAttempt': '1', 'app': {'treeSHA256': 'a' * 64},
            'externalPack': {'guideSHA256': 'b' * 64}}
        expected_binding = {'sourceSHA': 'e' * 40, 'dmgSHA256': 'd' * 64, 'appTreeSHA256': 'a' * 64, 'guideSHA256': 'b' * 64}
        expected_producer = {'sourceSHA': 'e' * 40, 'runID': 777, 'artifactID': 888,
            'artifactSHA256': 'f' * 64, 'producerJobID': 999, 'intakeBinding': expected_binding}
        for case in ('valid', 'fresh-claim', 'old-source', 'old-run', 'wrong-origin', 'wrong-dmg', 'wrong-producer',
                'producer-run', 'producer-artifact', 'producer-digest', 'producer-job', 'intake-app', 'intake-guide',
                'current-run', 'current-attempt', 'durable'):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                (root / 'pack-reuse').mkdir()
                for context, name in [('local-dmg', 'pack-source-signature.log'), ('local-installed', 'pack-signature.log')]:
                    proof = {'schema': 'retained-pack-copy-reuse/v1', 'state': 'REUSED', 'context': context,
                        'original': original_pack_proof(), 'currentSourceSHA': 'c' * 40, 'currentRunID': 555,
                        'currentAttempt': 1, 'currentJob': 'acceptance', 'packTreeSHA256': journey.LOCAL_PACK_TREE,
                        'rootMode': 0o755, 'currentDMGSHA256': 'd' * 64,
                        'runtimeProducer': copy.deepcopy(expected_producer),
                        'currentNativeCodesignOrStaplerPerformed': False, 'currentPackNotarizationPerformed': False,
                        'freshTrustStoreOrRevocationClaimed': False, 'newAppPackLoadQualified': False}
                    if case == 'fresh-claim': proof['currentNativeCodesignOrStaplerPerformed'] = True
                    elif case == 'old-source': proof['currentSourceSHA'] = 'b' * 40
                    elif case == 'old-run': proof['currentRunID'] = 554
                    elif case == 'wrong-origin': proof['original']['runID'] += 1
                    elif case == 'wrong-dmg': proof['currentDMGSHA256'] = '0' * 64
                    elif case == 'wrong-producer': proof['runtimeProducer']['sourceSHA'] = '0' * 40
                    elif case == 'producer-run': proof['runtimeProducer']['runID'] = 778
                    elif case == 'producer-artifact': proof['runtimeProducer']['artifactID'] = 889
                    elif case == 'producer-digest': proof['runtimeProducer']['artifactSHA256'] = '0' * 64
                    elif case == 'producer-job': proof['runtimeProducer']['producerJobID'] = 998
                    elif case == 'intake-app': proof['runtimeProducer']['intakeBinding']['appTreeSHA256'] = '0' * 64
                    elif case == 'intake-guide': proof['runtimeProducer']['intakeBinding']['guideSHA256'] = '0' * 64
                    journey.write_json(root / name, proof)
                    journey.write_json(root / 'pack-reuse' / (context + '.json'), proof if case != 'durable' else {})
                identity['externalPack']['verificationReuseSHA256'] = journey.sha256(root / 'pack-source-signature.log')
                env = {'GITHUB_ACTIONS': 'true', 'GITHUB_REPOSITORY': 'iret77/nexgenvideo', 'GITHUB_JOB': 'acceptance',
                    'GITHUB_RUN_ATTEMPT': '2' if case == 'current-attempt' else '1',
                    'GITHUB_RUN_ID': '556' if case == 'current-run' else '555', 'GITHUB_SHA': 'c' * 40}
                with patch.dict(os.environ, env), patch('compiled_app_release.local_pack_runtime_origin', return_value=expected_producer) as producer:
                    if case == 'valid':
                        journey.validate_local_pack_reuse(root, identity, 'c' * 40, 'e' * 40, 'd' * 64)
                        producer.assert_called_once_with(expected_binding, expected_dmg_sha256='d' * 64)
                    else:
                        with self.assertRaises(ValueError): journey.validate_local_pack_reuse(root, identity, 'c' * 40, 'e' * 40, 'd' * 64)

    def test_local_dmg_stage_proof_requires_real_file_installer_and_exact_saved_pin(self):
        screenshot, accessibility = self.root / 'screen.png', self.root / 'screen.ax'
        screenshot.write_bytes(b'\x89PNG\r\n\x1a\nfixture'); accessibility.write_text('native Install Format Pack and Track')
        visual = {'screenshot': screenshot.name, 'accessibility': accessibility.name,
            'screenshotSHA256': journey.sha256(screenshot), 'accessibilitySHA256': journey.sha256(accessibility)}
        stages = [{'stage': name, 'evidence': visual.copy()} for name in journey.LOCAL_STAGES]
        stages[0]['installedEntries'] = 0
        stages[2].update(scaleLabel=journey.SCALES['1.5'], selectedValue=journey.SCALES['1.5'])
        stages[3].update(packOrigin='mounted-dmg', packFilename='musicvideo.ngvpack')
        for index in (4, 5): stages[index].update(packID='musicvideo', version='0.6.0', schema='musicvideo/3.0.0')
        stages[-1].update(chooseEnabled=True, attachEnabled=False, trackUploaded=False)
        original = {'schema': 'nexgenvideo/external-local-musicvideo/1', 'stages': stages,
            'actions': [{'target': 'normal native action ' + str(index)} for index in range(12)]}
        journey.write_json(self.root / 'profile-before-launch.json', {'installedEntries': 0})
        journey.write_json(self.root / 'fresh-binding.json', {'activePlugin': 'musicvideo', 'activePluginVersion': '0.6.0',
            'activePluginProjectSchema': 'musicvideo/3.0.0'})
        journey.write_json(self.root / 'journey.json', original)
        self.assertEqual(journey.validate_local_stages(self.root), original)
        variants = []
        for index, key, value in [(0, 'installedEntries', 1), (3, 'packOrigin', 'preseeded-library'),
                (3, 'packFilename', 'other.ngvpack'), (5, 'version', '0.5.8'), (6, 'attachEnabled', True)]:
            changed = copy.deepcopy(original); changed['stages'][index][key] = value; variants.append(changed)
        changed = copy.deepcopy(original); changed['schema'] = 'nexgenvideo/external-fresh-musicvideo/1'; variants.append(changed)
        for value in variants:
            journey.write_json(self.root / 'journey.json', value)
            with self.subTest(value=value), self.assertRaises(ValueError): journey.validate_local_stages(self.root)



if __name__ == '__main__':
    unittest.main()
