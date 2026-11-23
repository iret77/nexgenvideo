import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

import signed_scene_history as history


class SignedSceneHistoryTests(unittest.TestCase):
    def test_signed_scene_rejects_unrelated_dispatch_modes_and_selectors(self):
        base = dict(candidate_kind='signed-scene-history', run_id='12345', source_sha='c' * 40,
                    artifact_id='123', artifact_sha256='a' * 64, expected_dmg_sha256='b' * 64, verified_pr_run_id='456')
        history.validate_dispatch(base)
        history.validate_dispatch(dict(base, candidate_kind="signed-scene-editing"))
        history.validate_dispatch(dict(base, journey_scenario='journey', interface_scale='1', test_bundle_artifact_id=''))
        for change in ({'test_bundle_artifact_id': '123'}, {'interface_scale': '1.5'}, {'run_id': '0'},
                       {'failure_artifact_id': '9'}, {'expected_catalog_sha256': 'a' * 64}, {'unexpected': 'true'}):
            with self.subTest(change=change), self.assertRaises(ValueError):
                history.validate_dispatch(dict(base, **change))

    def test_scene_result_requires_a_successful_real_process_and_independent_verifier(self):
        for status in (0, 1):
            with self.subTest(status=status), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                evidence = root / 'evidence'
                evidence.mkdir()
                proc = Mock(pid=472)
                proc.wait.return_value = status
                proc.poll.return_value = status
                app = root / 'NexGenVideo.app'
                checked = {'appScopePassed': True}
                with patch.dict(os.environ, {'NGV_SELFTEST_OLD': '1', 'GH_TOKEN': 'test-placeholder'}), \
                        patch.object(history.subprocess, 'Popen', return_value=proc) as launch, \
                        patch.object(history, 'scoped_success', return_value=checked) as verify:
                    if status:
                        with self.assertRaisesRegex(ValueError, 'exited'):
                            history.execute_history(app, root, evidence, 'c' * 40)
                        verify.assert_not_called()
                    else:
                        self.assertEqual(history.execute_history(app, root, evidence, 'c' * 40), checked)
                        files, product, pid = verify.call_args.args
                        self.assertEqual((product, pid), ('c' * 40, 472))
                        self.assertEqual(json.loads(files['process-result.json'])['returncode'], 0)
                    args, = launch.call_args.args
                    self.assertEqual(args.count('-de.h5ventures.nexgenvideo.notifications.enabled'), 1)
                    self.assertEqual(args[args.index('-de.h5ventures.nexgenvideo.notifications.enabled') + 1], 'NO')
                    self.assertEqual(args[-4:], ['-agentBackend', 'anthropicAPI',
                        '-de.h5ventures.nexgenvideo.mcp.enabled', 'NO'])
                    env = launch.call_args.kwargs['env']
                    self.assertEqual(env['NGV_SELFTEST_BPY_SCOPE'], 'scene-history')
                    self.assertEqual(Path(env['HOME']), (root / 'home').resolve())
                    self.assertEqual(env['HOME'], env['CFFIXED_USER_HOME'])
                    self.assertNotIn('GH_TOKEN', env)
                    self.assertNotIn('NGV_SELFTEST_OLD', env)

    def test_render_timing_requires_the_complete_planned_interval(self):
        proof = dict(request=dict(startFrame=7, endFrame=9, width=128, height=96),
                     state={'frames': [{'frame': i} for i in (7, 8, 9)]}, timebaseNumerator=24,
                     timebaseDenominator=1, timing=dict(numerator=5, denominator=48))
        stream = dict(width=128, height=96, codec_name='h264', color_primaries='bt709', color_transfer='bt709',
                      color_space='bt709', nb_read_frames='3', time_base='1/48', start_pts=0, duration_ts=5)
        frames = [{'pts': i} for i in (0, 2, 4)]
        history.validate_timing(proof, stream, frames)
        for observed, timing in ((dict(stream, nb_read_frames='2'), frames[:2]), (dict(stream, width=96), frames),
                                 (dict(stream, duration_ts=6), frames), (stream, [{'pts': i} for i in (0, 1, 4)])):
            with self.subTest(stream=observed, frames=timing), self.assertRaises(ValueError):
                history.validate_timing(proof, observed, timing)
