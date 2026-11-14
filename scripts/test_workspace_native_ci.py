"""Negative qualification fixtures; these files do not claim a native owner run."""
import copy
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
import urllib.error
import zipfile
from unittest.mock import patch

import workspace_native_ci as ci
from workspace_native_case import validate_processes
from workspace_native_evidence import validate_case
from workspace_ui_acceptance import ALL_CASES


class NativeQualificationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.identity = {'sourceSHA': 'a' * 40, 'archiveSHA256': 'b' * 64, 'validatorSHA256': 'c' * 64}
        self.identity_file = self.root / 'identity.json'; self.identity_file.write_text(json.dumps(self.identity))
        self.environment = patch.dict(os.environ, {'GITHUB_RUN_ID': '77', 'GITHUB_RUN_ATTEMPT': '2'})
        self.environment.start()

    def tearDown(self):
        self.environment.stop(); self.temp.cleanup()

    def storyboard_fixture(self):
        from test_workspace_ui_film_review import ActivityEvidenceTests
        activity = ActivityEvidenceTests()
        activity.setUp()
        self.addCleanup(activity.doCleanups)
        for image in activity.output.iterdir():
            (self.root / image.name).write_bytes(b"\x89PNG\r\n\x1a\n" + b"fixture" * 200)
        production = {"event": "production-workbench", "screenshots": ["init.png", "brief.png", "storyboard.png"],
            **dict.fromkeys(("threeColumns", "noTimelineOrEmptyPreview", "shotInspectorBound",
                            "twoStoryboardSections", "statusVisible"), True)}
        fields = [
            ("verse1.01", [("Section", "Verse 1"), ("Section timing", "0.0–12.0 s"), ("Camera", "Slow dolly"),
                           ("Framing", "Wide"), ("Angle", "Frontal"), ("Height", "Eye Level")]),
            ("chorus1.01", [("Section", "Chorus 1"), ("Section timing", "12.0–24.0 s"), ("Camera", "Slow push in"),
                            ("Framing", "Medium"), ("Angle", "Frontal"), ("Lens Hint", "Wide"), ("Location view", "Wide · Noon")]),
        ]
        production["shotInspectorSelections"] = [
            {"shotID": shot, "controlID": "storyboard.shot." + shot, "rawFieldsAbsent": True,
             "previousSelectionAbsent": True, "renderedFields": [{"label": key, "value": value} for key, value in values]}
            for shot, values in fields]
        production["storyboardCards"] = [
            {"shotID": shot, "subject": subject, "screenshot": shot + ".png",
             "fullyVisible": True, "renderedDescription": True, "rawFieldsAbsent": True}
            for shot, subject in [("verse1.01", "The singer stops at the platform edge."),
                                  ("verse1.02", "A train passes the empty platform."),
                                  ("chorus1.01", "The singer turns toward the morning light.")]]
        review = {"event": "storyboard-review", "cardDestination": "Storyboard", "pipelineDestination": "Storyboard",
            "screenshots": ["review.png", "decline.png"], **dict.fromkeys(("openedTabWithoutModal", "tabRoundTrip",
                "pipelineActionSameTarget", "approvalControlsUsable", "shownBytesMatchApproval", "changeMarked",
                "declinedFromStoryboard", "gatesUnchanged", "savedProjectUnchanged"), True)}
        utility = {"event": "agent-activity", "complete": True, "screenshots": ["agent1.png", "agent2.png", "agent3.png"]}
        for name in (production["screenshots"] + review["screenshots"] + utility["screenshots"]
                     + [card["screenshot"] for card in production["storyboardCards"]]):
            (self.root / name).write_bytes(b"\x89PNG\r\n\x1a\n" + b"fixture" * 200)
        return [review, production, utility, activity.row, {"event": "completed", "case": "storyboard", "scale": 1.5}]

    def test_storyboard_join_requires_all_three_readable_native_shot_cards(self):
        rows = self.storyboard_fixture()
        valid, images = validate_case("storyboard", rows, self.root, 1.5)
        self.assertTrue(valid)
        self.assertEqual(len(rows[1]["shotInspectorSelections"]), 2)
        self.assertTrue({"verse1.01.png", "verse1.02.png", "chorus1.01.png"} <= set(images))
        for defect in ("missing", "duplicate", "foreign", "subject", "visibility", "description", "raw", "shared-image"):
            changed = copy.deepcopy(rows)
            cards = changed[1]["storyboardCards"]
            if defect == "missing": cards.pop(1)
            elif defect == "duplicate": cards[1] = copy.deepcopy(cards[0])
            elif defect == "foreign": cards[1]["shotID"] = "foreign.01"
            elif defect == "subject": cards[1]["subject"] = "Another shot."
            elif defect == "shared-image": cards[1]["screenshot"] = cards[0]["screenshot"]
            else: cards[1][{"visibility": "fullyVisible", "description": "renderedDescription", "raw": "rawFieldsAbsent"}[defect]] = False
            with self.subTest(defect=defect):
                self.assertFalse(validate_case("storyboard", changed, self.root, 1.5)[0])

    def test_storyboard_join_preserves_original_native_activity_images_and_success_requirements(self):
        rows = self.storyboard_fixture()
        for defect in ("missing-workbench", "missing-activity", "failed-native", "missing-image", "corrupt-image",
                       "wrong-scale", "missing-inspector", "changed-gates"):
            changed = copy.deepcopy(rows)
            if defect == "missing-workbench": changed.pop(1)
            elif defect == "missing-activity": changed.pop(3)
            elif defect == "failed-native": changed.append({"event": "failed"})
            elif defect in {"missing-image", "corrupt-image"}:
                changed[1]["storyboardCards"][1]["screenshot"] = "unavailable.png"
                if defect == "corrupt-image": (self.root / "unavailable.png").write_bytes(b"invalid" * 200)
            elif defect == "wrong-scale": changed[-1]["scale"] = 1
            elif defect == "missing-inspector": changed[1]["shotInspectorSelections"].pop()
            else: changed[0]["gatesUnchanged"] = False
            with self.subTest(defect=defect):
                self.assertFalse(validate_case("storyboard", changed, self.root, 1.5)[0])

    def source_proof(self):
        from test_verified_pr_source_checks import fixtures, MERGE, TREE
        from verified_pr_source_checks import CHECKS, test_completion
        run, jobs, receipt, pr, commit, artifact, raw, log = fixtures(2)
        record = {'schema': 'core-pr-source-composition/v1', 'sourceSHA': MERGE, 'runID': '77', 'attempt': '1',
            'originalRun': run, 'originalJobs': jobs, 'originalArtifact': artifact, 'originalReceipt': receipt,
            'originalCheckoutCommit': commit, 'originalPR': pr, 'originalResult': test_completion(log),
            'originalLogSHA256': hashlib.sha256(log).hexdigest(), 'reusedSteps': list(CHECKS),
            'originalStepProof': 'rest-job-steps'}
        directory = self.root / 'source'; directory.mkdir()
        (directory / 'receipt.json').write_text(json.dumps(record, indent=2) + '\n')
        (directory / 'original-proof.zip').write_bytes(raw)
        (directory / 'original-job.log').write_bytes(log)
        return directory, record, MERGE, TREE

    def retained_identity(self):
        harness = 'c' * 40
        value = {**self.identity, 'schema': 'nexgenvideo/native-input/2', 'sourceSHA': 'e' * 40,
            'harnessSourceSHA': harness, 'runtimeRunID': 12, 'runtimeArtifactID': 34,
            'runtimeArtifactDigest': 'sha256:' + 'b' * 64,
            'sourceComposition': {'receiptSHA256': 'd' * 64,
                'composition': {'schema': 'core-pr-source-composition/v1', 'sourceSHA': harness}}}
        value['retainedRelease'] = {'productSourceSHA': value['sourceSHA'], 'harnessSourceSHA': harness,
            'producerRunID': 12, 'runtimeArtifactID': 34, 'runtimeArtifactDigest': value['runtimeArtifactDigest']}
        return value

    def test_retained_inputs_require_complete_release_source_and_no_unit_filter(self):
        valid = ['workspace-ui-app', '12', 'e' * 40, '100', '']
        ci.validate_inputs(*valid)
        ci.validate_inputs('', '', '', '', '')
        ci.validate_inputs('', '12', '', '100', '')
        for index, replacement in [(0, ''), (0, 'NexGenVideo-app'), (1, ''), (1, '0'),
                                   (2, 'not-a-commit'), (3, ''), (3, '0'), (4, 'NativeSegment')]:
            changed = valid.copy(); changed[index] = replacement
            with self.subTest(index=index, replacement=replacement), self.assertRaises(ValueError):
                ci.validate_inputs(*changed)

    def test_source_composition_rejects_substituted_receipt_tree_log_and_execution(self):
        directory, record, harness, tree = self.source_proof()
        environment = {'GITHUB_SHA': harness, 'GITHUB_REF_NAME': 'rc'}
        with patch.dict(os.environ, environment), patch.object(ci.subprocess, 'check_output', side_effect=[harness + '\n', tree + '\n']):
            result = ci.source_composition(directory, ci.sha(directory / 'receipt.json'), 100)
        self.assertEqual(result['composition'], record)
        for change in ({'sourceSHA': 'f' * 40}, {'runID': '78'}, {'attempt': '3'}, {'reusedSteps': []},
                       {'originalLogSHA256': '0' * 64}, {'originalReceipt': {}},
                       {'originalPR': {**record['originalPR'], 'merge_commit_sha': 'f' * 40}}):
            (directory / 'receipt.json').write_text(json.dumps({**record, **change}))
            with self.subTest(change=change), patch.dict(os.environ, environment), \
                 patch.object(ci.subprocess, 'check_output', side_effect=[harness + '\n', tree + '\n']), self.assertRaises(ValueError):
                ci.source_composition(directory, ci.sha(directory / 'receipt.json'), 100)
        (directory / 'receipt.json').write_text(json.dumps(record))
        with patch.dict(os.environ, environment), self.assertRaisesRegex(ValueError, 'composition changed'):
            ci.source_composition(directory, '0' * 64, 100)

    def test_retained_resolver_binds_exact_release_product_and_original_attempt(self):
        from test_diagnostic_acceptance import SignedBpyCandidateTests
        producer = SignedBpyCandidateTests(); producer.setUp()
        producer.artifact['name'] = 'workspace-ui-app'
        producer.jobs['jobs'][0]['labels'] = ['macrunner']
        producer.jobs['jobs'][0]['id'] = 56
        directory, record, harness, tree = self.source_proof()
        path = '.github/workflows/workspace-ui-acceptance.yml'
        environment = {'GITHUB_SHA': harness, 'GITHUB_REF_NAME': 'rc'}
        for changed in (path, 'Sources/NexGenVideo/App/NexGenVideoApp.swift'):
            with self.subTest(changed=changed), patch.dict(os.environ, environment), \
                 patch.object(ci, 'api', side_effect=[producer.run, producer.artifact, producer.jobs]), \
                 patch.object(ci.subprocess, 'run') as git_run, \
                 patch.object(ci.subprocess, 'check_output', side_effect=[harness + '\n', tree + '\n', (changed + '\0').encode()]), \
                 patch.object(ci, 'outputs'):
                if changed != path:
                    with self.assertRaises(ValueError):
                        ci.resolve(12, 'workspace-ui-app', 34, self.identity_file, product_source=producer.source,
                            proof_directory=directory, proof_sha=ci.sha(directory / 'receipt.json'), source_run=100, source_artifact=600)
                else:
                    ci.resolve(12, 'workspace-ui-app', 34, self.identity_file, product_source=producer.source,
                        proof_directory=directory, proof_sha=ci.sha(directory / 'receipt.json'), source_run=100, source_artifact=600)
                    identity = json.loads(self.identity_file.read_text())
                    self.assertEqual((identity['sourceSHA'], identity['harnessSourceSHA']), (producer.source, harness))
                    self.assertEqual(identity['retainedRelease']['producerAttempt'], 2)
                    self.assertEqual(identity['retainedRelease']['producerJobID'], 56)
                    self.assertEqual(identity['sourceComposition']['composition'], record)
                    self.assertEqual(identity['sourceComposition']['artifactID'], 600)
                    self.assertEqual(ci.execution_source(identity), harness)
                    self.assertEqual(git_run.call_args_list[0].args[0], ['git', 'merge-base', '--is-ancestor', producer.source, 'HEAD'])
        with patch.dict(os.environ, environment), self.assertRaises(ValueError):
            ci.resolve(12, 'workspace-ui-app', 34, self.identity_file, product_source=producer.source)
        for position in (0, 1):
            failures = [None, None]
            failures[position] = subprocess.CalledProcessError(1, 'git')
            with self.subTest(git_failure=position), patch.dict(os.environ, environment), \
                 patch.object(ci, 'api', side_effect=[producer.run, producer.artifact]), \
                 patch.object(ci.subprocess, 'check_output', side_effect=[harness + '\n', tree + '\n']), \
                 patch.object(ci.subprocess, 'run', side_effect=failures), self.assertRaises(subprocess.CalledProcessError):
                ci.resolve(12, 'workspace-ui-app', 34, self.identity_file, product_source=producer.source,
                    proof_directory=directory, proof_sha=ci.sha(directory / 'receipt.json'), source_run=100, source_artifact=600)

    def test_retained_worker_checks_product_harness_validator_and_archive_independently(self):
        runtime = self.root / 'runtime'; runtime.mkdir()
        archive = runtime / 'workspace-ui.tar.gz'; archive.write_bytes(b'exact-product-app')
        identity = self.retained_identity(); identity['archiveSHA256'] = ci.sha(archive)
        self.identity_file.write_text(json.dumps(identity))
        with patch.dict(os.environ, {'GITHUB_SHA': identity['harnessSourceSHA']}), \
             patch.object(ci, 'fingerprint', return_value=identity['validatorSHA256']):
            ci.verify_runtime(runtime, self.identity_file, ci.sha(self.identity_file))
            for changed in ({'harnessSourceSHA': 'f' * 40}, {'sourceSHA': identity['harnessSourceSHA']},
                            {'validatorSHA256': 'd' * 64}, {'retainedRelease': {}},
                            {'sourceComposition': {}}, {'schema': 'nexgenvideo/native-input/1'}):
                self.identity_file.write_text(json.dumps({**identity, **changed}))
                with self.subTest(changed=changed), self.assertRaises(ValueError):
                    ci.verify_runtime(runtime, self.identity_file, ci.sha(self.identity_file))
            self.identity_file.write_text(json.dumps(identity)); archive.write_bytes(b'changed-app')
            with self.assertRaises(ValueError): ci.verify_runtime(runtime, self.identity_file, ci.sha(self.identity_file))

    def test_retained_summary_requires_harness_job_and_evidence_origins(self):
        self.identity = self.retained_identity()
        plan = self.root / 'plan.json'; plan.write_text(json.dumps(ci.selection('all', 'cards', '1')))
        self.identity['planSHA256'] = ci.sha(plan); self.identity_file.write_text(json.dumps(self.identity))
        evidence = self.root / 'case'; self.cards(evidence)
        publication = self.root / 'publication'; ci.archive_evidence(evidence, self.identity_file, 'cards', 1, publication)
        stream = io.BytesIO()
        with zipfile.ZipFile(stream, 'w') as bundle:
            for path in publication.iterdir(): bundle.writestr(path.name, path.read_bytes())
        payload = stream.getvalue(); harness = self.identity['harnessSourceSHA']
        artifact = {'id': 3, 'name': 'native-evidence-cards-100-a2', 'expired': False,
            'workflow_run': {'id': 77, 'head_sha': harness}, 'digest': 'sha256:' + hashlib.sha256(payload).hexdigest()}
        job = {'id': 99, 'name': 'Native cards-100', 'run_id': 77, 'run_attempt': 2,
            'head_sha': harness, 'status': 'completed', 'conclusion': 'success'}
        def response(path):
            if '/artifacts?' in path: return {'artifacts': [artifact]}
            return {'jobs': [job] if '/attempts/2/' in path else []}
        with patch.dict(os.environ, {'GITHUB_SHA': harness}), patch.object(ci, 'fingerprint', return_value=self.identity['validatorSHA256']), \
             patch.object(ci, 'api', side_effect=response), \
             patch.object(ci, 'download_artifact', side_effect=lambda _, __, target: target.write_bytes(payload)):
            self.assertEqual(ci.summarize(self.root, self.root / 'valid', plan, self.identity_file, ci.sha(self.identity_file), remote=True), 0)
            for value in (job, artifact['workflow_run']):
                value['head_sha'] = self.identity['sourceSHA']
                with self.subTest(origin=value):
                    self.assertEqual(ci.summarize(self.root, self.root / ('wrong-' + str(len(value))), plan,
                        self.identity_file, ci.sha(self.identity_file), remote=True), 1)
                value['head_sha'] = harness

    def test_full_plan_is_the_exact_case_scale_product(self):
        plan = ci.selection('all')
        entries = plan['matrix']['include']
        self.assertEqual({(row['case'], row['scale']) for row in entries},
                         {(name, scale) for name in ALL_CASES for scale in (1, 1.25, 1.5)})
        self.assertEqual(len(entries), len(ALL_CASES) * 3)
        self.assertTrue(plan['batch']); self.assertTrue(plan['fullWorkspaceRequested'])
        narrow = ci.selection('all', 'frames', '1.5')
        self.assertEqual(narrow['matrix']['include'], [{'id': 'frames-150', 'case': 'frames', 'scale': 1.5}])
        self.assertFalse(narrow['batch']); self.assertFalse(narrow['fullWorkspaceRequested'])
        for args in [('unknown', '', 'all'), ('filmreview', 'frames', '1'), ('all', '', '1.1')]:
            with self.subTest(args=args), self.assertRaises(ValueError): ci.selection(*args)

    def test_artifact_identity_rejects_other_source_repository_and_workflow(self):
        run = {'id': 77, 'repository': {'full_name': 'iret77/nexgenvideo'}, 'head_sha': 'a' * 40,
               'event': 'workflow_dispatch', 'path': '.github/workflows/ci-batch.yml'}
        artifact = {'id': 8, 'name': 'workspace-ui-app', 'expired': False, 'digest': 'sha256:' + 'b' * 64,
                    'workflow_run': {'id': 77, 'head_sha': 'a' * 40}}
        ci.require_artifact(run, artifact, 'a' * 40, 77, 'workspace-ui-app')
        for changed in ({'head_sha': 'd' * 40}, {'repository': {'full_name': 'someone/other'}},
                        {'path': '.github/workflows/unrelated.yml'}, {'event': 'pull_request'}):
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                ci.require_artifact({**run, **changed}, artifact, 'a' * 40, 77, 'workspace-ui-app')
        for changed in ({'expired': True}, {'digest': ''}, {'workflow_run': {'id': 78, 'head_sha': 'a' * 40}}):
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                ci.require_artifact(run, {**artifact, **changed}, 'a' * 40, 77, 'workspace-ui-app')

    def test_release_workspace_producer_does_not_bypass_identity_or_artifact_type(self):
        run = {'id': 77, 'repository': {'full_name': 'iret77/nexgenvideo'},
               'head_sha': 'a' * 40, 'event': 'workflow_dispatch',
               'path': '.github/workflows/release.yml'}
        artifact = {'id': 8, 'name': 'workspace-ui-app', 'expired': False,
                    'digest': 'sha256:' + 'b' * 64,
                    'workflow_run': {'id': 77, 'head_sha': 'a' * 40}}
        ci.require_artifact(run, artifact, 'a' * 40, 77, 'workspace-ui-app')
        for changed in ({'head_sha': 'd' * 40}, {'id': 78}, {'event': 'pull_request'},
                        {'repository': {'full_name': 'someone/other'}},
                        {'path': '.github/workflows/unrelated.yml'}):
            with self.subTest(run=changed), self.assertRaises(ValueError):
                ci.require_artifact({**run, **changed}, artifact, 'a' * 40, 77, 'workspace-ui-app')
        for changed in ({'expired': True}, {'digest': ''}, {'name': 'diagnostic-release-evidence'},
                        {'workflow_run': {'id': 78, 'head_sha': 'a' * 40}},
                        {'workflow_run': {'id': 77, 'head_sha': 'd' * 40}}):
            with self.subTest(artifact=changed), self.assertRaises(ValueError):
                ci.require_artifact(run, {**artifact, **changed}, 'a' * 40, 77, 'workspace-ui-app')
        for name in ('diagnostic-release-evidence', 'release-user-journey-input'):
            with self.subTest(name=name), self.assertRaises(ValueError):
                ci.require_artifact(run, {**artifact, 'name': name}, 'a' * 40, 77, name)

    def runtime_zip(self):
        stream = io.BytesIO()
        with zipfile.ZipFile(stream, 'w') as bundle:
            for name in ('workspace-ui.tar.gz', 'bpy-source-receipt.json'):
                bundle.writestr(name, name.encode())
            receipt = {'schema': 'nexgenvideo/workspace-ui-input/1', 'sourceSHA': self.identity['sourceSHA'],
                       'archiveSHA256': hashlib.sha256(b'workspace-ui.tar.gz').hexdigest(),
                       'appTreeSHA256': 'd' * 64}
            bundle.writestr('workspace-ui-input.json', json.dumps(receipt))
        payload = stream.getvalue()
        self.identity.update(runtimeArtifactID=8, runtimeArtifactDigest='sha256:' + hashlib.sha256(payload).hexdigest())
        self.identity_file.write_text(json.dumps(self.identity))
        return payload

    def test_resolve_and_transfer_keep_the_original_producer_run(self):
        payload = self.runtime_zip()
        for producer_run, workflow in ((77, 'ci-batch'), (55, 'ci-batch'), (99, 'release')):
            with self.subTest(producer_run=producer_run):
                run = {'id': producer_run, 'repository': {'full_name': 'iret77/nexgenvideo'},
                       'head_sha': 'a' * 40, 'event': 'workflow_dispatch', 'path': f'.github/workflows/{workflow}.yml'}
                artifact = {'id': 8, 'name': 'workspace-ui-app', 'expired': False,
                            'digest': 'sha256:' + hashlib.sha256(payload).hexdigest(),
                            'workflow_run': {'id': producer_run, 'head_sha': 'a' * 40}}
                with patch.dict(os.environ, {'GITHUB_SHA': 'a' * 40}), \
                     patch.object(ci, 'api', side_effect=[run, artifact]) as api, \
                     patch.object(ci, 'outputs') as outputs:
                    ci.resolve(producer_run, 'workspace-ui-app', 8, self.identity_file)
                self.assertEqual([call.args[0] for call in api.call_args_list],
                                 [f'/actions/runs/{producer_run}', '/actions/artifacts/8'])
                outputs.assert_called_once_with({'artifact_id': '8', 'runtime_run_id': str(producer_run)})
                identity = json.loads(self.identity_file.read_text())
                self.assertEqual(identity['runtimeRunID'], producer_run)
                self.assertEqual(identity['runtimeArtifactID'], 8)
                self.assertEqual(identity['runtimeArtifactDigest'], artifact['digest'])
                self.assertEqual(identity['sourceSHA'], 'a' * 40)
                destination = self.root / f'producer-{producer_run}'
                with patch.object(ci, 'download_artifact') as download:
                    download.side_effect = lambda _, __, path: path.write_bytes(payload)
                    ci.download_runtime(self.identity_file, destination)
                download.assert_called_once_with(8, artifact['digest'],
                                                 self.root / 'native-runtime-transfer.zip')
                self.assertEqual({path.name for path in destination.iterdir()},
                                 {'workspace-ui.tar.gz', 'workspace-ui-input.json', 'bpy-source-receipt.json'})
                self.assertEqual((destination / 'workspace-ui.tar.gz').read_bytes(), b'workspace-ui.tar.gz')

    def test_runtime_transfer_requires_server_digest_before_extracting(self):
        payload = self.runtime_zip()
        with patch.dict(os.environ, {'GH_TOKEN': 'fixture-token'}), patch.object(ci.urllib.request, 'build_opener') as opener:
            opener.return_value.open.return_value = io.BytesIO(payload + b'changed')
            destination = self.root / 'runtime'
            with self.assertRaisesRegex(ValueError, 'digest'):
                ci.download_runtime(self.identity_file, destination)
            self.assertEqual(list(destination.iterdir()), [])

    def test_signed_artifact_redirect_never_receives_github_credentials(self):
        payload = self.runtime_zip()
        location = 'https://artifact.example.invalid/bytes?signature=fixture'
        redirect = urllib.error.HTTPError('https://api.github.com/artifact', 302, 'redirect',
                                         {'Location': location}, io.BytesIO())
        with patch.dict(os.environ, {'GH_TOKEN': 'fixture-token'}), \
             patch.object(ci.urllib.request, 'build_opener') as opener, \
             patch.object(ci.urllib.request, 'urlopen', return_value=io.BytesIO(payload)) as blob:
            opener.return_value.open.side_effect = redirect
            ci.download_runtime(self.identity_file, self.root / 'runtime')
            request = opener.return_value.open.call_args.args[0]
            self.assertEqual(request.get_header('Authorization'), 'Bearer fixture-token')
            blob.assert_called_once_with(location, timeout=120)
        self.assertEqual((self.root / 'runtime/workspace-ui.tar.gz').read_bytes(), b'workspace-ui.tar.gz')

    def test_runtime_receipt_rejects_changed_source_archive_and_invalid_tree(self):
        payload = self.runtime_zip()
        destination = self.root / 'runtime'; destination.mkdir()
        ci.extract_transfer(io.BytesIO(payload), destination,
                            {'workspace-ui.tar.gz', 'workspace-ui-input.json',
                             'bpy-source-receipt.json'})
        receipt = ci.runtime_receipt(destination, self.identity)
        path = destination / 'workspace-ui-input.json'
        for changed in ({'schema': 'unknown'}, {'sourceSHA': 'e' * 40},
                        {'archiveSHA256': 'f' * 64}, {'appTreeSHA256': ''},
                        {'appTreeSHA256': 7}, {'extra': 'not-declared'}):
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                path.write_text(json.dumps({**receipt, **changed}))
                ci.runtime_receipt(destination, self.identity)
        path.write_text(json.dumps(receipt))
        (destination / 'workspace-ui.tar.gz').write_bytes(b'changed')
        with self.assertRaises(ValueError): ci.runtime_receipt(destination, self.identity)

    def test_runtime_transfer_rejects_missing_duplicate_extra_and_special_members(self):
        names = ['workspace-ui.tar.gz', 'workspace-ui-input.json',
                 'bpy-source-receipt.json']
        for variant in (names[:-1], names + ['extra'], names[:-1] + [names[0]], names):
            stream = io.BytesIO()
            with zipfile.ZipFile(stream, 'w') as bundle:
                for name in variant:
                    info = zipfile.ZipInfo(name)
                    if variant is names: info.external_attr = 0o120777 << 16
                    bundle.writestr(info, b'fixture')
            with self.subTest(variant=variant), tempfile.TemporaryDirectory() as target, self.assertRaises(ValueError):
                ci.extract_transfer(stream, Path(target), set(names))

    def test_native_worker_requires_exact_identity_and_app_bytes(self):
        runtime = self.root / 'runtime'; runtime.mkdir()
        archive = runtime / 'workspace-ui.tar.gz'; archive.write_bytes(b'exact-app')
        self.identity['archiveSHA256'] = ci.sha(archive)
        self.identity_file.write_text(json.dumps(self.identity))
        expected = ci.sha(self.identity_file)
        with patch.dict(os.environ, {'GITHUB_SHA': self.identity['sourceSHA']}), \
             patch.object(ci, 'fingerprint', return_value=self.identity['validatorSHA256']):
            ci.verify_runtime(runtime, self.identity_file, expected)
            archive.write_bytes(b'different-app')
            with self.assertRaisesRegex(ValueError, 'runtime changed'):
                ci.verify_runtime(runtime, self.identity_file, expected)
            self.identity_file.write_text(json.dumps({**self.identity, 'sourceSHA': 'e' * 40}))
            with self.assertRaisesRegex(ValueError, 'identity changed'):
                ci.verify_runtime(runtime, self.identity_file, expected)

    def test_full_evidence_tree_preserves_nested_media_and_hidden_proof(self):
        evidence = self.root / 'evidence'; evidence.mkdir()
        names = ['export-recovery-150/restarted-decoded/audio.f32', 'generation-recovery-150/history-output.wav',
                 'scale-150-frames-owner/Frame project.ngv/.exact-proof', 'generic-nle-150/Final cut.mp4']
        for name in names:
            path = evidence / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(name.encode())
        publication = self.root / 'publication'
        ci.archive_evidence(evidence, self.identity_file, 'frames', 1.5, publication)
        restored = self.root / 'restored'; manifest = ci.unpack_evidence(publication, restored)
        self.assertEqual({row['path'] for row in manifest['files']}, {*names, 'case-result.json'})
        for name in names: self.assertEqual((restored / name).read_bytes(), name.encode())
        self.assertFalse(json.loads((restored / 'case-result.json').read_text())['completed'])

    def test_symlink_and_private_environment_refuse_publication(self):
        evidence = self.root / 'evidence'; evidence.mkdir()
        secret = self.root / 'outside'; secret.write_bytes(b'not-public')
        (evidence / 'escape').symlink_to(secret)
        with self.assertRaises(ValueError): ci.archive_evidence(evidence, self.identity_file, 'frames', 1, self.root / 'publication')
        with patch.dict(os.environ, {'NGV_EXAMPLE_FIXTURE_ROOT': 'private'}), self.assertRaises(ValueError):
            ci.archive_evidence(self.root / 'clean', self.identity_file, 'frames', 1, self.root / 'private-publication')

    def test_tampered_archive_and_escaping_members_fail_closed(self):
        evidence = self.root / 'evidence'; evidence.mkdir(); (evidence / 'proof').write_bytes(b'actual')
        publication = self.root / 'publication'
        ci.archive_evidence(evidence, self.identity_file, 'frames', 1, publication)
        with (publication / 'evidence.tar.gz').open('ab') as stream: stream.write(b'changed')
        with self.assertRaises(ValueError): ci.unpack_evidence(publication, self.root / 'bad')
        with tarfile.open(publication / 'evidence.tar.gz', 'w:gz') as archive:
            entry = tarfile.TarInfo('../escaped'); entry.size = 1; archive.addfile(entry, io.BytesIO(b'x'))
        manifest = json.loads((publication / 'evidence-manifest.json').read_text())
        manifest['archiveSHA256'] = ci.sha(publication / 'evidence.tar.gz')
        (publication / 'evidence-manifest.json').write_text(json.dumps(manifest))
        with self.assertRaises(ValueError): ci.unpack_evidence(publication, self.root / 'traversal')
        self.assertFalse((self.root / 'escaped').exists())

    def test_three_generation_processes_have_three_completions(self):
        complete = {'event': 'completed', 'case': 'generationrecovery', 'scale': 1.5}
        rows = [copy.deepcopy(complete) for _ in range(3)]
        with patch('workspace_ui_acceptance.generation_recovery_evidence', return_value=(True, [])):
            self.assertTrue(validate_case('generationrecovery', rows, self.root, 1.5)[0])
            self.assertFalse(validate_case('generationrecovery', rows[:2], self.root, 1.5)[0])
            self.assertFalse(validate_case('generationrecovery', rows + [complete], self.root, 1.5)[0])
        starts = [{'event': 'started', 'case': 'generationrecovery', 'scale': 1.5, 'restorationIgnored': True}] * 3
        self.assertTrue(validate_processes('generationrecovery', starts, 1.5))
        self.assertFalse(validate_processes('generationrecovery', starts[:2], 1.5))

    def cards(self, output, completed=True):
        output.mkdir()
        image = output / 'card.png'; image.write_bytes(b'\x89PNG\r\n\x1a\n' + b'fixture' * 200)
        rows = [{'event': 'started', 'case': 'cards', 'scale': 1, 'restorationIgnored': True},
                {'event': 'project-cards', 'width': 213, 'height': 170.4, 'openVerified': True,
                 'unavailableDisabled': True, 'unavailableContentSeparated': True, 'screenshot': 'card.png'},
                {'event': 'completed', 'case': 'cards', 'scale': 1}]
        (output / 'scale-100.log').write_text('\n'.join(json.dumps(row) for row in rows))
        record = {'schema': 'nexgenvideo/native-case/1', 'identity': self.identity, 'case': 'cards', 'scale': 1,
                  'completed': completed, 'exitCode': 0, 'events': rows}
        (output / 'case-result.json').write_text(json.dumps(record))
        return record

    def test_result_cannot_replace_real_native_events_with_a_pass_flag(self):
        root = self.root / 'case'; record = self.cards(root)
        self.assertTrue(ci.verify_result(record, root, self.identity, 'cards', 1))
        record['events'][1]['unavailableDisabled'] = False
        (root / 'scale-100.log').write_text('\n'.join(json.dumps(row) for row in record['events']))
        self.assertFalse(ci.verify_result(record, root, self.identity, 'cards', 1))
        record['events'] = []
        self.assertFalse(ci.verify_result(record, root, self.identity, 'cards', 1))

    def test_summary_requires_all_expected_keys_and_does_not_use_an_older_success(self):
        plan_file = self.root / 'plan.json'; plan_file.write_text(json.dumps(ci.selection('all', 'cards', '1')))
        self.identity['planSHA256'] = ci.sha(plan_file)
        self.identity_file.write_text(json.dumps(self.identity))
        artifacts = self.root / 'artifacts'; artifacts.mkdir()
        for attempt, completed in ((1, True), (2, False)):
            evidence = self.root / ('attempt-' + str(attempt)); self.cards(evidence, completed=completed)
            with patch.dict(os.environ, {'GITHUB_RUN_ATTEMPT': str(attempt)}):
                ci.archive_evidence(evidence, self.identity_file, 'cards', 1,
                                    artifacts / ('native-evidence-cards-100-a' + str(attempt)))
        self.assertEqual(ci.summarize(artifacts, self.root / 'summary', plan_file, self.identity_file, ci.sha(self.identity_file)), 1)
        report = json.loads((self.root / 'summary/result.json').read_text())
        self.assertFalse(report['completed']); self.assertFalse(report['fullWorkspaceAcceptance'])
        self.assertEqual(report['results'][0]['originAttempt'], 2)
        empty = self.root / 'empty'; empty.mkdir()
        self.assertEqual(ci.summarize(empty, self.root / 'missing-summary', plan_file, self.identity_file, ci.sha(self.identity_file)), 1)

    def test_summary_refuses_a_narrowed_plan_or_replaced_identity(self):
        plan = self.root / 'plan.json'; plan.write_text(json.dumps(ci.selection('all')))
        self.identity['planSHA256'] = ci.sha(plan)
        self.identity_file.write_text(json.dumps(self.identity))
        expected = ci.sha(self.identity_file)
        plan.write_text(json.dumps(ci.selection('all', 'cards', '1')))
        with self.assertRaisesRegex(ValueError, 'plan changed'):
            ci.summarize(self.root, self.root / 'summary', plan, self.identity_file, expected)
        self.identity_file.write_text(json.dumps({**self.identity, 'planSHA256': ci.sha(plan)}))
        with self.assertRaisesRegex(ValueError, 'identity changed'):
            ci.summarize(self.root, self.root / 'summary', plan, self.identity_file, expected)

    def test_remote_summary_checks_latest_job_and_releases_each_extracted_tree(self):
        plan = self.root / 'plan.json'; plan.write_text(json.dumps(ci.selection('all', 'cards', '1')))
        self.identity['planSHA256'] = ci.sha(plan)
        self.identity_file.write_text(json.dumps(self.identity))
        evidence = self.root / 'case'; self.cards(evidence)
        publication = self.root / 'publication'
        ci.archive_evidence(evidence, self.identity_file, 'cards', 1, publication)
        stream = io.BytesIO()
        with zipfile.ZipFile(stream, 'w') as bundle:
            for path in publication.iterdir(): bundle.writestr(path.name, path.read_bytes())
        payload = stream.getvalue()
        artifact = {'id': 3, 'name': 'native-evidence-cards-100-a2', 'expired': False,
                    'workflow_run': {'id': 77, 'head_sha': self.identity['sourceSHA']},
                    'digest': 'sha256:' + hashlib.sha256(payload).hexdigest()}
        job = {'id': 99, 'name': 'workspace-ui-acceptance / Native cards-100', 'run_id': 77, 'run_attempt': 2,
               'head_sha': self.identity['sourceSHA'], 'status': 'completed', 'conclusion': 'success'}

        def response(path):
            if '/artifacts?' in path: return {'artifacts': [artifact]}
            return {'jobs': [job] if '/attempts/2/' in path else []}

        def download(identifier, digest, destination):
            self.assertEqual(identifier, artifact['id']); self.assertEqual(digest, artifact['digest'])
            destination.write_bytes(payload)

        with patch.object(ci, 'api', side_effect=response), patch.object(ci, 'download_artifact', side_effect=download):
            target = self.root / 'remote-summary'
            self.assertEqual(ci.summarize(self.root, target, plan, self.identity_file, ci.sha(self.identity_file), remote=True), 0)
            self.assertEqual([path.name for path in target.iterdir()], ['result.json'])
            report = json.loads((target / 'result.json').read_text())
            self.assertEqual(report['results'][0]['originJobID'], 99)
            job['conclusion'] = 'failure'
            self.assertEqual(ci.summarize(self.root, self.root / 'failed-job', plan, self.identity_file,
                                          ci.sha(self.identity_file), remote=True), 1)

    def test_newer_failed_job_without_an_artifact_overrides_prior_success(self):
        plan = self.root / 'plan.json'; plan.write_text(json.dumps(ci.selection('all', 'cards', '1')))
        self.identity['planSHA256'] = ci.sha(plan)
        self.identity_file.write_text(json.dumps(self.identity))
        artifact = {'name': 'native-evidence-cards-100-a1'}
        def response(path):
            if '/artifacts?' in path: return {'artifacts': [artifact]}
            attempt = 2 if '/attempts/2/' in path else 1
            return {'jobs': [{'name': 'Native cards-100', 'id': attempt, 'run_id': 77, 'run_attempt': attempt,
                             'head_sha': self.identity['sourceSHA'], 'status': 'completed',
                             'conclusion': 'failure' if attempt == 2 else 'success'}]}
        with patch.object(ci, 'api', side_effect=response), patch.object(ci, 'download_artifact') as download:
            self.assertEqual(ci.summarize(self.root, self.root / 'remote', plan, self.identity_file,
                                          ci.sha(self.identity_file), remote=True), 1)
            download.assert_not_called()

    def test_failed_only_resume_preserves_the_actual_older_success_attempt(self):
        plan = self.root / 'plan.json'; plan.write_text(json.dumps(ci.selection('all', 'cards', '1')))
        self.identity['planSHA256'] = ci.sha(plan)
        self.identity_file.write_text(json.dumps(self.identity))
        evidence = self.root / 'case'; self.cards(evidence)
        publication = self.root / 'publication'
        with patch.dict(os.environ, {'GITHUB_RUN_ATTEMPT': '1'}):
            ci.archive_evidence(evidence, self.identity_file, 'cards', 1, publication)
        stream = io.BytesIO()
        with zipfile.ZipFile(stream, 'w') as bundle:
            for path in publication.iterdir(): bundle.writestr(path.name, path.read_bytes())
        payload = stream.getvalue()
        artifact = {'id': 3, 'name': 'native-evidence-cards-100-a1', 'expired': False,
                    'workflow_run': {'id': 77, 'head_sha': self.identity['sourceSHA']},
                    'digest': 'sha256:' + hashlib.sha256(payload).hexdigest()}
        job = {'id': 99, 'name': 'workspace-ui-acceptance / Native cards-100', 'run_id': 77, 'run_attempt': 1,
               'head_sha': self.identity['sourceSHA'], 'status': 'completed', 'conclusion': 'success'}
        for carried_over in (False, True):
            def response(path):
                if '/artifacts?' in path: return {'artifacts': [artifact]}
                return {'jobs': [job] if '/attempts/1/' in path or carried_over else []}

            def download(identifier, digest, destination):
                self.assertEqual((identifier, digest), (artifact['id'], artifact['digest']))
                destination.write_bytes(payload)

            with self.subTest(carried_over=carried_over), patch.object(ci, 'api', side_effect=response), \
                 patch.object(ci, 'download_artifact', side_effect=download):
                target = self.root / f'carried-{carried_over}'
                self.assertEqual(ci.summarize(self.root, target, plan, self.identity_file,
                                              ci.sha(self.identity_file), remote=True), 0)
                report = json.loads((target / 'result.json').read_text())
                self.assertEqual(report['results'][0]['originAttempt'], 1)
                self.assertEqual(report['results'][0]['originJobID'], 99)

    def test_later_listing_of_old_job_cannot_hide_newer_failure(self):
        old = {'id': 99, 'name': 'Native cards-100', 'run_attempt': 1, 'conclusion': 'success'}
        failed = {**old, 'id': 100, 'run_attempt': 2, 'conclusion': 'failure'}
        def response(path):
            return {'jobs': [failed if '/attempts/2/' in path else old]}
        with patch.dict(os.environ, {'GITHUB_RUN_ATTEMPT': '3'}), patch.object(ci, 'api', side_effect=response):
            self.assertEqual(ci.latest_native_jobs({('cards', 1)})[('cards', 1)], (2, failed))

    def test_job_origin_is_strict_and_cannot_claim_a_future_attempt(self):
        for origin in (None, False, 0, -1, 1.0, '1', 2):
            job = {'id': 99, 'name': 'Native cards-100', 'run_attempt': origin}
            with self.subTest(origin=origin), patch.object(ci, 'api', return_value={'jobs': [job]}), \
                 self.assertRaisesRegex(ValueError, 'invalid origin'):
                ci.latest_native_jobs({('cards', 1)})

    def test_one_origin_attempt_cannot_acquire_a_different_job_identity(self):
        def response(path):
            return {'jobs': [{'id': 99 if '/attempts/1/' in path else 100,
                             'name': 'Native cards-100', 'run_attempt': 1}]}
        with patch.object(ci, 'api', side_effect=response), self.assertRaisesRegex(ValueError, 'Conflicting'):
            ci.latest_native_jobs({('cards', 1)})


class BpyFollowupBindingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.identity = Path(self.temp.name) / 'original-app.json'
        self.run = {'id': 77, 'repository': {'full_name': 'iret77/nexgenvideo'},
                    'head_sha': 'a' * 40, 'event': 'workflow_dispatch',
                    'path': '.github/workflows/ci-batch.yml', 'status': 'completed', 'conclusion': 'failure'}
        steps = [{'name': n, 'status': 'completed', 'conclusion': 'success'} for n in
                 ('Build', 'Test', 'Bundle (debug, ad-hoc signed)', 'Upload .app artifact')]
        self.jobs = [{'id': 101, 'name': 'Core / Build & Test', 'status': 'completed',
                      'conclusion': 'success', 'steps': steps},
                     {'id': 102, 'name': 'Core / bpy-runtime / runtime', 'status': 'completed', 'conclusion': 'failure'}]
        self.artifacts = [{'id': 8, 'name': 'NexGenVideo-app', 'expired': False,
                           'digest': 'sha256:' + 'b' * 64, 'workflow_run': {'id': 77, 'head_sha': 'a' * 40}}]

    def tearDown(self):
        self.temp.cleanup()

    def api(self, path):
        if path == '/actions/runs/77':
            return self.run
        if '/jobs?' in path:
            return {'jobs': self.jobs}
        if '/artifacts?' in path:
            return {'artifacts': self.artifacts}
        raise AssertionError('Unexpected API route: ' + path)

    def resolve(self):
        with patch.dict(os.environ, {'GITHUB_SHA': 'd' * 40}), \
             patch.object(ci, 'api', side_effect=self.api), patch.object(ci, 'outputs') as emitted:
            result = ci.resolve_bpy_followup(77, self.identity)
        return result, emitted

    def test_original_app_source_is_separate_from_the_current_harness(self):
        result, emitted = self.resolve()
        self.assertEqual(result['scope'], 'original-app-diagnostic')
        self.assertEqual(result['appSourceSHA'], 'a' * 40)
        self.assertEqual(result['harnessSHA'], 'd' * 40)
        self.assertEqual(result['failedRuntimeJobID'], 102)
        self.assertEqual(json.loads(self.identity.read_text()), result)
        emitted.assert_called_once_with({'source_sha': 'a' * 40, 'artifact_id': '8', 'artifact_sha256': 'b' * 64})

    def test_foreign_or_incompatible_original_producers_are_rejected(self):
        original = copy.deepcopy(self.run)
        for change in ({'id': 78}, {'repository': {'full_name': 'foreign/repo'}}, {'head_sha': 'invalid'},
                       {'event': 'pull_request'}, {'path': '.github/workflows/release.yml'},
                       {'status': 'queued'}, {'conclusion': 'cancelled'}, {'conclusion': 'success'}):
            self.run = {**original, **change}
            with self.subTest(change=change), self.assertRaises(ValueError):
                self.resolve()
        self.assertFalse(self.identity.exists())

    def test_only_a_failed_native_job_with_a_completed_original_build_can_resume(self):
        original = copy.deepcopy(self.jobs)
        changes = [('build-failed', lambda: self.jobs[0].update(conclusion='failure')),
                   ('skipped-test', lambda: self.jobs[0]['steps'][1].update(conclusion='skipped')),
                   ('missing-test', lambda: self.jobs[0]['steps'].pop(1)),
                   ('native-passed', lambda: self.jobs[1].update(conclusion='success')),
                   ('native-pending', lambda: self.jobs[1].update(status='in_progress')),
                   ('ambiguous-native', lambda: self.jobs.append(copy.deepcopy(self.jobs[1]))),
                   ('invalid-job', lambda: self.jobs[1].update(id=0))]
        for name, mutate in changes:
            self.jobs = copy.deepcopy(original)
            mutate()
            with self.subTest(name=name), self.assertRaises(ValueError):
                self.resolve()
        self.assertFalse(self.identity.exists())

    def test_original_artifact_identity_cannot_be_swapped_or_ambiguous(self):
        original = copy.deepcopy(self.artifacts)
        for change in ({'expired': True}, {'digest': ''}, {'id': True},
                       {'workflow_run': {'id': 78, 'head_sha': 'a' * 40}},
                       {'workflow_run': {'id': 77, 'head_sha': 'f' * 40}}):
            self.artifacts = [{**original[0], **change}]
            with self.subTest(change=change), self.assertRaises(ValueError):
                self.resolve()
        self.artifacts = [original[0], {**original[0], 'id': 9}]
        with self.assertRaises(ValueError):
            self.resolve()
        self.assertFalse(self.identity.exists())

    def test_binding_reads_later_inventory_pages_without_losing_the_original(self):
        def api(path):
            if path == '/actions/runs/77':
                return self.run
            kind = 'jobs' if '/jobs?' in path else 'artifacts'
            if 'page=1&' in path or path.endswith('page=1'):
                return {kind: [{'id': i, 'name': 'unrelated'} for i in range(100)]}
            return {kind: self.jobs if kind == 'jobs' else self.artifacts}

        with patch.dict(os.environ, {'GITHUB_SHA': 'd' * 40}), patch.object(ci, 'api', side_effect=api), \
             patch.object(ci, 'outputs'):
            result = ci.resolve_bpy_followup(77, self.identity)
        self.assertEqual(result['runtimeArtifactID'], 8)


if __name__ == '__main__': unittest.main()
