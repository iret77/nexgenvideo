import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import app_cohort_v2
from unittest.mock import patch
import zipfile

import retained_release_runtime as runtime

sys.path.insert(0, str(Path(__file__).parent / 'external-gui'))
import acceptance as journey
sys.path.pop(0)


class RetainedReleaseRuntimeTests(unittest.TestCase):
    def test_current_runtime_destinations_match_the_three_actual_callers(self):
        import compiled_app_release as compiled
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); workspace = root / 'workspace'; workspace.mkdir(); runner = root / 'runner'; runner.mkdir()
            env = {'GITHUB_ACTIONS': 'true', 'GITHUB_REPOSITORY': 'iret77/nexgenvideo',
                'GITHUB_RUN_ATTEMPT': '1', 'GITHUB_WORKSPACE': str(workspace), 'RUNNER_TEMP': str(runner)}
            for job, directory, base in [('analyze', workspace / '.build', workspace),
                    ('replay', runner / 'chat-replay', runner), ('acceptance', runner / 'settings-runtime', runner)]:
                with self.subTest(job=job), patch.dict(os.environ, env | {'GITHUB_JOB': job}), patch.object(compiled.sys, 'platform', 'darwin'):
                    self.assertEqual(compiled.retained_runtime_destination(directory), base)
                    with self.assertRaises(ValueError): compiled.retained_runtime_destination(base / 'unrelated')

    def test_current_runtime_pack_reuse_keeps_app_native_checks_and_records_exact_parent(self):
        import compiled_app_release as compiled
        import retained_packaging as packaging
        for changed in ('valid', 'pack', 'root-mode', 'parent-app', 'parent-archive', 'current-run'):
            with self.subTest(changed=changed), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary); runner = root / 'runner'; runner.mkdir(); workspace = root / 'workspace'; workspace.mkdir()
                directory = runner / 'chat-replay'; pack = directory / 'plugins/musicvideo.ngvpack'; pack.mkdir(parents=True)
                pack.chmod(0o755); (pack / 'image').write_bytes(b'qualified pack')
                tree = compiled.canonical_bundle_tree(pack)
                source = compiled.SIGNED_RESUME['sourceSHA']; app = {'treeSHA256': 'a' * 64, 'executableSHA256': 'e' * 64}
                receipt = {'archiveSHA256': 'b' * 64, 'appTreeSHA256': app['treeSHA256']}
                proof = {'productSourceSHA': source, 'packaging': {'qualified': 'parent'}, 'producerRunID': 777,
                    'runtimeArtifactID': 888, 'runtimeArtifactSHA256': 'd' * 64,
                    'harnessSourceSHA': 'c' * 40, 'executionRunID': '999', 'executionAttempt': '1'}
                parent = {'stage': 'complete', 'producerSourceSHA': 'c' * 40, 'runID': 777,
                    'final': {'app': app, 'runtimeArchiveSHA256': 'b' * 64, 'packTreeSHA256': tree, 'packArchiveSHA256': compiled.PACK_SHA}}
                if changed == 'pack': (pack / 'image').write_bytes(b'changed pack')
                elif changed == 'root-mode': pack.chmod(0o700)
                elif changed == 'parent-app': parent['final']['app'] = {'treeSHA256': 'f' * 64}
                elif changed == 'parent-archive': parent['final']['runtimeArchiveSHA256'] = 'f' * 64
                elif changed == 'current-run': proof['executionRunID'] = '998'
                env = {'GITHUB_ACTIONS': 'true', 'GITHUB_REPOSITORY': 'iret77/nexgenvideo', 'GITHUB_RUN_ATTEMPT': '1',
                    'GITHUB_JOB': 'replay', 'GITHUB_SHA': 'c' * 40, 'GITHUB_RUN_ID': '999',
                    'GITHUB_WORKSPACE': str(workspace), 'RUNNER_TEMP': str(runner)}
                origin = ({'id': compiled.RETAINED_RUN}, {'id': compiled.PACK_NATIVE_PROOF['jobID']},
                    {'id': compiled.FINAL_ARTIFACT[0], 'digest': 'sha256:' + compiled.FINAL_ARTIFACT[1]})
                with patch.dict(os.environ, env), patch.object(compiled.sys, 'platform', 'darwin'), \
                        patch.object(packaging, 'consumer_record', return_value=parent), patch.object(packaging, 'compiled_signed_product', return_value=True), \
                        patch.object(compiled, 'PACK_TREE', tree), patch.object(compiled, 'pack_verification_origin', return_value=origin), \
                        patch.object(journey, 'metadata', return_value=app), patch.object(app_cohort_v2, 'has_manifest', return_value=False), \
                        patch.object(runtime.subprocess, 'run') as commands, patch('builtins.print'):
                    if changed == 'valid':
                        self.assertEqual(runtime.validate_app(directory, source, receipt, proof=proof), app)
                        self.assertEqual([call.args[0][0] for call in commands.call_args_list], ['codesign', 'xcrun', 'spctl'])
                        self.assertEqual(proof['packVerificationReuse']['runtimeArtifactID'], 888)
                        self.assertEqual(proof['packVerificationReuse']['parent'], proof['packaging'])
                        self.assertFalse(proof['packVerificationReuse']['currentNativeCodesignOrStaplerPerformed'])
                        self.assertTrue((directory / 'pack-verification.reused.json').is_file())
                    else:
                        with self.assertRaises(ValueError): runtime.validate_app(directory, source, receipt, proof=proof)
                        self.assertNotIn('packVerificationReuse', proof)
                        self.assertFalse((directory / 'pack-verification.reused.json').exists())
                    self.assertFalse(any(str(pack) in call.args[0] for call in commands.call_args_list))

    def setUp(self):
        self.source, self.harness, self.digest = 'a' * 40, 'c' * 40, 'b' * 64
        self.run = dict(id=12, head_sha=self.source, path='.github/workflows/release.yml',
                        event='workflow_dispatch', status='completed', run_attempt=1,
                        repository=dict(full_name='iret77/nexgenvideo'))
        self.jobs = dict(total_count=1, jobs=[dict(id=56, name='release', status='completed', conclusion='success',
                        run_id=12, run_attempt=1, head_sha=self.source,
                        started_at='2026-11-02T20:20:00Z', completed_at='2026-11-02T20:51:00Z')])
        self.artifact = dict(id=34, name='workspace-ui-app', expired=False, digest='sha256:' + self.digest,
                        workflow_run=dict(id=12, head_sha=self.source), created_at='2026-11-02T20:47:00Z',
                        updated_at='2026-11-02T20:48:00Z', expires_at='2099-01-01T00:00:00Z')
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def bind(self, changed='scripts/retained_release_runtime.py\0'):
        with patch.object(runtime, 'api', side_effect=[self.run, self.jobs, self.artifact]), \
             patch.object(app_cohort_v2, 'has_manifest', return_value=False), \
             patch.object(runtime.subprocess, 'run') as command, \
             patch.object(runtime.subprocess, 'check_output', side_effect=[changed.encode(), self.harness]):
            artifact, proof = runtime.bind(12, self.source, 34, self.digest)
        self.assertTrue(all(call.kwargs.get('check') for call in command.call_args_list))
        return artifact, proof

    def test_exact_release_artifact_keeps_product_and_harness_provenance_separate(self):
        artifact, proof = self.bind()
        self.assertEqual(artifact, self.artifact)
        self.assertEqual(proof['productSourceSHA'], self.source)
        self.assertEqual(proof['harnessSourceSHA'], self.harness)
        self.assertEqual((proof['producerRunID'], proof['producerAttempt'], proof['producerJobID']), (12, 1, 56))
        self.assertEqual(proof['changedHarnessPaths'], ['scripts/retained_release_runtime.py'])

    def test_incomplete_or_invalid_selectors_fail_before_any_lookup(self):
        for values in ((0, self.source, 34, self.digest), (12, '', 34, self.digest),
                       (12, self.source, 0, self.digest), (12, self.source, 34, 'invalid')):
            with self.subTest(values=values), patch.object(runtime, 'api') as api, self.assertRaises(ValueError):
                runtime.bind(*values)
            api.assert_not_called()

    def test_product_lockfile_and_runtime_changes_cannot_reuse_the_app(self):
        for path in ('Sources/NexGenVideo/App/NexGenVideoApp.swift', 'Package.resolved', 'scripts/bundle.sh',
                     'scripts/bpy_runtime_acceptance.py', 'Runtime/bpy/manifest.json'):
            with self.subTest(path=path), self.assertRaises(ValueError):
                self.bind(path + '\0')

    def test_foreign_artifact_or_unfinished_release_job_is_rejected(self):
        for key, value in (('name', 'NexGenVideo-app'), ('expired', True), ('digest', 'sha256:' + 'f' * 64),
                           ('workflow_run', dict(id=13, head_sha=self.source))):
            original = copy.deepcopy(self.artifact)
            self.artifact[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.bind()
            self.artifact = original
        self.jobs['jobs'][0]['status'] = 'in_progress'
        with self.assertRaises(ValueError):
            self.bind()

    def test_dirty_checkout_and_unrelated_history_stop_before_artifact_access(self):
        for position in (0, 1):
            results = [None] * position + [subprocess.CalledProcessError(1, ['git'])]
            with self.subTest(position=position), patch.object(runtime, 'api') as api, \
                 patch.object(runtime.subprocess, 'run', side_effect=results), self.assertRaises(subprocess.CalledProcessError):
                runtime.bind(12, self.source, 34, self.digest)
            api.assert_not_called()

    def transfer(self, archive, *, broken=False):
        payload = b'exact original runtime archive'
        receipt = dict(schema='nexgenvideo/workspace-ui-input/1', sourceSHA=self.source,
                       archiveSHA256=hashlib.sha256(payload).hexdigest(), appTreeSHA256='d' * 64)
        with zipfile.ZipFile(archive, 'w') as bundle:
            bundle.writestr('workspace-ui.tar.gz', payload + (b'changed' if broken else b''))
            bundle.writestr('workspace-ui-input.json', json.dumps(receipt))
            bundle.writestr('bpy-source-receipt.json', '{}')

    def test_restore_refuses_non_ci_or_non_macos_before_downloading(self):
        for platform, actions in (('linux', 'true'), ('darwin', 'false')):
            with self.subTest(platform=platform, actions=actions), patch.object(runtime.sys, 'platform', platform), \
                 patch.dict(os.environ, GITHUB_ACTIONS=actions), patch.object(runtime, 'download') as download, \
                 self.assertRaises(ValueError):
                runtime.restore(self.artifact, {}, self.root / 'runtime')
            download.assert_not_called()

    def test_restore_checks_archive_and_app_tree_before_publishing_proof(self):
        proof = dict(productSourceSHA=self.source)
        identity = dict(treeSHA256='d' * 64, executableSHA256='e' * 64)
        with patch.object(runtime.sys, 'platform', 'darwin'), patch.dict(os.environ, GITHUB_ACTIONS='true'), \
             patch.object(runtime, 'download', side_effect=lambda artifact, archive: self.transfer(archive)), \
             patch.object(runtime.subprocess, 'run') as command, \
             patch.object(runtime, 'validate_app', return_value=identity) as validate:
            runtime.restore(self.artifact, proof, self.root / 'runtime')
        self.assertEqual(proof['appTreeSHA256'], 'd' * 64)
        self.assertEqual(proof['executableSHA256'], 'e' * 64)
        self.assertEqual(command.call_args.args[0][0:2], ['tar', '-xzf'])
        self.assertTrue(command.call_args.kwargs['check'])
        validate.assert_called_once()

    def test_changed_archive_or_preexisting_app_fails_before_extraction(self):
        for broken, name in ((True, 'changed'), (False, 'existing')):
            directory = self.root / name
            if not broken: (directory / 'NexGenVideo.app').mkdir(parents=True)
            with self.subTest(broken=broken), patch.object(runtime.sys, 'platform', 'darwin'), \
                 patch.dict(os.environ, GITHUB_ACTIONS='true'), \
                 patch.object(runtime, 'download', side_effect=lambda artifact, archive: self.transfer(archive, broken=broken)), \
                 patch.object(runtime.subprocess, 'run') as command, self.assertRaises(ValueError):
                runtime.restore(self.artifact, dict(productSourceSHA=self.source), directory)
            command.assert_not_called()

    def test_followups_skip_app_compilation_and_report_the_original_product_source(self):
        root = Path(__file__).resolve().parents[1]
        chat = (root / '.github/workflows/chat-hang-replay.yml').read_text()
        audio = (root / '.github/workflows/private-example-analysis.yml').read_text()
        for workflow in (chat, audio):
            self.assertIn("inputs.runtime_artifact == '' && inputs.runtime_run_id == ''", workflow)
            self.assertIn('retained_release_runtime.py bind', workflow)
            self.assertIn('retained_release_runtime.py restore', workflow)
            self.assertIn('--artifact-sha256 "$ORIGINAL_DIGEST"', workflow)
        self.assertIn('NGV_GIT_COMMIT: ${{ inputs.runtime_source_sha || github.sha }}', audio)
        self.assertIn("'harnessSHA': os.environ['GITHUB_SHA']", audio)

    def test_changed_app_tree_or_failed_signature_cannot_be_accepted(self):
        (self.root / 'plugins/musicvideo.ngvpack').mkdir(parents=True)
        identity = dict(treeSHA256='d' * 64)
        with patch.object(journey, 'metadata', return_value=identity), \
             patch.object(runtime.subprocess, 'run') as command, self.assertRaises(ValueError):
            runtime.validate_app(self.root, self.source, dict(appTreeSHA256='f' * 64))
        command.assert_not_called()
        with patch.object(journey, 'metadata', return_value=identity), \
             patch.object(runtime.subprocess, 'run', side_effect=subprocess.CalledProcessError(1, ['codesign'])), \
             self.assertRaises(subprocess.CalledProcessError):
            runtime.validate_app(self.root, self.source, dict(appTreeSHA256='d' * 64))


if __name__ == '__main__':
    unittest.main()
