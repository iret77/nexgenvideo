from pathlib import Path
import json
import os
import subprocess
import sys
import tempfile
import textwrap
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, mock_open, patch
import zipfile

import yaml

from hang_diagnostic_acceptance import capture_helper_failure, verify_helper_recovery, verify_retained_key
from verify_diagnostic_candidate import APP_DIAGNOSTIC_PATHS, BPY_DIAGNOSTIC_PATHS, CAPTURE_HARNESS_PATHS, CI_HARNESS_PATHS, HARNESS_PATHS, verify, verify_app_crash_archive, verify_app_diagnostic, verify_bpy_diagnostic, verify_ci
from verify_diagnostic_candidate import SIGNED_BPY_HARNESS_PATHS, SIGNED_JOURNEY_HARNESS_PATHS, verify_signed_bpy, verify_signed_journey
from verify_diagnostic_candidate import SIGNED_DESKTOP_HARNESS_PATHS, SIGNED_WORKSPACE_HARNESS_PATHS, verify_signed_desktop, verify_signed_workspace


class NativeAppTargetWorkflowTests(unittest.TestCase):
    def test_registered_target_builder_uses_exact_source_binding_and_preserves_each_product_before_the_next(self):
        workflow = yaml.safe_load((Path(__file__).resolve().parent.parent / '.github/workflows/diagnostic-acceptance.yml').read_text())
        source = workflow['jobs']['source']
        job = workflow['jobs']['app-target-build']
        self.assertEqual(job['runs-on'], 'macrunner')
        self.assertEqual(job['needs'], 'source')
        self.assertEqual(job['if'], "inputs.candidate_kind == 'native-app-targets'")
        self.assertEqual(job['env']['TARGET_BINDING_ARTIFACT_ID'], '${{ needs.source.outputs.target-binding-id }}')
        self.assertEqual(job['env']['TARGET_BINDING_DIGEST'], '${{ needs.source.outputs.target-binding-digest }}')
        steps = job['steps']; indexes = {step['id']: index for index, step in enumerate(steps) if 'id' in step}
        for phase, next_phase in [('production', 'testable'), ('testable', 'tests'), ('tests', None)]:
            compiled, uploaded = indexes[phase], indexes[phase + '_upload']
            self.assertLess(compiled, uploaded)
            if next_phase: self.assertLess(uploaded, indexes[next_phase])
            self.assertEqual(steps[uploaded]['with']['name'], 'app-target-' + phase + '-products')
            self.assertIn('always()', steps[uploaded]['if'])
            self.assertEqual(steps[uploaded]['with']['if-no-files-found'], 'error')
        self.assertFalse(any(step.get('continue-on-error') for step in steps))
        self.assertTrue(any(step.get('with', {}).get('name') == 'app-target-retention-fallback' for step in steps))
        for artifact in ('app-target-retention-fallback', 'app-target-build-evidence'):
            upload = next(step for step in steps if step.get('with', {}).get('name') == artifact)
            self.assertIn('always()', upload['if'])
            self.assertIn('${{ runner.temp }}/app-target-build/tests-driver-plan/', upload['with']['path'])
            self.assertTrue(upload['with']['include-hidden-files'])
        self.assertEqual(source['outputs']['target-binding-id'], '${{ steps.target-binding-upload.outputs.artifact-id }}')


class CaptureOriginalRetentionTests(unittest.TestCase):
    def test_initial_capture_failure_preserves_original_exception_and_owned_bytes(self):
        import hang_diagnostic_acceptance as capture
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            root = home / "Library/Logs/NexGenVideo/HangIncidents"
            output = home / "evidence"
            error = AssertionError("three dropped snapshots")

            def fail(args):
                folder = root / "own-recording"
                folder.mkdir(parents=True)
                (folder / "heartbeat.json").write_text(json.dumps({"processID": 123, "dropped": 3}))
                (folder / "events-1.json").write_bytes(b'[{"sequence":1}]')
                (folder / "self-1.stacks").write_bytes(b"exact original stack\x00\xff")
                capture._capture_processes[123] = "wait"
                raise error

            with patch.object(capture.Path, "home", return_value=home), \
                    patch.object(sys, "argv", ["capture", "App.app", "Symbols.dSYM", "--output", str(output)]), \
                    patch.object(capture, "verify", side_effect=fail):
                with self.assertRaises(AssertionError) as raised:
                    capture.main()
            self.assertIs(raised.exception, error)
            with zipfile.ZipFile(output / "capture-recordings.zip") as archive:
                self.assertEqual(archive.read("own-recording/self-1.stacks"), b"exact original stack\x00\xff")
                self.assertEqual(json.loads(archive.read("own-recording/heartbeat.json"))["dropped"], 3)
            receipt = json.loads((output / "capture-originals.json").read_text())
            self.assertEqual(receipt["recordings"], [{"name": "own-recording", "pid": 123, "mode": "wait"}])
            self.assertFalse(receipt["captureErrors"])

    def test_capture_process_keeps_raw_output_and_closed_stdin(self):
        import hang_diagnostic_acceptance as capture
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)

            def spawn(command, **kwargs):
                self.assertEqual(command, ["App.app/Contents/MacOS/NexGenVideo"])
                self.assertEqual(kwargs["stdin"], subprocess.DEVNULL)
                self.assertEqual(kwargs["stderr"], subprocess.STDOUT)
                kwargs["stdout"].write(b"raw output before failure\x00\xff")
                return SimpleNamespace(pid=123)

            with patch.object(capture.subprocess, "Popen", side_effect=spawn), \
                    patch.dict(capture._capture_processes, {}, clear=True):
                capture.launch_capture(["App.app/Contents/MacOS/NexGenVideo"], {}, output, "wait")
                self.assertEqual(capture._capture_processes, {123: "wait"})
            self.assertEqual((output / "capture-wait.log").read_bytes(), b"raw output before failure\x00\xff")

    def test_retention_write_failure_never_masks_original_capture_failure(self):
        import hang_diagnostic_acceptance as capture
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            error = AssertionError("original capture failure")
            with patch.object(capture.Path, "home", return_value=home), \
                    patch.object(sys, "argv", ["capture", "App.app", "Symbols.dSYM", "--output", str(home / "evidence")]), \
                    patch.object(capture, "verify", side_effect=error), \
                    patch.object(capture, "retain_capture_recordings", side_effect=OSError), \
                    patch.object(capture.sys, "stderr"):
                with self.assertRaises(AssertionError) as raised:
                    capture.main()
            self.assertIs(raised.exception, error)

    def test_retention_refuses_foreign_recordings_and_symlink_escapes(self):
        import hang_diagnostic_acceptance as capture
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "recordings"
            output = Path(directory) / "evidence"
            output.mkdir()
            for name, pid in (("foreign", 456), ("linked", 123)):
                folder = root / name
                folder.mkdir(parents=True)
                (folder / "heartbeat.json").write_text(json.dumps({"processID": pid}))
            secret = Path(directory) / "outside"
            secret.write_bytes(b"must never be archived")
            (root / "linked/escape").symlink_to(secret)
            with patch.dict(capture._capture_processes, {123: "wait"}, clear=True):
                receipt = capture.retain_capture_recordings(root, set(), output)
            with zipfile.ZipFile(output / "capture-recordings.zip") as archive:
                self.assertEqual(archive.namelist(), [])
            self.assertEqual(receipt["unmatched"], [{"name": "foreign", "reason": "unowned-process"}])
            self.assertEqual(receipt["captureErrors"], [{"name": "linked", "error": "ValueError"}])

    def test_startup_and_all_four_key_children_can_use_the_recorded_launcher(self):
        import hang_diagnostic_acceptance as capture
        import verify_hang_startup as startup
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            process = Mock(pid=123)
            process.poll.return_value = None
            launch = Mock(return_value=process)
            with patch.object(startup.Path, "home", return_value=home), \
                    patch.object(startup.time, "monotonic", side_effect=[0, 16]):
                result = startup.verify_startup(home / "App.app", starts=0, launch=launch)
            self.assertTrue(result["disabledChecked"])
            self.assertEqual(launch.call_args.args[2], "0-disabled")
            process.terminate.assert_called_once()
            children = [Mock(returncode=code) for code in [0, 70, 70, 0]]
            for child in children:
                child.poll.return_value = child.returncode
            with patch.object(capture, "launch_capture", side_effect=children) as launch:
                capture.verify_retained_key(home / "App.app", "hang-diagnostic-" + "a" * 8 + "-" + "b" * 4 +
                    "-" + "c" * 4 + "-" + "d" * 4 + "-" + "e" * 12, "generated-test-key", output=home)
            self.assertEqual([call.args[3] for call in launch.call_args_list],
                             ["retained-key-0", "retained-key-1", "retained-key-2", "retained-key-3"])
            for child in children:
                child.wait.assert_called_once_with(timeout=15)

    def test_rc_capture_reuses_only_exact_owned_macrunner_release_and_unchanged_app(self):
        from copy import deepcopy
        source, digest = "a" * 40, "b" * 64
        run = dict(id=12, head_sha=source, path=".github/workflows/release.yml", event="workflow_dispatch",
                   head_branch="iret77/rc-delivery-base", status="completed", run_attempt=1,
                   repository=dict(full_name="iret77/nexgenvideo"), actor=dict(login="iret77"))
        jobs = dict(total_count=1, jobs=[dict(name="release", status="completed", conclusion="success",
                    run_id=12, head_sha=source, run_attempt=1, labels=["macrunner"],
                    started_at="2026-11-08T00:00:00Z", completed_at="2026-11-08T00:10:00Z")])
        artifact = dict(id=34, name="diagnostic-release-evidence", expired=False, digest="sha256:" + digest,
                        workflow_run=dict(id=12, head_sha=source), created_at="2026-11-08T00:05:00Z",
                        updated_at="2026-11-08T00:05:01Z", expires_at="2099-01-01T00:00:00Z")
        changed = {".github/workflows/diagnostic-acceptance.yml", ".github/workflows/release.yml",
                   "scripts/hang_diagnostic_acceptance.py", "scripts/verify_hang_startup.py",
                   "scripts/verify_diagnostic_candidate.py", "scripts/test_diagnostic_acceptance.py"}
        self.assertEqual(CAPTURE_HARNESS_PATHS, changed)
        verify(run, jobs, artifact, 12, source, 34, digest, changed)
        for field, bad in (("actor", dict(login="foreign")), ("run_attempt", 2), ("head_sha", "c" * 40)):
            changed = deepcopy(run)
            changed[field] = bad
            with self.subTest(field=field), self.assertRaises(ValueError):
                verify(changed, jobs, artifact, 12, source, 34, digest, HARNESS_PATHS)
        jobs["jobs"][0]["labels"] = ["macos-27"]
        with self.assertRaisesRegex(ValueError, "macrunner"):
            verify(run, jobs, artifact, 12, source, 34, digest, HARNESS_PATHS)
        jobs["jobs"][0]["labels"] = ["macrunner"]
        with self.assertRaisesRegex(ValueError, "application or build inputs"):
            verify(run, jobs, artifact, 12, source, 34, digest, [*HARNESS_PATHS, "Sources/NexGenVideo/App/AppDelegate.swift"])

    def test_retained_rc_capture_requires_exact_product_and_successful_owned_release(self):
        from copy import deepcopy
        import retained_packaging as packaging
        source, producer, checksum = 'a' * 40, 'b' * 40, 'c' * 64
        record = {'producerSourceSHA': producer}
        run = {'id': 12, 'head_sha': producer, 'head_branch': 'iret77/rc-delivery-base',
               'path': '.github/workflows/release.yml', 'event': 'workflow_dispatch', 'run_attempt': 1,
               'status': 'completed', 'conclusion': 'failure', 'repository': {'full_name': packaging.REPOSITORY},
               'actor': {'login': 'iret77'}}
        job = {'name': 'release', 'run_id': 12, 'head_sha': producer, 'run_attempt': 1, 'labels': ['macrunner'],
               'status': 'completed', 'conclusion': 'success', 'started_at': '2026-11-10T00:00:00Z',
               'completed_at': '2026-11-10T00:10:00Z'}
        artifact = {'id': 34, 'name': 'diagnostic-release-evidence', 'expired': False, 'digest': 'sha256:' + checksum,
                    'workflow_run': {'id': 12, 'head_sha': producer}, 'created_at': '2026-11-10T00:05:00Z',
                    'updated_at': '2026-11-10T00:05:01Z', 'expires_at': '2099-01-01T00:00:00Z'}
        for variant in ('valid', 'foreign', 'failed-release', 'native-input', 'main'):
            actual, release = deepcopy(run), deepcopy(job)
            paths = ['scripts/retained_packaging.py']
            if variant == 'foreign': actual['actor']['login'] = 'foreign'
            if variant == 'failed-release': release['conclusion'] = 'failure'
            if variant == 'native-input': paths += ['Sources/NexGenVideo/App/AppDelegate.swift']
            if variant == 'main': actual['head_branch'] = 'main'
            with self.subTest(variant=variant), patch.object(packaging, 'load_provenance', return_value={'record': record}), \
                    patch.object(packaging, 'component_consumer_repair_paths', return_value={'scripts/retained_packaging.py'}):
                args = (actual, {'total_count': 1, 'jobs': [release]}, artifact, 12, source, 34, checksum, paths)
                if variant == 'valid': verify(*args, packaging={'exact': 'selectors'})
                else:
                    with self.assertRaises(ValueError): verify(*args, packaging={'exact': 'selectors'})

    def test_retained_capture_rebinds_current_product_before_execution_and_keeps_all_release_cases(self):
        root = Path(__file__).resolve().parents[1]
        workflow = yaml.safe_load((root / '.github/workflows/diagnostic-acceptance.yml').read_text())
        steps = workflow['jobs']['acceptance']['steps']
        checkout = next(step for step in steps if step.get('uses', '').startswith('actions/checkout@'))
        self.assertEqual(checkout['with']['fetch-depth'], 0)
        positions = {step.get('name'): index for index, step in enumerate(steps)}
        bind = next(step for step in steps if step.get('name') == 'Rebind retained packaging before diagnostic app execution')
        self.assertLess(positions[bind['name']], positions['Retrieve the exact signed candidate'])
        self.assertIn('consumer_harness(bound', bind['run'])
        self.assertIn('packaging=selected', bind['run'])
        self.assertEqual(bind['if'], "inputs.packaging_producer_source_sha != ''")
        recovery = next(step for step in steps if step.get('name') == 'Verify generation batch pricing recovery')
        self.assertIn('NGV_SELFTEST_GENERATION_BATCH_RECOVERY=1', recovery['run'])
        self.assertIn("grep -qx 'SELFTEST_GENERATION_BATCH_RECOVERY_OK'", recovery['run'])
        termination = next(step for step in steps if step.get('name') == 'Verify asynchronous termination, cancellation and restart')
        self.assertIn('app_termination_acceptance.py NexGenVideo.app', termination['run'])
        self.assertIn('--product-source "$CANDIDATE_SOURCE"', termination['run'])
        upload = next(step for step in steps if step.get('with', {}).get('name') == 'diagnostic-runtime-acceptance')
        self.assertIn('evidence/termination/', upload['with']['path'].splitlines())
        self.assertIn('evidence/packaging-provenance/', upload['with']['path'].splitlines())

    def test_both_registered_capture_callers_retain_all_logs_and_original_recordings(self):
        root = Path(__file__).resolve().parents[1]
        for filename, jobname in (("diagnostic-acceptance.yml", "acceptance"), ("release.yml", "diagnostic-acceptance")):
            workflow = yaml.safe_load((root / ".github/workflows" / filename).read_text())
            upload = next(step for step in workflow["jobs"][jobname]["steps"]
                          if step.get("with", {}).get("name") == "diagnostic-runtime-acceptance")
            self.assertEqual(upload["if"], "always()")
            self.assertIn("evidence/*.log", upload["with"]["path"].splitlines())
            self.assertIn("evidence/capture-*.zip", upload["with"]["path"].splitlines())


class DiagnosticCompiledClientRouteTests(unittest.TestCase):
    def setUp(self):
        self.workflow = yaml.safe_load((Path(__file__).resolve().parents[1] / '.github/workflows/diagnostic-acceptance.yml').read_text())
        self.inputs = self.workflow.get('on', self.workflow.get(True))['workflow_dispatch']['inputs']
        self.steps = self.workflow['jobs']['source']['steps']
        guard = next(step for step in self.steps if step.get('name') == 'Require exact compiled UI client selectors')
        self.code = guard['run'].split("python3 - <<'PY'\n", 1)[1].rsplit('\nPY', 1)[0]
        self.env = dict(KIND='signed-transport', TEST_BUNDLE_RUN_ID='12', TEST_BUNDLE_ARTIFACT_ID='34',
                        TEST_BUNDLE_ARTIFACT_SHA256='b' * 64, GITHUB_SHA='a' * 40)
        self.fields = ('TEST_BUNDLE_RUN_ID', 'TEST_BUNDLE_ARTIFACT_ID', 'TEST_BUNDLE_ARTIFACT_SHA256')
        with patch.object(sys, 'path', [str(Path(__file__).parent / 'external-gui'), *sys.path]):
            import test_bundle
        self.bundle = test_bundle

    def guard(self, **changes):
        with patch.dict(os.environ, dict(self.env, **changes), clear=True), patch.object(sys, 'path', sys.path.copy()):
            exec(compile(self.code, '<diagnostic-client-guard>', 'exec'), {})

    def test_signed_modes_accept_the_exact_tuple_without_resolving_another_artifact(self):
        with patch.object(self.bundle, 'api') as api, patch.object(self.bundle, 'validate_client_source',
                wraps=self.bundle.validate_client_source) as validate:
            for kind in ('signed-journey', 'signed-transport'):
                with self.subTest(kind=kind):
                    self.guard(KIND=kind)
                    validate.assert_called_with('12', '34', 'b' * 64, 'a' * 40)
            api.assert_not_called()

    def test_journey_preserves_empty_and_same_source_run_only_but_rejects_foreign_run_only(self):
        with patch.object(self.bundle, 'api') as api:
            self.guard(KIND='signed-journey', **dict.fromkeys(self.fields, ''))
            api.assert_not_called()
            api.return_value = dict(repository=dict(full_name='iret77/nexgenvideo'), head_sha='a' * 40)
            self.guard(KIND='signed-journey', TEST_BUNDLE_ARTIFACT_ID='', TEST_BUNDLE_ARTIFACT_SHA256='')
            api.assert_called_once_with('/actions/runs/12')
            api.return_value['head_sha'] = 'c' * 40
            with self.assertRaisesRegex(ValueError, 'different client source'):
                self.guard(KIND='signed-journey', TEST_BUNDLE_ARTIFACT_ID='', TEST_BUNDLE_ARTIFACT_SHA256='')

    def test_transport_rejects_every_incomplete_tuple_before_any_remote_lookup(self):
        with patch.object(self.bundle, 'api') as api:
            for kind, scenario in (('signed-transport', 'journey'), ('signed-journey', 'normal-fresh-local-musicvideo')):
                for mask in range(7):
                    changes = {key: self.env[key] if mask & (1 << index) else '' for index, key in enumerate(self.fields)}
                    with self.subTest(kind=kind, mask=mask), self.assertRaisesRegex(ValueError, 'exact original compiled UI client'):
                        self.guard(KIND=kind, JOURNEY_SCENARIO=scenario, **changes)
            api.assert_not_called()

    def test_signed_modes_reject_malformed_client_identity_and_consumer_source(self):
        for kind in ('signed-journey', 'signed-transport'):
            for field, value in (('TEST_BUNDLE_RUN_ID', '0'), ('TEST_BUNDLE_RUN_ID', ' 12'),
                                 ('TEST_BUNDLE_ARTIFACT_ID', '-1'), ('TEST_BUNDLE_ARTIFACT_ID', '3.4'),
                                 ('TEST_BUNDLE_ARTIFACT_SHA256', 'B' * 64), ('TEST_BUNDLE_ARTIFACT_SHA256', 'b' * 63),
                                 ('GITHUB_SHA', 'a' * 39)):
                with self.subTest(kind=kind, field=field, value=value), self.assertRaises(ValueError):
                    self.guard(KIND=kind, **{field: value})

    def test_other_modes_reject_each_ignored_selector_before_any_remote_lookup(self):
        with patch.object(self.bundle, 'api') as api:
            for kind in self.inputs['candidate_kind']['options']:
                if kind in ('signed-journey', 'signed-transport'):
                    continue
                self.guard(KIND=kind, **dict.fromkeys(self.fields, ''))
                for field in self.fields:
                    selected = dict.fromkeys(self.fields, '')
                    selected[field] = self.env[field]
                    with self.subTest(kind=kind, field=field), self.assertRaisesRegex(ValueError, 'cannot be ignored'):
                        self.guard(KIND=kind, **selected)
            api.assert_not_called()

    def test_registered_caller_exposes_and_forwards_all_three_exact_selectors(self):
        self.assertLessEqual(len(self.inputs), 25)
        for name in ('test_bundle_run_id', 'test_bundle_artifact_id', 'test_bundle_artifact_sha256'):
            self.assertEqual(self.inputs[name], dict(description=self.inputs[name]['description'], type='string', default=''))
            for kind in ('signed-journey', 'signed-transport'):
                job = self.workflow['jobs'][kind]
                self.assertEqual(job['needs'], ['source', 'transport-fixture'] if kind == 'signed-transport' else 'source')
                self.assertEqual(job['uses'], './.github/workflows/external-gui-acceptance.yml')
                self.assertEqual(job['with'][name], '${{ inputs.' + name + ' }}')

    def test_original_transport_validator_keeps_native_xcode_and_pinned_media_tools(self):
        source = self.workflow['jobs']['source']
        self.assertEqual(source['runs-on'], 'ubuntu-24.04')
        fixture_job = self.workflow['jobs']['transport-fixture']
        self.assertEqual(fixture_job['needs'], 'source')
        self.assertEqual(fixture_job['if'], "inputs.candidate_kind == 'signed-transport'")
        self.assertEqual(fixture_job['runs-on'], 'macrunner')
        self.assertEqual(fixture_job['timeout-minutes'], 10)
        steps = fixture_job['steps']
        self.assertEqual(steps[0]['uses'], 'actions/checkout@v4')
        self.assertEqual(steps[0]['with']['fetch-depth'], 0)
        self.assertFalse(any(step.get('id') == 'transport_fixture' for step in self.steps))
        setup = next(step for step in steps if step.get('id') == 'fixture-media-tools')
        self.assertEqual(setup['if'], "inputs.candidate_kind == 'signed-transport'")
        self.assertEqual(setup['uses'], 'mamba-org/setup-micromamba@f457c30a868e4760d3a6fcea5f25dc655b8edf39')
        self.assertEqual(setup['with']['create-args'], 'ffmpeg=9.0.2=gpl_*')
        self.assertEqual(setup['with']['micromamba-root-path'], '${{ runner.temp }}/micromamba')
        self.assertEqual(setup['with']['post-cleanup'], 'all')
        inspect = next(step for step in steps if step.get('name') == 'Require independent fixture media inspection')
        self.assertEqual(inspect['if'], setup['if'])
        self.assertEqual(inspect['env']['MEDIA_TOOLS_BIN'], '${{ steps.fixture-media-tools.outputs.environment-path }}/bin')
        for command in ('test "$(uname -m)" = arm64', '"$MEDIA_TOOLS_BIN/ffmpeg" -version',
                        '"$MEDIA_TOOLS_BIN/ffprobe" -version', 'echo "$MEDIA_TOOLS_BIN" >> "$GITHUB_PATH"'):
            self.assertIn(command, inspect['run'])
        fixture = next(step for step in steps if step.get('id') == 'transport_fixture')
        self.assertEqual(fixture['if'], setup['if'])
        self.assertLess(steps.index(setup), steps.index(inspect))
        self.assertLess(steps.index(inspect), steps.index(fixture))
        self.assertIn('python3 scripts/external-gui/transport_fixture.py --run-id "$CANDIDATE_RUN"', fixture['run'])
        self.assertNotIn('xcodebuild', '\n'.join(step.get('run', '') for step in self.steps + steps))
        consumer = self.workflow['jobs']['signed-transport']['with']
        for output in ('fixture_artifact_id', 'fixture_sha256'):
            self.assertEqual(consumer[output], '${{ needs.transport-fixture.outputs.' + output + ' }}')


class DiagnosticLocalMusicvideoRouteTests(unittest.TestCase):
    def setUp(self):
        self.workflow = yaml.safe_load((Path(__file__).resolve().parents[1] / '.github/workflows/diagnostic-acceptance.yml').read_text())
        self.inputs = self.workflow.get('on', self.workflow.get(True))['workflow_dispatch']['inputs']
        self.steps = self.workflow['jobs']['source']['steps']
        step = next(row for row in self.steps if row.get('name') == 'Require exact local Musicvideo continuation inputs')
        self.code = step['run'].split("python3 - <<'PY'\n", 1)[1].rsplit('\nPY', 1)[0]
        self.env = dict(KIND='signed-journey', JOURNEY_SCENARIO='normal-fresh-local-musicvideo', CATALOG_DIGEST='c' * 64,
            SCALE='1.5', VERIFIED_PR='12', DMG_DIGEST='d' * 64, PRODUCER_RUN='34', PRODUCER_SOURCE='a' * 40,
            RUNTIME_ARTIFACT='56', RUNTIME_DIGEST='e' * 64)

    def guard(self, **changes):
        with patch.dict(os.environ, dict(self.env, **changes), clear=True):
            exec(compile(self.code, '<local-musicvideo-inputs>', 'exec'), {})

    def test_local_case_uses_exact_dmg_catalog_client_and_current_source_through_the_registered_caller(self):
        self.guard()
        self.assertLessEqual(len(self.inputs), 25)
        self.assertEqual(self.inputs['journey_scenario']['default'], 'journey')
        self.assertEqual(self.inputs['journey_scenario']['options'], ['journey', 'normal-fresh-local-musicvideo'])
        job = self.workflow['jobs']['signed-journey']
        self.assertEqual(job['needs'], 'source')
        self.assertEqual(job['uses'], './.github/workflows/external-gui-acceptance.yml')
        self.assertEqual(job['with']['scenario'], "${{ inputs.journey_scenario || 'journey' }}")
        self.assertEqual(job['with']['expected_catalog_sha256'], '${{ inputs.expected_catalog_sha256 }}')
        self.assertEqual(job['with']['expected_pack_sha256'], "${{ inputs.journey_scenario == 'normal-fresh-local-musicvideo' && '37fcee05d1ac334b20eb392c61cc3b7a94af165dc3b967c61602bc79d6dc4388' || '' }}")
        for field in ('test_bundle_run_id', 'test_bundle_artifact_id', 'test_bundle_artifact_sha256', 'verified_pr_run_id'):
            self.assertEqual(job['with'][field], '${{ inputs.' + field + ' }}')
        proof = next(row for row in self.steps if row.get('name') == 'Reuse complete current merged PR source proof')
        self.assertIn("(inputs.candidate_kind == 'signed-journey' && inputs.journey_scenario == 'normal-fresh-local-musicvideo')", proof['if'])
        for field, value in [('SCALE', '1'), ('SCALE', 'all'), ('VERIFIED_PR', ''), ('PRODUCER_RUN', '0'),
                ('RUNTIME_ARTIFACT', '-1'), ('PRODUCER_SOURCE', 'a' * 39), ('CATALOG_DIGEST', ''),
                ('CATALOG_DIGEST', 'C' * 64), ('DMG_DIGEST', 'd' * 63), ('RUNTIME_DIGEST', 'e' * 63)]:
            with self.subTest(field=field, value=value), self.assertRaises(ValueError): self.guard(**{field: value})

    def test_default_journey_is_neutral_but_no_other_mode_or_scenario_can_ignore_local_catalog_inputs(self):
        for kind in self.inputs['candidate_kind']['options']:
            with self.subTest(kind=kind):
                self.guard(KIND=kind, JOURNEY_SCENARIO='journey', CATALOG_DIGEST='')
                self.guard(KIND=kind, JOURNEY_SCENARIO='', CATALOG_DIGEST='')
            if kind != 'signed-journey':
                with self.subTest(kind=kind), self.assertRaises(ValueError): self.guard(KIND=kind)
        for scenario in ('journey', '', 'transport', 'unknown'):
            with self.subTest(scenario=scenario), self.assertRaises(ValueError): self.guard(JOURNEY_SCENARIO=scenario)


class AppCrashCandidateTests(unittest.TestCase):
    def setUp(self):
        self.source = "a" * 40
        self.digest = "b" * 64
        self.run = dict(id=12, head_sha=self.source, path=".github/workflows/ci-batch.yml",
                        event="workflow_dispatch", status="completed", conclusion="failure", run_attempt=1,
                        repository=dict(full_name="iret77/nexgenvideo"))
        prefix = "Compile, unit tests, app and native bpy acceptance / "
        self.jobs = dict(jobs=[dict(name=prefix + name, status="completed", conclusion="success",
                                   run_id=12, run_attempt=1, head_sha=self.source)
                              for name in ("Light Checks", "Agent UI Evidence", "bpy-source / source")])
        self.jobs["jobs"].append(dict(name=prefix + "Build & Test", status="completed", conclusion="failure",
                                     run_id=12, run_attempt=1, head_sha=self.source,
                                     started_at="2026-10-24T00:17:15Z", completed_at="2026-10-24T00:26:52Z",
                                     steps=[dict(name=name, status="completed", conclusion=result) for name, result in (
                                         ("Build", "success"), ("Verify build did not mutate tracked source", "success"),
                                         ("Stage test runtime inputs", "success"), ("Test", "failure"),
                                         ("Upload render review test diagnosis", "success"), ("Upload .app artifact", "skipped"))]))
        self.jobs["total_count"] = len(self.jobs["jobs"])
        self.artifact = dict(id=34, name="render-review-test-diagnostic-12", expired=False,
                             digest="sha256:" + self.digest, workflow_run=dict(id=12, head_sha=self.source),
                             created_at="2026-10-24T00:26:45Z", updated_at="2026-10-24T00:26:46Z",
                             expires_at="2099-01-01T00:00:00Z")

    def check(self, paths=APP_DIAGNOSTIC_PATHS):
        verify_app_diagnostic(self.run, self.jobs, self.artifact, 12, self.source, 34, self.digest, paths)

    def test_accepts_exact_failed_test_producer_with_successful_build(self):
        self.check()

    def test_rejects_foreign_or_nonfailed_producer(self):
        for key, bad in (("head_sha", "c" * 40), ("id", 13), ("conclusion", "success"),
                         ("status", "in_progress"), ("event", "push"), ("run_attempt", 0),
                         ("path", ".github/workflows/ci.yml"), ("repository", dict(full_name="other/repo"))):
            old = self.run[key]
            self.run[key] = bad
            with self.subTest(field=key), self.assertRaises(ValueError):
                self.check()
            self.run[key] = old

    def test_every_prerequisite_must_belong_to_this_source_and_attempt(self):
        for job in self.jobs["jobs"]:
            for key, bad in (("run_attempt", 2), ("head_sha", "c" * 40), ("run_id", 13), ("status", "in_progress")):
                old = job[key]
                job[key] = bad
                with self.subTest(job=job["name"], field=key), self.assertRaises(ValueError):
                    self.check()
                job[key] = old

    def test_missing_duplicate_or_failed_prerequisites_cannot_be_hidden(self):
        from copy import deepcopy
        original = deepcopy(self.jobs)
        for change in ("missing", "duplicate", "truncated", "failed"):
            self.jobs = deepcopy(original)
            if change == "missing": self.jobs["jobs"].pop(0)
            elif change == "duplicate": self.jobs["jobs"].append(self.jobs["jobs"][0])
            elif change == "failed": self.jobs["jobs"][0]["conclusion"] = "failure"
            if change != "truncated": self.jobs["total_count"] = len(self.jobs["jobs"])
            else: self.jobs["total_count"] += 1
            with self.subTest(change=change), self.assertRaises(ValueError):
                self.check()

    def test_a_failed_build_or_additional_failure_cannot_be_reclassified(self):
        steps = self.jobs["jobs"][-1]["steps"]
        for step in steps:
            old = step["conclusion"]
            step["conclusion"] = "success" if old != "success" else "failure"
            with self.subTest(step=step["name"]), self.assertRaises(ValueError):
                self.check()
            step["conclusion"] = old
        steps.append(dict(name="another failure", status="completed", conclusion="failure"))
        with self.assertRaises(ValueError):
            self.check()

    def test_artifact_cannot_come_from_another_attempt_or_be_substituted(self):
        for key, bad in (("created_at", "2026-10-24T00:00:00Z"), ("updated_at", "2026-10-24T00:27:00Z"),
                         ("expires_at", "2020-01-01T00:00:00Z"), ("digest", "sha256:" + "c" * 64),
                         ("expired", True), ("id", 35), ("name", "NexGenVideo-app"),
                         ("workflow_run", dict(id=13, head_sha=self.source))):
            old = self.artifact[key]
            self.artifact[key] = bad
            with self.subTest(field=key), self.assertRaises(ValueError):
                self.check()
            self.artifact[key] = old

    def test_original_product_tests_and_capture_code_must_remain_identical(self):
        for path in ("Tests/NexGenVideoTests/Rendering/GlowKernelTests.swift", "Metal/Glow.metal", "Package.swift",
                     "Sources/NexGenVideo/Compositing/Kernels/GlowKernel.swift", "Tests/AppKitTestHost/AppKitTestHost.swift",
                     "scripts/stage_test_runtime.sh", ".github/workflows/ci.yml"):
            with self.subTest(path=path), self.assertRaises(ValueError):
                self.check([*APP_DIAGNOSTIC_PATHS, path])

    def test_original_archive_must_prove_successful_prior_phases_and_owned_signal(self):
        from copy import deepcopy
        import hashlib
        base = {
            "run.json": dict(runID="12", sourceSHA=self.source, testExitCode=139, effectiveExitCode=139),
            "hosted-suite/suite.json": dict(sourceSHA=self.source, completed=False, scope="all", filter="", phases=[
                dict(name=name, exitCode=0, status="verified-execution", framework=dict(passed=True))
                for name in ("xctest", "engine-swift-testing")] + [
                    dict(name="app-swift-testing", exitCode=-11, status="failed", pid=123)]),
            "hosted-suite/app-swift-testing/post-mortem/receipt.json": dict(
                status="bound-report-captured", originalExitCode=-11, ownedChild=dict(pid=123),
                reports=[dict(file="owned-host-0.ips")]),
        }
        changes = ("valid", "wrong-digest", "wrong-run", "wrong-source", "hidden-exit", "filtered", "engine-failed",
                   "missing-phase", "completed", "wrong-signal", "foreign-pid", "unbound-report", "duplicate")
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "original.zip"
            for change in changes:
                records = deepcopy(base)
                original = records["run.json"]
                suite = records["hosted-suite/suite.json"]
                receipt = records["hosted-suite/app-swift-testing/post-mortem/receipt.json"]
                if change == "wrong-run": original["runID"] = "13"
                elif change == "wrong-source": suite["sourceSHA"] = "c" * 40
                elif change == "hidden-exit": original["effectiveExitCode"] = 0
                elif change == "filtered": suite["filter"] = "GlowKernelTests"
                elif change == "engine-failed": suite["phases"][1]["framework"]["passed"] = False
                elif change == "missing-phase": suite["phases"].pop(0)
                elif change == "completed": suite["completed"] = True
                elif change == "wrong-signal": suite["phases"][-1]["exitCode"] = -6
                elif change == "foreign-pid": receipt["ownedChild"]["pid"] = 999
                elif change == "unbound-report": receipt["reports"] = []
                with zipfile.ZipFile(path, "w") as archive:
                    for name, value in records.items(): archive.writestr(name, json.dumps(value))
                    if change == "duplicate":
                        import warnings
                        with warnings.catch_warnings():
                            warnings.simplefilter("ignore", UserWarning)
                            archive.writestr("run.json", json.dumps(original))
                digest = hashlib.sha256(path.read_bytes()).hexdigest() if change != "wrong-digest" else "0" * 64
                with self.subTest(change=change):
                    if change == "valid": verify_app_crash_archive(path, 12, self.source, digest)
                    else:
                        with self.assertRaises(ValueError):
                            verify_app_crash_archive(path, 12, self.source, digest)


class CandidateProvenanceTests(unittest.TestCase):
    def setUp(self):
        self.source = "a" * 40
        self.digest = "b" * 64
        self.run = dict(id=12, head_sha=self.source, path=".github/workflows/release.yml",
                        event="workflow_dispatch", head_branch="main", status="completed",
                        repository=dict(full_name="iret77/nexgenvideo"), conclusion="failure")
        self.jobs = dict(total_count=2, jobs=[dict(name="release", conclusion="success"),
                                            dict(name="diagnostic-acceptance", conclusion="failure")])
        self.artifact = dict(id=34, name="diagnostic-release-evidence", expired=False,
                             digest=f"sha256:{self.digest}",
                             workflow_run=dict(id=12, head_sha=self.source))

    def check(self, paths=HARNESS_PATHS):
        verify(self.run, self.jobs, self.artifact, 12, self.source, 34, self.digest, paths)

    def test_accepts_failed_runtime_job_only_when_signed_release_succeeded(self):
        self.check()
        self.jobs["jobs"][0]["conclusion"] = "failure"
        with self.assertRaisesRegex(ValueError, "release job"):
            self.check()

    def test_rejects_foreign_or_incomplete_source_runs(self):
        for field, value in dict(id=13, head_sha="c" * 40, path=".github/workflows/ci.yml",
                                 event="pull_request", head_branch="feature", status="in_progress",
                                 repository=dict(full_name="another/repository")).items():
            with self.subTest(field=field):
                original = self.run
                self.run = {**original, field: value}
                with self.assertRaises(ValueError):
                    self.check()
                self.run = original

    def test_rejects_missing_duplicate_or_truncated_release_jobs(self):
        for jobs in (dict(total_count=1, jobs=[]), dict(total_count=0, jobs=[]),
                     dict(total_count=2, jobs=[self.jobs["jobs"][0]] * 2)):
            with self.subTest(jobs=jobs):
                self.jobs = jobs
                with self.assertRaises(ValueError):
                    self.check()

    def test_rejects_substituted_expired_or_modified_artifacts(self):
        for field, value in dict(id=35, name="other", expired=True, digest="sha256:" + "c" * 64,
                                 workflow_run=dict(id=13, head_sha=self.source)).items():
            with self.subTest(field=field):
                original = self.artifact
                self.artifact = {**original, field: value}
                with self.assertRaises(ValueError):
                    self.check()
                self.artifact = original
        self.artifact["workflow_run"]["head_sha"] = "c" * 40
        with self.assertRaises(ValueError):
            self.check()

    def test_rejects_any_app_build_or_pack_change(self):
        for path in ("Sources/NexGenVideo/App/NexGenVideoApp.swift", "Package.resolved",
                     "scripts/bundle.sh", ".github/workflows/release.yml", "Info.plist",
                     "musicvideo/manifest.json"):
            with self.subTest(path=path), self.assertRaisesRegex(ValueError, "new signed build"):
                self.check([*HARNESS_PATHS, path])


class SignedBpyCandidateTests(unittest.TestCase):
    def setUp(self):
        self.source, self.digest = "a" * 40, "b" * 64
        self.run = dict(id=12, head_sha=self.source, path=".github/workflows/release.yml",
                        event="workflow_dispatch", head_branch="release-candidate", status="completed",
                        conclusion="failure", run_attempt=2, repository=dict(full_name="iret77/nexgenvideo"))
        self.jobs = dict(total_count=1, jobs=[dict(name="release", conclusion="success", status="completed",
                        run_id=12, head_sha=self.source, run_attempt=2,
                        started_at="2026-11-02T20:20:00Z", completed_at="2026-11-02T20:51:03Z")])
        self.artifact = dict(id=34, name="diagnostic-release-evidence", expired=False,
                        digest="sha256:" + self.digest, workflow_run=dict(id=12, head_sha=self.source),
                        created_at="2026-11-02T20:50:20Z", updated_at="2026-11-02T20:50:47Z",
                        expires_at="2099-01-01T00:00:00Z")

    def check(self, paths=SIGNED_BPY_HARNESS_PATHS):
        verify_signed_bpy(self.run, self.jobs, self.artifact, 12, self.source, 34, self.digest, paths)

    def test_accepts_signed_release_job_despite_later_acceptance_failure(self):
        for status in ("queued", "in_progress", "completed"):
            self.run["status"] = status
            with self.subTest(run_status=status):
                self.check()

    def test_desktop_retention_has_a_distinct_role_and_keeps_producer_attempt_guards(self):
        self.artifact['name'] = 'workspace-ui-app'
        self.jobs['jobs'][0]['labels'] = ['macrunner']
        arguments = [self.run, self.jobs, self.artifact, 12, self.source, 34, self.digest]
        verify_signed_desktop(*arguments, SIGNED_DESKTOP_HARNESS_PATHS)
        for path in ('.github/workflows/chat-hang-replay.yml', '.github/workflows/private-example-analysis.yml',
                     'scripts/bundle.sh', 'Sources/NexGenVideo/App/NexGenVideoApp.swift',
                     'musicvideo/manifest.json', 'Package.resolved', 'scripts/unrelated.py'):
            with self.subTest(path=path), self.assertRaises(ValueError):
                verify_signed_desktop(*arguments, [*SIGNED_DESKTOP_HARNESS_PATHS, path])
        with self.assertRaises(ValueError):
            verify_signed_workspace(*arguments, ['.github/workflows/workspace-ui-acceptance.yml'])
        self.assertNotIn('.github/workflows/workspace-ui-acceptance.yml', SIGNED_WORKSPACE_HARNESS_PATHS)
        for field, value in [('run_attempt', 1), ('conclusion', 'failure'), ('labels', ['ubuntu-24.04'])]:
            job = self.jobs['jobs'][0]; old = job[field]; job[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                verify_signed_desktop(*arguments, SIGNED_DESKTOP_HARNESS_PATHS)
            job[field] = old

    def test_rejects_foreign_or_unfinished_producer(self):
        for key, value in (("id", 13), ("head_sha", "c" * 40), ("path", ".github/workflows/ci.yml"),
                           ("event", "push"), ("status", "waiting"), ("run_attempt", 0),
                           ("repository", dict(full_name="other/repo"))):
            old = self.run[key]
            self.run[key] = value
            with self.subTest(field=key), self.assertRaises(ValueError):
                self.check()
            self.run[key] = old

    def test_rejects_failed_foreign_or_wrong_attempt_release_job(self):
        job = self.jobs["jobs"][0]
        for key, value in (("conclusion", "failure"), ("status", "in_progress"), ("run_id", 13),
                           ("head_sha", "c" * 40), ("run_attempt", 1)):
            old = job[key]
            job[key] = value
            with self.subTest(field=key), self.assertRaises(ValueError):
                self.check()
            job[key] = old

    def test_rejects_missing_duplicate_or_truncated_job_inventory(self):
        original = self.jobs
        for jobs in (dict(total_count=0, jobs=[]), dict(total_count=2, jobs=original["jobs"]),
                     dict(total_count=2, jobs=original["jobs"] * 2)):
            self.jobs = jobs
            with self.subTest(jobs=jobs), self.assertRaises(ValueError):
                self.check()
        self.jobs = original

    def test_rejects_substituted_expired_or_other_attempt_artifact(self):
        for key, value in (("id", 35), ("name", "NexGenVideo-app"), ("expired", True),
                           ("digest", "sha256:" + "c" * 64),
                           ("workflow_run", dict(id=13, head_sha=self.source)),
                           ("workflow_run", dict(id=12, head_sha="c" * 40)),
                           ("created_at", "2026-11-02T20:00:00Z"),
                           ("updated_at", "2026-11-02T21:00:00Z"),
                           ("expires_at", "2020-01-01T00:00:00Z")):
            old = self.artifact[key]
            self.artifact[key] = value
            with self.subTest(field=key), self.assertRaises(ValueError):
                self.check()
            self.artifact[key] = old

    def test_product_runtime_lockfiles_and_source_pins_cannot_change(self):
        for path in ("Sources/NexGenVideo/App/NexGenVideoApp.swift", "Package.resolved", "Package.swift",
                     "scripts/bundle.sh", ".github/workflows/release.yml", "Info.plist",
                     "musicvideo/manifest.json", "scripts/consume_bpy_distributable_source.py",
                     ".github/actions/prepare-bpy-source/action.yml", "scripts/bpy_runtime_acceptance.py"):
            with self.subTest(path=path), self.assertRaises(ValueError):
                self.check([*SIGNED_BPY_HARNESS_PATHS, path])

    def test_distribution_source_comes_from_its_app_artifact_without_sibling_job(self):
        workflow = (Path(__file__).resolve().parents[1] / ".github/workflows/bpy-runtime-acceptance.yml").read_text()
        receipt = workflow.split("name: managed-bpy-source-receipt-", 1)[0].rsplit("      - uses:", 1)[1]
        self.assertIn("if: inputs.runtime_run_id == '' && !inputs.distribution", receipt)
        source = workflow.split("      - name: Prepare qualified source for the original CI app\n", 1)[1].split("      - name:", 1)[0]
        self.assertIn("if: inputs.runtime_run_id != '' || inputs.distribution", source)
        self.assertIn("ORIGINAL_SOURCE: ${{ inputs.expected_source_sha || github.sha }}", source)
        self.assertIn('--receipt "$RUNNER_TEMP/download/bpy-source/bpy-source-receipt.json"', source)
        relocate = workflow.split("      - name: Relocate the exact app and prepare denied resources\n", 1)[1].split("      - name:", 1)[0]
        for command in ('scripts/verify_bpy_bundle.sh "$APP" --distribution', 'xcrun stapler validate "$APP"',
                        'spctl -a -vvv -t exec "$APP"', 'codesign --verify --strict --verbose=2 "$APP"'):
            self.assertIn(command, relocate)

    def test_signed_retry_is_source_gated_and_runs_distribution_acceptance(self):
        workflow = (Path(__file__).resolve().parents[1] / ".github/workflows/diagnostic-acceptance.yml").read_text()
        job = workflow.split("  signed-bpy:\n", 1)[1].split("\n  ci-bpy-resource-diagnostic:", 1)[0]
        for binding in ('needs: source', "if: inputs.candidate_kind == 'signed-bpy'",
                        'uses: ./.github/workflows/bpy-runtime-acceptance.yml',
                        'artifact: diagnostic-release-evidence', 'app_zip: diagnostic-app.zip', 'distribution: true',
                        'runtime_run_id: ${{ inputs.run_id }}', 'expected_source_sha: ${{ inputs.source_sha }}',
                        'app_artifact_id: ${{ inputs.artifact_id }}', 'app_artifact_sha256: ${{ inputs.artifact_sha256 }}'):
            self.assertIn(binding, job)
        self.assertNotIn('continue-on-error', job)
        self.assertNotIn('bundle.sh', job)

    def test_signed_journey_requires_its_own_immutable_release_dmg_artifact(self):
        self.artifact['name'] = 'release-user-journey-input'
        arguments = [self.run, self.jobs, self.artifact, 12, self.source, 34, self.digest]
        verify_signed_journey(*arguments, SIGNED_JOURNEY_HARNESS_PATHS)
        for name in ('diagnostic-release-evidence', 'workspace-ui-app'):
            self.artifact['name'] = name
            with self.subTest(name=name), self.assertRaises(ValueError):
                verify_signed_journey(*arguments, SIGNED_JOURNEY_HARNESS_PATHS)
        self.artifact['name'] = 'release-user-journey-input'
        for path in ('Sources/NexGenVideo/App/NexGenVideoApp.swift', 'Package.resolved', 'scripts/bundle.sh'):
            with self.subTest(path=path), self.assertRaises(ValueError):
                verify_signed_journey(*arguments, [*SIGNED_JOURNEY_HARNESS_PATHS, path])


class BpyOpenCandidateTests(unittest.TestCase):
    def setUp(self):
        self.source = "a" * 40
        self.digest = "b" * 64
        self.run = dict(id=12, head_sha=self.source, path=".github/workflows/ci-batch.yml",
                        event="workflow_dispatch", status="completed", conclusion="failure", run_attempt=2,
                        repository=dict(full_name="iret77/nexgenvideo"))
        prefix = "Compile, unit tests, app and native bpy acceptance / "
        self.jobs = dict(jobs=[dict(name=prefix + name, status="completed", conclusion="success",
                                   run_id=12, run_attempt=2, head_sha=self.source)
                              for name in ("Light Checks", "Agent UI Evidence", "bpy-source / source",
                                           "diagnostic-startup", "Build & Test")])
        self.jobs["jobs"][-1].update(started_at="2026-10-23T19:59:07Z", completed_at="2026-10-23T20:38:40Z")
        self.jobs["jobs"].append(dict(name=prefix + "bpy-runtime / runtime", status="completed",
                                     conclusion="failure", run_id=12, run_attempt=2, head_sha=self.source,
                                     steps=[dict(name=name, status="completed", conclusion=result) for name, result in (
                                         ("Relocate the exact app and prepare denied resources", "success"),
                                         ("Prove pre-lease and post-exec host-crash cleanup", "failure"),
                                         ("Prepare the independent retained Bible YAML parser", "skipped"),
                                         ("Run real bpy acceptance without ambient Blender or Python", "skipped"))]))
        self.jobs["total_count"] = len(self.jobs["jobs"])
        self.artifact = dict(id=34, name="NexGenVideo-app", expired=False, digest="sha256:" + self.digest,
                             workflow_run=dict(id=12, head_sha=self.source), created_at="2026-10-23T20:37:27Z",
                             updated_at="2026-10-23T20:38:00Z", expires_at="2099-01-01T00:00:00Z")

    def check(self, paths=BPY_DIAGNOSTIC_PATHS):
        verify_bpy_diagnostic(self.run, self.jobs, self.artifact, 12, self.source, 34, self.digest, paths)

    def test_second_attempt_app_has_successful_core_prerequisites_and_exact_failure(self):
        self.check()

    def test_other_attempt_or_source_cannot_supply_any_prerequisite(self):
        for job in self.jobs["jobs"]:
            for key, bad in (("run_attempt", 1), ("head_sha", "c" * 40), ("run_id", 13)):
                old = job[key]
                job[key] = bad
                with self.subTest(job=job["name"], field=key), self.assertRaises(ValueError):
                    self.check()
                job[key] = old

    def test_artifact_must_be_produced_in_this_attempt_and_unexpired(self):
        for key, bad in (("created_at", "2026-10-23T19:00:00Z"), ("updated_at", "2026-10-23T21:00:00Z"),
                         ("expires_at", "2020-01-01T00:00:00Z"), ("digest", "sha256:" + "c" * 64),
                         ("expired", True), ("id", 35)):
            old = self.artifact[key]
            self.artifact[key] = bad
            with self.subTest(field=key), self.assertRaises(ValueError):
                self.check()
            self.artifact[key] = old

    def test_duplicate_missing_or_failed_prerequisite_is_rejected(self):
        original = list(self.jobs["jobs"])
        for altered in (original[:-1], original + [original[0]]):
            self.jobs = dict(jobs=altered, total_count=len(altered))
            with self.assertRaises(ValueError):
                self.check()
        self.jobs = dict(jobs=original, total_count=len(original))
        self.jobs["jobs"][3]["conclusion"] = "failure"
        with self.assertRaises(ValueError):
            self.check()

    def test_failure_cannot_be_reclassified_or_hidden_by_another_failure(self):
        steps = self.jobs["jobs"][-1]["steps"]
        for step in steps:
            old = step["conclusion"]
            step["conclusion"] = "success" if old != "success" else "failure"
            with self.assertRaises(ValueError):
                self.check()
            step["conclusion"] = old
        steps.append(dict(name="another failure", status="completed", conclusion="failure"))
        with self.assertRaises(ValueError):
            self.check()

    def test_product_or_runtime_harness_changes_cannot_reuse_the_original_app(self):
        for path in ("Sources/BpyRuntimeProtocol/BpyRuntimeStorage.swift", "Runtime/bpy/runtime-lock.json",
                     "scripts/bpy_runtime_acceptance.py", ".github/workflows/bpy-runtime-acceptance.yml",
                     "scripts/verify_bpy_bundle.sh", "Package.swift"):
            with self.subTest(path=path), self.assertRaises(ValueError):
                self.check([*BPY_DIAGNOSTIC_PATHS, path])

    def test_old_runtime_mode_retains_its_original_attempt_requirement(self):
        with self.assertRaisesRegex(ValueError, "completed CI batch"):
            verify_ci(self.run, self.jobs, self.artifact, 12, self.source, 34, self.digest, CI_HARNESS_PATHS)


class CICandidateProvenanceTests(unittest.TestCase):
    def setUp(self):
        self.source = "a" * 40
        self.digest = "b" * 64
        self.run = dict(id=12, head_sha=self.source, path=".github/workflows/ci-batch.yml",
                        event="workflow_dispatch", status="completed", run_attempt=1,
                        repository=dict(full_name="iret77/nexgenvideo"), conclusion="failure")
        self.jobs = dict(total_count=4, jobs=[
            dict(name="Compile, unit tests, app and native bpy acceptance / " + name,
                 conclusion="success", status="completed", run_id=12, run_attempt=1, head_sha=self.source)
            for name in ("Light Checks", "Build & Test", "bpy-source / source", "Agent UI Evidence")])
        self.jobs["jobs"].append(dict(
            name="Compile, unit tests, app and native bpy acceptance / diagnostic-startup",
            conclusion="failure", status="completed", run_id=12, run_attempt=1, head_sha=self.source,
            steps=[dict(name=name, status="completed", conclusion="failure" if index == 4 else "success")
                   for index, name in enumerate([
                       "Prove shipped build 97 misses normal recorder startup",
                       "Verify normal startup and disabled preference",
                       "Exercise native Export Cancel, Retry and Reveal actions",
                       "Verify generation batch pricing recovery on macOS 26",
                       "Verify helper recovery during active work"])]))
        self.jobs["total_count"] = len(self.jobs["jobs"])
        self.artifact = dict(id=34, name="NexGenVideo-app", expired=False,
                             digest=f"sha256:{self.digest}", workflow_run=dict(id=12, head_sha=self.source))

    def check(self, paths=CI_HARNESS_PATHS):
        verify_ci(self.run, self.jobs, self.artifact, 12, self.source, 34, self.digest, paths)

    def test_failed_runtime_batch_can_reuse_successful_exact_build(self):
        self.check()

    def test_rejects_failed_missing_duplicate_or_other_attempt_build(self):
        from copy import deepcopy
        original = deepcopy(self.jobs)
        for field, value in (("conclusion", "failure"), ("run_id", 13),
                             ("run_attempt", 2), ("head_sha", "c" * 40)):
            self.jobs = deepcopy(original)
            self.jobs["jobs"][1][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.check()
        self.jobs = deepcopy(original)
        self.jobs["jobs"].append(self.jobs["jobs"][1])
        self.jobs["total_count"] = len(self.jobs["jobs"])
        with self.assertRaises(ValueError):
            self.check()
        self.jobs = deepcopy(original)
        self.jobs["jobs"].pop()
        with self.assertRaises(ValueError):
            self.check()

    def test_rejects_other_producer_expired_or_substituted_archive(self):
        for field, value in (("path", ".github/workflows/release.yml"), ("status", "in_progress"),
                             ("head_sha", "c" * 40), ("event", "pull_request"), ("run_attempt", 0), ("run_attempt", 2),
                             ("repository", {"full_name": "other/repo"})):
            original = self.run
            self.run = {**original, field: value}
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.check()
            self.run = original
        for field, value in (("expired", True), ("digest", "sha256:" + "c" * 64),
                             ("id", 35), ("name", "workspace-ui-app"),
                             ("workflow_run", {"id": 13, "head_sha": self.source})):
            original = self.artifact
            self.artifact = {**original, field: value}
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.check()
            self.artifact = original

    def test_product_pack_runtime_and_build_input_changes_require_new_build(self):
        for path in ("Sources/NexGenVideo/App/AppDelegate.swift", "Package.swift", "Package.resolved",
                     "Runtime/bpy/runtime-lock.json", "scripts/bundle.sh", "scripts/stage_bpy_runtime.sh",
                     "Info.plist", "musicvideo/manifest.json", ".github/workflows/release.yml"):
            with self.subTest(path=path), self.assertRaises(ValueError):
                self.check([*CI_HARNESS_PATHS, path])

    def test_helper_continuation_cannot_hide_another_diagnostic_failure(self):
        from copy import deepcopy
        original = deepcopy(self.jobs)
        for index in range(4):
            for conclusion in ("failure", "skipped", "cancelled"):
                self.jobs = deepcopy(original)
                self.jobs["jobs"][-1]["steps"][index]["conclusion"] = conclusion
                with self.subTest(index=index, conclusion=conclusion), self.assertRaises(ValueError):
                    self.check()
        for change in ("missing", "duplicate", "passed", "missing-prior", "reordered"):
            self.jobs = deepcopy(original)
            steps = self.jobs["jobs"][-1]["steps"]
            if change == "missing": steps.pop()
            elif change == "duplicate": steps.append(deepcopy(steps[-1]))
            elif change == "passed": steps[-1]["conclusion"] = "success"
            elif change == "missing-prior": steps.pop(0)
            elif change == "reordered": steps[0], steps[1] = steps[1], steps[0]
            with self.subTest(change=change), self.assertRaises(ValueError):
                self.check()

    def test_runtime_selectors_require_complete_retained_identity(self):
        workflow = (Path(__file__).resolve().parents[1] / ".github/workflows/bpy-runtime-acceptance.yml").read_text()
        step = workflow.split("      - name: Validate original app selectors\n", 1)[1].split("\n      - ", 1)[0]
        script = textwrap.dedent(step.split("        run: |\n", 1)[1])
        empty = dict(ORIGINAL_RUN="", ORIGINAL_SOURCE="", ORIGINAL_ARTIFACT="", ORIGINAL_DIGEST="", DISTRIBUTION="false")
        complete = {**empty, "ORIGINAL_RUN": "12", "ORIGINAL_SOURCE": self.source,
                    "ORIGINAL_ARTIFACT": "34", "ORIGINAL_DIGEST": self.digest}
        cases = [(empty, True), ({**empty, "DISTRIBUTION": "true"}, True), (complete, True),
                 ({**complete, "DISTRIBUTION": "true"}, True)]
        for key in ("ORIGINAL_RUN", "ORIGINAL_SOURCE", "ORIGINAL_ARTIFACT", "ORIGINAL_DIGEST"):
            cases.append(({**complete, key: ""}, False))
            cases.append(({**complete, key: "invalid"}, False))
        for environment, valid in cases:
            with self.subTest(environment=environment):
                result = subprocess.run(["bash", "-c", script], env={**os.environ, **environment},
                                        stdin=subprocess.DEVNULL, capture_output=True, timeout=5)
                self.assertEqual(result.returncode == 0, valid, result.stderr.decode())

    def test_original_app_transfer_resumes_exact_bytes_and_rejects_changed_metadata(self):
        import hashlib
        import pinned_download as transfer
        import reuse_bpy_binary_evidence as reuse
        from test_pinned_download import Response

        workflow = (Path(__file__).resolve().parents[1] / ".github/workflows/bpy-runtime-acceptance.yml").read_text()
        step = workflow.split("      - name: Retrieve the bound original CI app\n", 1)[1].split("\n      - ", 1)[0]
        script = textwrap.dedent(step.split("          python3 - <<'PY'\n", 1)[1].split("          PY\n", 1)[0])
        payload = b"original immutable App archive"
        digest = hashlib.sha256(payload).hexdigest()
        artifact = dict(id=42, name="NexGenVideo-app", expired=False, size_in_bytes=len(payload),
                        digest="sha256:" + digest, workflow_run=dict(id=12, head_sha=self.source))
        environment = dict(ORIGINAL_ARTIFACT="42", ORIGINAL_NAME="NexGenVideo-app",
                           ORIGINAL_DIGEST=digest, ORIGINAL_RUN="12", ORIGINAL_SOURCE=self.source)
        with tempfile.TemporaryDirectory() as directory, \
             patch.dict(os.environ, {**environment, "RUNNER_TEMP": directory}), \
             patch.object(reuse, "api", return_value=artifact) as metadata, \
             patch.object(reuse, "source_response", side_effect=[
                 Response(payload[:5], failure=TimeoutError()),
                 Response(payload[5:], 206, {"Content-Range": f"bytes 5-{len(payload) - 1}/{len(payload)}",
                                            "Content-Length": str(len(payload) - 5)})]) as response, \
             patch.object(transfer.time, "sleep"):
            exec(script, {})
            self.assertEqual((Path(directory) / "original-app.zip").read_bytes(), payload)
            self.assertEqual([call.args[1] for call in response.call_args_list], [0, 5])
            metadata.assert_called_once_with("/actions/artifacts/42")
        for change in ({"id": 99}, {"name": "foreign"}, {"expired": True},
                       {"digest": "sha256:" + "f" * 64}, {"size_in_bytes": 0},
                       {"workflow_run": dict(id=99, head_sha=self.source)},
                       {"workflow_run": dict(id=12, head_sha="f" * 40)}):
            with self.subTest(change=change), tempfile.TemporaryDirectory() as directory, \
                 patch.dict(os.environ, {**environment, "RUNNER_TEMP": directory}), \
                 patch.object(reuse, "api", return_value={**artifact, **change}), \
                 patch.object(reuse, "source_response") as response:
                with self.assertRaises(ValueError):
                    exec(script, {})
                response.assert_not_called()
                self.assertFalse((Path(directory) / "original-app.zip").exists())
        with tempfile.TemporaryDirectory() as directory, \
             patch.dict(os.environ, {**environment, "RUNNER_TEMP": directory}), \
             patch.object(reuse, "api", return_value=artifact), \
             patch.object(reuse, "source_response", return_value=Response(b"x" * len(payload))) as response:
            with self.assertRaisesRegex(ValueError, "size or digest mismatch"):
                exec(script, {})
            response.assert_called_once()

    def test_resumed_source_preparation_passes_the_original_receipt_identity(self):
        workflow = (Path(__file__).resolve().parents[1] / ".github/workflows/bpy-runtime-acceptance.yml").read_text()
        step = workflow.split("      - name: Prepare qualified source for the original CI app\n", 1)[1].split("      - name:", 1)[0]
        self.assertIn("if: inputs.runtime_run_id != '' || inputs.distribution", step)
        self.assertIn("ORIGINAL_SOURCE: ${{ inputs.expected_source_sha || github.sha }}", step)
        script = textwrap.dedent(step.split("        run: |\n", 1)[1])
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            interpreter = root / "python3"
            interpreter.write_text(f"#!{sys.executable}\nimport json,sys\nprint(json.dumps(sys.argv[1:]))\n")
            interpreter.chmod(0o755)
            result = subprocess.run(["bash", "-c", script],
                                    env={**os.environ, "PATH": str(root) + os.pathsep + os.environ["PATH"],
                                         "RUNNER_TEMP": temporary, "ORIGINAL_SOURCE": self.source,
                                         "GITHUB_SHA": "c" * 40},
                                    stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=5, check=True)
            self.assertEqual(json.loads(result.stdout), ["scripts/consume_bpy_distributable_source.py",
                             "--output-directory", str(root / "source"), "--source-sha", self.source,
                             "--receipt", str(root / "download/bpy-source/bpy-source-receipt.json")])
        normal = workflow.split("      - uses: ./.github/actions/prepare-bpy-source\n", 1)[1].split("      - name:", 1)[0]
        self.assertIn("if: inputs.runtime_run_id == '' && !inputs.distribution", normal)


class HelperRecoveryEvidenceTests(unittest.TestCase):
    def test_timeout_preserves_capture_and_still_fails_and_reaps_own_process(self):
        process = Mock(pid=123, returncode=None)
        failure = subprocess.TimeoutExpired(["app"], 65)
        process.wait.side_effect = [failure, 0]
        process.poll.return_value = None
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with patch("hang_diagnostic_acceptance.Path.home", return_value=root), patch(
                "hang_diagnostic_acceptance.subprocess.Popen", return_value=process,
            ) as launch, patch("hang_diagnostic_acceptance.capture_helper_failure") as capture:
                with self.assertRaises(subprocess.TimeoutExpired) as caught:
                    verify_helper_recovery(Path("app"), output=root / "evidence")
                self.assertIs(caught.exception, failure)
                self.assertEqual(capture.call_args.args[0], process)
                self.assertIs(capture.call_args.args[-1], failure)
                self.assertEqual(process.wait.call_args_list[0].kwargs, {"timeout": 65})
                self.assertEqual(process.wait.call_args_list[-1].kwargs, {"timeout": 5})
                process.kill.assert_called_once()
                self.assertNotEqual(launch.call_args.kwargs["stdout"], subprocess.DEVNULL)
                self.assertEqual(launch.call_args.kwargs["stderr"], subprocess.STDOUT)

    def test_capture_failure_cannot_replace_original_timeout(self):
        process = Mock(pid=123)
        process.poll.return_value = None
        failure = subprocess.TimeoutExpired(["app"], 65)
        process.wait.side_effect = [failure, 0]
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with patch("hang_diagnostic_acceptance.Path.home", return_value=root), patch(
                "hang_diagnostic_acceptance.subprocess.Popen", return_value=process,
            ), patch("hang_diagnostic_acceptance.capture_helper_failure", side_effect=OSError("full")), patch(
                "hang_diagnostic_acceptance.Path.open", mock_open(),
            ) as opened:
                opened.return_value.write.side_effect = OSError("disk full")
                with self.assertRaises(subprocess.TimeoutExpired) as caught:
                    verify_helper_recovery(Path("app"), output=root / "evidence")
                self.assertIs(caught.exception, failure)
                process.kill.assert_called_once()

    def test_capture_keeps_only_new_recordings_bound_to_launched_pid(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "recordings"
            root.mkdir()
            output = Path(temporary) / "evidence"
            output.mkdir()
            for name, pid in (("old", 123), ("own", 123), ("other", 456)):
                folder = root / name
                folder.mkdir()
                (folder / "heartbeat.json").write_text(json.dumps({"processID": pid}))
                (folder / "sample.stacks").write_text("stack")
            (root / "linked").symlink_to(root / "own", target_is_directory=True)
            process = Mock(pid=123)
            process.poll.return_value = None
            with patch("hang_diagnostic_acceptance.subprocess.run", side_effect=OSError("no sample")):
                capture_helper_failure(process, root, {root / "old"}, output, RuntimeError("failed"))
            receipt = json.loads((output / "helper-recovery-failure.json").read_text())
            self.assertEqual(receipt["recordings"], ["own"])
            self.assertEqual(receipt["captureErrors"], ["OSError"])
            with zipfile.ZipFile(output / "helper-recovery-recordings.zip") as archive:
                self.assertEqual(set(archive.namelist()), {"own/heartbeat.json", "own/sample.stacks"})
                self.assertEqual(archive.read("own/sample.stacks"), b"stack")
            process.kill.assert_not_called()

    def test_sample_is_bounded_and_bad_heartbeat_does_not_hide_other_recordings(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "recordings"
            root.mkdir()
            output = Path(temporary) / "evidence"
            output.mkdir()
            for name, value in (("a-bad", []), ("b-valid", {"processID": 123})):
                folder = root / name
                folder.mkdir()
                (folder / "heartbeat.json").write_text(json.dumps(value))
            process = Mock(pid=123)
            process.poll.return_value = None
            result = SimpleNamespace(returncode=0, stdout=b"sample complete", stderr=b"")
            with patch("hang_diagnostic_acceptance.subprocess.run", return_value=result) as sample:
                capture_helper_failure(process, root, set(), output, RuntimeError("failed"))
            self.assertEqual(sample.call_args.args[0], ["/usr/bin/sample", "123", "1", "-file",
                                                      str(output / "helper-recovery-sample.log")])
            self.assertEqual(sample.call_args.kwargs["timeout"], 10)
            self.assertEqual(sample.call_args.kwargs["stdin"], subprocess.DEVNULL)
            receipt = json.loads((output / "helper-recovery-failure.json").read_text())
            self.assertEqual(receipt["sampleExitCode"], 0)
            self.assertEqual(receipt["recordings"], ["b-valid"])
            self.assertEqual(receipt["unmatched"], [{"folder": "a-bad", "reason": "invalid-heartbeat"}])
            self.assertEqual((output / "helper-recovery-sample-tool.log").read_bytes(), b"sample complete")


class RetainedKeyAcceptanceTests(unittest.TestCase):
    def verify(self, codes):
        with patch("hang_diagnostic_acceptance.subprocess.run",
                   side_effect=[SimpleNamespace(returncode=code) for code in codes]):
            verify_retained_key(Path("NexGenVideo.app"),
                                "hang-diagnostic-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", "synthetic-key")

    def test_accepts_real_key_and_rejects_changed_key_and_missing_recording(self):
        self.verify([0, 70, 70, 0])

    def test_rejects_an_app_that_always_succeeds_or_cannot_read_its_key(self):
        for codes in ([0, 0, 0, 0], [70, 70, 70, 70], [0, 70, 0, 0], [0, 70, 70, 70]):
            with self.subTest(codes=codes), self.assertRaises(AssertionError):
                self.verify(codes)


if __name__ == "__main__":
    unittest.main()
