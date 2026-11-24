import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

import signed_scene_history as history


def source_commit(root, build):
    plist = root / history.SOURCE_PLIST
    plist.parent.mkdir(parents=True, exist_ok=True)
    plist.write_bytes(plistlib.dumps({'CFBundleVersion': build, 'CFBundleShortVersionString': '1.8.0'}))
    git = ['git', '-c', 'user.name=fixture', '-c', 'user.email=fixture@example.invalid', '-C', str(root)]
    subprocess.run(git + ['add', history.SOURCE_PLIST], check=True)
    subprocess.run(git + ['commit', '-q', '--no-gpg-sign', '-m', 'build ' + build], check=True)
    return subprocess.check_output(git + ['rev-parse', 'HEAD'], text=True).strip()


class SignedSceneHistoryTests(unittest.TestCase):
    def test_mounted_build_is_the_product_source_build_after_the_release_bump(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            older = source_commit(root, '148')
            newer = source_commit(root, '311')
            mounted = lambda build, version='1.8.0': {'dmgSHA256': 'b' * 64,
                                                      'app': {'CFBundleVersion': build, 'CFBundleShortVersionString': version}}
            history.verify_mounted_identity(mounted('149'), 'b' * 64, older, root)
            history.verify_mounted_identity(mounted('312'), 'b' * 64, newer, root)
            for value, product in ((mounted('148'), older), (mounted('147'), older), (mounted('149'), newer),
                                   (mounted('311'), newer), (mounted('312', '1.8.1'), newer)):
                with self.subTest(value=value, product=product), self.assertRaises(ValueError):
                    history.verify_mounted_identity(value, 'b' * 64, product, root)
            with self.assertRaises(ValueError):
                history.verify_mounted_identity(mounted('312'), 'c' * 64, newer, root)
            for build in ('0', '14a', ''):
                with self.subTest(build=build), self.assertRaises(ValueError):
                    history.released_build(source_commit(root, build), root)

    def test_image_acquisition_accepts_the_derived_build_of_any_product(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            product = source_commit(root, '311')
            run = dict(id=12345, run_attempt=1, head_sha=product, repository={'full_name': 'iret77/nexgenvideo'},
                       actor={'login': 'iret77'}, path='.github/workflows/release.yml', head_branch=history.BASE,
                       event='workflow_dispatch', status='completed')
            pending = dict(name='acceptance-pending', conclusion='failure', run_attempt=1, run_id=12345, head_sha=product)
            inventory = dict(total_count=1, jobs=[pending])
            inputs = dict(run_id='12345', expected_dmg_sha256='b' * 64)
            for build, accepted in (('312', True), ('311', False), ('147', False)):
                mounted = {'dmgSHA256': 'b' * 64, 'app': {'CFBundleVersion': build, 'CFBundleShortVersionString': '1.8.0'}}
                with self.subTest(build=build), patch.object(history, 'REPOSITORY', root), \
                        patch.object(history, 'api', side_effect=[run, inventory]), \
                        patch.object(history, 'internal_image_evidence', return_value=mounted), \
                        self.assertRaisesRegex(ValueError, 'not enough values to unpack' if accepted else 'mounted receipt differs'):
                    history.acquire_image(root, inputs, product)

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

                def start(*args, **kwargs):
                    kwargs['stderr'].write(b'[app] NOTICE: notifications disabled in settings\n')
                    kwargs['stderr'].flush()
                    native = Path(kwargs['env']['NGV_SELFTEST_BPY'])
                    history.write(native / 'launch-presentation.json', dict(pid=proc.pid, windowNumber=34,
                        onScreenWindowNumbers=[40], shownUptime=68.1, orderedOutUptime=70.5, observedUptime=70.6))
                    return proc

                with patch.dict(os.environ, {'NGV_SELFTEST_OLD': '1', 'GH_TOKEN': 'test-placeholder'}), \
                        patch.object(history.subprocess, 'Popen', side_effect=start) as launch, \
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

    def test_splash_proof_requires_the_launched_process_and_a_departed_window(self):
        proof = dict(pid=47, windowNumber=34, onScreenWindowNumbers=[40], shownUptime=0.4, orderedOutUptime=1.4, observedUptime=1.6)
        for change in (dict(pid=49), dict(windowNumber=True), dict(onScreenWindowNumbers=[34, 40]),
                       dict(onScreenWindowNumbers=[]), dict(onScreenWindowNumbers=[True]), dict(onScreenWindowNumbers='40'),
                       dict(shownUptime=2), dict(orderedOutUptime=True), dict(observedUptime=1), dict(observedUptime=float('inf'))):
            with self.subTest(change=change), self.assertRaises(ValueError):
                history.verify_launch_presentation(proof | change, 47)

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

    def test_chunk_ranges_match_the_actual_pngs_and_jobs(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            chunks, outputs = [], {}
            for frame in (1, 2):
                image = dict(filename=f'clay-{frame:08d}.png', sha256=str(frame) * 64)
                outputs[image['filename']] = image
                name = f'part-{frame}.json'
                part = dict(request=dict(startFrame=frame, endFrame=frame, cameraID='wide'),
                            scene={'revision': 'confirmed'}, jobID=str(frame), jobFingerprint=str(frame) * 64, outputs=[image])
                (folder / name).write_text(json.dumps(part))
                chunks.append(dict(startFrame=frame, endFrame=frame, jobID=part['jobID'], jobFingerprint=part['jobFingerprint'],
                                   proofFilename=name, proofSHA256=history.checksum(folder / name)))
            proof = dict(request=dict(startFrame=1, endFrame=2, cameraID='wide'), scene={'revision': 'confirmed'}, chunks=chunks)
            with patch.object(history, 'validate_worker_render', return_value={'frames': 1}):
                self.assertEqual(len(history.validate_chunks(folder, proof, outputs)), 2)
                for ranges in (chunks[:1], list(reversed(chunks)), [chunks[0], chunks[0]],
                               [chunks[0], dict(chunks[1], jobID=chunks[0]['jobID'])],
                               [chunks[0], dict(chunks[1], endFrame=3)]):
                    with self.subTest(chunks=ranges), self.assertRaises(ValueError):
                        history.validate_chunks(folder, dict(proof, chunks=ranges), outputs)

    def test_worker_render_verifies_settings_after_the_actual_frame(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            job = '12345678-ABCD-4321-ABCD-123456789ABC'
            folder = root / job
            folder.mkdir()
            name = 'clay-00000003.png'
            image = dict(filename=name, sha256='a' * 64, byteCount=219)
            pose = {'frame': 3, 'matrixWorld': [1.0]}
            actual = dict(before=['CYCLES', 'CPU'], after=['CYCLES', 'CPU'], result='FINISHED',
                          cameraID='wide', frame=3, filename=name, pid=27)
            proof = dict(jobID=job, jobFingerprint='b' * 64, scene={'revision': 'first'}, framePoses=[pose],
                         outputs=[image], request=dict(startFrame=3, endFrame=3, cameraID='wide'))
            for changes in ({}, {'after': ['CYCLES', 'GPU']}, {'cameraID': 'other'}, {'result': 'CANCELLED'}, {'pid': 0}):
                with self.subTest(changes=changes):
                    frames = folder / 'clay-frames.json'
                    frames.write_text(json.dumps([dict(pose, execution=actual | changes)]))
                    descriptors = [dict(name=name, sha256=image['sha256'], byteCount=image['byteCount']),
                                   dict(name=frames.name, sha256=history.checksum(frames), byteCount=frames.stat().st_size)]
                    (folder / 'job.json').write_text(json.dumps(dict(jobID=job, jobFingerprint=proof['jobFingerprint'],
                        sourceRevision='first', outputs=descriptors)))
                    if changes:
                        with self.assertRaises(ValueError):
                            history.validate_worker_render(root, proof)
                    else:
                        with patch.object(history, 'verify_saved_render', return_value=28) as verified:
                            row = history.validate_worker_render(root, proof)
                            self.assertEqual((row['workerPID'], row['verifierPID']), (27, 28))
                            self.assertEqual(verified.call_args.args[3], 27)

    def test_verifier_binds_executable_and_module_to_the_observed_service(self):
        with tempfile.TemporaryDirectory() as temp:
            app = Path(temp) / 'NexGenVideo.app'
            services = app / 'Contents/XPCServices'
            roots = [services / f'NexGenVideoBpyService{slot}.xpc/Contents/Resources/BpyRuntime' for slot in (0, 1)]
            for root in roots:
                for name in ('site-packages/bpy/__init__.so', 'python/bin/python3.13'):
                    file = root / name
                    file.parent.mkdir(parents=True, exist_ok=True)
                    file.write_bytes(b'fixture')
            for root in roots:
                value = dict(bpyModule=str(root / 'site-packages/bpy/__init__.so'),
                             executable=str(root / 'python/bin/python3.13'))
                self.assertEqual(history.verifier_runtime(value, app), root)
                other, = [r for r in roots if r != root]
                with self.assertRaises(ValueError):
                    history.verifier_runtime(dict(value, executable=str(other / 'python/bin/python3.13')), app)
