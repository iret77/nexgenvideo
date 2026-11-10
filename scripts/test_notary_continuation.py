from contextlib import contextmanager, ExitStack
import copy
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import stat
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import compiled_component_reuse as component
import notary_continuation as notary
import retained_packaging


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


class NotaryContinuationTests(unittest.TestCase):
    @contextmanager
    def fixture(self):
        with tempfile.TemporaryDirectory() as name, ExitStack() as stack:
            base = Path(name)
            workspace, temporary = base / 'workspace', base / 'runner'
            workspace.mkdir(); temporary.mkdir()
            artifact = workspace / '.build/NexGenVideo.zip'
            artifact.parent.mkdir(); artifact.write_bytes(b'original signed App bytes')
            archive = sha(artifact.read_bytes())
            stack.enter_context(patch.object(notary, 'ARCHIVE', archive))
            stack.enter_context(patch.object(component, 'ORIGIN', dict(component.ORIGIN, appArchiveSHA256=archive)))
            journal = {'schema': 'release-notary/v1', 'sha256': archive,
                'submissionID': notary.SUBMISSION, 'sourceSHA': notary.SOURCE}
            state = temporary / 'release-notary-state'; state.mkdir()
            journal_raw = (json.dumps(journal, indent=2) + '\n').encode()
            (state / (archive + '.json')).write_bytes(journal_raw)
            stack.enter_context(patch.object(notary, 'JOURNAL_SHA', sha(journal_raw)))
            binding = {'productSourceSHA': notary.SOURCE, 'producerSourceSHA': 'b' * 40, 'runID': 999,
                'stage': 'input', 'files': {},
                'originalSignedBuildRunID': notary.RUN, 'signedInput': {'componentProduct': component.record()},
                'previousNotary': {'journals': {archive: journal}}}
            context = {'schema': 'release-notary-context/v2', 'repository': 'iret77/nexgenvideo',
                'sourceSHA': notary.SOURCE, 'producerSourceSHA': binding['producerSourceSHA'],
                'buildRunID': notary.RUN, 'runID': 999}
            (state / 'context.json').write_text(json.dumps(context))
            root = temporary / 'packaging'; (root / 'input').mkdir(parents=True)
            raw = retained_packaging.encoded(binding)
            (root / 'input/packaging-provenance.json').write_bytes(raw)
            stack.enter_context(patch.dict(os.environ, {'RUNNER_TEMP': str(temporary), 'GITHUB_WORKSPACE': str(workspace),
                'GITHUB_SHA': binding['producerSourceSHA'], 'GITHUB_RUN_ID': '999',
                'RETAINED_PACKAGING_ROOT': str(root), 'RETAINED_PACKAGING_INPUT_SHA256': sha(raw),
                'NOTARY_KEY_FILE': 'fixture-key-file', 'NOTARY_KEY_ID': 'fixture-key-id', 'NOTARY_ISSUER': 'fixture-issuer'}))
            clock = [0.0]
            def sleep(seconds): clock[0] += seconds
            yield artifact, state, binding, clock, sleep

    def accepted(self, argv, **kwargs):
        self.assertEqual(argv[:4], ['xcrun', 'notarytool', 'info', notary.SUBMISSION])
        self.assertLessEqual(kwargs['timeout'], 60)
        return subprocess.CompletedProcess(argv, 0, json.dumps({'id': notary.SUBMISSION, 'status': 'Accepted'}).encode(), b'')

    def evidence(self, state):
        root = state / 'observations' / notary.ARCHIVE
        return {path.name: path.read_bytes() for path in root.iterdir()}

    def test_existing_submission_acceptance_retains_exact_originals_and_canonical_result(self):
        with self.fixture() as (artifact, state, binding, clock, sleep):
            invoke = unittest.mock.Mock(side_effect=self.accepted)
            self.assertEqual(notary.observe(artifact, state, binding, invoke=invoke,
                monotonic=lambda: clock[0], sleep=sleep), 0)
            result = notary.verify_observations(self.evidence(state), binding)
            self.assertTrue(result['acceptedForContinuation'])
            self.assertFalse(result['newSubmissionPerformed'])
            self.assertEqual(invoke.call_count, 1)
            with self.assertRaises(ValueError):
                notary.observe(artifact, state, binding, invoke=invoke, monotonic=lambda: clock[0], sleep=sleep)
            self.assertEqual(invoke.call_count, 1)

    def test_missing_or_changed_journal_payload_context_binding_or_link_fails_before_apple(self):
        for change in ('missing', 'submission', 'payload', 'context', 'binding', 'linked-state', 'duplicate'):
            with self.subTest(change=change), self.fixture() as (artifact, state, binding, clock, sleep):
                journal = state / (notary.ARCHIVE + '.json')
                if change == 'missing': journal.rename(state / 'missing-journal')
                elif change == 'submission': journal.write_bytes(journal.read_bytes().replace(notary.SUBMISSION.encode(), b'0' * 36))
                elif change == 'payload': artifact.write_bytes(b'replaced App')
                elif change == 'context': (state / 'context.json').write_text('{}')
                elif change == 'binding':
                    root = Path(os.environ['RETAINED_PACKAGING_ROOT']); (root / 'input/packaging-provenance.json').write_text('{}')
                elif change == 'duplicate': journal.write_bytes(journal.read_bytes().replace(b'{', b'{"schema":"wrong",', 1))
                else:
                    destination = state.with_name('other-state'); state.rename(destination); state.symlink_to(destination, target_is_directory=True)
                invoke = unittest.mock.Mock()
                with self.assertRaises(ValueError):
                    notary.observe(artifact, state, binding, invoke=invoke, monotonic=lambda: clock[0], sleep=sleep)
                invoke.assert_not_called()

    def test_malformed_nonfinite_mismatched_and_transport_answers_are_durable_unknown(self):
        answers = [b'[]', b'null', b'{', b'{"id":"wrong","status":"Accepted"}',
            json.dumps({'id': notary.SUBMISSION, 'status': []}).encode(),
            ('{"id":"' + notary.SUBMISSION + '","status":NaN}').encode(),
            ('{"id":"wrong","id":"' + notary.SUBMISSION + '","status":"Accepted"}').encode()]
        for answer in answers:
            with self.subTest(answer=answer), self.fixture() as (artifact, state, binding, clock, sleep):
                invoke = unittest.mock.Mock(return_value=subprocess.CompletedProcess([], 0, answer, b'original stderr'))
                self.assertNotEqual(notary.observe(artifact, state, binding, invoke=invoke,
                    monotonic=lambda: clock[0], sleep=sleep), 0)
                members = self.evidence(state)
                result = json.loads(members['result.json'])
                self.assertEqual(result['state'], 'UNKNOWN')
                self.assertFalse(result['acceptedForContinuation'])
                self.assertEqual(members['query-1.stdout'], answer)
                with self.assertRaises(ValueError): notary.verify_observations(members, binding)

    def test_in_progress_is_bounded_and_never_resubmits_or_qualifies_pending(self):
        with self.fixture() as (artifact, state, binding, clock, sleep):
            def invoke(argv, **kwargs):
                self.assertEqual(argv[2], 'info')
                return subprocess.CompletedProcess(argv, 0,
                    json.dumps({'id': notary.SUBMISSION, 'status': 'In Progress'}).encode(), b'')
            self.assertEqual(notary.observe(artifact, state, binding, invoke=invoke,
                monotonic=lambda: clock[0], sleep=sleep), 75)
            self.assertEqual(clock[0], 900)
            result = json.loads(self.evidence(state)['result.json'])
            self.assertEqual(result['state'], 'PENDING')
            self.assertFalse(result['appleFinalStatusKnown'])

    def test_late_genuine_accepted_observation_does_not_admit_continuation(self):
        with self.fixture() as (artifact, state, binding, clock, sleep):
            def late(argv, **kwargs):
                result = self.accepted(argv, **kwargs); clock[0] = 901; return result
            self.assertNotEqual(notary.observe(artifact, state, binding, invoke=late,
                monotonic=lambda: clock[0], sleep=sleep), 0)
            result = json.loads(self.evidence(state)['result.json'])
            self.assertEqual(result['state'], 'ACCEPTED')
            self.assertTrue(result['appleFinalStatusKnown'])
            self.assertFalse(result['acceptedForContinuation'])

    def test_invalid_preserves_bounded_diagnostic_log_without_new_submission(self):
        with self.fixture() as (artifact, state, binding, clock, sleep):
            calls = []
            def invoke(argv, **kwargs):
                calls.append(argv[2]); self.assertLessEqual(kwargs['timeout'], 60)
                return subprocess.CompletedProcess(argv, 0,
                    json.dumps({'id': notary.SUBMISSION, 'status': 'Invalid'} if argv[2] == 'info' else {'issues': ['actual failure']}).encode(), b'')
            self.assertNotEqual(notary.observe(artifact, state, binding, invoke=invoke,
                monotonic=lambda: clock[0], sleep=sleep), 0)
            self.assertEqual(calls, ['info', 'log'])
            members = self.evidence(state)
            self.assertIn('diagnostic.stdout', members)
            self.assertEqual(json.loads(members['result.json'])['state'], 'REJECTED')

    def test_slow_original_observation_persistence_cannot_claim_in_budget_acceptance(self):
        with self.fixture() as (artifact, state, binding, clock, sleep):
            original = notary.persist
            def persist(path, value):
                original(path, value)
                if path.name == 'observation.json': clock[0] = 901
            with patch.object(notary, 'persist', side_effect=persist):
                self.assertNotEqual(notary.observe(artifact, state, binding, invoke=self.accepted,
                    monotonic=lambda: clock[0], sleep=sleep), 0)
            result = json.loads(self.evidence(state)['result.json'])
            self.assertFalse(result['completionInBudget'])
            self.assertFalse(result['acceptedForContinuation'])

    def test_artifact_mutation_during_info_is_rejected_after_original_outputs_are_saved(self):
        with self.fixture() as (artifact, state, binding, clock, sleep):
            def mutate(argv, **kwargs):
                result = self.accepted(argv, **kwargs); artifact.write_bytes(b'changed while Apple answered'); return result
            with self.assertRaises(ValueError):
                notary.observe(artifact, state, binding, invoke=mutate, monotonic=lambda: clock[0], sleep=sleep)
            self.assertIn('query-1.stdout', self.evidence(state))

    def test_observation_consumer_rejects_substitutions_in_terminal_query_context_and_inventory(self):
        with self.fixture() as (artifact, state, binding, clock, sleep):
            notary.observe(artifact, state, binding, invoke=self.accepted, monotonic=lambda: clock[0], sleep=sleep)
            members = self.evidence(state)
            for change in ('stdout', 'query-missing', 'context', 'extra', 'result',
                'bool-attempt', 'float-run', 'bool-exit', 'float-exit'):
                changed = copy.deepcopy(members)
                if change == 'stdout': changed['query-1.stdout'] += b'changed'
                elif change == 'query-missing': del changed['query-1.stderr']
                elif change == 'context': changed['context.json'] = changed['context.json'].replace(b'999', b'998')
                elif change == 'extra': changed['unbound.txt'] = b'unbound'
                elif change == 'result':
                    value = json.loads(changed['result.json']); value['completionInBudget'] = False
                    changed['result.json'] = json.dumps(value).encode()
                else:
                    value = json.loads(changed['result.json'])
                    if change in {'bool-attempt', 'float-run'}:
                        context = json.loads(changed['context.json'])
                        context['attempt' if change == 'bool-attempt' else 'runID'] = True if change == 'bool-attempt' else 999.0
                        changed['context.json'] = json.dumps(context).encode()
                        value['contextSHA256'] = sha(changed['context.json'])
                    else:
                        query = json.loads(changed['query-1.json'])
                        query['exitCode'] = False if change == 'bool-exit' else 0.0
                        changed['query-1.json'] = json.dumps(query).encode()
                        value['queries'][0]['recordSHA256'] = sha(changed['query-1.json'])
                        observation = json.loads(changed['observation.json']); observation['queries'] = value['queries']
                        changed['observation.json'] = json.dumps(observation).encode()
                        value['observationSHA256'] = sha(changed['observation.json'])
                    changed['result.json'] = json.dumps(value).encode()
                with self.subTest(change=change), self.assertRaises(ValueError): notary.verify_observations(changed, binding)
            def archive(values, *, linked=False):
                buffer = io.BytesIO()
                with zipfile.ZipFile(buffer, 'w') as output:
                    for name, raw in values.items():
                        info = zipfile.ZipInfo(name)
                        info.external_attr = ((stat.S_IFLNK | 0o777) if linked else (stat.S_IFREG | 0o644)) << 16
                        output.writestr(info, raw)
                return buffer.getvalue()
            original = archive({notary.ARCHIVE + '/' + name: raw for name, raw in members.items()})
            self.assertEqual(notary.observation_members(original), members)
            with self.assertRaises(ValueError): retained_packaging.read_proof_archive(original)
            for values, linked in [({'other/context.json': b'{}'}, False), ({'context.json': b'{}'}, False),
                ({notary.ARCHIVE + '/../context.json': b'{}'}, False), ({notary.ARCHIVE + '/context.json': b'outside'}, True)]:
                with self.subTest(values=list(values), linked=linked), self.assertRaises(ValueError):
                    notary.observation_members(archive(values, linked=linked))
