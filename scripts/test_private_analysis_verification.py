import contextlib
import copy
import io
import json
import os
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

import private_analysis_verification as verify


class PrivateAnalysisVerificationTests(unittest.TestCase):
    def test_resume_selectors_are_exact_and_cannot_inject_public_content(self):
        selected = {'runID': 1, 'sourceSHA': 'a' * 40, 'jobID': 2, 'reportDigest': 'sha256:' + 'b' * 64,
            'fixtureDigest': 'sha256:' + 'c' * 64, 'pointerArtifactID': 3, 'pointerArtifactSHA256': 'd' * 64}
        self.assertEqual(verify.validate_reuse(json.dumps(selected)), selected)
        self.assertIsNone(verify.validate_reuse(''))
        for key, value in [('runID', True), ('reportDigest', 'mutable-tag'), ('sourceSHA', 'private song'), ('filename', 'private song')]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                verify.validate_reuse(json.dumps(dict(selected, **{key: value})))
        with self.assertRaises(ValueError):verify.raw_json('{"runID":1,"runID":2}')
        with self.assertRaises(ValueError):verify.raw_json('{"value":1e999}')

    def test_public_receipt_accepts_only_finite_identity_and_complete_checks(self):
        receipt = dict.fromkeys(verify.PUBLIC_KEYS)
        receipt.update(schema='private-analysis-verification/v1', status='QUALIFIED', errorCode=None,
            reportDigest='sha256:' + 'a' * 64, fixtureDigest='sha256:' + 'b' * 64,
            privateInventorySHA256='c' * 64, productRunID=1, productSourceSHA='d' * 40,
            runtimeArtifactID=2, runtimeArtifactSHA256='e' * 64, nativeRunID=3, nativeJobID=4,
            nativeHarnessSourceSHA='f' * 40, verificationRunID=5, verificationHarnessSourceSHA='a' * 40,
            checks=dict.fromkeys(verify.CHECKS, True))
        self.assertEqual(verify.public_receipt(receipt), receipt)
        for changed in (dict(receipt, filename='private song'), dict(receipt, errorCode='secret'),
                dict(receipt, checks=dict(receipt['checks'], native_origin=False)), dict(receipt, productRunID=True)):
            with self.subTest(changed=changed), self.assertRaises(ValueError):verify.public_receipt(changed)

    def test_parser_failure_cannot_put_private_exception_text_in_logs_or_public_receipt(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); public = root / 'public.json'; log = io.StringIO()
            with patch.object(verify, 'selected_origin', side_effect=ValueError('PRIVATE-LYRICS-SECRET')), contextlib.redirect_stdout(log):
                self.assertFalse(verify.verify(public, root / 'work'))
            self.assertNotIn('PRIVATE-LYRICS-SECRET', log.getvalue() + public.read_text())
            self.assertEqual(json.loads(public.read_text())['errorCode'], 'INTERNAL')
            verify.public_receipt(json.loads(public.read_text()))

    def test_archive_reader_rejects_links_escape_and_case_collisions(self):
        for defect in ('../escape', '/absolute', 'link', 'case'):
            with self.subTest(defect=defect), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary); archive = root / 'report.tar.gz'
                with tarfile.open(archive, 'w:gz') as stream:
                    first = tarfile.TarInfo('safe.json'); first.size = 2; stream.addfile(first, io.BytesIO(b'{}'))
                    second = tarfile.TarInfo('SAFE.json' if defect == 'case' else defect)
                    if defect == 'link':second.type = tarfile.SYMTYPE;second.linkname = '/private'
                    else:second.size = 2
                    stream.addfile(second, None if defect == 'link' else io.BytesIO(b'{}'))
                with self.assertRaises(ValueError):verify.extract_report(archive, root / 'report')
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); archive = root / 'report.tar.gz'
            with tarfile.open(archive, 'w:gz') as stream:
                entry = tarfile.TarInfo('./nested/file.json');entry.size = 2;stream.addfile(entry, io.BytesIO(b'{}'))
            verify.extract_report(archive, root / 'report')
            self.assertEqual((root / 'report/nested/file.json').read_bytes(), b'{}')

    def test_independent_audio_expectations_detect_changed_measurements(self):
        analysis = {'duration_s': 8.0, 'bpm': 120.0, 'beats': [0, 1, 2], 'downbeats': [0, 2],
            'sections': [{'index': 0, 'start': 0, 'end': 4, 'label': 'Verse'}, {'index': 1, 'start': 4, 'end': 8, 'label': None}],
            'structure_resolution': {'status': 'resolved', 'method': 'per_boundary_evidence',
                'accepted_boundary_count': 1, 'candidate_boundary_count': 3}}
        expected = {'duration_s': 8, 'duration_tolerance_s': 0.1, 'bpm': 120, 'bpm_tolerance': 1,
            'section_labels': ['Verse', None], 'section_boundaries_s': [4], 'section_boundary_tolerance_s': 0.1,
            'expect_boundary_reduction': True}
        verify.numeric_expectations(analysis, expected)
        for changed in ('bpm', 'section-time', 'duplicate-beat', 'fake-resolution'):
            candidate = copy.deepcopy(analysis)
            if changed == 'bpm':candidate['bpm'] = 90
            elif changed == 'section-time':candidate['sections'][1]['start'] = 5
            elif changed == 'duplicate-beat':candidate['beats'] = [0, 1, 1]
            else:candidate['structure_resolution']['status'] = 'unresolved'
            with self.subTest(changed=changed), self.assertRaises(ValueError):verify.numeric_expectations(candidate, expected)

    def test_data_only_workflow_cannot_schedule_app_or_compiler_for_resume(self):
        import yaml
        text = Path('.github/workflows/private-example-analysis.yml').read_text()
        jobs = yaml.safe_load(text)['jobs']
        self.assertIn("inputs.report_reuse_json == ''", jobs['analyze']['if'])
        self.assertIn("inputs.report_reuse_json == ''", jobs['build-runtime-harness']['if'])
        verifier = jobs['verify-report']
        self.assertEqual(verifier['runs-on'], 'macrunner')
        self.assertIn("inputs.report_reuse_json != ''", verifier['if'])
        commands = '\n'.join(step.get('run', '') for step in verifier['steps'])
        for forbidden in ('swift ', 'swiftc', 'xcodebuild', 'bundle.sh', '.app/Contents/MacOS/', 'ngvpack.sh'):
            self.assertNotIn(forbidden, commands)
        self.assertLess(text.index('Validate report continuation before macOS allocation'), text.index('  build-runtime-harness:'))

    def test_fresh_report_and_failed_sibling_workflow_keep_exact_native_job_and_pointer_authority(self):
        selected = {'runID': 100, 'sourceSHA': 'a' * 40, 'jobID': 101, 'reportDigest': 'sha256:' + 'b' * 64,
            'fixtureDigest': 'sha256:' + 'c' * 64, 'pointerArtifactID': 102, 'pointerArtifactSHA256': 'd' * 64}
        run = {'id': 100, 'head_sha': 'a' * 40, 'run_attempt': 1, 'status': 'in_progress', 'conclusion': '',
            'repository': {'full_name': verify.REPOSITORY}, 'actor': {'login': 'iret77'}, 'path': '.github/workflows/private-example-analysis.yml'}
        job = {'id': 101, 'run_id': 100, 'head_sha': 'a' * 40, 'run_attempt': 1, 'status': 'completed', 'conclusion': 'success',
            'labels': ['macrunner'], 'steps': [{'name': name, 'conclusion': 'success'} for name in verify.NATIVE_STEPS]}
        value = {'schema': 'private-analysis-pointer/v1', 'nativeRunID': 100, 'nativeAttempt': 1,
            'nativeHarnessSourceSHA': 'a' * 40, 'reportDigest': selected['reportDigest'], 'fixtureDigest': selected['fixtureDigest'],
            'productRunID': 90, 'productSourceSHA': 'e' * 40, 'runtimeArtifactID': 91, 'runtimeArtifactSHA256': 'f' * 64}
        env = {'GITHUB_RUN_ID': '100', 'GITHUB_JOB': 'verify-report', 'ORIGINAL_RUN': '90', 'ORIGINAL_SOURCE': 'e' * 40,
            'ORIGINAL_ARTIFACT': '91', 'ORIGINAL_DIGEST': 'f' * 64}
        for changed in ('fresh', 'failed-sibling', 'failed-native', 'wrong-pointer'):
            with self.subTest(changed=changed), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary); current_run = copy.deepcopy(run); current_job = copy.deepcopy(job)
                current_pointer = copy.deepcopy(value)
                if changed == 'failed-sibling':current_run.update(status='completed', conclusion='failure')
                elif changed == 'failed-native':current_job['conclusion'] = 'failure'
                elif changed == 'wrong-pointer':current_pointer['reportDigest'] = 'sha256:' + '9' * 64
                def download(_, target):
                    import zipfile
                    with zipfile.ZipFile(target, 'w') as archive:archive.writestr('private-analysis-pointer.json', json.dumps(current_pointer))
                with patch.dict(os.environ, env), patch.object(verify, 'api', side_effect=[current_run, {'total_count': 1, 'jobs': [current_job]}, {'size_in_bytes': 200}]), \
                        patch.object(verify, 'verify_artifact'), patch.object(verify, 'download', side_effect=download), \
                        patch.object(verify, 'checksum', return_value='d' * 64):
                    if changed in {'fresh', 'failed-sibling'}:
                        self.assertEqual(verify.native_origin(selected, root)[0], value)
                    else:
                        with self.assertRaises(ValueError):verify.native_origin(selected, root)


def private_project_fixture(root):
    from test_musicvideo_intake_evidence import intake_fixture
    from test_workspace_ui_v2_owner import TITLES
    report = root / 'report'; fixtures = root / 'fixtures';fixtures.mkdir()
    host = intake_fixture(report, lyrics_name='Lyrics.txt')
    (report / 'hostflow.json').write_text(json.dumps(host))
    song = fixtures / 'Song.wav';song.write_bytes((report / 'intake-track-source.bin').read_bytes())
    lyrics = fixtures / 'Lyrics.txt';lyrics.write_bytes(b'one line\r\nsecond line\r\n')
    def write(path, value):
        path.parent.mkdir(parents=True, exist_ok=True);path.write_text(json.dumps(value))
    project = report / 'approved-project.ngv';data = project / 'pipeline';data.mkdir(parents=True)
    write(project / 'ngv.json', {'activePlugin': 'musicvideo', 'activePluginVersion': '0.6.0', 'activePluginProjectSchema': 'musicvideo/3.0.0'})
    (data / 'project.yaml').write_text('project: Unit\n')
    (data / 'audio').mkdir();(data / 'audio/Song.wav').write_bytes(song.read_bytes())
    (data / 'audio/vocals.wav').write_bytes(b'vocals' * 50)
    alignment = [{'start': 0, 'end': 2, 'text': 'one line', 'words': [{'text': 'one', 'start': 0, 'end': 1, 'score': 0.9}]}]
    analysis = {'schema': 'analysis/v3', 'song_path': 'audio/Song.wav', 'song_sha256': verify.checksum(song),
        'duration_s': 8, 'bpm': 120, 'beats': [0, 1, 2], 'downbeats': [0, 2],
        'sections': [{'index': 0, 'start': 0, 'end': 8, 'label': None}],
        'stems': {'vocals': 'audio/vocals.wav'}, 'alignment': alignment, 'structure_resolution': {}}
    approved = copy.deepcopy(analysis);approved['sections'][0]['label'] = 'Section 1';approved['tempo_multiplier'] = 1.0
    write(report / 'analysis.json', analysis);write(report / 'approved-analysis.json', approved);write(data / 'analysis/Song.json', approved)
    measurement = {'schema': 'analysis_measurement_proof/v1', 'song_sha256': verify.checksum(song), 'project': 'Unit',
        'lyrics_alignment': {'source_path': 'audio/Song.wav', 'source_sha256': verify.checksum(song),
            'lyrics_sha256': verify.checksum(lyrics), 'alignment_sha256': 'a' * 64,
            'timing_evidence': 'known_text_alignment', 'timing_method': 'attention_dtw',
            'lyric_token_count': 1, 'matched_token_count': 1, 'marker_count': 0}}
    write(report / 'measurement-proof.json', measurement)
    gates = []
    for index, phase in enumerate(verify.PHASES):
        following = verify.PHASES[index + 1] if index < len(verify.PHASES) - 1 else 'complete'
        gates.append({'phase': phase, 'nextPhase': following, 'approvedPersisted': True, 'handoffHidden': True,
            'gatesBeforeSHA256': 'b' * 64, 'gatesAfterSHA256': 'c' * 64, 'artifactTitle': TITLES[index],
            'handoffPhase': following, 'surface': 'production', 'selectedPhaseAfter': 'render' if following == 'complete' else following,
            'controlID': 'agent.gate.approve', 'openControlID': 'agent.gate.open',
            'openedFromPhase': 'brief' if phase == 'project_init' else 'project_init',
            'blockedBeforeApproval': True, 'readyBeforeClick': True, 'blockedReason': 'Missing artifact',
            'artifactSHA256': 'd' * 64, 'packagedInstructions': following != 'complete',
            'handoffInstructionsSHA256': None if following == 'complete' else 'e' * 64,
            'handoffTurnID': f'00000000-0000-4000-8000-{index:012d}',
            'screenshots': ['hostflow-track-lyrics.png', 'hostflow-repeatable-intake.png', 'intake-location.png']})
    paths = {'script/current.v1.json': 'script/v1', 'storyboard/current.v2.yaml': 'storyboard/v2',
        'storyboard/timing-current.v1.json': 'storyboard-timing/v1', 'shot-planning/current.v1.json': 'shot-planning-draft/v1',
        'shotlist/v1.v5.yaml': 'shotlist/v5', 'render-review/current.v1.json': 'render-review/v1',
        'execution/extensions/production-plan-assembly.v1.json': 'production-plan-assembly/v1',
        'reviews/sequence/current.v2.json': 'production-sequence-review/v2', 'review/timeline-style.v2.json': 'timeline-style-review/v2'}
    for name, schema in paths.items():write(data / name, {'schema': schema})
    write(data / 'gates.yaml', {'schema': 'gates/v2', 'gates': {phase: {'approved': True, 'state': 'approved'} for phase in verify.PHASES}})
    paths['gates.yaml'] = 'gates/v2'
    hashes = {name: verify.checksum(data / name) for name in paths}
    playback = {'schema': 'playback-range/v1', 'header': {'inputs': []}, 'kind': 'fullSong',
        'analysis': {'id': 'analysis', 'role': 'musicvideo.analysis', 'path': 'analysis/Song.json', 'sha256': verify.checksum(report / 'approved-analysis.json')},
        'timebase': {'ticksPerSecond': 600, 'fpsNumerator': 30, 'fpsDenominator': 1},
        'audioDurationTicks': 4800, 'startTicks': 0, 'durationTicks': 4800}
    write(data / 'brief/playback-range.v1.json', playback)
    movie = report / 'film.mp4';movie.write_bytes(b'unit-video' * 200)
    poster = report / 'film.poster.png';poster.write_bytes((report / 'intake-location.png').read_bytes())
    delivery = dict.fromkeys(('nativeAssembly', 'nativeFullFilmReview', 'nativeStyleReview', 'nativeExportWorkspace',
        'nativeSaveDestination', 'posterSelectedRemovedRestored', 'movieAndPosterPublished', 'actualOutputQC', 'changedOutputRejected'), True)
    delivery.update(movie='film.mp4', outputSHA256=verify.checksum(movie), posterSHA256=verify.checksum(poster),
        decodedMedia={'verifiedShots': 2, 'verifiedFrames': 6, 'verifiedAudioClips': 1, 'decodedAudioSamples': 8000,
            'audioRMS': 0.2, 'audioCorrelation': 0.98, 'decodedDurationSeconds': 8})
    pointers = ['script.scene.apply', 'storyboard.edit.apply', 'storyboard.undo', 'storyboard.redo', 'animatic.play',
        'storyboard.view', 'sequence.build', 'sequence.play', 'sequence.pause', 'sequence.record', 'style.begin', 'style.record', 'export.start',
        'storyboard.native-sketch.confirm', 'render-review.record-native', 'production.assembly.build', 'sequence.whole',
        'export.artwork.frame', 'export.artwork.remove', 'export.qc.recheck']
    states = {'native Script revision': {'before': 1, 'after': 2},
        'multiple moments with native Undo and Redo': {'momentIDs': ['one', 'two']}, 'two moments within one shot': {},
        'native Shot Planning Undo and Redo': {}, 'complete native film playback': {},
        'actual exported movie and poster': {'outputSHA256': delivery['outputSHA256'], 'posterSHA256': delivery['posterSHA256']}}
    write(report / 'owner-v2-film-review.json', {'timeline': {'sha256': 'b' * 64}})
    states['actual exported movie and poster'].update(filmReviewSHA256=verify.checksum(report / 'owner-v2-film-review.json'), timelineSHA256='b' * 64)
    states.update({'two moments within one shot': {'cutUnchanged': True, 'playingWhenLeaving': True, 'stoppedAfterLeaving': True,
        'playbackDetached': True, 'stoppedTick': 1, 'endTick': 2},
        'native Shot Planning Undo and Redo': {'before': 1, 'applied': 2, 'undone': 3, 'redone': 4},
        'imported reference contract': {'requiredObligations': [], 'nativeReferenceSelectionClaim': False},
        'reference-only Frames contract': {'requiredFrameRoles': [], 'generatedFrameClaim': False, 'nativePhaseApproval': True},
        'native pre-render inspection': {'fingerprint': 'c' * 64, 'reviewEvidenceSHA256': 'd' * 64},
        'native production assembly': {'shotIDs': ['s1', 's2'], 'clipIDs': ['c1', 'c2']},
        'complete native film playback': {'firstFrame': 0, 'endFrame': 240, 'observedSeconds': 8, 'decodedSeconds': 8},
        'native timeline style': {'fingerprint': 'e' * 64, 'findingCount': 1},
        'native delivery byte changes rejected': {'changedMovieRejected': True, 'changedPosterRejected': True, 'exactRestorationReverified': True}})
    native = {'progress': 'owner-v2-musicvideo.json', 'screenshots': ['intake-location.png'],
        'interactions': [{'kind': 'pointer', 'id': name} for name in pointers]
            + [{'kind': 'verified-state', 'label': name, 'evidence': evidence} for name, evidence in states.items()]
            + [{'kind': 'save-panel', 'exactURLVerified': True}]}
    write(report / native['progress'], dict(native, schema='native-visual-source-progress/v1', failure=None))
    owner = dict.fromkeys(('allPhasesApproved', 'savedAndReopened', 'nativeScriptEdit', 'nativeMultipleMoments',
        'nativeStoryboardUndoRedo', 'nativeMomentAssignments', 'nativeAnimaticMomentChange', 'nativeShotSourceAndRange',
        'nativeShotUndoRedo', 'nativePreRenderReview'), True)
    owner.update(workflow='musicvideo', executionFixture='private_song_imported', retainedProject='approved-project.ngv', phases=verify.PHASES,
        canonicalSHA256=hashes, nativeGateApprovals=gates, delivery=delivery,
        privateSongBinding={'songSHA256': verify.checksum(song), 'analysisSHA256': verify.checksum(report / 'approved-analysis.json'),
            'playbackRangeSHA256': verify.checksum(data / 'brief/playback-range.v1.json')},
        nativeEvidence=native)
    write(report / 'owner-v2-result.json', owner)
    write(report / 'fullflow.json', {'complete': True, 'owner': owner, 'analysisLineage': {
        'measured': {'path': 'analysis.json', 'sha256': verify.checksum(report / 'analysis.json')},
        'approved': {'path': 'approved-analysis.json', 'sha256': verify.checksum(report / 'approved-analysis.json')}}})
    return report, data, analysis, song, lyrics


class PrivateProjectBytesTests(unittest.TestCase):
    def test_private_project_accepts_real_format_with_vocals_only_mix_alignment_and_supplied_labels(self):
        with tempfile.TemporaryDirectory() as temporary:
            report, data, analysis, song, lyrics = private_project_fixture(Path(temporary))
            result = verify.project_evidence(report, analysis, song, lyrics, lambda *args: 'a' * 64)
            self.assertEqual(result['executionFixture'], 'private_song_imported')

    def test_missing_canonical_changed_media_range_and_saved_project_cannot_qualify(self):
        for defect in ('song-bytes', 'project-analysis', 'canonical-file', 'export', 'playback', 'measurement-source', 'phase-order', 'missing-action', 'missing-progress'):
            with self.subTest(defect=defect), tempfile.TemporaryDirectory() as temporary:
                report, data, analysis, song, lyrics = private_project_fixture(Path(temporary))
                if defect == 'song-bytes':(data / 'audio/Song.wav').write_bytes(b'substitution')
                elif defect == 'project-analysis':(data / 'analysis/Song.json').write_bytes(b'{}')
                elif defect == 'canonical-file':(data / 'script/current.v1.json').write_bytes(b'{}')
                elif defect == 'export':(report / 'film.mp4').write_bytes(b'substitution')
                elif defect == 'playback':
                    path = data / 'brief/playback-range.v1.json';value = json.loads(path.read_text());value['startTicks'] = 1;path.write_text(json.dumps(value))
                elif defect == 'measurement-source':
                    path = report / 'measurement-proof.json';value = json.loads(path.read_text());value['lyrics_alignment']['source_sha256'] = 'b' * 64;path.write_text(json.dumps(value))
                elif defect == 'missing-progress':(report / 'owner-v2-musicvideo.json').write_text('{}')
                else:
                    for name in ('owner-v2-result.json', 'fullflow.json'):
                        path = report / name;value = json.loads(path.read_text());owner = value if name.startswith('owner') else value['owner']
                        if defect == 'phase-order':owner['phases'] = list(reversed(owner['phases']))
                        else:owner['nativeEvidence']['interactions'] = []
                        path.write_text(json.dumps(value))
                with self.assertRaises(ValueError):verify.project_evidence(report, analysis, song, lyrics, lambda *args: 'a' * 64)


class RuntimeHashDomainsTests(unittest.TestCase):
    def test_original_tar_receipt_and_outer_artifact_have_distinct_hash_domains(self):
        bound = {'productSourceSHA': 'a' * 40, 'producerRunID': 1, 'producerAttempt': 1, 'producerJobID': 2,
            'runtimeArtifactID': 3, 'runtimeArtifactSHA256': 'b' * 64}
        identity = {'nativeRunID': 4, 'nativeHarnessSourceSHA': 'c' * 40}
        runtime = dict(bound, schema='nexgenvideo/retained-release-runtime/1', executionRunID='4', executionAttempt='1',
            harnessSourceSHA='c' * 40, archiveSHA256='d' * 64, appTreeSHA256='e' * 64, executableSHA256='f' * 64, runtimeInputSHA256='1' * 64)
        verify.runtime_binding(runtime, bound, identity)
        for key, value in [('runtimeArtifactSHA256', 'd' * 64), ('archiveSHA256', None), ('producerJobID', 99), ('harnessSourceSHA', 'e' * 40)]:
            with self.subTest(key=key), self.assertRaises(ValueError):verify.runtime_binding(dict(runtime, **{key: value}), bound, identity)
