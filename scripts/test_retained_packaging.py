import copy
from contextlib import chdir
import datetime
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import stat
import subprocess
import sys
import tempfile
import textwrap
import unittest
from unittest.mock import patch
import zipfile
import yaml

import retained_packaging as packaging


class RetainedPackagingTests(unittest.TestCase):
    product = "a" * 40
    producer = "b" * 40

    def test_cli_uses_the_same_evidence_capture_as_nested_imported_verifiers(self):
        entry = Path(__file__).resolve().parent / 'retained_packaging.py'
        code = textwrap.dedent("""
            import hashlib, io, pathlib, runpy, sys, zipfile, json
            from unittest.mock import patch
            entry = pathlib.Path(sys.argv[1]); sys.path.insert(0, str(entry.parent))
            import retained_packaging as p
            import compiled_component_reuse as c
            logs = {'actions/jobs/' + str(c.ORIGIN['builderJobID']) + '/logs': b'builder',
                    'actions/jobs/' + str(c.ORIGIN['releaseJobID']) + '/logs': b'release'}
            origin = dict(c.ORIGIN, builderRawSHA256=hashlib.sha256(b'builder').hexdigest(),
                          releaseRawSHA256=hashlib.sha256(b'release').hexdigest())
            release = dict(id=origin['releaseJobID'], run_id=origin['runID'], head_sha=origin['sourceSHA'],
                           run_attempt=1, name='release', labels=['macrunner'], status='completed', conclusion='failure',
                           steps=[dict(name=name, conclusion='success') for name in c.RELEASE_STEPS])
            routes = {'actions/jobs/' + str(origin['releaseJobID']): release,
                      'actions/artifacts/' + str(origin['assemblyArtifactID']): {'id': origin['assemblyArtifactID']}}
            def collect(*args, **kwargs):
                c.verify_native_originals({}, {'id': origin['builderJobID']})
                return dict(productSourceSHA=origin['sourceSHA'], producerSourceSHA='b'*40, runID=70), {}
            def bind(root):
                record, files = p.collect_binding({})
                with zipfile.ZipFile(io.BytesIO(files['original-api-evidence.zip'])) as z:
                    acquisition = json.loads(z.read('acquisition.json'))
                assert set(acquisition['json']) == set(routes), acquisition
                assert set(acquisition['bytes']) == set(logs), acquisition
                assert p.CAPTURE.get() is None and p.REPLAY.get() is None and p.BUDGET.get() is None
            sys.argv = [str(entry), 'bind', '--root', 'unused-probe-destination']
            with patch.object(c, 'ORIGIN', origin), patch.object(p, 'collect_original_binding', side_effect=collect), \
                    patch.object(p, 'live_api', side_effect=routes.__getitem__), \
                    patch.object(p, 'live_read_api', side_effect=lambda route, **kwargs: logs[route]), \
                    patch.object(p, 'live_verify_artifact'), patch.object(p, 'bind_current', side_effect=bind):
                runpy.run_path(str(entry), run_name='__main__')
        """)
        environment = {key: value for key, value in os.environ.items() if key not in {'PYTHONPATH', 'GH_TOKEN'}}
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run([sys.executable, '-I', '-c', code, str(entry)], cwd=directory,
                                    env=environment, capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_every_packaging_consumer_retains_supplement_even_after_failure(self):
        root = Path(__file__).resolve().parents[1] / '.github/workflows'
        callers = {'release': ['release-gate', 'release', 'diagnostic-acceptance'], 'diagnostic-acceptance': ['source', 'transport-fixture', 'acceptance'],
                   'bpy-runtime-acceptance': ['runtime'], 'external-gui-acceptance': ['cases', 'test-runtime', 'acceptance'],
                   'workspace-ui-acceptance': ['source', 'runtime', 'acceptance', 'batch-review'],
                   'settings-owner-acceptance': ['cases', 'acceptance'], 'chat-hang-replay': ['source', 'replay'],
                   'private-example-analysis': ['source-gate', 'analyze'], 'ci-batch': ['validate'],
                   'retained-runtime-failure-diagnostic': ['measurement']}
        for filename, jobs in callers.items():
            workflow = yaml.safe_load((root / (filename + '.yml')).read_text())
            for job in jobs:
                with self.subTest(workflow=filename, job=job):
                    uploads = [step for step in workflow['jobs'][job]['steps']
                               if step.get('with', {}).get('path') == '${{ runner.temp }}/retained-packaging-supplements/']
                    self.assertEqual(len(uploads), 1)
                    self.assertEqual(uploads[0]['if'], 'always()')
                    self.assertNotIn('continue-on-error', uploads[0])
                    self.assertIn('${{ github.job }}', uploads[0]['with']['name'])
        diagnostic = yaml.safe_load((root / 'release.yml').read_text())['jobs']['diagnostic-acceptance']['steps']
        checkout = next(step for step in diagnostic if step.get('uses', '').startswith('actions/checkout@'))
        self.assertEqual(checkout['with']['fetch-depth'], 0)

    def test_component_repair_paths_require_the_exact_canonical_record(self):
        record = {'runID': 70, 'producerSourceSHA': self.producer}
        gap = dict(packaging.COMPONENT_CAPTURE_GAP, recordSHA256=packaging.digest(packaging.encoded(record)))
        with patch.object(packaging, 'COMPONENT_CAPTURE_GAP', gap):
            self.assertIn('scripts/retained_packaging.py', packaging.component_consumer_repair_paths(record))
            self.assertFalse(packaging.component_consumer_repair_paths(record | {'runID': 71}))
            self.assertFalse(any(path.startswith(('Sources/', 'Engine/', 'Tests/', 'plugins/'))
                                 for path in packaging.component_consumer_repair_paths(record)))

    def component_supplement_fixture(self):
        import compiled_component_reuse as component
        logs = {f"actions/jobs/{component.ORIGIN[key]}/logs": raw for key, raw in
                (('builderJobID', b'original full builder'), ('releaseJobID', b'original full release'))}
        origin = dict(component.ORIGIN, builderRawSHA256=packaging.digest(b'original full builder'),
                      releaseRawSHA256=packaging.digest(b'original full release'))
        producer = {'id': origin['runID'], 'head_sha': origin['sourceSHA']}
        builder = {'id': origin['builderJobID'], 'started_at': '2026-11-04T08:00:00Z',
                   'completed_at': '2026-11-04T09:00:00Z'}
        release = {'id': origin['releaseJobID'], 'run_id': origin['runID'], 'head_sha': origin['sourceSHA'],
                   'run_attempt': 1, 'name': 'release', 'labels': ['macrunner'], 'status': 'completed', 'conclusion': 'failure',
                   'steps': [{'name': name, 'conclusion': 'success'} for name in component.RELEASE_STEPS]}
        assembly = {'id': origin['assemblyArtifactID'], 'name': 'release-compiled-app-assembly-' + str(origin['runID']) + '-a1',
                    'digest': 'sha256:' + origin['assemblyArtifactSHA256'], 'expired': False,
                    'workflow_run': producer, 'created_at': '2026-11-04T08:10:00Z',
                    'updated_at': '2026-11-04T08:11:00Z', 'expires_at': '2027-01-01T00:00:00Z'}
        record = {'runID': 70, 'productSourceSHA': origin['sourceSHA'], 'producerSourceSHA': self.producer,
                  'stage': 'complete', 'attempt': 1, 'ref': 'owned-base'}
        captured = {'json': {'actions/runs/70': {'id': 70, 'head_sha': self.producer, 'head_branch': 'owned-base',
                                              'created_at': '2026-11-04T10:00:00Z'},
                            f"actions/runs/{origin['runID']}/attempts/1/jobs?per_page=100": {'total_count': 2, 'jobs': [builder, release]},
                            f"actions/runs/{origin['runID']}/artifacts?per_page=100": {'total_count': 1, 'artifacts': [assembly]}},
                    'bytes': {}, 'legacy': {}}
        with patch.object(packaging, 'utc_now', return_value='2026-11-04T10:10:00Z'):
            raw = packaging.encoded_api_evidence(captured, record)
        gap = {'runID': 70, 'producerSourceSHA': self.producer, 'productSourceSHA': origin['sourceSHA'],
               'artifactID': 701, 'artifactSHA256': '9' * 64, 'recordSHA256': packaging.digest(packaging.encoded(record)),
               'acquisitionSHA256': packaging.digest(raw)}
        container = {'id': 701, 'digest': 'sha256:' + '9' * 64, 'workflow_run': {'id': 70, 'head_sha': self.producer},
                     'created_at': '2026-11-04T10:40:00Z'}
        current = {'id': 71, 'head_sha': 'c' * 40, 'run_attempt': 1, 'repository': {'full_name': packaging.REPOSITORY},
                   'actor': {'login': 'iret77'}, 'event': 'workflow_dispatch', 'created_at': '2026-11-04T10:50:00Z'}
        environment = {'GITHUB_ACTIONS': 'true', 'GITHUB_REPOSITORY': packaging.REPOSITORY, 'GITHUB_RUN_ID': '71',
                       'GITHUB_RUN_ATTEMPT': '1', 'GITHUB_JOB': 'runtime', 'GITHUB_SHA': 'c' * 40}
        return origin, producer, builder, raw, record, gap, container, current, environment, logs

    def test_exact_component_supplement_restores_full_native_origin_without_rewriting_history(self):
        import compiled_component_reuse as component
        origin, producer, builder, raw, record, gap, container, current, environment, logs = self.component_supplement_fixture()
        before = bytes(raw)
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, environment | {'RUNNER_TEMP': directory}), \
                patch.object(component, 'ORIGIN', origin), patch.object(packaging, 'COMPONENT_CAPTURE_GAP', gap), \
                patch.object(packaging, 'live_api', return_value=current) as api, \
                patch.object(packaging, 'live_read_api', side_effect=lambda route, **kwargs: logs[route]) as download:
            for index in range(2):
                with packaging.authenticated_originals(raw, record, container, {}) as supplement:
                    component.verify_native_originals(producer, builder)
                    with self.assertRaisesRegex(ValueError, 'Original API evidence is missing'):
                        packaging.api('actions/jobs/999')
                    self.assertIsNotNone(supplement)
                self.assertIsNone(packaging.REPLAY.get())
            self.assertEqual(api.call_count, 1)
            self.assertEqual(download.call_count, 2)
            self.assertEqual(raw, before)
            saved = Path(directory) / 'retained-packaging-supplements' / (gap['recordSHA256'] + '.zip')
            with zipfile.ZipFile(saved) as archive:
                metadata = json.loads(archive.read('supplement.json'))
            self.assertFalse(metadata['historicalAcquisitionRewritten'])
            self.assertEqual(metadata['execution']['GITHUB_RUN_ID'], '71')
            self.assertEqual(set(metadata['rawLogs']), set(logs))
            with self.assertRaises(ValueError):
                with packaging.authenticated_originals(raw, record | {'stage': 'restored'}, container, {}): pass
            with self.assertRaises(ValueError):
                with packaging.authenticated_originals(raw, record, container | {'id': 702}, {}): pass
            with patch.dict(os.environ, GITHUB_RUN_ID='72'), self.assertRaisesRegex(ValueError, 'scope, execution'):
                with packaging.authenticated_originals(raw, record, container, {}): pass
            members = packaging.read_proof_archive(saved.read_bytes())
            members[next(name for name in members if name.endswith('.bin'))] = b'changed original raw'
            with zipfile.ZipFile(saved, 'w') as archive:
                for name, value in members.items(): archive.writestr(name, value)
            with self.assertRaisesRegex(ValueError, 'original raw bytes changed'):
                with packaging.authenticated_originals(raw, record, container, {}): pass

    def test_component_supplement_rejects_unpinned_history_and_never_repeats_partial_acquisition(self):
        import compiled_component_reuse as component
        fixture = self.component_supplement_fixture()
        origin, producer, builder, raw, record, gap, container, current, environment, logs = fixture
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, environment | {'RUNNER_TEMP': directory}), \
                patch.object(component, 'ORIGIN', origin), patch.object(packaging, 'COMPONENT_CAPTURE_GAP', gap), \
                patch.object(packaging, 'live_api', return_value=current), \
                patch.object(packaging, 'live_read_api', return_value=b'wrong original') as download:
            with self.assertRaisesRegex(ValueError, 'Fresh component origin raw log differs'):
                with packaging.authenticated_originals(raw, record, container, {}): pass
            calls = download.call_count
            with self.assertRaisesRegex(ValueError, 'already consumed'):
                with packaging.authenticated_originals(raw, record, container, {}): pass
            self.assertEqual(download.call_count, calls)
        with patch.object(packaging, 'COMPONENT_CAPTURE_GAP', gap), patch.object(packaging, 'live_read_api') as download:
            with self.assertRaisesRegex(ValueError, 'exact immutable original'):
                with packaging.authenticated_originals(raw, record | {'attempt': 2}, container, {}): pass
            download.assert_not_called()

    def compiled_binding_fixture(self):
        from compiled_app_release import SIGNED_RESUME, PACK_SHA, PACK_TREE
        origin = SIGNED_RESUME
        return {'productSourceSHA': origin['sourceSHA'], 'producerSourceSHA': self.producer, 'runID': 777,
            'originalSignedBuildRunID': origin['runID'], 'signedInput': {'compiledProduct': {
                'schema': 'compiled-signed-product-reuse/v1', 'original': origin, 'packArchiveSHA256': PACK_SHA,
                'packTreeSHA256': PACK_TREE, 'appRootMode': 0o755, 'freshCompilerCoreAssemblyOrRootSignPerformed': False}},
            'previousNotary': {'journals': {}, 'stateArtifact': {'id': origin['stateArtifactID'], 'digest': 'sha256:' + origin['stateSHA256']},
                'context': {'schema': 'release-notary-context/v1', 'repository': packaging.REPOSITORY,
                    'sourceSHA': origin['sourceSHA'], 'buildRunID': origin['runID'], 'runID': origin['runID']}}}

    def test_compiled_resume_keeps_context_only_exception_bound_to_exact_original_state_bytes(self):
        import compiled_app_release as compiled
        binding = self.compiled_binding_fixture()
        context = binding['previousNotary']['context']
        raw = io.BytesIO()
        with zipfile.ZipFile(raw, 'w') as archive: archive.writestr('context.json', json.dumps(context))
        original = dict(compiled.SIGNED_RESUME, stateSHA256=hashlib.sha256(raw.getvalue()).hexdigest())
        with patch.object(compiled, 'SIGNED_RESUME', original):
            self.assertEqual(packaging.state_records(raw.getvalue(), original['sourceSHA'], original['sourceSHA'], original['runID']), (context, {}))
            for product, producer, run_id in [(self.product, self.product, original['runID']),
                    (original['sourceSHA'], self.producer, original['runID']), (original['sourceSHA'], original['sourceSHA'], 778)]:
                with self.subTest(product=product, producer=producer, run_id=run_id), self.assertRaises(ValueError):
                    packaging.state_records(raw.getvalue(), product, producer, run_id)
            changed = io.BytesIO()
            with zipfile.ZipFile(changed, 'w') as archive: archive.writestr('context.json', json.dumps(context, indent=4))
            with self.assertRaises(ValueError):
                packaging.state_records(changed.getvalue(), original['sourceSHA'], original['sourceSHA'], original['runID'])

    def test_first_compiled_notary_requires_complete_signed_product_and_original_empty_state(self):
        binding = self.compiled_binding_fixture()
        self.assertTrue(packaging.compiled_first_notary(binding))
        for section, key, value in [('previousNotary', 'journals', {'f' * 64: {}}),
                ('previousNotary', 'stateArtifact', {'id': 123, 'digest': 'sha256:' + 'f' * 64}),
                ('signedInput', 'compiledProduct', {})]:
            changed = copy.deepcopy(binding); changed[section][key] = value
            with self.subTest(section=section, key=key): self.assertFalse(packaging.compiled_first_notary(changed))
        changed = copy.deepcopy(binding); changed['originalSignedBuildRunID'] += 1
        self.assertFalse(packaging.compiled_signed_product(changed))

    def test_empty_current_apple_state_is_allowed_only_before_the_exact_first_compiled_app_submission(self):
        binding = self.compiled_binding_fixture()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            context = {'schema': 'release-notary-context/v2', 'repository': packaging.REPOSITORY,
                'sourceSHA': binding['productSourceSHA'], 'producerSourceSHA': binding['producerSourceSHA'],
                'buildRunID': binding['originalSignedBuildRunID'], 'runID': binding['runID']}
            (root / 'context.json').write_text(json.dumps(context))
            with patch.dict(os.environ, NOTARY_STATE_DIR=str(root)):
                self.assertEqual(packaging.current_notary_state(binding, initial_app=True), (context, {}))
                with self.assertRaises(ValueError): packaging.current_notary_state(binding)
                changed = dict(context, buildRunID=123); (root / 'context.json').write_text(json.dumps(changed))
                with self.assertRaises(ValueError): packaging.current_notary_state(binding, initial_app=True)

    def test_original_compiled_pack_reuse_does_not_invent_or_require_a_new_pack_submission(self):
        from compiled_app_release import PACK_SHA
        binding = self.compiled_binding_fixture()
        self.assertTrue(packaging.qualified_pack_archives({'.build/plugins/musicvideo.ngvpack.zip': PACK_SHA}, binding))
        self.assertFalse(packaging.qualified_pack_archives({'.build/plugins/musicvideo.ngvpack.zip': 'f' * 64}, binding))
        legacy = {'previousNotary': {'journals': {}}}
        self.assertFalse(packaging.qualified_pack_archives({'.build/plugins/musicvideo.ngvpack.zip': PACK_SHA}, legacy))
        legacy['previousNotary']['journals'][PACK_SHA] = {'submissionID': 'original'}
        self.assertTrue(packaging.qualified_pack_archives({'.build/plugins/musicvideo.ngvpack.zip': PACK_SHA}, legacy))

    def test_later_compiled_notary_resume_accepts_only_the_exact_new_app_journal(self):
        from compiled_app_release import SIGNED_RESUME
        product, app_sha = SIGNED_RESUME['sourceSHA'], SIGNED_RESUME['appArchiveSHA256']
        for changed in ('valid', 'foreign-journal', 'legacy', 'substituted-app'):
            with self.subTest(changed=changed):
                record = self.compiled_binding_fixture(); record['stage'] = 'restored'
                record['signedInput']['manifest'] = {'files': {'NexGenVideo.zip': {'sha256': app_sha}}}
                if changed == 'legacy': record['signedInput'].pop('compiledProduct')
                if changed == 'substituted-app': record['signedInput']['manifest']['files']['NexGenVideo.zip']['sha256'] = 'f' * 64
                context = {'schema': 'release-notary-context/v2', 'repository': packaging.REPOSITORY, 'sourceSHA': product,
                    'producerSourceSHA': self.producer, 'runID': 7, 'buildRunID': SIGNED_RESUME['runID']}
                journals = {app_sha: {'schema': 'release-notary/v1', 'sha256': app_sha, 'sourceSHA': product,
                    'submissionID': '11111111-1111-1111-1111-111111111111'}}
                if changed == 'foreign-journal':
                    journals['f' * 64] = dict(journals[app_sha], sha256='f' * 64)
                stream = io.BytesIO()
                with zipfile.ZipFile(stream, 'w') as archive:
                    archive.writestr('context.json', json.dumps(context))
                    for checksum, value in journals.items(): archive.writestr(checksum + '.json', json.dumps(value))
                raw = stream.getvalue()
                artifact = {'id': 9, 'name': 'release-notary-state-' + product, 'size_in_bytes': len(raw),
                    'digest': 'sha256:' + hashlib.sha256(raw).hexdigest()}
                run = {'id': 7, 'head_sha': self.producer, 'repository': {'full_name': packaging.REPOSITORY},
                    'path': '.github/workflows/release.yml', 'event': 'workflow_dispatch', 'run_attempt': 1,
                    'actor': {'login': 'iret77'}, 'status': 'completed', 'conclusion': 'failure'}
                job = {'id': 8, 'name': 'release', 'run_id': 7, 'head_sha': self.producer, 'run_attempt': 1,
                    'labels': ['macrunner'], 'status': 'completed', 'conclusion': 'failure'}
                routes = {'actions/runs/7': run, 'actions/runs/7/attempts/1/jobs?per_page=100': {'total_count': 1, 'jobs': [job]},
                    'actions/runs/7/artifacts?per_page=100': {'total_count': 1, 'artifacts': [artifact]}, 'actions/artifacts/9': artifact}
                with patch.object(packaging, 'api', side_effect=routes.__getitem__), \
                        patch.object(packaging, 'load_provenance', return_value={'record': record, 'rawProofSHA256': 'e' * 64}), \
                        patch.object(packaging, 'verify_artifact'), patch.object(packaging, 'read_api', return_value=raw):
                    if changed == 'valid':
                        actual, original = packaging.prior_notary(7, product, packaging={'producerSourceSHA': self.producer})
                        self.assertEqual(actual['journals'], journals)
                        self.assertEqual(original, raw)
                        self.assertIsNone(actual['dmgProof'])
                    else:
                        with self.assertRaises(ValueError): packaging.prior_notary(7, product, packaging={'producerSourceSHA': self.producer})

    def closure_fixture(self):
        comparison = {"base_commit": {"sha": self.product}, "merge_base_commit": {"sha": self.product},
                      "status": "ahead", "total_commits": 1, "commits": [{"sha": self.producer}],
                      "files": [{"filename": "scripts/retained_packaging.py", "status": "added"},
                                {"filename": "scripts/plan_dmg_capacity.py", "status": "modified"}]}
        entries = [{"path": name, "mode": "100644" if name.startswith("Package.") else "040000",
                    "type": "blob" if name.startswith("Package.") else "tree",
                    "sha": hashlib.sha1(name.encode()).hexdigest()} for name in packaging.PRODUCT_OBJECTS]
        records = {"compare/" + self.product + "..." + self.producer: comparison,
                   "git/commits/" + self.product: {"sha": self.product, "tree": {"sha": "c" * 40}},
                   "git/commits/" + self.producer: {"sha": self.producer, "tree": {"sha": "d" * 40}},
                   "git/trees/" + "c" * 40: {"sha": "c" * 40, "truncated": False, "tree": copy.deepcopy(entries)},
                   "git/trees/" + "d" * 40: {"sha": "d" * 40, "truncated": False, "tree": copy.deepcopy(entries)}}
        return records, comparison

    def mode(self):
        return {"productSourceSHA": self.product, "productSourceRunID": "11", "verifiedSourceRunID": "22",
                "priorNotaryRunID": "33", "artifactOnly": "true", "dryRun": "true", "version": "1.8.0"}

    def local_git_fixture(self):
        return {("status", "--porcelain", "--untracked-files=no"): b"",
                ("rev-parse", "HEAD"): self.producer.encode(), ("rev-parse", "HEAD^{tree}"): b"d" * 40,
                ("merge-base", self.product, self.producer): self.product.encode(),
                ("rev-list", self.product + ".." + self.producer): self.producer.encode(),
                ("diff", "--no-renames", "--name-status", "-z", self.product, self.producer):
                    b"A\0scripts/retained_packaging.py\0M\0scripts/plan_dmg_capacity.py\0"}

    def test_packaging_selectors_are_complete_explicit_and_positive(self):
        self.assertIsNone(packaging.selectors("", "", ""))
        self.assertEqual(packaging.selectors(self.producer, "123", "e" * 64),
                         {"producerSourceSHA": self.producer, "artifactID": 123, "artifactSHA256": "e" * 64})
        for values in [(self.producer, "", "e" * 64), ("", "123", "e" * 64),
                       (self.producer, "123", ""), (self.producer, "0", "e" * 64),
                       (self.producer, " 123", "e" * 64), (self.producer, "-1", "e" * 64),
                       (self.producer, "123", "E" * 64), (self.producer, 123, "e" * 64)]:
            with self.subTest(values=values), self.assertRaises(ValueError):
                packaging.selectors(*values)

    def test_packaging_mode_preserves_empty_legacy_and_requires_complete_dry_inputs(self):
        with patch.dict(os.environ, GITHUB_SHA=self.producer):
            self.assertIsNone(packaging.mode_inputs({}))
            mode = packaging.mode_inputs(self.mode())
            self.assertEqual(mode["productSourceSHA"], self.product)
            self.assertEqual(mode["priorNotaryRunID"], 33)
            for key in ("productSourceSHA", "productSourceRunID", "verifiedSourceRunID", "priorNotaryRunID"):
                with self.subTest(key=key), self.assertRaises(ValueError):
                    packaging.mode_inputs(self.mode() | {key: ""})
            for key, value in [("artifactOnly", "false"), ("dryRun", "false"), ("productSourceSHA", self.producer),
                               ("productSourceRunID", "0"), ("version", "1.8"), ("priorNotaryRunID", " 33")]:
                with self.subTest(key=key), self.assertRaises(ValueError):
                    packaging.mode_inputs(self.mode() | {key: value})

    def test_packaging_mode_rejects_each_mixed_resume_or_client_selector(self):
        with patch.dict(os.environ, GITHUB_SHA=self.producer):
            for key in ("completedReleaseTestsRunID", "completedEngineTestsRunID", "signedBuildRunID", "testBundleRunID"):
                with self.subTest(key=key), self.assertRaises(ValueError):
                    packaging.mode_inputs(self.mode() | {key: "44"})
            for key in ("priorProducerSourceSHA", "priorProvenanceArtifactID", "priorProvenanceArtifactSHA256"):
                with self.subTest(key=key), self.assertRaises(ValueError):
                    packaging.mode_inputs(self.mode() | {key: "e" * 40 if key.endswith("SourceSHA") else "44"})

    def test_packaging_closure_rebinds_all_native_objects_and_complete_local_graph(self):
        records, _ = self.closure_fixture()
        local = self.local_git_fixture()
        with patch.dict(os.environ, GITHUB_SHA=self.producer), patch.object(packaging, "api", side_effect=records.__getitem__), \
                patch.object(packaging, "git", side_effect=lambda *args: local[args]):
            result = packaging.source_closure(self.product, self.producer, local=True)
        self.assertEqual(result["productSourceSHA"], self.product)
        self.assertEqual(result["producerSourceSHA"], self.producer)
        self.assertEqual(set(result["productObjects"]), set(packaging.PRODUCT_OBJECTS))
        self.assertEqual(result["commits"], [self.producer])
        import app_cohort_v2 as cohort
        original = {'appSourceSHA': 'e' * 40, 'nativeSourceObjects': {'Sources': 'f' * 40},
                    'roleSourceObjects': {'production': {'Sources/App.swift': '1' * 40}},
                    'componentSourceObjects': {'Engine': '2' * 40}, 'ciPaths': ['scripts/retained_packaging.py']}
        current = copy.deepcopy(original)
        current['ciPaths'] += ['scripts/plan_dmg_capacity.py', 'scripts/release_dmg_probe.py']
        comparison = records['compare/' + self.product + '...' + self.producer]
        comparison['files'].append({'filename': 'scripts/release_dmg_probe.py', 'status': 'modified'})
        local[("diff", "--no-renames", "--name-status", "-z", self.product, self.producer)] += b'M\0scripts/release_dmg_probe.py\0'
        with patch.dict(os.environ, GITHUB_SHA=self.producer), patch.object(packaging, 'api', side_effect=records.__getitem__), \
                patch.object(packaging, 'git', side_effect=lambda *args: local[args]), \
                patch.object(cohort, 'has_manifest', return_value=True), \
                patch.object(cohort, 'manifest', side_effect={self.product: original, self.producer: current}.__getitem__), \
                patch.object(cohort, 'objects', side_effect=lambda source, paths:
                    original['nativeSourceObjects'] if tuple(paths) == cohort.NATIVE_OBJECTS else dict(paths)), \
                patch.object(cohort.subprocess, 'run'), \
                patch.object(cohort, 'git', side_effect=AssertionError('Historical producer does not own the current checkout')) as local_head:
            self.assertNotIn('scripts/release_dmg_probe.py', original['ciPaths'])
            self.assertIn('scripts/release_dmg_probe.py', packaging.packaging_paths(self.product, self.producer))
            self.assertEqual(packaging.source_closure(self.product, self.producer, local=True)['commits'], [self.producer])
            self.assertEqual(packaging.source_closure(self.product, self.producer)['producerSourceSHA'], self.producer)
            local_head.assert_not_called()
            for field in ('roleSourceObjects', 'componentSourceObjects', 'nativeSourceObjects'):
                with self.subTest(changed=field):
                    saved = current[field]; current[field] = {'changed': '3' * 40}
                    with self.assertRaises(ValueError): packaging.source_closure(self.product, self.producer)
                    current[field] = saved
            comparison['files'].append({'filename': 'scripts/not_in_manifest.py', 'status': 'modified'})
            with self.assertRaises(ValueError): packaging.source_closure(self.product, self.producer)
            comparison['files'].pop()
            comparison['files'].append({'filename': 'Sources/App.swift', 'status': 'modified'})
            current['ciPaths'].append('Sources/App.swift')
            records['git/trees/' + 'd' * 40]['tree'][0]['sha'] = '4' * 40
            with self.assertRaisesRegex(ValueError, 'native product objects'):
                packaging.source_closure(self.product, self.producer)

    def test_packaging_closure_rejects_product_edits_renames_and_incomplete_history(self):
        for change in [{"files": [{"filename": "Sources/NexGenVideo/App/App.swift", "status": "modified"}]},
                       {"files": [{"filename": "scripts/retained_packaging.py", "status": "renamed", "previous_filename": "other.py"}]},
                       {"status": "diverged"}, {"total_commits": 2}, {"commits": [{"sha": "e" * 40}]},
                       {"merge_base_commit": {"sha": "e" * 40}}]:
            records, comparison = self.closure_fixture()
            comparison.update(change)
            with self.subTest(change=change), patch.object(packaging, "api", side_effect=records.__getitem__), \
                    self.assertRaises(ValueError):
                packaging.source_closure(self.product, self.producer)

    def test_packaging_closure_rejects_native_object_tamper_even_with_allowed_diff(self):
        records, _ = self.closure_fixture()
        records["git/trees/" + "d" * 40]["tree"][0]["sha"] = "e" * 40
        with patch.object(packaging, "api", side_effect=records.__getitem__), \
                self.assertRaisesRegex(ValueError, "native product objects"):
            packaging.source_closure(self.product, self.producer)

    def test_packaging_closure_rejects_dirty_or_fabricated_local_checkout(self):
        variants = [(('status', '--porcelain', '--untracked-files=no'), b' M scripts/retained_packaging.py', 'source is dirty'),
                    (('rev-parse', 'HEAD'), b'e' * 40, 'checkout differs'),
                    (('rev-parse', 'HEAD^{tree}'), b'e' * 40, 'checkout differs'),
                    (('merge-base', self.product, self.producer), b'e' * 40, 'not the packaging ancestor'),
                    (('rev-list', self.product + '..' + self.producer), (self.producer + '\n' + self.producer).encode(), 'commit graph differs'),
                    (('diff', '--no-renames', '--name-status', '-z', self.product, self.producer),
                     b'A\0scripts/retained_packaging.py\0', 'Local packaging diff differs')]
        for command, output, reason in variants:
            records, _ = self.closure_fixture()
            local = self.local_git_fixture(); local[command] = output
            with patch.dict(os.environ, GITHUB_SHA=self.producer), patch.object(packaging, "api", side_effect=records.__getitem__), \
                    patch.object(packaging, "git", side_effect=lambda *args: local[args]), \
                    self.subTest(command=command), self.assertRaisesRegex(ValueError, reason):
                packaging.source_closure(self.product, self.producer, local=True)

    def test_packaging_archive_rejects_duplicate_link_directory_and_escaping_members(self):
        for variant in ("duplicate", "link", "directory", "escape"):
            raw = io.BytesIO()
            with zipfile.ZipFile(raw, "w") as archive:
                entry = zipfile.ZipInfo("../proof.json" if variant == "escape" else "proof.json")
                if variant == "link": entry.external_attr = (stat.S_IFLNK | 0o777) << 16
                archive.writestr(entry, b"{}")
                if variant == "duplicate": archive.writestr("proof.json", b"changed")
                if variant == "directory": archive.writestr("directory/", b"")
            with self.subTest(variant=variant), self.assertRaises(ValueError):
                packaging.read_proof_archive(raw.getvalue())

    def test_packaging_execution_recheck_sees_only_index_against_head_change(self):
        record = {"runID": 7, "producerSourceSHA": self.producer, "ref": "iret77/packaging-base"}
        environment = {"GITHUB_RUN_ID": "7", "GITHUB_SHA": self.producer,
                       "GITHUB_REF_NAME": record["ref"], "GITHUB_RUN_ATTEMPT": "1"}
        def output(*args):
            if args == ('rev-parse', 'HEAD'): return self.producer.encode()
            if args == ('diff', '--no-renames', '--name-only'): return b''
            if args == ('diff', '--no-renames', '--name-only', 'HEAD', '--'):
                return b'scripts/retained_packaging.py\n'
            self.fail('Unexpected source recheck command')
        with patch.dict(os.environ, environment), patch.object(packaging, 'git', side_effect=output), \
                self.assertRaisesRegex(ValueError, 'changed after qualification'):
            packaging.execution_source(record)

    def test_packaging_chain_limit_counts_current_node_before_any_parent(self):
        before_native = packaging.provenance_chain(current=True)
        downstream = packaging.provenance_chain()
        packaging.enter_provenance(downstream, (100, 200))
        for index in range(7):
            packaging.enter_provenance(before_native, (index, index + 10))
            packaging.enter_provenance(downstream, (index, index + 10))
        self.assertEqual(before_native['depth'], 8)
        self.assertEqual(downstream['depth'], 8)
        for chain in (before_native, downstream):
            with self.assertRaisesRegex(ValueError, 'too deep'):
                packaging.enter_provenance(chain, (500, 600))
        cycle = packaging.provenance_chain(current=True)
        packaging.enter_provenance(cycle, (7, 9))
        with self.assertRaisesRegex(ValueError, 'cyclic'):
            packaging.enter_provenance(cycle, (7, 9))

    def test_packaging_parent_rejects_lost_or_changed_non_b_dmg_journal(self):
        def journal(checksum, identifier):
            return {'schema': 'release-notary/v1', 'sha256': checksum,
                    'sourceSHA': self.product, 'submissionID': identifier}
        known = {checksum: journal(checksum, identifier) for checksum, identifier in
                 [('1' * 64, '11111111-1111-1111-1111-111111111111'),
                  ('2' * 64, '22222222-2222-2222-2222-222222222222'),
                  ('3' * 64, '33333333-3333-3333-3333-333333333333')]}
        parent = {'record': {'originalSignedBuildRunID': 5, 'previousNotary': {'journals': known}, 'stage': 'restored'},
                  'rawProofSHA256': 'e' * 64}
        context = {'schema': 'release-notary-context/v2', 'repository': packaging.REPOSITORY,
                   'sourceSHA': self.product, 'producerSourceSHA': self.producer, 'runID': 7, 'buildRunID': 5}
        for changed in [dict(list(known.items())[:2]), known | {'3' * 64: journal('3' * 64, '44444444-4444-4444-4444-444444444444')}]:
            raw = io.BytesIO()
            with zipfile.ZipFile(raw, 'w') as archive:
                archive.writestr('context.json', json.dumps(context))
                for checksum, value in changed.items(): archive.writestr(checksum + '.json', json.dumps(value))
            encoded = raw.getvalue()
            artifact = {'id': 9, 'name': 'release-notary-state-' + self.product, 'size_in_bytes': len(encoded),
                        'digest': 'sha256:' + hashlib.sha256(encoded).hexdigest()}
            producer = {'id': 7, 'head_sha': self.producer, 'repository': {'full_name': packaging.REPOSITORY},
                        'path': '.github/workflows/release.yml', 'event': 'workflow_dispatch', 'run_attempt': 1,
                        'actor': {'login': 'iret77'}, 'status': 'completed', 'conclusion': 'failure'}
            job = {'id': 8, 'name': 'release', 'run_id': 7, 'head_sha': self.producer, 'run_attempt': 1,
                   'labels': ['macrunner'], 'status': 'completed', 'conclusion': 'failure'}
            routes = {'actions/runs/7': producer, 'actions/runs/7/attempts/1/jobs?per_page=100': {'total_count': 1, 'jobs': [job]},
                      'actions/runs/7/artifacts?per_page=100': {'total_count': 1, 'artifacts': [artifact]}, 'actions/artifacts/9': artifact}
            with patch.object(packaging, 'api', side_effect=routes.__getitem__), \
                    patch.object(packaging, 'load_provenance', return_value=parent), \
                    patch.object(packaging, 'verify_artifact'), patch.object(packaging, 'read_api', return_value=encoded), \
                    self.subTest(journals=changed), self.assertRaisesRegex(ValueError, 'known Apple submission'):
                packaging.prior_notary(7, self.product, packaging={'producerSourceSHA': self.producer})

    def provenance_fixture(self):
        import release_checkpoint
        import test_verified_pr_source_checks as source_fixture

        routes, _ = self.closure_fixture()
        downloads = {}
        environment = {'GITHUB_ACTIONS': 'true', 'GITHUB_REPOSITORY': packaging.REPOSITORY,
                       'GITHUB_EVENT_NAME': 'workflow_dispatch', 'GITHUB_SHA': self.producer,
                       'GITHUB_RUN_ID': '70', 'GITHUB_RUN_ATTEMPT': '1', 'GITHUB_REF_NAME': 'packaging-base'}
        def archive(members):
            raw = io.BytesIO()
            with zipfile.ZipFile(raw, 'w') as bundle:
                for name, value in members.items(): bundle.writestr(name, value)
            return raw.getvalue()
        def run(identifier, source, hour):
            value = {'id': identifier, 'head_sha': source, 'head_branch': 'packaging-base',
                     'repository': {'full_name': packaging.REPOSITORY}, 'event': 'workflow_dispatch',
                     'path': '.github/workflows/release.yml', 'actor': {'login': 'iret77'}, 'run_attempt': 1,
                     'status': 'completed', 'conclusion': 'failure', 'created_at': f'2026-11-04T{hour}:00:00Z'}
            routes[f'actions/runs/{identifier}'] = value
            return value
        def job(producer, name, conclusion, hour):
            return {'id': producer['id'] * 10 + (1 if name == 'release-build' else 2), 'name': name,
                    'run_id': producer['id'], 'run_attempt': 1, 'head_sha': producer['head_sha'],
                    'status': 'completed', 'conclusion': conclusion, 'labels': ['macrunner'],
                    'started_at': f'2026-11-04T{hour}:00:00Z', 'completed_at': f'2026-11-04T{hour}:59:00Z', 'steps': []}
        def artifact(identifier, name, producer, owner, raw):
            value = {'id': identifier, 'name': name, 'expired': False, 'workflow_run': {'id': producer['id'], 'head_sha': producer['head_sha']},
                     'size_in_bytes': len(raw), 'digest': 'sha256:' + packaging.digest(raw),
                     'created_at': owner['started_at'], 'updated_at': owner['completed_at'], 'expires_at': '2099-01-01T00:00:00Z'}
            routes[f'actions/artifacts/{identifier}'] = value
            downloads[f'actions/artifacts/{identifier}/zip'] = raw
            return value
        for identifier, target, tree, head, checkout in [(11, self.product, 'c' * 40, '1' * 40, 'e' * 40),
                                                        (22, self.producer, 'd' * 40, '2' * 40, 'f' * 40)]:
            source_run, jobs, receipt, pr, commit, _, _, log = source_fixture.fixtures()
            source_run.update(id=identifier, head_sha=head)
            jobs['jobs'][0].update(id=identifier + 1000, run_id=identifier, head_sha=head,
                                  started_at='2026-11-04T00:00:00Z', completed_at='2026-11-04T00:59:00Z')
            receipt.update(runID=identifier, headSHA=head, checkoutSHA=checkout, treeSHA=tree,
                           baseRef=environment['GITHUB_REF_NAME'], pullRequest=identifier + 300)
            pr.update(number=identifier + 300, merge_commit_sha=target)
            pr['head']['sha'] = head; pr['base']['ref'] = environment['GITHUB_REF_NAME']
            commit.update(sha=checkout, tree={'sha': tree})
            raw = archive({'receipt.json': json.dumps(receipt)})
            item = artifact(identifier + 100, f'verified-pr-source-{identifier}-a1', source_run,
                            {'started_at': '2026-11-04T00:00:00Z', 'completed_at': '2026-11-04T00:59:00Z'}, raw)
            routes.update({f'actions/runs/{identifier}': source_run,
                           f'actions/runs/{identifier}/attempts/1/jobs?per_page=100': jobs,
                           f'actions/runs/{identifier}/artifacts?per_page=100': {'total_count': 1, 'artifacts': [item]},
                           f'git/commits/{checkout}': commit, f'pulls/{identifier + 300}': pr})
            downloads[f"actions/jobs/{jobs['jobs'][0]['id']}/logs"] = log
        original = run(50, self.product, '01')
        builder = job(original, 'release-build', 'success', '02')
        builder['steps'] = [{'name': name, 'conclusion': 'success'} for name in
                            ('Build and sign app', 'Retain signed build input', 'Retain signed build proof')]
        old_release = job(original, 'release', 'failure', '03')
        manifest = {'schema': 'release-signed-input/v1', 'repository': packaging.REPOSITORY,
                    'sourceSHA': self.product, 'runID': 50, 'attempt': 1, 'appTreeSHA256': '6' * 64,
                    'identity': {'sourceSHA': self.product, 'version': '1.8.0', 'build': '105', 'catalogURL': 'https://example.test/catalog.json'},
                    'nativeEvidence': {'schema': 'fresh-release-tests/v1', 'suite': {'sourceSHA': self.product,
                        'completed': True, 'configuration': 'release', 'scope': 'all', 'filter': ''}},
                    'files': {name: {'bytes': index + 1, 'sha256': str(index + 1) * 64} for index, name in enumerate(release_checkpoint.FILES)}}
        signed_proof = archive({'manifest.json': json.dumps(manifest)})
        app_sha = manifest['files']['NexGenVideo.zip']['sha256']; pack_sha = '5' * 64
        journals = {value: {'schema': 'release-notary/v1', 'sourceSHA': self.product, 'sha256': value,
                           'submissionID': identifier} for value, identifier in
                    [(app_sha, '11111111-1111-1111-1111-111111111111'), (pack_sha, '22222222-2222-2222-2222-222222222222')]}
        def state(producer):
            context = {'schema': 'release-notary-context/v1', 'repository': packaging.REPOSITORY,
                       'sourceSHA': self.product, 'buildRunID': 50, 'runID': producer['id']}
            return archive({'context.json': json.dumps(context), **{key + '.json': json.dumps(value) for key, value in journals.items()}})
        prefix = 'release-signed-input-' + self.product
        items = [artifact(501, prefix, original, builder, b'original signed payload'),
                 artifact(502, prefix + '-proof', original, builder, signed_proof),
                 artifact(503, 'release-notary-state-' + self.product, original, old_release, state(original))]
        routes['actions/runs/50/attempts/1/jobs?per_page=100'] = {'total_count': 2, 'jobs': [builder, old_release]}
        routes['actions/runs/50/artifacts?per_page=100'] = {'total_count': 3, 'artifacts': items}
        previous = run(60, self.product, '06'); previous_release = job(previous, 'release', 'failure', '07')
        previous_state = artifact(601, 'release-notary-state-' + self.product, previous, previous_release, state(previous))
        routes['actions/runs/60/attempts/1/jobs?per_page=100'] = {'total_count': 1, 'jobs': [previous_release]}
        routes['actions/runs/60/artifacts?per_page=100'] = {'total_count': 1, 'artifacts': [previous_state]}
        current = run(70, self.producer, '09'); current_release = job(current, 'release', 'success', '10')
        routes['actions/runs/70/attempts/1/jobs?per_page=100'] = {'total_count': 1, 'jobs': [current_release]}
        values = self.mode() | {'priorNotaryRunID': '60'}
        def publish(record, files):
            if record['stage'] == 'complete':
                checkpoint = {'schema': 'release-dmg-checkpoint/v2', 'context': record['final']['notaryContext'],
                              'appTreeSHA256': 'd' * 64, 'appRuntimeTreeSHA256': '7' * 64, 'files': {'NexGenVideo.dmg': {'bytes': 10, 'sha256': 'c' * 64},
                                                               'plugins.tar.gz': {'bytes': 20, 'sha256': 'd' * 64}}}
                payload = artifact(703, 'release-dmg-input-' + self.product, current, current_release, b'actual checkpoint bytes')
                payload.update(created_at='2026-11-04T10:05:00Z', updated_at='2026-11-04T10:06:00Z')
                small = archive({'manifest.json': json.dumps({'schema': 'nexgenvideo/dmg-artifact-proof/1',
                    'sourceSHA': self.product, 'producerSourceSHA': self.producer, 'runID': 70,
                    'payloadArtifact': payload, 'checkpoint': checkpoint})})
                small_artifact = artifact(702, 'release-dmg-proof-' + self.product, current, current_release, small)
                small_artifact.update(created_at='2026-11-04T10:10:00Z', updated_at='2026-11-04T10:11:00Z')
                record['final']['dmgSubmissionArtifact'] = small_artifact
                record['final']['dmgSubmissionPayloadArtifact'] = payload
                files['submitted-dmg-proof.zip'] = small
                record['files'] = record['files'] | {'submitted-dmg-proof.zip': {'bytes': len(small), 'sha256': packaging.digest(small)}}
            raw = archive({**files, 'packaging-provenance.json': packaging.encoded(record)})
            item = artifact(701, packaging.COMPLETE_ARTIFACT if record['stage'] == 'complete' else packaging.RESTORED_ARTIFACT,
                            current, current_release, raw)
            item.update(created_at='2026-11-04T10:40:00Z', updated_at='2026-11-04T10:41:00Z')
            return packaging.selectors(self.producer, '701', item['digest'][7:])
        return routes, downloads, environment, values, journals, publish

    def complete_fixture(self, record, journals):
        manifest = record['signedInput']['manifest']
        app = {'NGVSourceCommit': self.product, 'CFBundleShortVersionString': '1.8.0', 'CFBundleVersion': '105',
               'CFBundleIdentifier': 'de.h5ventures.nexgenvideo', 'treeSHA256': '7' * 64}
        context = {'schema': 'release-notary-context/v2', 'repository': packaging.REPOSITORY,
                   'sourceSHA': self.product, 'producerSourceSHA': self.producer, 'buildRunID': 50, 'runID': 70}
        dmg = '8' * 64; submitted = 'c' * 64
        final_journals = journals | {submitted: {'schema': 'release-notary/v1', 'sourceSHA': self.product,
                                         'sha256': submitted, 'submissionID': '33333333-3333-3333-3333-333333333333'}}
        return record | {'stage': 'complete', 'restoredOriginal': {'sourceSHA': self.product, 'producerRun': 50,
            'appTreeSHA256': manifest['appTreeSHA256'], 'identity': manifest['identity']},
            'originalPackArchives': {'.build/plugins/musicvideo.ngvpack.zip': '5' * 64},
            'final': {'app': app, 'appTreeSHA256': app['treeSHA256'], 'dmgSHA256': dmg,
                'submittedDMGSHA256': submitted,
                'runtimeArchiveSHA256': packaging.digest(b'exact final runtime archive'), 'bpySourceReceiptSHA256': 'a' * 64,
                'packArchiveSHA256': '5' * 64, 'packTreeSHA256': 'b' * 64,
                'notaryContext': context, 'notaryJournals': final_journals}}

    def test_full_provenance_rebinds_actual_sources_signed_build_apple_ids_and_parent_bytes(self):
        routes, downloads, environment, values, journals, publish = self.provenance_fixture()
        with patch.dict(os.environ, environment), patch.object(packaging, 'utc_now', return_value='2026-11-04T10:20:00Z'), \
                patch.object(packaging, 'live_api', side_effect=routes.__getitem__), \
                patch.object(packaging, 'live_read_api', side_effect=lambda route, **kwargs: downloads[route]), \
                patch.object(packaging, 'git', side_effect=lambda *args: self.local_git_fixture()[args]):
            record, files = packaging.collect_binding(values)
            self.assertEqual(packaging.validate_binding(record, files), self.product)
            self.assertEqual(record['originalSignedBuildRunID'], 50)
            self.assertEqual(record['previousNotary']['journals'], journals)
            self.assertEqual(set(files), packaging.PROOF_FILES | {'original-notary-state.zip'})
            complete = self.complete_fixture(record, journals)
            selected = publish(complete, files)
            with tempfile.TemporaryDirectory() as temporary:
                bound = packaging.consumer_binding(70, self.product, selected, archive_root=Path(temporary))
                self.assertEqual(packaging.consumer_record(bound, self.product, 70), complete)
                archives = list((Path(temporary) / 'parents').glob('*.zip'))
                self.assertEqual(len(archives), 1)
                self.assertEqual(archives[0].read_bytes(), downloads['actions/artifacts/701/zip'])
                acquired = json.loads(archives[0].with_suffix('.complete.json').read_text())
                self.assertEqual(acquired['sha256'], selected['artifactSHA256'])
            self.assertEqual(bound['rawProofSHA256'], packaging.digest(packaging.encoded(complete)))

    def test_pre_submit_signed_build_keeps_absent_state_through_acquisition_snapshot_and_replay(self):
        import app_release_v2 as app_release
        import base64
        from compiled_app_release import PACK_SHA
        routes, downloads, environment, values, _, publish = self.provenance_fixture()
        values = values | {'priorNotaryRunID': '', 'signedBuildRunID': '50'}
        jobs = routes['actions/runs/50/attempts/1/jobs?per_page=100']['jobs']
        release = next(job for job in jobs if job['name'] == 'release')
        names = ['Submit App notarization exactly once', 'Notarize and staple app',
                 'Notarize and staple downloadable format packs', 'Submit DMG notarization exactly once', 'Notarize and staple DMG']
        release['steps'] = [{'name': name, 'status': 'completed', 'conclusion': 'skipped'} for name in names]
        inventory = routes['actions/runs/50/artifacts?per_page=100']
        inventory['artifacts'] = [item for item in inventory['artifacts'] if item['id'] != 503]
        inventory['total_count'] = len(inventory['artifacts'])
        with zipfile.ZipFile(io.BytesIO(downloads['actions/artifacts/502/zip'])) as archive:
            manifest = json.loads(archive.read('manifest.json'))
        noise = base64.b64encode(hashlib.shake_256(b'large-native-proof').digest(2 * 1024**2)).decode()
        manifest['nativeEvidence']['suite']['capturedOutput'] = noise + 'e' * (13 * 1024**2 - len(noise))
        data = io.BytesIO()
        with zipfile.ZipFile(data, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
            archive.writestr('manifest.json', json.dumps(manifest))
        downloads['actions/artifacts/502/zip'] = data.getvalue()
        routes['actions/artifacts/502'].update(size_in_bytes=len(data.getvalue()), digest='sha256:' + packaging.digest(data.getvalue()))
        routes['actions/runs/70/attempts/1/jobs?per_page=100']['jobs'][0]['steps'] = [
            {'name': 'Restore exact signed build', 'conclusion': 'success'}]
        pre_submit, signed_input = app_release.pre_submit, packaging.signed_input
        def certificate(producer, job):
            with patch.object(app_release.cohort, 'has_manifest', return_value=True):
                return pre_submit(producer, job)
        def typed_signed(run_id, product):
            signed, proof, state = signed_input(run_id, product)
            return signed | {'cohortProduct': {'qualifiedBySeparateCohortTests': True}}, proof, state
        with patch.dict(os.environ, environment), patch.object(packaging, 'utc_now', return_value='2026-11-04T10:20:00Z'), \
                patch.object(packaging, 'live_api', side_effect=routes.__getitem__), \
                patch.object(packaging, 'live_read_api', side_effect=lambda route, **kwargs: downloads[route]), \
                patch.object(packaging, 'git', side_effect=lambda *args: self.local_git_fixture()[args]), \
                patch.object(app_release, 'pre_submit', side_effect=certificate), \
                patch.object(packaging, 'signed_input', side_effect=typed_signed), \
                patch.object(packaging, 'cohort_signed_product', side_effect=lambda record: bool(record.get('signedInput', {}).get('cohortProduct'))):
            record, files = packaging.collect_binding(values)
            self.assertEqual(packaging.validate_binding(record, files), self.product)
            self.assertEqual(record['originalSignedBuildRunID'], 50)
            self.assertEqual(record['previousNotary']['journals'], {})
            self.assertNotIn('context', record['previousNotary'])
            self.assertEqual(set(files), packaging.PROOF_FILES - {'prior-notary-state.zip'} | {'pre-submit-origin.json'})
            with tempfile.TemporaryDirectory() as directory:
                packaging.save_stage(Path(directory), record, files)
                self.assertEqual(packaging.read_stage(Path(directory), 'input'), (record, files))
            restored = self.complete_fixture(record, {})
            restored.pop('final'); restored['stage'] = 'restored'
            restored['originalPackArchives'] = {'.build/plugins/musicvideo.ngvpack.zip': PACK_SHA}
            self.assertEqual(packaging.load_provenance(70, self.product, publish(restored, files), allow_failed=True)['record'], restored)
            for step in release['steps']:
                with self.subTest(entered=step['name']):
                    step['conclusion'] = 'failure'
                    with self.assertRaises(ValueError): packaging.prior_origin(record['mode'], self.product)
                    step['conclusion'] = 'skipped'
            with self.subTest(unknownIntent=True):
                inventory['artifacts'].append({'name': 'release-app-notary-intent-' + self.product})
                inventory['total_count'] += 1
                with self.assertRaises(ValueError): packaging.prior_origin(record['mode'], self.product)

    def test_complete_provenance_rejects_each_independent_identity_or_payload_tamper(self):
        routes, downloads, environment, values, journals, publish = self.provenance_fixture()
        with patch.dict(os.environ, environment), patch.object(packaging, 'utc_now', return_value='2026-11-04T10:20:00Z'), \
                patch.object(packaging, 'live_api', side_effect=routes.__getitem__), \
                patch.object(packaging, 'live_read_api', side_effect=lambda route, **kwargs: downloads[route]), \
                patch.object(packaging, 'git', side_effect=lambda *args: self.local_git_fixture()[args]):
            record, files = packaging.collect_binding(values)
            complete = self.complete_fixture(record, journals)
            self.assertEqual(packaging.load_provenance(70, self.product, publish(complete, files))['record'], complete)
            for field, changed, reason in [('productSourceSHA', 'c' * 40, 'source or encoding'),
                                           ('producerSourceSHA', 'c' * 40, 'source or encoding'),
                                           ('originalSignedBuildRunID', 99, 'another original signed build')]:
                with self.subTest(field=field), self.assertRaisesRegex(ValueError, reason):
                    packaging.load_provenance(70, self.product, publish(complete | {field: changed}, files))
            for key in ('submittedDMGSHA256', 'appTreeSHA256'):
                broken = copy.deepcopy(complete); broken['final'][key] = '0' * 64
                with self.subTest(final=key), self.assertRaises(ValueError):
                    packaging.load_provenance(70, self.product, publish(broken, files))
            altered = dict(files); altered['signed-proof.zip'] += b'changed'
            with self.assertRaisesRegex(ValueError, 'evidence bytes changed'):
                packaging.load_provenance(70, self.product, publish(complete, altered))

    def test_partial_failed_provenance_cannot_qualify_runtime_or_hide_missing_restore(self):
        routes, downloads, environment, values, journals, publish = self.provenance_fixture()
        with patch.dict(os.environ, environment), patch.object(packaging, 'utc_now', return_value='2026-11-04T10:20:00Z'), \
                patch.object(packaging, 'live_api', side_effect=routes.__getitem__), \
                patch.object(packaging, 'live_read_api', side_effect=lambda route, **kwargs: downloads[route]), \
                patch.object(packaging, 'git', side_effect=lambda *args: self.local_git_fixture()[args]):
            record, files = packaging.collect_binding(values)
            restored = self.complete_fixture(record, journals); restored.pop('final'); restored['stage'] = 'restored'
            selected = publish(restored, files)
            release = routes['actions/runs/70/attempts/1/jobs?per_page=100']['jobs'][0]
            release['conclusion'] = 'failure'
            with self.assertRaisesRegex(ValueError, 'required completion'):
                packaging.load_provenance(70, self.product, selected)
            with self.assertRaisesRegex(ValueError, 'restore never passed'):
                packaging.load_provenance(70, self.product, selected, allow_failed=True)
            release['steps'] = [{'name': 'Restore exact signed build', 'conclusion': 'success'}]
            self.assertEqual(packaging.load_provenance(70, self.product, selected, allow_failed=True)['record'], restored)

    def test_historical_proof_keeps_valid_originals_after_original_retention_expires(self):
        import retained_app_test_products as original_artifacts
        class AcquisitionClock(datetime.datetime):
            @classmethod
            def now(cls, tz=None): return cls(2026, 11, 4, 10, 20, tzinfo=datetime.timezone.utc)
        routes, downloads, environment, values, journals, publish = self.provenance_fixture()
        for route, value in routes.items():
            if route.startswith('actions/artifacts/'):
                value['expires_at'] = '2026-11-04T11:00:00Z'
        with patch.dict(os.environ, environment), patch.object(packaging, 'utc_now', return_value='2026-11-04T10:20:00Z'), \
                patch.object(packaging, 'live_api', side_effect=routes.__getitem__) as api, \
                patch.object(packaging, 'live_read_api', side_effect=lambda route, **kwargs: downloads[route]) as reader, \
                patch.object(packaging, 'git', side_effect=lambda *args: self.local_git_fixture()[args]):
            with patch.object(original_artifacts, 'datetime', AcquisitionClock):
                record, files = packaging.collect_binding(values)
            complete = self.complete_fixture(record, journals)
            selected = publish(complete, files)
            routes = {route: value for route, value in routes.items() if not route.startswith('actions/')
                      or route in {'actions/runs/70', 'actions/runs/70/attempts/1/jobs?per_page=100', 'actions/artifacts/701'}}
            api.side_effect = routes.__getitem__
            reader.side_effect = lambda route, **kwargs: downloads[route] if route == 'actions/artifacts/701/zip' else self.fail('Old original fetched again')
            api.reset_mock(); reader.reset_mock()
            bound = packaging.consumer_binding(70, self.product, selected)
            self.assertEqual(packaging.consumer_record(bound, self.product, 70), complete)
            self.assertIsNone(packaging.REPLAY.get())
            self.assertTrue(all(call.args[0] == 'actions/artifacts/701/zip' for call in reader.call_args_list))
            self.assertFalse(any(call.args[0].startswith('actions/runs/50') for call in api.call_args_list))

    def test_historical_proof_rejects_missing_bytes_expired_at_acquisition_and_false_time(self):
        routes, downloads, environment, values, journals, publish = self.provenance_fixture()
        with patch.dict(os.environ, environment), patch.object(packaging, 'utc_now', return_value='2026-11-04T10:20:00Z'), \
                patch.object(packaging, 'live_api', side_effect=routes.__getitem__), \
                patch.object(packaging, 'live_read_api', side_effect=lambda route, **kwargs: downloads[route]), \
                patch.object(packaging, 'git', side_effect=lambda *args: self.local_git_fixture()[args]):
            record, files = packaging.collect_binding(values)
            original = packaging.read_proof_archive(files['original-api-evidence.zip'])
            for variant, reason in [('missing-byte-route', 'bytes are missing'), ('expired', 'invalid at acquisition'),
                                    ('future-clock', 'acquisition context differs')]:
                members = dict(original); acquisition = json.loads(members['acquisition.json'])
                if variant == 'missing-byte-route': acquisition['bytes'].pop('actions/jobs/1011/logs')
                elif variant == 'expired': acquisition['json']['actions/artifacts/111']['expires_at'] = '2026-11-04T10:30:00Z'
                else: acquisition['recordedAt'] = '2026-11-04T10:50:00Z'
                members['acquisition.json'] = packaging.encoded(acquisition)
                if variant == 'missing-byte-route':
                    wanted = {entry['name'] for entry in acquisition['bytes'].values()}
                    members = {name: raw for name, raw in members.items() if name == 'acquisition.json' or name in wanted}
                buffer = io.BytesIO()
                with zipfile.ZipFile(buffer, 'w') as archive:
                    for name, raw in members.items(): archive.writestr(name, raw)
                changed_files = dict(files, **{'original-api-evidence.zip': buffer.getvalue()})
                complete = self.complete_fixture(copy.deepcopy(record), journals)
                complete['files']['original-api-evidence.zip'] = {'bytes': len(buffer.getvalue()), 'sha256': packaging.digest(buffer.getvalue())}
                selected = publish(complete, changed_files)
                with self.subTest(variant=variant), self.assertRaisesRegex(ValueError, reason):
                    packaging.load_provenance(70, self.product, selected)
                self.assertIsNone(packaging.REPLAY.get())

    def test_fresh_acquisition_cannot_be_redirected_into_authenticated_replay(self):
        token = packaging.REPLAY.set({'json': {}, 'bytes': {}, 'legacy': {}, 'asOf': None})
        try:
            with patch.object(packaging, 'live_api') as api, self.assertRaisesRegex(ValueError, 'cannot use historical'):
                packaging.collect_binding(self.mode())
            api.assert_not_called()
        finally:
            packaging.REPLAY.reset(token)

    def test_legacy_dmg_reads_actual_outer_and_member_bytes_without_a_v2_sidecar(self):
        source = {'id': 60, 'head_sha': self.product}
        checkpoint = {'schema': 'release-dmg-checkpoint/v1', 'context': {'schema': 'release-notary-context/v1',
            'repository': packaging.REPOSITORY, 'sourceSHA': self.product, 'runID': 60, 'buildRunID': 50},
            'appTreeSHA256': '7' * 64, 'files': {name: {'bytes': len(raw), 'sha256': packaging.digest(raw)}
                for name, raw in [('NexGenVideo.dmg', b'actual original DMG'), ('plugins.tar.gz', b'original pack TAR')]}}
        def payload(changed=False):
            raw = io.BytesIO()
            with zipfile.ZipFile(raw, 'w') as archive:
                archive.writestr('dmg-checkpoint.json', json.dumps(checkpoint))
                archive.writestr('NexGenVideo.dmg', b'actual original DMG' + (b'changed' if changed else b''))
                archive.writestr('plugins.tar.gz', b'original pack TAR')
            return raw.getvalue()
        for changed in (False, True):
            raw = payload(changed)
            artifact = {'id': 601, 'size_in_bytes': len(raw), 'digest': 'sha256:' + packaging.digest(raw)}
            with self.subTest(changed=changed), patch.object(packaging, 'download', side_effect=lambda item, path: path.write_bytes(raw)):
                if changed:
                    with self.assertRaisesRegex(ValueError, 'member size differs'):
                        packaging.legacy_dmg_proof(source, artifact, self.product)
                else:
                    proof = packaging.legacy_dmg_proof(source, artifact, self.product)
                    self.assertEqual(proof['checkpoint'], checkpoint)
                    self.assertEqual(proof['legacyAcquisition']['archiveSHA256'], packaging.digest(raw))
                    self.assertEqual(proof['rawProofSHA256'], packaging.digest(packaging.encoded(proof['legacyAcquisition'])))

    def test_runtime_and_settings_consumers_keep_a_h_and_r_explicit_and_reject_wrong_bytes(self):
        import release_acceptance_identity as settings
        import verify_diagnostic_candidate as candidates
        import workspace_native_ci as native
        routes, downloads, environment, values, journals, publish = self.provenance_fixture()
        with patch.dict(os.environ, environment), patch.object(packaging, 'utc_now', return_value='2026-11-04T10:20:00Z'), \
                patch.object(packaging, 'live_api', side_effect=routes.__getitem__), \
                patch.object(packaging, 'live_read_api', side_effect=lambda route, **kwargs: downloads[route]), \
                patch.object(packaging, 'git', side_effect=lambda *args: self.local_git_fixture()[args]):
            record, files = packaging.collect_binding(values)
            complete = self.complete_fixture(record, journals); selected = publish(complete, files)
            proof = packaging.consumer_binding(70, self.product, selected)
            receipt = {'schema': 'nexgenvideo/workspace-ui-input/2', 'sourceSHA': self.product,
                       'producerSourceSHA': self.producer, 'packagingProvenanceSHA256': proof['rawProofSHA256'],
                       'archiveSHA256': complete['final']['runtimeArchiveSHA256'], 'appTreeSHA256': '7' * 64}
            with tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                (root / 'workspace-ui.tar.gz').write_bytes(b'exact final runtime archive')
                (root / 'workspace-ui-input.json').write_text(json.dumps(receipt))
                identity = {'sourceSHA': self.product, 'packaging': proof}
                self.assertEqual(native.runtime_receipt(root, identity), receipt)
                for key, value in [('sourceSHA', self.producer), ('producerSourceSHA', self.product),
                                   ('packagingProvenanceSHA256', '0' * 64), ('archiveSHA256', '0' * 64)]:
                    (root / 'workspace-ui-input.json').write_text(json.dumps(receipt | {key: value}))
                    with self.subTest(receipt=key), self.assertRaises(ValueError): native.runtime_receipt(root, identity)
                (root / 'workspace-ui-input.json').write_text(json.dumps(receipt))
                with self.assertRaises(ValueError): native.runtime_receipt(root, {'sourceSHA': self.product})
            run = routes['actions/runs/70']; jobs = routes['actions/runs/70/attempts/1/jobs?per_page=100']
            artifact = {'id': 704, 'name': 'workspace-ui-app', 'expired': False, 'digest': 'sha256:' + 'd' * 64,
                'workflow_run': {'id': 70, 'head_sha': self.producer}, 'created_at': '2026-11-04T10:45:00Z',
                'updated_at': '2026-11-04T10:46:00Z', 'expires_at': '2099-01-01T00:00:00Z'}
            for verifier in (candidates.verify_signed_workspace, candidates.verify_signed_desktop, candidates.verify_signed_settings):
                verifier(run, jobs, artifact, 70, self.product, 704, 'd' * 64, [], packaging=selected)
                with self.subTest(legacy=verifier.__name__), self.assertRaises(ValueError):
                    verifier(run, jobs, artifact, 70, self.product, 704, 'd' * 64, [])
                with self.subTest(app_edit=verifier.__name__), self.assertRaisesRegex(ValueError, 'application or build inputs'):
                    verifier(run, jobs, artifact, 70, self.product, 704, 'd' * 64, ['Sources/NexGenVideo/App.swift'], packaging=selected)
            binding = {'schema': 'nexgenvideo/release-acceptance-binding/2', 'sourceSHA': self.product,
                'runID': 70, 'attempt': 1, 'runtimeArtifactID': 704, 'runtimeArtifactSHA256': 'd' * 64,
                'producerArtifactID': 705, 'producerArtifactSHA256': 'e' * 64,
                **{key: complete['final'][key] for key in ('dmgSHA256', 'appTreeSHA256', 'packTreeSHA256')},
                'packaging': selected, 'packagingProvenanceSHA256': proof['rawProofSHA256']}
            producer = {'schema': 'nexgenvideo/release-workspace-producer/2', 'sourceSHA': self.product,
                'producerSourceSHA': self.producer, 'packagingProvenanceSHA256': proof['rawProofSHA256'],
                'runID': '70', 'runAttempt': '1', 'app': complete['final']['app'],
                'dmgSHA256': complete['final']['dmgSHA256'], 'mountedAppTreeSHA256': '7' * 64,
                'packTreeSHA256': complete['final']['packTreeSHA256'], 'archiveSHA256': receipt['archiveSHA256']}
            settings.validate_producer(producer, binding, receipt)
            for key in ('dmgSHA256', 'packTreeSHA256'):
                with self.subTest(binding=key), self.assertRaises(ValueError):
                    settings.validate_producer(producer, binding | {key: '0' * 64}, receipt)
            with self.assertRaises(ValueError): settings.declared_binding(binding | {'schema': 'nexgenvideo/release-acceptance-binding/1'})

    def test_nested_compressed_acquisition_uses_the_same_expansion_budget_before_reading_members(self):
        def compressed(name, value=b'x'):
            raw = io.BytesIO()
            with zipfile.ZipFile(raw, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
                archive.writestr(name, value * (20 * 1024**2))
            return raw.getvalue()
        budget = packaging.provenance_chain()
        token = packaging.BUDGET.set(budget)
        try:
            first, second = compressed('first.bin'), compressed('second.bin', b'y')
            self.assertLess(len(first) + len(second), 100_000)
            first_records = packaging.read_proof_archive(first)
            original = first_records.pop('first.bin')
            self.assertIs(packaging.read_proof_archive(first)['first.bin'], original)
            self.assertEqual(budget['expandedBytes'], 20 * 1024**2)
            with self.assertRaisesRegex(ValueError, 'shared byte bound'):
                packaging.read_proof_archive(second)
            self.assertEqual(budget['expandedBytes'], 20 * 1024**2)
            one = io.BytesIO()
            with zipfile.ZipFile(one, 'w') as archive: archive.writestr('one.bin', b'x')
            budget.clear(); budget.update(packaging.provenance_chain())
            budget['expandedBytes'] = packaging.MAX_PROOF_BYTES - 1
            packaging.read_proof_archive(one.getvalue())
            self.assertEqual(budget['expandedBytes'], packaging.MAX_PROOF_BYTES)
            packaging.read_proof_archive(one.getvalue())
            self.assertEqual(budget['expandedBytes'], packaging.MAX_PROOF_BYTES)
            two = io.BytesIO()
            with zipfile.ZipFile(two, 'w') as archive: archive.writestr('two.bin', b'y')
            with self.assertRaisesRegex(ValueError, 'shared byte bound'):
                packaging.read_proof_archive(two.getvalue())
        finally:
            packaging.BUDGET.reset(token)

    def test_complete_consumer_checks_the_actual_dmg_payload_descriptor(self):
        routes, downloads, environment, values, journals, publish = self.provenance_fixture()
        with patch.dict(os.environ, environment), patch.object(packaging, 'utc_now', return_value='2026-11-04T10:20:00Z'), \
                patch.object(packaging, 'live_api', side_effect=routes.__getitem__), \
                patch.object(packaging, 'live_read_api', side_effect=lambda route, **kwargs: downloads[route]), \
                patch.object(packaging, 'git', side_effect=lambda *args: self.local_git_fixture()[args]):
            record, files = packaging.collect_binding(values)
            complete = self.complete_fixture(record, journals); publish(complete, files)
            original_files = dict(files)
            with zipfile.ZipFile(io.BytesIO(files['submitted-dmg-proof.zip'])) as archive:
                original = json.loads(archive.read('manifest.json'))
            artifact = copy.deepcopy(complete['final']['dmgSubmissionArtifact'])
            for key, value in [('id', 999), ('name', 'foreign-payload'), ('digest', 'sha256:' + '0' * 64),
                               ('workflow_run', {'id': 99, 'head_sha': self.producer}),
                               ('workflow_run', {'id': 70, 'head_sha': self.product})]:
                changed = copy.deepcopy(original); changed['payloadArtifact'][key] = value
                raw = io.BytesIO()
                with zipfile.ZipFile(raw, 'w') as archive: archive.writestr('manifest.json', json.dumps(changed))
                changed_files = dict(original_files, **{'submitted-dmg-proof.zip': raw.getvalue()})
                broken = copy.deepcopy(complete)
                broken['files']['submitted-dmg-proof.zip'] = {'bytes': len(raw.getvalue()), 'sha256': packaging.digest(raw.getvalue())}
                broken['final']['dmgSubmissionArtifact'] = artifact | {'size_in_bytes': len(raw.getvalue()),
                    'digest': 'sha256:' + packaging.digest(raw.getvalue())}
                # Keep the outer typed proof self-consistent; only the payload relation is wrong.
                outer = io.BytesIO()
                with zipfile.ZipFile(outer, 'w') as archive:
                    for name, content in {**changed_files, 'packaging-provenance.json': packaging.encoded(broken)}.items():
                        archive.writestr(name, content)
                routes['actions/artifacts/701'].update(size_in_bytes=len(outer.getvalue()), digest='sha256:' + packaging.digest(outer.getvalue()))
                downloads['actions/artifacts/701/zip'] = outer.getvalue()
                selected = packaging.selectors(self.producer, '701', packaging.digest(outer.getvalue()))
                with self.subTest(payload=key, value=value), self.assertRaisesRegex(ValueError, 'Recorded packaging artifact differs'):
                    packaging.load_provenance(70, self.product, selected)

    def test_failed_harness_parent_is_revalidated_from_its_complete_original_zip(self):
        routes, downloads, environment, values, journals, publish = self.provenance_fixture()
        clock = ['2026-11-04T10:20:00Z']
        local = self.local_git_fixture()
        with patch.dict(os.environ, environment), patch.object(packaging, 'utc_now', side_effect=lambda: clock[0]), \
                patch.object(packaging, 'live_api', side_effect=routes.__getitem__), \
                patch.object(packaging, 'live_read_api', side_effect=lambda route, **kwargs: downloads[route]), \
                patch.object(packaging, 'git', side_effect=lambda *args: local[args]):
            parent, parent_files = packaging.collect_binding(values)
            restored = self.complete_fixture(parent, journals); restored.pop('final'); restored['stage'] = 'restored'
            selected = publish(restored, parent_files)
            parent_job = routes['actions/runs/70/attempts/1/jobs?per_page=100']['jobs'][0]
            parent_job.update(conclusion='failure', steps=[{'name': 'Restore exact signed build', 'conclusion': 'success'}])
            context = {'schema': 'release-notary-context/v2', 'repository': packaging.REPOSITORY,
                       'sourceSHA': self.product, 'producerSourceSHA': self.producer, 'buildRunID': 50, 'runID': 70}
            state = io.BytesIO()
            with zipfile.ZipFile(state, 'w') as archive:
                archive.writestr('context.json', json.dumps(context))
                for key, value in journals.items(): archive.writestr(key + '.json', json.dumps(value))
            state_artifact = {'id': 704, 'name': 'release-notary-state-' + self.product, 'expired': False,
                'size_in_bytes': len(state.getvalue()), 'digest': 'sha256:' + packaging.digest(state.getvalue()),
                'workflow_run': {'id': 70, 'head_sha': self.producer}, 'created_at': '2026-11-04T10:50:00Z',
                'updated_at': '2026-11-04T10:51:00Z', 'expires_at': '2099-01-01T00:00:00Z'}
            routes['actions/artifacts/704'] = state_artifact; downloads['actions/artifacts/704/zip'] = state.getvalue()
            routes['actions/runs/70/artifacts?per_page=100'] = {'total_count': 2, 'artifacts': [routes['actions/artifacts/701'], state_artifact]}
            next_source, next_tree, next_head, next_checkout = 'c' * 40, '5' * 40, '3' * 40, '4' * 40
            current = copy.deepcopy(routes['actions/runs/70']); current.update(id=80, head_sha=next_source, created_at='2026-11-04T11:00:00Z')
            routes['actions/runs/80'] = current
            source_run = copy.deepcopy(routes['actions/runs/22']); source_run.update(id=32, head_sha=next_head)
            source_jobs = copy.deepcopy(routes['actions/runs/22/attempts/1/jobs?per_page=100'])
            source_jobs['jobs'][0].update(id=1032, run_id=32, head_sha=next_head)
            with zipfile.ZipFile(io.BytesIO(downloads['actions/artifacts/122/zip'])) as archive:
                receipt = json.loads(archive.read('receipt.json'))
            receipt.update(runID=32, headSHA=next_head, checkoutSHA=next_checkout, treeSHA=next_tree, pullRequest=332)
            source_raw = io.BytesIO()
            with zipfile.ZipFile(source_raw, 'w') as archive: archive.writestr('receipt.json', json.dumps(receipt))
            source_artifact = copy.deepcopy(routes['actions/artifacts/122'])
            source_artifact.update(id=132, name='verified-pr-source-32-a1', workflow_run={'id': 32, 'head_sha': next_head},
                size_in_bytes=len(source_raw.getvalue()), digest='sha256:' + packaging.digest(source_raw.getvalue()))
            pr = copy.deepcopy(routes['pulls/322']); pr.update(number=332, merge_commit_sha=next_source); pr['head']['sha'] = next_head
            routes.update({'actions/runs/32': source_run, 'actions/runs/32/attempts/1/jobs?per_page=100': source_jobs,
                'actions/runs/32/artifacts?per_page=100': {'total_count': 1, 'artifacts': [source_artifact]},
                'actions/artifacts/132': source_artifact, 'pulls/332': pr,
                'git/commits/' + next_checkout: {'sha': next_checkout, 'tree': {'sha': next_tree}},
                'git/commits/' + next_source: {'sha': next_source, 'tree': {'sha': next_tree}},
                'git/trees/' + next_tree: copy.deepcopy(routes['git/trees/' + 'd' * 40])})
            routes['git/trees/' + next_tree]['sha'] = next_tree
            downloads['actions/artifacts/132/zip'] = source_raw.getvalue(); downloads['actions/jobs/1032/logs'] = downloads['actions/jobs/1022/logs']
            comparison = copy.deepcopy(routes['compare/' + self.product + '...' + self.producer])
            comparison.update(total_commits=2, commits=[{'sha': self.producer}, {'sha': next_source}])
            routes['compare/' + self.product + '...' + next_source] = comparison
            routes['compare/' + self.producer + '...' + next_source] = {'base_commit': {'sha': self.producer},
                'merge_base_commit': {'sha': self.producer}, 'status': 'ahead', 'total_commits': 1,
                'commits': [{'sha': next_source}], 'files': [{'filename': 'scripts/plan_dmg_capacity.py', 'status': 'modified'}]}
            local.update({('rev-parse', 'HEAD'): next_source.encode(), ('rev-parse', 'HEAD^{tree}'): next_tree.encode(),
                ('merge-base', self.product, next_source): self.product.encode(),
                ('rev-list', self.product + '..' + next_source): (self.producer + '\n' + next_source).encode(),
                ('diff', '--no-renames', '--name-status', '-z', self.product, next_source):
                    b'A\0scripts/retained_packaging.py\0M\0scripts/plan_dmg_capacity.py\0'})
            os.environ['GITHUB_SHA'] = next_source; os.environ['GITHUB_RUN_ID'] = '80'; clock[0] = '2026-11-04T11:20:00Z'
            next_values = values | {'verifiedSourceRunID': '32', 'priorNotaryRunID': '70',
                'priorProducerSourceSHA': self.producer, 'priorProvenanceArtifactID': '701',
                'priorProvenanceArtifactSHA256': selected['artifactSHA256']}
            child, child_files = packaging.collect_binding(next_values)
            self.assertEqual(child['originalSignedBuildRunID'], 50)
            self.assertEqual(child['previousNotary']['parentProvenance']['artifactID'], 701)
            cached = packaging.read_proof_archive(child_files['original-api-evidence.zip'])
            acquisition = json.loads(cached['acquisition.json'])
            route = acquisition['bytes']['actions/artifacts/701/zip']
            self.assertEqual(cached[route['name']], downloads['actions/artifacts/701/zip'])
            self.assertEqual(packaging.validate_binding(child, child_files), self.product)
            self.assertIsNone(packaging.REPLAY.get()); self.assertIsNone(packaging.BUDGET.get())

    def test_record_complete_preserves_actual_post_staple_bytes_and_the_original_submission(self):
        routes, downloads, environment, values, journals, publish = self.provenance_fixture()
        local = self.local_git_fixture() | {('diff', '--no-renames', '--name-only', 'HEAD', '--'): b''}
        with tempfile.TemporaryDirectory() as temporary, chdir(temporary), patch.dict(os.environ, environment), \
                patch.object(packaging, 'utc_now', return_value='2026-11-04T10:20:00Z'), \
                patch.object(packaging, 'live_api', side_effect=routes.__getitem__), \
                patch.object(packaging, 'live_read_api', side_effect=lambda route, **kwargs: downloads[route]), \
                patch.object(packaging, 'git', side_effect=lambda *args: local[args]):
            root = Path(temporary) / 'proof'
            record, files = packaging.collect_binding(values)
            packaging.save_stage(root, record, files)
            restored = self.complete_fixture(record, journals); restored.pop('final'); restored['stage'] = 'restored'
            packaging.save_stage(root, restored, files)
            skeleton = self.complete_fixture(record, journals); publish(skeleton, dict(files))
            with zipfile.ZipFile(io.BytesIO(downloads['actions/artifacts/702/zip'])) as archive:
                small = archive.read('manifest.json')
            descriptor = json.loads(small); checkpoint = descriptor['checkpoint']
            (root / 'dmg-proof').mkdir(); (root / 'dmg-proof/manifest.json').write_bytes(small)
            checkpoint_file = root / 'submitted-checkpoint.json'; checkpoint_file.write_text(json.dumps(checkpoint))
            routes['actions/runs/70/artifacts?per_page=100'] = {'total_count': 3,
                'artifacts': [routes['actions/artifacts/' + str(identifier)] for identifier in (701, 702, 703)]}
            state = Path(temporary) / 'notary'; state.mkdir()
            (state / 'context.json').write_text(json.dumps(checkpoint['context']))
            for checksum, journal in skeleton['final']['notaryJournals'].items():
                (state / (checksum + '.json')).write_text(json.dumps(journal))
            build = Path('.build'); (build / 'plugins').mkdir(parents=True)
            dmg = build / 'NexGenVideo.dmg'; dmg.write_bytes(b'final stapled DMG bytes')
            pack = build / 'plugins/musicvideo.ngvpack.zip'; pack.write_bytes(b'final stapled pack bytes')
            os.environ.update(RETAINED_PACKAGING_ROOT=str(root), RETAINED_PACKAGING_INPUT_SHA256=packaging.digest(packaging.encoded(record)),
                RETAINED_PACKAGING_RESTORED_SHA256=packaging.digest(packaging.encoded(restored)),
                RETAINED_PACKAGING_DMG_CHECKPOINT=str(checkpoint_file), NOTARY_STATE_DIR=str(state),
                NGV_RELEASE_MOUNTED_APP_TREE_SHA256='7' * 64, NGV_RELEASE_DMG_SHA256=packaging.file_checksum(dmg),
                NGV_RELEASE_PACK_ZIP_SHA256=packaging.file_checksum(pack), NGV_RELEASE_PACK_TREE_SHA256='b' * 64,
                GITHUB_ENV=str(Path(temporary) / 'outputs'))
            checksum = packaging.record_complete(root, skeleton['final']['app'], packaging.digest(b'exact final runtime archive'), 'a' * 64, pack)
            completed, completed_files = packaging.read_stage(root, 'complete')
            self.assertEqual(packaging.validate_binding(completed, completed_files), self.product)
            self.assertEqual(completed['final']['dmgSHA256'], packaging.file_checksum(dmg))
            self.assertEqual(completed['final']['submittedDMGSHA256'], 'c' * 64)
            self.assertNotEqual(completed['final']['submittedDMGSHA256'], completed['final']['dmgSHA256'])
            self.assertEqual(completed['final']['dmgSubmissionPayloadArtifact']['id'], 703)
            self.assertEqual(checksum, packaging.digest((root / 'complete/packaging-provenance.json').read_bytes()))
            self.assertIn('RETAINED_PACKAGING_COMPLETE_SHA256=' + checksum, Path(os.environ['GITHUB_ENV']).read_text())

    def test_every_retained_release_callsite_receives_its_current_repository_token(self):
        root = Path(__file__).resolve().parents[1]
        workflow = yaml.safe_load((root / '.github/workflows/release.yml').read_text())
        reached = []
        for job_name in ('release-gate', 'release'):
            job = workflow['jobs'][job_name]
            for step in job['steps']:
                body = step.get('run', '')
                if not any(name in body for name in ('retained_packaging.py', 'release_checkpoint.py',
                           'from release_checkpoint import product_source', 'bundle.sh notarize')): continue
                effective = workflow.get('env', {}) | job.get('env', {}) | step.get('env', {})
                with self.subTest(job=job_name, step=step.get('name')):
                    self.assertEqual(effective.get('GH_TOKEN'), '${{ github.token }}')
                    self.assertEqual(job['permissions']['actions'], 'read' if job_name == 'release' else 'write')
                    self.assertIn(job['permissions']['pull-requests'], {'read', 'write'})
                reached.append(step.get('name'))
        self.assertIn('Record DMG before notarization', reached)
        self.assertIn('Transfer the verified installed DMG app for workspace acceptance', reached)
        gates = workflow['jobs']['release-gate']['steps']
        guard = next(i for i, step in enumerate(gates) if step.get('run') == 'python3 scripts/retained_packaging.py validate-inputs')
        first_publication = next(i for i, step in enumerate(gates) if step.get('name') == 'Inspect or resume release publication')
        self.assertLess(guard, first_publication)
        self.assertNotIn('if', gates[guard])

    def test_real_external_import_context_reaches_both_deferred_native_verifiers(self):
        entry = Path(__file__).resolve().parent / 'external-gui/acceptance.py'
        code = textwrap.dedent('''
            import pathlib, runpy, sys
            entry = pathlib.Path(sys.argv[1])
            sys.path.insert(0, str(entry.parent))
            runpy.run_path(str(entry), run_name='external_entry_import_probe')
            from release_checkpoint import verify_manifest
            source = 'a' * 40
            manifest = {'schema': 'release-signed-input/v1', 'repository': 'iret77/nexgenvideo',
                'sourceSHA': source, 'runID': 50, 'attempt': 1, 'appTreeSHA256': '6' * 64,
                'identity': {'sourceSHA': source, 'version': '1.8.0', 'build': '105', 'catalogURL': 'https://example.test/catalog'},
                'nativeEvidence': {'schema': 'resumed-release-tests/v1', 'suite': {}}}
            try: verify_manifest(manifest, source, 50)
            except ValueError as error: assert str(error) == 'Resumed Release aggregate is incomplete'
            else: raise AssertionError('Invalid aggregate unexpectedly passed')
            assert pathlib.Path(sys.modules['release_engine_resume'].__file__).resolve() == entry.parents[1] / 'release_engine_resume.py'
            manifest['nativeEvidence'] = {'schema': 'release-native-reuse/v1'}
            try: verify_manifest(manifest, source, 50)
            except ValueError as error: assert str(error) == 'Reused native test evidence differs'
            else: raise AssertionError('Invalid original native receipt unexpectedly passed')
            assert pathlib.Path(sys.modules['release_native_proof'].__file__).resolve() == entry.parents[1] / 'release_native_proof.py'
        ''')
        environment = {key: value for key, value in os.environ.items() if key not in {'PYTHONPATH', 'GH_TOKEN'}}
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run([sys.executable, '-I', '-c', code, str(entry)], cwd=directory,
                                    env=environment, capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_recorded_source_artifact_metadata_cannot_contradict_unchanged_actual_bytes(self):
        routes, downloads, environment, values, journals, publish = self.provenance_fixture()
        with patch.dict(os.environ, environment), patch.object(packaging, 'utc_now', return_value='2026-11-04T10:20:00Z'), \
                patch.object(packaging, 'live_api', side_effect=routes.__getitem__), \
                patch.object(packaging, 'live_read_api', side_effect=lambda route, **kwargs: downloads[route]), \
                patch.object(packaging, 'git', side_effect=lambda *args: self.local_git_fixture()[args]):
            record, files = packaging.collect_binding(values)
            for name in ('product-source.json', 'harness-source.json'):
                for field, value in [('digest', 'sha256:' + '0' * 64), ('size_in_bytes', 1),
                                     ('workflow_run', {'id': 999, 'head_sha': self.product})]:
                    changed = json.loads(files[name]); changed['artifact'][field] = value
                    changed_files = dict(files, **{name: packaging.encoded(changed)})
                    completed = self.complete_fixture(copy.deepcopy(record), journals)
                    completed['files'][name] = {'bytes': len(changed_files[name]), 'sha256': packaging.digest(changed_files[name])}
                    selected = publish(completed, changed_files)
                    with self.subTest(name=name, field=field), self.assertRaisesRegex(ValueError, 'Recorded packaging artifact differs'):
                        packaging.load_provenance(70, self.product, selected)

    def test_same_source_app_with_changed_resource_or_mode_cannot_satisfy_canonical_bytes(self):
        import release_acceptance_identity as identities
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / 'NexGenVideo.app'; contents = app / 'Contents'
            (contents / 'MacOS').mkdir(parents=True); (contents / 'Resources').mkdir()
            executable = contents / 'MacOS/NexGenVideo'; executable.write_bytes(b'synthetic fixture'); executable.chmod(0o755)
            info = {'CFBundleIdentifier': 'de.h5ventures.nexgenvideo', 'CFBundleExecutable': 'NexGenVideo',
                    'CFBundleShortVersionString': '1.8.0', 'CFBundleVersion': '105',
                    'NGVSourceCommit': self.product, 'LSMinimumSystemVersion': '26.0'}
            (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
            resource = contents / 'Resources/data'; resource.write_bytes(b'original')
            actual = identities.gui_tools().metadata(app, self.product)
            canonical = {'final': {'app': actual, 'appTreeSHA256': actual['treeSHA256']}}
            with patch.object(packaging, 'consumer_record', return_value=canonical):
                self.assertEqual(packaging.verify_app_bytes(app, {'productSourceSHA': self.product}), actual)
                resource.write_bytes(b'changed with same source SHA')
                with self.assertRaisesRegex(ValueError, 'canonical final App bytes'):
                    packaging.verify_app_bytes(app, {'productSourceSHA': self.product})
                resource.write_bytes(b'original'); executable.chmod(0o700)
                with self.assertRaisesRegex(ValueError, 'canonical final App bytes'):
                    packaging.verify_app_bytes(app, {'productSourceSHA': self.product})

    def test_shared_native_verifier_fingerprints_reject_missing_or_uncommitted_dependency(self):
        dependencies = ('scripts/release_engine_resume.py', 'scripts/release_native_proof.py', 'scripts/release_test_repair.py',
            'scripts/compiled_core_reuse.py', 'scripts/fixtures/compiled-core-reuse-886.json',
            'scripts/compiled_app_release.py', 'scripts/compiled_xctest_reuse.py', 'scripts/fixtures/compiled-app-native-inventory.json',
            'scripts/native_app_target_build.py', 'scripts/native_app_target_recipe.py', 'scripts/native_app_build_plan.py',
            'scripts/fixtures/native-test-entry-point.json')
        for name in dependencies:
            self.assertIn(name, packaging.VERIFIER_INPUTS)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); committed = {name: name.encode() for name in packaging.VERIFIER_INPUTS}
            for name, raw in committed.items():
                path = root / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(raw)
            def git(*args):
                if args == ('rev-parse', 'HEAD'): return self.producer.encode()
                if args[0] == 'show': return committed[args[1].split(':', 1)[1]]
                self.fail('Unexpected fingerprint Git call')
            with patch.dict(os.environ, GITHUB_SHA=self.producer), patch.object(packaging, 'git', side_effect=git):
                result = packaging.committed_inputs(packaging.VERIFIER_INPUTS, root)
                self.assertEqual(set(result), set(packaging.VERIFIER_INPUTS))
                for name in dependencies:
                    (root / name).write_bytes(b'different verifier')
                    with self.subTest(dependency=name), self.assertRaisesRegex(ValueError, 'differs from committed bytes'):
                        packaging.committed_inputs(packaging.VERIFIER_INPUTS, root)
                    (root / name).write_bytes(committed[name])
                (root / 'scripts/release_native_proof.py').rename(root / 'outside-verifier')
                with self.assertRaisesRegex(ValueError, 'not a regular file'):
                    packaging.committed_inputs(packaging.VERIFIER_INPUTS, root)

    def test_actual_input_cli_rejects_every_partial_new_selector_before_canonical_bind(self):
        script = Path(__file__).with_name('retained_packaging.py')
        valid = {'version': '1.8.0', 'artifact_only': True, 'dry_run': True,
                 'retained_product_source_sha': self.product, 'retained_product_source_pr_run_id': '11',
                 'verified_pr_run_id': '22', 'notary_progress_run_id': '60'}
        prior = {'prior_packaging_producer_source_sha': 'c' * 40,
                 'prior_packaging_provenance_artifact_id': '701', 'prior_packaging_provenance_artifact_sha256': 'd' * 64}
        cases = [({}, True), (valid, True), (valid | prior, True)]
        cases += [({key: value for key, value in valid.items() if key != missing}, False) for missing in
                  ('retained_product_source_sha', 'retained_product_source_pr_run_id', 'verified_pr_run_id', 'notary_progress_run_id')]
        cases += [(valid | {key: False}, False) for key in ('artifact_only', 'dry_run')]
        cases += [(valid | {name: value}, False) for name, value in prior.items()]
        cases += [(valid | {name: value for name, value in prior.items() if name != missing}, False) for missing in prior]
        with tempfile.TemporaryDirectory() as directory:
            event = Path(directory) / 'event.json'
            environment = {key: value for key, value in os.environ.items() if key not in {'PYTHONPATH', 'GH_TOKEN'}}
            environment.update(GITHUB_SHA=self.producer, GITHUB_EVENT_PATH=str(event))
            for inputs, accepted in cases:
                event.write_text(json.dumps({'inputs': inputs}))
                result = subprocess.run([sys.executable, str(script), 'validate-inputs'], cwd=directory,
                    env=environment, capture_output=True, text=True, timeout=15)
                with self.subTest(inputs=inputs):
                    self.assertEqual(result.returncode == 0, accepted, result.stdout + result.stderr)

    def test_v2_dmg_checkpoint_keeps_both_actual_bundle_tree_algorithms(self):
        import release_acceptance_identity as identities
        import release_checkpoint as checkpoint
        with tempfile.TemporaryDirectory() as directory, chdir(directory):
            app = Path('.build/NexGenVideo.app'); contents = app / 'Contents'
            (contents / 'MacOS').mkdir(parents=True); (contents / 'Resources').mkdir()
            executable = contents / 'MacOS/NexGenVideo'; executable.write_bytes(b'synthetic App fixture'); executable.chmod(0o755)
            (contents / 'Resources/data').write_bytes(b'exact resources')
            (contents / 'Current').symlink_to('MacOS')
            Path('.build/NexGenVideo.dmg').write_bytes(b'actual submitted DMG fixture')
            signed_tree = checkpoint.tree_digest(app); runtime_tree = identities.tree_sha256(app)
            self.assertNotEqual(signed_tree, runtime_tree)
            state = Path(directory) / 'notary'; state.mkdir()
            context = {'schema': 'release-notary-context/v2', 'repository': packaging.REPOSITORY,
                       'sourceSHA': self.product, 'producerSourceSHA': self.producer, 'buildRunID': 50, 'runID': 70}
            (state / 'context.json').write_text(json.dumps(context))
            def tar(*args):
                self.assertEqual(args[:2], ('tar', '-czf'))
                Path(args[2]).write_bytes(b'exact pack TAR fixture')
            environment = {'GITHUB_SHA': self.producer, 'GITHUB_RUN_ID': '70', 'NOTARY_STATE_DIR': str(state),
                           'GITHUB_ENV': str(Path(directory) / 'outputs')}
            with patch.dict(os.environ, environment), patch.object(checkpoint, 'packaging_binding',
                    return_value={'productSourceSHA': self.product, 'originalSignedBuildRunID': 50}), \
                    patch.object(checkpoint, 'run', side_effect=tar):
                checkpoint.create_dmg(Path(directory) / 'checkpoint')
            record = json.loads((Path(directory) / 'checkpoint/dmg-checkpoint.json').read_text())
            self.assertEqual(record['schema'], 'release-dmg-checkpoint/v2')
            self.assertEqual(record['appTreeSHA256'], signed_tree)
            self.assertEqual(record['appRuntimeTreeSHA256'], runtime_tree)
            self.assertNotEqual(record['appTreeSHA256'], record['appRuntimeTreeSHA256'])

    def test_complete_receipt_rejects_missing_or_signed_algorithm_in_runtime_tree_field(self):
        routes, downloads, environment, values, journals, publish = self.provenance_fixture()
        with patch.dict(os.environ, environment), patch.object(packaging, 'utc_now', return_value='2026-11-04T10:20:00Z'), \
                patch.object(packaging, 'live_api', side_effect=routes.__getitem__), \
                patch.object(packaging, 'live_read_api', side_effect=lambda route, **kwargs: downloads[route]), \
                patch.object(packaging, 'git', side_effect=lambda *args: self.local_git_fixture()[args]):
            record, files = packaging.collect_binding(values)
            complete = self.complete_fixture(record, journals); publish(complete, files)
            with zipfile.ZipFile(io.BytesIO(files['submitted-dmg-proof.zip'])) as archive:
                original = json.loads(archive.read('manifest.json'))
            self.assertNotEqual(original['checkpoint']['appTreeSHA256'], original['checkpoint']['appRuntimeTreeSHA256'])
            for missing in (True, False):
                changed = copy.deepcopy(original)
                if missing: changed['checkpoint'].pop('appRuntimeTreeSHA256')
                else: changed['checkpoint']['appRuntimeTreeSHA256'] = changed['checkpoint']['appTreeSHA256']
                raw = io.BytesIO()
                with zipfile.ZipFile(raw, 'w') as archive: archive.writestr('manifest.json', json.dumps(changed))
                broken = copy.deepcopy(complete); altered = dict(files, **{'submitted-dmg-proof.zip': raw.getvalue()})
                broken['files']['submitted-dmg-proof.zip'] = {'bytes': len(raw.getvalue()), 'sha256': packaging.digest(raw.getvalue())}
                broken['final']['dmgSubmissionArtifact'].update(size_in_bytes=len(raw.getvalue()), digest='sha256:' + packaging.digest(raw.getvalue()))
                outer = io.BytesIO()
                with zipfile.ZipFile(outer, 'w') as archive:
                    for name, value in {**altered, 'packaging-provenance.json': packaging.encoded(broken)}.items(): archive.writestr(name, value)
                routes['actions/artifacts/701'].update(size_in_bytes=len(outer.getvalue()), digest='sha256:' + packaging.digest(outer.getvalue()))
                downloads['actions/artifacts/701/zip'] = outer.getvalue()
                selected = packaging.selectors(self.producer, '701', packaging.digest(outer.getvalue()))
                with self.subTest(missing=missing), self.assertRaisesRegex(ValueError, 'submitted DMG identity'):
                    packaging.load_provenance(70, self.product, selected)


if __name__ == "__main__":
    unittest.main()
