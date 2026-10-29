import array
import copy
import hashlib
import json
import math
from pathlib import Path
import struct
import tempfile
import unittest

from export_owner_evidence import check_job, decode_proof, restart_processes, preparation_evidence


class ExportEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        # These synthetic validator shapes do not claim native export or decoder evidence.
        self.filename = 'synthetic.mp4'
        output = b'synthetic codec placeholder'
        (self.root / self.filename).write_bytes(output)
        samples = array.array('f', [.1 * math.sin(i * .071 + i * i * .00000023) for i in range(96000)])
        data = b''.join(struct.pack('<f', x) for x in samples)
        fmt = struct.pack('<HHIIHH', 3, 1, 48000, 192000, 4, 32)
        body = b'WAVEfmt ' + struct.pack('<I', len(fmt)) + fmt + b'data' + struct.pack('<I', len(data)) + data
        (self.root / 'Original sound.wav').write_bytes(b'RIFF' + struct.pack('<I', len(body)) + body)
        (self.root / 'decoded.f32').write_bytes(data)
        frames = []
        for index in range(48):
            line = [13, 51, 217] * 320
            start = round(80 + 120 * index / 47)
            line[start * 3:(start + 50) * 3] = [255, 255, 255] * 50
            frames.append({'value': index, 'timescale': 24, 'width': 720, 'height': 1280,
                'pixelSHA256': hashlib.sha256(bytes(line)).hexdigest(), 'centerLine': line})
        self.proof = {'filename': self.filename, 'sha256': hashlib.sha256(output).hexdigest(), 'codec': 'avc1',
            'width': 720, 'height': 1280, 'fps': 24, 'duration': 2, 'frames': frames, 'audioStart': 0,
            'audioSamples': 96000, 'audioFile': 'decoded.f32', 'audioSHA256': hashlib.sha256(data).hexdigest()}
        spec = {'target_kind': 'master', 'width': 720, 'height': 1280, 'fps_numerator': 24, 'fps_denominator': 1}
        qc = {'passed': True, 'width': 720, 'height': 1280, 'fps_numerator': 24, 'fps_denominator': 1,
            'audio_codec': 'aac ', 'audio_channels': 1, 'duration_value': 48, 'duration_timescale': 24}
        self.job = {'id': 'one', 'status': 'completed', 'kind': 'video', 'output': self.filename,
            'outputSHA256': self.proof['sha256'], 'attempt': {'id': 'one', 'status': 'succeeded',
            'output_sha256': self.proof['sha256'], 'spec': spec, 'probe_qc': qc}}

    def preparation_fixture(self):
        actions, screenshots, observations = [], [], []
        def record(label, evidence):
            actions.append({'kind': 'verified-state', 'label': label, 'evidence': copy.deepcopy(evidence)})
        def image(label):
            name = 'synthetic-' + label + '.png'; screenshots.append(name)
            (self.root / name).write_bytes(b'\x89PNG\r\n\x1a\n' + b'synthetic parser fixture' * 64)
        def put(name, value):
            raw = json.dumps(value, sort_keys=True).encode(); (self.root / name).write_bytes(raw)
            return hashlib.sha256(raw).hexdigest()
        def source(variant, moment, changed):
            timeline = {'tracks': [{'clips': [{'id': 'picture', 'transform': {'flipHorizontal': changed == 'timeline'}}]}]}
            manifest = {'entries': [{'id': 'picture'}, {'id': 'sound'}] + ([{'id': 'new'}] if changed == 'manifest' else [])}
            values = {'timeline': timeline, 'manifest': manifest, 'metadata': {'project': 'new' if changed == 'metadata' else 'original'}}
            return {field: put('preparation-' + variant + '-' + moment + '-' + field + '.json', value) for field, value in values.items()}
        record('preparation destination before second Export', {'panel': 7, 'keyEquivalent': 'e', 'modifiers': 1 << 20, 'menuEnabled': False})
        actions.append({'kind': 'keyboard', 'code': 14, 'characters': 'e', 'modifiers': 1 << 20, 'window': 7})
        record('preparation native key delivered', {'code': 14, 'window': 7})
        record('preparation destination single panel', {'firstPanel': 7, 'afterSecondExportPanel': 7, 'count': 1, 'startEnabled': False, 'savePanelIDs': [7], 'showExportDialog': False, 'ownerHasAttachedSheet': False, 'runLoopCheckpoint': True})
        image('destination-owner-disabled'); image('destination-first-panel')
        for index, variant in enumerate(['cancel', 'timeline', 'manifest', 'metadata']):
            before = source(variant, 'before', None); current = source(variant, 'current', None if variant == 'cancel' else variant)
            retry_source = source(variant, 'retry-source', variant if variant in ('timeline', 'manifest') else None)
            record('preparation held ' + variant, {'preparing': 'Preparing export…', 'startEnabled': False, 'jobIDs': ['old']})
            if variant == 'cancel':
                actions.append({'kind': 'pointer', 'id': 'export.cancel-preparation'}); image('cancelling-preparation')
            elif variant == 'timeline': actions.append({'kind': 'pointer', 'id': 'inspector.transform.arrow.left.and.right'})
            elif variant == 'manifest': record('application-menu', {'path': ['File', 'Import Media…']})
            else:
                old_identity = put('preparation-metadata-identity-before.json', {'id': 'original'})
                new_identity = put('preparation-metadata-identity-current.json', {'id': 'new'})
                record('controlled metadata source mutation', {'nativeMetadataUI': False, 'originalSHA256': old_identity, 'changedSHA256': new_identity})
            output = 'preparation-' + variant + '.mp4'; retry = 'preparation-' + variant + '-retry.mp4'
            for filename in (output, retry): actions.append({'kind': 'save-panel', 'filename': filename, 'exactURLVerified': True, 'nativeDirectoryAndFilenameTyped': True})
            (self.root / retry).write_bytes(b'synthetic retry ' + variant.encode())
            job = copy.deepcopy(self.job); job['id'] = 'retry-' + str(index); job['output'] = retry; job['outputSHA256'] = hashlib.sha256((self.root / retry).read_bytes()).hexdigest()
            job['attempt']['id'] = job['id']; job['attempt']['output_sha256'] = job['outputSHA256']
            job['attempt']['finished_timeline_sha256'] = retry_source['timeline']
            for scope in ('spec', 'probe_qc'): job['attempt'][scope].update(width=180, height=320)
            put('preparation-' + variant + '-retry-job.json', job)
            put('preparation-' + variant + '-finished.json', {'timeline_sha256': retry_source['timeline']})
            record('actual loaded export QC', {'jobID': job['id'], 'attemptID': job['id'], 'completed': True})
            row = {'variant': variant, 'before': before, 'current': current, 'retrySource': retry_source,
                'output': output, 'outputExists': False, 'jobsBefore': ['old'], 'jobsAfter': ['old'], 'deliveryBefore': {'old': 'a' * 64},
                'deliveryAfter': {'old': 'a' * 64}, 'barrierExited': True, 'error': None if variant == 'cancel' else 'The project changed while preparing the export. Prepare the export again from the current edit.',
                'result': 'Export cancelled.' if variant == 'cancel' else None, 'retryOutput': retry, 'retryJobID': job['id'], 'retrySHA256': job['outputSHA256']}
            image('preparing-' + variant); image('preparation-finished-' + variant)
            record('preparation observation ' + variant, row); observations.append(row)
        return {'observations': observations, 'destinationPanelID': 7, 'nativeMetadataUI': False}, actions, screenshots

    def test_preparation_required_independent_source_and_retry_shape(self):
        result, actions, images = self.preparation_fixture()
        preparation_evidence(self.root, result, actions, images)

    def test_missing_preparation_subpath_or_image_is_rejected(self):
        for missing in ('subpath', 'image', 'delivery'):
            result, actions, images = self.preparation_fixture()
            if missing == 'subpath': result['observations'].pop()
            elif missing == 'image': images.remove('synthetic-cancelling-preparation.png')
            else: actions[:] = [row for row in actions if row.get('label') != 'preparation native key delivered']
            with self.assertRaises(ValueError): preparation_evidence(self.root, result, actions, images)

    def test_wrong_source_dimension_or_retry_revision_is_rejected(self):
        for fault in ('dimension', 'retry', 'late-output'):
            result, actions, images = self.preparation_fixture()
            if fault == 'dimension':
                row = result['observations'][1]
                for field in row['before']:
                    (self.root / ('preparation-timeline-current-' + field + '.json')).write_bytes(
                        (self.root / ('preparation-timeline-before-' + field + '.json')).read_bytes())
                row['current'] = dict(row['before'])
                next(action for action in actions if action.get('label') == 'preparation observation timeline')['evidence'] = copy.deepcopy(row)
            elif fault == 'retry': (self.root / 'preparation-timeline-finished.json').write_text(json.dumps({'timeline_sha256': '0' * 64}))
            else: (self.root / 'preparation-cancel.mp4').write_bytes(b'late publication')
            with self.assertRaisesRegex(ValueError, 'Wrong independent source dimension' if fault == 'dimension' else 'Retry finished-film receipt|Rejected preparation published'):
                preparation_evidence(self.root, result, actions, images)

    def test_second_export_deferred_state_is_required(self):
        for field, value in [('showExportDialog', True), ('ownerHasAttachedSheet', True), ('runLoopCheckpoint', False), ('savePanelIDs', [7, 8]), ('startEnabled', True)]:
            with self.subTest(field=field):
                result, actions, images = self.preparation_fixture()
                next(action for action in actions if action.get('label') == 'preparation destination single panel')['evidence'][field] = value
                with self.assertRaises(ValueError): preparation_evidence(self.root, result, actions, images)

    def decode(self):
        (self.root / 'decoded.json').write_text(json.dumps(self.proof))
        return decode_proof(self.root, 'decoded', self.filename, 'avc1', 720, 1280, 48)

    def job_check(self):
        (self.root / 'one-job.json').write_text(json.dumps(self.job))
        return check_job(self.root, 'one', 'master', 720, 1280, 48, self.filename)

    def test_complete_shape(self):
        self.assertEqual(len(self.decode()['frames']), 48)
        self.assertEqual(self.job_check()['id'], 'one')

    def test_wrong_codec_or_portrait_dimensions(self):
        for field, value in [('codec', 'hvc1'), ('width', 1280), ('height', 720), ('fps', 30)]:
            with self.subTest(field=field):
                old = self.proof[field]; self.proof[field] = value
                with self.assertRaises(ValueError): self.decode()
                self.proof[field] = old

    def test_retimed_or_repeated_pixels(self):
        original = copy.deepcopy(self.proof)
        self.proof['frames'][20]['value'] = 19
        with self.assertRaises(ValueError): self.decode()
        self.proof = copy.deepcopy(original)
        self.proof['frames'][20]['centerLine'] = self.proof['frames'][0]['centerLine']
        with self.assertRaises(ValueError): self.decode()
        self.proof = copy.deepcopy(original)
        for frame in self.proof['frames']: frame['pixelSHA256'] = '0' * 64
        with self.assertRaises(ValueError): self.decode()

    def test_silent_sound_with_matching_file_hash_is_rejected(self):
        audio = b'\0' * (96000 * 4)
        (self.root / 'decoded.f32').write_bytes(audio)
        self.proof['audioSHA256'] = hashlib.sha256(audio).hexdigest()
        with self.assertRaises(ValueError): self.decode()

    def test_replaced_movie(self):
        (self.root / self.filename).write_bytes(b'different movie')
        with self.assertRaises(ValueError): self.decode()
        with self.assertRaises(ValueError): self.job_check()

    def test_wrong_target_or_qc(self):
        self.job['attempt']['spec']['target_kind'] = 'derivative'
        with self.assertRaises(ValueError): self.job_check()
        self.job['attempt']['spec']['target_kind'] = 'master'
        self.job['attempt']['probe_qc']['passed'] = False
        with self.assertRaises(ValueError): self.job_check()


class ExportRestartProtocolTests(unittest.TestCase):
    def setUp(self):
        self.processes = [{'stage': 'prepare', 'scale': 1.5, 'processID': 101, 'exitCode': -9, 'observedSIGSTOP': True},
            {'stage': 'resume', 'scale': 1.5, 'processID': 102, 'exitCode': 0, 'observedSIGSTOP': False}]
        self.state = {'processID': 101, 'progress': .2}
        self.row = {'processID': 102}

    def valid(self):
        return restart_processes(self.processes, self.state, self.row, 1.5)

    def test_actual_two_process_protocol_shape(self):
        self.assertTrue(self.valid())

    def test_normal_exit_does_not_prove_interruption(self):
        self.processes[0]['exitCode'] = 0
        self.assertFalse(self.valid())

    def test_kill_without_observed_own_stop_is_not_proof(self):
        self.processes[0]['observedSIGSTOP'] = False
        self.assertFalse(self.valid())

    def test_wrong_or_same_process_is_rejected(self):
        self.state['processID'] = 400
        self.assertFalse(self.valid())
        self.state['processID'] = 101; self.processes[1]['processID'] = 101; self.row['processID'] = 101
        self.assertFalse(self.valid())

    def test_already_completed_or_unknown_progress_is_rejected(self):
        for value in (0, 1, float('nan'), True):
            with self.subTest(value=value):
                self.state['progress'] = value
                self.assertFalse(self.valid())


class InterchangeEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(); self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / 'Export source.ngv/media').mkdir(parents=True)
        video = self.root / 'Export source.ngv/media/Moving source.mov'
        sound = self.root / 'Original sound.wav'
        video.write_bytes(b'synthetic interchange video'); sound.write_bytes(b'synthetic interchange audio')
        self.media = [video, sound]
        self.hashes = [hashlib.sha256(p.read_bytes()).hexdigest() for p in self.media]
        self.originals = dict(zip((p.resolve() for p in self.media), self.hashes))
        self.video_outputs = {}
        for stem in ('handoff', 'handoff-1.10', 'handoff-1.14'):
            identity = hashlib.sha256(b'project:/media/Moving source.mov').hexdigest()[:8]
            copy = self.root / (stem + ' Media') / ('Moving source--' + identity + '-' + self.hashes[0][:8] + '.mov')
            copy.parent.mkdir(); copy.write_bytes(video.read_bytes()); self.video_outputs[stem] = copy
        from export_owner_evidence import XML_WARNING
        xml = '<xmeml><sequence><media>'
        for role, clip, ref, path in [('video', 'picture', 'export-picture', self.video_outputs['handoff']), ('audio', 'sound', 'export-sound', sound)]:
            xml += '<' + role + '><track><clipitem id="clipitem-' + clip + '"><start>0</start><end>48</end><file id="file-' + ref + '-' + role + '"><pathurl>'
            xml += path.as_uri().replace('file://', 'file://localhost//') + '</pathurl></file></clipitem></track></' + role + '>'
        xml += '</media></sequence></xmeml>'
        (self.root / 'handoff.xml').write_text(xml)
        self.write('xmeml-job', {'status': 'completed', 'outputSHA256': hashlib.sha256(xml.encode()).hexdigest(), 'warnings': [XML_WARNING]})
        for version, target in [('1.10', 'final-cut-pro'), ('1.14', 'resolve')]:
            paths = [self.video_outputs['handoff-' + version], sound]
            body = '<fcpxml version="' + version + '"><resources><format frameDuration="1/24s" width="180" height="320"/>'
            body += ''.join('<asset id="' + ref + '" ' + capability + '="1"><media-rep kind="original-media" src="' + path.as_uri() + '"/></asset>'
                for ref, capability, path in [('picture-asset', 'hasVideo', paths[0]), ('sound-asset', 'hasAudio', paths[1])])
            body += '</resources><library><event><project><sequence duration="2s"><spine><gap>'
            body += ''.join('<asset-clip ref="' + ref + '" lane="' + lane + '" enabled="1" offset="0s" start="0s" duration="2s"/>'
                for ref, lane in [('picture-asset', '1'), ('sound-asset', '-1')])
            body += '</gap></spine></sequence></project></event></library></fcpxml>'
            (self.root / ('handoff-' + version + '.fcpxml')).write_text(body)
            self.write('handoff-' + version + '-job', {'status': 'completed', 'fcpxml': {'version': version, 'target': target,
                'outputSHA256': hashlib.sha256(body.encode()).hexdigest(), 'validation': {'schemaProfile': 'apple/fcpxml-dtd/' + version},
                'mediaBindings': [{'sourceURL': path.as_uri(), 'mediaSHA256': digest, 'assetID': asset, 'mediaRef': ref,
                    'mediaRefs': [ref], 'stagedProjectMedia': ref == 'export-picture'}
                    for path, digest, asset, ref in zip(paths, self.hashes, ['picture-asset', 'sound-asset'], ['export-picture', 'export-sound'])]}})

    def write(self, name, value):
        (self.root / (name + '.json')).write_text(json.dumps(value))

    def check(self):
        from export_owner_evidence import interchange
        interchange(self.root)

    def test_synthetic_shape(self):
        self.check()

    def test_actual_media_replacement_invalidates_receipt(self):
        self.media[0].write_bytes(b'changed')
        with self.assertRaises((ValueError, OSError)): self.check()

    def test_published_companion_bytes_cannot_change(self):
        self.video_outputs['handoff'].write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'companion'): self.check()

    def test_other_exports_companion_is_not_this_exports_source(self):
        output = self.root / 'handoff.xml'
        old = self.video_outputs['handoff'].as_uri().replace('file://', 'file://localhost//')
        output.write_text(output.read_text().replace(old, self.video_outputs['handoff-1.10'].as_uri()))
        report = json.loads((self.root / 'xmeml-job.json').read_text())
        report['outputSHA256'] = hashlib.sha256(output.read_bytes()).hexdigest(); self.write('xmeml-job', report)
        with self.assertRaises(ValueError): self.check()

    def test_xml_picture_and_sound_cannot_swap_original_urls(self):
        output = self.root / 'handoff.xml'
        video, sound = [p.as_uri().replace('file://', 'file://localhost//') for p in [self.video_outputs['handoff'], self.media[1]]]
        output.write_text(output.read_text().replace(video, '__picture__').replace(sound, video).replace('__picture__', sound))
        report = json.loads((self.root / 'xmeml-job.json').read_text())
        report['outputSHA256'] = hashlib.sha256(output.read_bytes()).hexdigest(); self.write('xmeml-job', report)
        with self.assertRaisesRegex(ValueError, 'wrong original media'): self.check()

    def test_fcpxml_clips_cannot_swap_or_drop_exact_source_timing(self):
        for version in ('1.10', '1.14'):
            name = 'handoff-' + version; output = self.root / (name + '.fcpxml')
            original = output.read_text(); original_report = (self.root / (name + '-job.json')).read_text()
            swapped = original.replace('ref="picture-asset"', 'ref="__picture__"').replace('ref="sound-asset"', 'ref="picture-asset"').replace('ref="__picture__"', 'ref="sound-asset"')
            for mutation in [swapped, original.replace(' start="0s"', '', 1)]:
                with self.subTest(version=version, mutation=mutation):
                    output.write_text(mutation); report = json.loads(original_report)
                    report['fcpxml']['outputSHA256'] = hashlib.sha256(output.read_bytes()).hexdigest(); self.write(name + '-job', report)
                    with self.assertRaises(ValueError): self.check()
                    output.write_text(original); (self.root / (name + '-job.json')).write_text(original_report)

    def test_xml_warning_cannot_disappear(self):
        path = self.root / 'xmeml-job.json'; value = json.loads(path.read_text()); value['warnings'] = []
        path.write_text(json.dumps(value))
        with self.assertRaises(ValueError): self.check()

    def test_wrong_fcpxml_profile_is_not_validated(self):
        path = self.root / 'handoff-1.14-job.json'; value = json.loads(path.read_text())
        value['fcpxml']['validation']['schemaProfile'] = 'apple/fcpxml-dtd/1.10'; path.write_text(json.dumps(value))
        with self.assertRaises(ValueError): self.check()

    def test_disposable_export_source_is_rejected_even_with_same_bytes(self):
        from export_owner_evidence import media_reference
        temporary = self.root / 'NexGenVideoExportQueue/job'; temporary.mkdir(parents=True)
        video = temporary / 'source.mov'; video.write_bytes(self.media[0].read_bytes())
        with self.assertRaises(ValueError): media_reference(video.as_uri(), self.root, self.originals)

    def test_arbitrary_external_copy_is_not_durable_original_media(self):
        from export_owner_evidence import media_reference
        with tempfile.TemporaryDirectory() as other:
            copied = Path(other) / 'Identical source.mov'
            copied.write_bytes(self.media[0].read_bytes())
            with self.assertRaises(ValueError):
                media_reference(copied.as_uri(), self.root, self.originals)
            alias = self.root / 'linked-outside.mov'
            alias.symlink_to(copied)
            with self.assertRaises(ValueError):
                media_reference(alias.as_uri(), self.root, self.originals)

    def test_identical_recovery_copy_is_not_the_original_even_with_updated_receipt(self):
        copied = self.root / 'Recovery/source.mov'; copied.parent.mkdir()
        copied.write_bytes(self.media[0].read_bytes())
        output = self.root / 'handoff.xml'
        output.write_text(output.read_text().replace(self.video_outputs['handoff'].as_uri().replace('file://', 'file://localhost//'), copied.as_uri()))
        report = self.root / 'xmeml-job.json'; value = json.loads(report.read_text())
        value['outputSHA256'] = hashlib.sha256(output.read_bytes()).hexdigest()
        report.write_text(json.dumps(value))
        with self.assertRaises(ValueError): self.check()

    def test_in_root_parent_alias_is_not_a_retained_media_url(self):
        from export_owner_evidence import media_reference
        alias = self.root / 'Temporary alias'; alias.symlink_to(self.media[0].parent, target_is_directory=True)
        with self.assertRaises(ValueError):
            media_reference((alias / self.media[0].name).as_uri(), self.root, self.originals)

    def test_original_anchor_cannot_alias_an_in_root_recovery_package(self):
        package = self.root / 'Export source.ngv'
        recovery = self.root / 'Recovery/package'; recovery.parent.mkdir()
        package.rename(recovery)
        package.symlink_to(recovery, target_is_directory=True)
        old_url = self.media[0].as_uri()
        new_url = (recovery / 'media/Moving source.mov').as_uri()
        xml = self.root / 'handoff.xml'
        xml.write_text(xml.read_text().replace(old_url, new_url))
        report = json.loads((self.root / 'xmeml-job.json').read_text())
        report['outputSHA256'] = hashlib.sha256(xml.read_bytes()).hexdigest()
        self.write('xmeml-job', report)
        for version in ('1.10', '1.14'):
            name = 'handoff-' + version
            output = self.root / (name + '.fcpxml')
            output.write_text(output.read_text().replace(old_url, new_url))
            report = json.loads((self.root / (name + '-job.json')).read_text())
            report['fcpxml']['outputSHA256'] = hashlib.sha256(output.read_bytes()).hexdigest()
            for binding in report['fcpxml']['mediaBindings']:
                if binding['sourceURL'] == old_url: binding['sourceURL'] = new_url
            self.write(name + '-job', report)
        with self.assertRaisesRegex(ValueError, 'directory alias'): self.check()

    def test_parent_traversal_is_not_a_literal_original_media_url(self):
        from export_owner_evidence import media_reference
        (self.root / 'Recovery').mkdir()
        alias = self.root / 'Recovery/../Original sound.wav'
        with self.assertRaises(ValueError): media_reference(alias.as_uri(), self.root, self.originals)

    def test_fcpxml_bindings_must_cover_both_actual_originals(self):
        for version in ('1.10', '1.14'):
            name = 'handoff-' + version + '-job'
            original = (self.root / (name + '.json')).read_text()
            report = json.loads(original)
            report['fcpxml']['mediaBindings'][1] = dict(report['fcpxml']['mediaBindings'][0])
            self.write(name, report)
            with self.subTest(version=version), self.assertRaisesRegex(ValueError, 'omits an original source'):
                self.check()
            (self.root / (name + '.json')).write_text(original)

    def test_relative_file_url_is_not_a_retained_media_url(self):
        from export_owner_evidence import media_reference
        with self.assertRaises(ValueError):
            media_reference('file:Original%20sound.wav', self.root, self.originals)

    def test_symlinked_parent_cannot_escape_the_evidence_root(self):
        from export_owner_evidence import media_reference
        with tempfile.TemporaryDirectory() as other:
            copied = Path(other) / 'Identical source.mov'
            copied.write_bytes(self.media[0].read_bytes())
            alias = self.root / 'outside'
            alias.symlink_to(Path(other), target_is_directory=True)
            with self.assertRaises(ValueError):
                media_reference((alias / copied.name).as_uri(), self.root, self.originals)


class NativeQCBindingTests(unittest.TestCase):
    def test_old_passed_qc_is_not_the_new_job(self):
        from export_owner_evidence import native_qc
        action = {'kind': 'verified-state', 'label': 'actual loaded export QC',
            'evidence': {'jobID': 'new', 'attemptID': 'old', 'completed': True}}
        self.assertFalse(native_qc([action], 'new'))
        action['evidence']['attemptID'] = 'new'
        self.assertTrue(native_qc([action], 'new'))
        action['evidence']['completed'] = False
        self.assertFalse(native_qc([action], 'new'))
