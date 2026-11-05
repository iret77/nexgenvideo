import copy
import base64
import ast
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
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
                    'TEST_BUNDLE_RUN_ID': '', 'RETAINED_SOURCE': '', 'RETAINED_RUN': '',
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

    def transport_bundle_fixture(self):
        current = 'd' * 40
        payloads = {(journey.ROOT / name).relative_to(journey.REPOSITORY).as_posix(): (journey.ROOT / name).read_bytes()
                    for name in journey.TEST_INPUTS}
        payloads.update({name: (journey.REPOSITORY / name).read_bytes() for name in journey.SHARED_INPUTS})
        files = {name: hashlib.sha256(value).hexdigest() for name, value in payloads.items()}
        original = dict(payloads)
        helper = 'scripts/external-gui/test_bundle.py'
        lines = original[helper].decode().splitlines(keepends=True)
        removed = set()
        for node in ast.parse(original[helper]).body:
            if isinstance(node, ast.FunctionDef) and node.name in {'_test_builder_view', '_source_snapshot', '_transport_compatibility'}:
                removed.update(range(node.lineno - 1, node.end_lineno))
        original[helper] = ''.join(line for index, line in enumerate(lines) if index not in removed).encode()
        original[helper] = original[helper].replace(b'def resolve(args):\n', b'def resolve(args):\n    original_consumer = True\n', 1)
        original['scripts/external-gui/transport.py'] = original['scripts/external-gui/transport.py'].replace(b'transport_reuse=True', b'transport_reuse=False')
        guard = 'scripts/verify_diagnostic_candidate.py'
        original[guard] = original[guard].replace(
            b'SIGNED_TRANSPORT_HARNESS_PATHS = SIGNED_ACCEPTANCE_EVIDENCE_PATHS | {"scripts/external-gui/test_bundle.py"}',
            b'SIGNED_TRANSPORT_HARNESS_PATHS = SIGNED_ACCEPTANCE_EVIDENCE_PATHS')
        self.assertNotEqual(original[guard], payloads[guard])
        workflow = (journey.REPOSITORY / '.github/workflows/external-gui-acceptance.yml').read_text()
        original['.github/workflows/external-gui-acceptance.yml'] = ''.join(line for line in workflow.splitlines(keepends=True)
            if 'NGV_TRANSPORT_TEST_BUNDLE_REUSE:' not in line).encode()
        original_files = {name: hashlib.sha256(original[name]).hexdigest() for name in files}
        xctestrun = plistlib.dumps({'Test': {'TestHostPath': '__TESTROOT__/Runner.app',
            'TestBundlePath': '__TESTHOST__/Contents/PlugIns/Test.xctest'}})
        entries = [('Runner.app/Contents/PlugIns/Test.xctest/binary', 'file', b'original native client'),
                   ('Tests.xctestrun', 'file', xctestrun)]
        archive = self.archive(entries)
        products = self.root / 'original-products'
        for name, _, content in entries:
            path = products / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(content)
        receipt = {'schema': 'nexgenvideo/external-tests-input/1', 'sourceSHA': self.sha,
            'testFiles': original_files, 'architecture': 'arm64', 'deploymentTarget': '26.0',
            'xcode': 'Xcode 27\nBuild version 18A123', 'runID': 12, 'attempt': 1,
            'archiveSHA256': journey.sha256(archive), 'productsSHA256': bundle.products_sha256(products),
            'xctestrun': 'Tests.xctestrun'}
        raw_receipt = (json.dumps(receipt, indent=2) + '\n').encode()
        transfer = self.root / 'transfer.zip'
        with zipfile.ZipFile(transfer, 'w') as handle:
            handle.write(archive, 'tests.tar.gz'); handle.writestr('tests-input.json', raw_receipt)
        artifact = self.artifact | {'digest': 'sha256:' + journey.sha256(transfer)}
        comparison = {'base_commit': {'sha': self.sha}, 'merge_base_commit': {'sha': self.sha},
            'status': 'ahead', 'total_commits': 1, 'commits': [{'sha': current}],
            'files': [{'filename': name, 'status': 'modified'} for name in ['.github/workflows/diagnostic-acceptance.yml',
                '.github/workflows/external-gui-acceptance.yml', helper, 'scripts/external-gui/transport.py', guard]]}
        history = copy.deepcopy(comparison)

        def git_output(arguments, **kwargs):
            if arguments[-2:] == ['rev-parse', 'HEAD']: return current.encode()
            if 'merge-base' in arguments: return history['merge_base_commit']['sha'].encode()
            if 'rev-list' in arguments: return '\n'.join(item['sha'] for item in history['commits']).encode()
            if 'diff' in arguments: return ''.join('M\0' + item['filename'] + '\0' for item in history['files']).encode()
            if 'show' in arguments:
                commit, name = arguments[-1].split(':', 1)
                if commit == current and name == '.github/workflows/external-gui-acceptance.yml': return workflow.encode()
                self.assertEqual(commit, self.sha)
                return original[name]
            self.fail('Unexpected test bundle Git command: ' + str(arguments))

        def api(route):
            if route == '/actions/runs/12': return copy.deepcopy(self.run)
            if route.startswith('/contents/'):
                name, ref = route.removeprefix('/contents/').split('?ref=')
                self.assertEqual(ref, self.sha)
                return {'type': 'file', 'encoding': 'base64', 'content': base64.b64encode(original[name]).decode()}
            if route == '/compare/' + self.sha + '...' + current: return copy.deepcopy(comparison)
            self.fail('Unexpected test bundle API route: ' + route)

        def download(item, destination):
            self.assertEqual(item, artifact)
            destination.write_bytes(transfer.read_bytes())
            self.assertEqual('sha256:' + journey.sha256(destination), artifact['digest'])

        return SimpleNamespace(current=current, files=files, original=original, original_files=original_files,
            workflow=workflow, receipt=receipt, raw_receipt=raw_receipt, artifact=artifact, comparison=comparison,
            history=history, git_output=git_output, api=api, download=download, destination=self.root / 'resolved')

    def resolve_transport_fixture(self, fixture, *, enabled=True):
        with patch.dict(os.environ, {'GITHUB_SHA': fixture.current, 'GITHUB_RUN_ID': '78',
                                    'GITHUB_OUTPUT': str(self.root / 'output'),
                                    'NGV_TRANSPORT_TEST_BUNDLE_REUSE': '1' if enabled else ''}), \
                patch.object(journey, 'test_source_identity', return_value=(fixture.current, fixture.files)), \
                patch.object(journey, 'output', side_effect=fixture.git_output), \
                patch.object(bundle, 'api', side_effect=fixture.api), \
                patch.object(bundle, 'items', side_effect=lambda route, key: [fixture.artifact] if key == 'artifacts' else [self.job]), \
                patch.object(bundle, 'download', side_effect=fixture.download):
            bundle.resolve(SimpleNamespace(run_id=12, artifact_id=None, destination=str(fixture.destination)))

    def test_transport_reuses_original_products_through_resolver_consumer_and_posthoc(self):
        fixture = self.transport_bundle_fixture()
        self.resolve_transport_fixture(fixture)
        self.assertEqual((fixture.destination / 'tests-input.json').read_bytes(), fixture.raw_receipt)
        with patch.object(journey, 'output', side_effect=fixture.git_output):
            xctestrun, receipt = bundle.consume(fixture.destination, self.root / 'consumed', fixture.current,
                                               fixture.files, transport_reuse=True)
            self.assertTrue(xctestrun.is_file())
            self.assertEqual(receipt, fixture.receipt)
            self.assertEqual((xctestrun.parent / 'Runner.app/Contents/PlugIns/Test.xctest/binary').read_bytes(), b'original native client')
            self.assertEqual(bundle.products_sha256(xctestrun.parent), fixture.receipt['productsSHA256'])
            self.assertEqual(bundle.verify_input(fixture.destination, fixture.current, fixture.files,
                                                transport_reuse=True), fixture.receipt)
        proof = journey.read_json(fixture.destination / 'tests-producer.json')['transportCompatibility']
        self.assertEqual(proof['producerSourceSHA'], self.sha)
        self.assertEqual(proof['consumerSourceSHA'], fixture.current)
        self.assertEqual(proof['producerFiles'], fixture.original_files)
        self.assertEqual(proof['consumerFiles'], fixture.files)

    def assert_transport_guard_rejects(self, fixture, reason):
        files = {name: hashlib.sha256(fixture.original[name]).hexdigest() for name in fixture.files}
        with patch.object(journey, 'output', side_effect=fixture.git_output), self.assertRaisesRegex(ValueError, reason):
            bundle._transport_compatibility(self.sha, files, fixture.current, fixture.files,
                fixture.original['scripts/external-gui/test_bundle.py'].decode(),
                fixture.original['.github/workflows/external-gui-acceptance.yml'].decode(), fixture.comparison)

    def test_transport_reuse_rejects_changed_native_inputs_build_recipe_imports_and_workflow(self):
        fixture = self.transport_bundle_fixture()
        for name in fixture.original_files:
            if name in {'scripts/external-gui/test_bundle.py', 'scripts/external-gui/transport.py', 'scripts/verify_diagnostic_candidate.py'}: continue
            original = fixture.original[name]
            fixture.original[name] = original + b'changed compilation input'
            with self.subTest(input=name): self.assert_transport_guard_rejects(fixture, 'Compiled UI test inputs or shared build helpers changed')
            fixture.original[name] = original
        helper = 'scripts/external-gui/test_bundle.py'; original = fixture.original[helper]
        for changed in [original.replace(b"'ARCHS=arm64'", b"'ARCHS=x86_64'"), b'import unreviewed_build_tool\n' + original,
                        original.replace(b"ARTIFACT = 'external-gui-tests'", b"ARTIFACT = 'substituted-tests'"),
                        original.replace(b'def resolve(args):', b'@change_module\ndef resolve(args):'),
                        original.replace(b'def resolve(args):', b'def resolve(args=change_module()):')]:
            self.assertNotEqual(changed, original)
            fixture.original[helper] = changed
            reason = 'Consumer declaration changes module execution' if b'@change_module' in changed else 'malformed node or string' if b'args=change_module()' in changed else 'UI test build recipe, imports or constants changed'
            with self.subTest(recipe=changed[:100]): self.assert_transport_guard_rejects(fixture, reason)
        fixture.original[helper] = original
        guard = 'scripts/verify_diagnostic_candidate.py'; original_guard = fixture.original[guard]
        variants = [b'import unreviewed_guard_helper\n' + original_guard,
            original_guard.replace(b'def verify_signed_journey(*args):\n', b'def verify_signed_journey(*args):\n    changed_build_guard = True\n'),
            original_guard.replace(b'SIGNED_JOURNEY_BASE_HARNESS_PATHS = SIGNED_BPY_HARNESS_PATHS | {', b'SIGNED_JOURNEY_BASE_HARNESS_PATHS = set() | {'),
            original_guard.replace(b'SIGNED_SETTINGS_HARNESS_PATHS = SIGNED_ACCEPTANCE_EVIDENCE_PATHS', b'SIGNED_SETTINGS_HARNESS_PATHS = set()'),
            original_guard.replace(b'SIGNED_TRANSPORT_HARNESS_PATHS = SIGNED_ACCEPTANCE_EVIDENCE_PATHS', b'SIGNED_TRANSPORT_HARNESS_PATHS = SIGNED_ACCEPTANCE_EVIDENCE_PATHS | {"scripts/bundle.sh"}')]
        for changed in variants:
            self.assertNotEqual(changed, original_guard); fixture.original[guard] = changed
            with self.subTest(shared_guard=changed[:100]):
                self.assert_transport_guard_rejects(fixture, 'UI test build guard changed outside the transport declaration|Unsupported transport-only guard change')
        fixture.original[guard] = original_guard
        key = '.github/workflows/external-gui-acceptance.yml'
        fixture.original[key] = fixture.original[key].replace(b'runs-on: macrunner', b'runs-on: other-runner', 1)
        self.assert_transport_guard_rejects(fixture, 'UI test build workflow changed')

    def test_transport_reuse_requires_proof_explicit_context_original_attempt_and_unchanged_products(self):
        fixture = self.transport_bundle_fixture()
        with self.assertRaises(ValueError): self.resolve_transport_fixture(fixture, enabled=False)
        self.resolve_transport_fixture(fixture)
        producer_path = fixture.destination / 'tests-producer.json'; original = producer_path.read_bytes()
        producer = json.loads(original)
        changes = [dict(producer, transportCompatibility=None), {key: value for key, value in producer.items() if key != 'transportCompatibility'},
                   dict(producer, job=dict(producer['job'], run_attempt=2)),
                   dict(producer, run=dict(producer['run'], head_sha='e' * 40))]
        for key, value in [('consumerSourceSHA', 'e' * 40), ('producerFiles', {}), ('buildRecipeSHA256', 'e' * 64), ('kind', 'journey')]:
            changes.append(dict(producer, transportCompatibility=dict(producer['transportCompatibility'], **{key: value})))
        forged = copy.deepcopy(producer)
        helper = 'scripts/external-gui/test_bundle.py'
        forged['transportCompatibility']['producerBuilder'] += '\n# forged original consumer\n'
        forged['transportCompatibility']['producerFiles'][helper] = hashlib.sha256(forged['transportCompatibility']['producerBuilder'].encode()).hexdigest()
        changed_receipt = copy.deepcopy(fixture.receipt)
        changed_receipt['testFiles'] = forged['transportCompatibility']['producerFiles']
        receipt_path = fixture.destination / 'tests-input.json'
        receipt_path.write_text(json.dumps(changed_receipt))
        forged['receiptSHA256'] = journey.sha256(receipt_path)
        producer_path.write_text(json.dumps(forged))
        with patch.object(journey, 'output', side_effect=fixture.git_output), self.assertRaises(ValueError):
            bundle.verify_input(fixture.destination, fixture.current, fixture.files, transport_reuse=True)
        receipt_path.write_bytes(fixture.raw_receipt)
        producer_path.write_bytes(original)
        with patch.object(journey, 'output', side_effect=fixture.git_output):
            with self.assertRaises(ValueError): bundle.verify_input(fixture.destination, fixture.current, fixture.files)
            for changed in changes:
                producer_path.write_text(json.dumps(changed))
                with self.subTest(change=changed), self.assertRaises(ValueError):
                    bundle.verify_input(fixture.destination, fixture.current, fixture.files, transport_reuse=True)
            producer_path.write_bytes(original)
            (fixture.destination / 'tests.tar.gz').write_bytes(b'changed products')
            with self.assertRaises(ValueError):
                bundle.consume(fixture.destination, self.root / 'substituted', fixture.current, fixture.files, transport_reuse=True)

    def test_transport_reuse_rejects_unrelated_incomplete_or_product_changing_history(self):
        fixture = self.transport_bundle_fixture(); original = copy.deepcopy(fixture.comparison)
        mutations = [('status', 'diverged'), ('merge_base_commit', {'sha': 'e' * 40}), ('total_commits', 2),
                     ('files', fixture.comparison['files'][:-1]),
                     ('commits', [{'sha': 'e' * 40}]), ('files', [{'filename': 'Sources/NexGenVideo/App/NexGenVideoApp.swift', 'status': 'modified'}]),
                     ('files', [{'filename': 'scripts/external-gui/test_bundle.py', 'status': 'renamed', 'previous_filename': 'other.py'}]),
                     ('files', [{'filename': 'scripts/external-gui/test_bundle.py', 'status': 'modified'}] * 300)]
        for key, value in mutations:
            fixture.comparison.clear(); fixture.comparison.update(copy.deepcopy(original)); fixture.comparison[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError): self.resolve_transport_fixture(fixture)
        fixture.comparison.clear(); fixture.comparison.update(copy.deepcopy(original))
        fixture.history['merge_base_commit'] = {'sha': 'e' * 40}
        with self.assertRaises(ValueError): self.resolve_transport_fixture(fixture)
        fixture.history.clear(); fixture.history.update(copy.deepcopy(original))
        fixture.history['files'].append({'filename': 'Sources/NexGenVideo/App/NexGenVideoApp.swift', 'status': 'modified'})
        with self.assertRaises(ValueError): self.resolve_transport_fixture(fixture)

    def test_registered_transport_requires_existing_test_bundle_and_preserves_other_modes(self):
        import textwrap
        workflow = (journey.REPOSITORY / '.github/workflows/diagnostic-acceptance.yml').read_text()
        step = workflow.split('      - name: Require exact public transport continuation inputs\n', 1)[1].split('      - name:', 1)[0]
        code = textwrap.dedent(step.split("          python3 - <<'PY'\n", 1)[1].split('          PY', 1)[0])
        values = {'KIND': 'signed-transport', 'VERIFIED_PR': '12', 'TEST_BUNDLE': '34', 'JOURNEY_JOB': '56',
                  'JOURNEY_ARTIFACT': '78', 'JOURNEY_DIGEST': '1' * 64, 'SCALE': '1.5', 'DMG_DIGEST': '2' * 64,
                  'EXTRA_SOURCE': '', 'EXTRA_PRODUCTS': '', 'EXTRA_FAILURE': '', 'EXTRA_PRODUCTS_SHA': '', 'EXTRA_FAILURE_SHA': ''}
        result = subprocess.run([sys.executable, '-c', code], env=os.environ | values, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        for changed in [values | {'TEST_BUNDLE': value} for value in ('', '0', '-1', ' 34', 'other')]:
            self.assertNotEqual(subprocess.run([sys.executable, '-c', code], env=os.environ | changed,
                                               capture_output=True, timeout=10).returncode, 0)
        normal = values | {'KIND': 'signed-journey', 'VERIFIED_PR': '', 'JOURNEY_JOB': '', 'JOURNEY_ARTIFACT': '', 'JOURNEY_DIGEST': ''}
        self.assertNotEqual(subprocess.run([sys.executable, '-c', code], env=os.environ | normal, capture_output=True, timeout=10).returncode, 0)
        normal['TEST_BUNDLE'] = ''
        self.assertEqual(subprocess.run([sys.executable, '-c', code], env=os.environ | normal, capture_output=True, timeout=10).returncode, 0)
        entry = workflow.split('  signed-transport:\n', 1)[1].split('\n  ci-bpy-resource-diagnostic:', 1)[0]
        self.assertIn('test_bundle_run_id: ${{ inputs.test_bundle_run_id }}', entry)

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


if __name__ == '__main__':
    unittest.main()
