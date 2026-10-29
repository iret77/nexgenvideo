import array
import copy
import hashlib
import json
import math
from pathlib import Path
import tempfile
import unittest

from layered_timeline_evidence import layered_timeline_evidence


def fixture(root):
    # Synthetic decoder/validator shapes are not native UI or codec evidence.
    directory = root / 'layered-timeline-150'; package = directory / 'Layered film.ngv'
    (package / 'media').mkdir(parents=True)
    def write(name, value):
        (directory / (name + '.json')).write_text(json.dumps(value))
    def clip(key, media, kind, duration):
        return {'id': key, 'mediaRef': media, 'mediaType': kind, 'durationFrames': duration, 'startFrame': 0,
                'trimStartFrame': 0, 'trimEndFrame': 0, 'speed': 1, 'opacity': 1,
                'transform': {'centerX': .5, 'centerY': .5, 'width': 1, 'height': 1}}
    sources = []; entries = []; clips = []
    filenames = ['Bouncing dot.lottie', 'Green corner.png', 'Yellow corner.png', 'Moving background.mov', 'Original sound.wav']
    for index, (filename, kind) in enumerate(zip(filenames, ('lottie', 'image', 'image', 'video', 'audio'))):
        data = ('synthetic validator source ' + filename).encode() * 40
        (directory / filename).write_bytes(data); (package / 'media' / filename).write_bytes(data)
        key = 'media-' + str(index)
        sources.append({'file': filename, 'id': key, 'type': kind, 'sha256': hashlib.sha256(data).hexdigest()})
        entries.append({'id': key, 'source': {'project': {'relativePath': 'media/' + filename}}})
        clips.append(clip('clip-' + str(index), key, kind, 60 if index == 0 else 150))
    title_ids = ['one', 'two']
    titles = []
    for key, text, y in [('two', 'TWO', 42), ('one', 'ONE', 8)]:
        title = clip(key, '', 'text', 90)
        title.update(textContent=text, textStyle={'fontSize': 144, 'shadow': {'enabled': False}})
        title['transform'] = {'centerX': 38 / 320, 'centerY': (y + 15) / 180, 'width': 60 / 320, 'height': 30 / 180}
        titles.append(title)
    tracks = [{'id': 'track-' + str(i), 'type': 'audio' if i == 6 else 'video',
               'muted': False, 'hidden': False, 'syncLocked': True, 'clips': [c]} for i, c in enumerate(titles + clips)]
    base = {'width': 320, 'height': 180, 'fps': 30, 'tracks': tracks}
    write('layered', base)
    reordered = copy.deepcopy(base); reordered['tracks'][3], reordered['tracks'][4] = reordered['tracks'][4], reordered['tracks'][3]
    write('reordered', reordered)
    removed = copy.deepcopy(base); removed['tracks'].pop(4); write('removed', removed)
    flagged = copy.deepcopy(base); flagged['tracks'][2]['hidden'] = True; flagged['tracks'][6]['muted'] = True; flagged['tracks'][3]['syncLocked'] = False
    write('flags', flagged)
    final = copy.deepcopy(base); final['tracks'][3]['syncLocked'] = False; write('final', final)
    (package / 'project.json').write_text(json.dumps(final)); (package / 'media.json').write_text(json.dumps({'entries': entries}))
    (package / 'editor-state.json').write_text(json.dumps({'schema': 1, 'trackHeights': {t['id']: 74 if i == 2 else 50 for i, t in enumerate(tracks)}}))
    movie = b'synthetic validator movie'; (directory / 'Layered film.mp4').write_bytes(movie)
    write('decoded', {'duration': 5, 'frames': [i / 30 for i in range(150)], 'audioStart': 0, 'audioSamples': 240000, 'sourceSamples': 240000})
    def rect(image, x0, y0, x1, y1, pixel):
        row = bytes(pixel) * (x1 - x0)
        for y in range(y0, y1):
            offset = (y * 320 + x0) * 4; image[offset:offset + len(row)] = row
    with (directory / 'decoded.bgra').open('wb') as output:
        for frame in range(150):
            image = bytearray(bytes((13, 51, 217, 255)) * (320 * 180))
            rect(image, 240, 0, 320, 45, (0, 255, 0, 255)); rect(image, 0, 135, 80, 180, (0, 255, 255, 255))
            x = round(80 + 120 * frame / 149); rect(image, x, 65, x + 50, 115, (255, 255, 255, 255))
            if frame < 90:
                rect(image, 8, 12, 60, 24, (255, 255, 255, 255)); rect(image, 8, 46, 60, 58, (255, 255, 255, 255))
            if frame < 60:
                center = 110 if frame != 30 else 209; radius = 15 if frame != 30 else 40
                for y in range(90 - radius, 90 + radius):
                    for x in range(center - radius, center + radius):
                        if (x - center) ** 2 + (y - 90) ** 2 < radius ** 2:
                            offset = (y * 320 + x) * 4; image[offset:offset + 4] = bytes((220, 100, 80, 255))
            output.write(image)
    pcm = array.array('f', (.02 * math.sin(2 * math.pi * 173 * i / 48000) for i in range(240000))).tobytes()
    (directory / 'source.f32').write_bytes(pcm); (directory / 'decoded.f32').write_bytes(pcm)
    actions = [{'kind': 'pointer', 'id': prefix + source['id']} for source in sources for prefix in ('source.overwrite.', 'media.asset.')]
    actions += [{'kind': 'pointer', 'id': 'editing.add-text'}] * 2 + [{'kind': 'pointer', 'id': 'export.start'}]
    actions += [{'kind': 'file-panel', 'path': f, 'selectedURLVerified': True, 'nativePathEditorVerified': True} for f in filenames]
    actions.append({'kind': 'save-panel', 'filename': 'Layered film.mp4', 'exactURLVerified': True, 'nativeDirectoryAndFilenameTyped': True})
    for field, value in [('text.content', 'ONE'), ('inspector.value.Text size', '144'), ('inspector.value.Position X', '8'), ('inspector.value.Position Y', '8'),
                         ('text.content', 'TWO'), ('inspector.value.Text size', '144'), ('inspector.value.Position X', '8'), ('inspector.value.Position Y', '42')]:
        actions.append({'kind': 'text', 'field': {'id': field, 'expected': value, 'actual': value, 'focusLeftTarget': True}})
    actions += [{'kind': 'verified-state', 'label': 'native-clip-menu', 'evidence': {'item': item}} for item in ('Move Track Down', 'Remove Track V5 and 1 Clip')]
    for label, count in [('layered.hidden', 2), ('layered.muted', 2), ('layered.syncLocked', 1), ('layered.track-height', 1)]:
        actions += [{'kind': 'verified-state', 'label': 'native-drag' if label.endswith('height') else 'native-pointer', 'evidence': {'target': label}} for _ in range(count)]
    for code, modifiers, count in ((6, 1048576, 5), (6, 1179648, 3), (1, 1048576, 2)):
        actions += [{'kind': 'keyboard', 'code': code, 'modifiers': modifiers} for _ in range(count)]
    actions.append({'kind': 'verified-state', 'label': 'layered film independently decoded', 'evidence': {
        'filmHashBeforeResize': 'a' * 64, 'filmHashAfterResize': 'a' * 64, 'trackHeightBefore': 50, 'trackHeightAfter': 74}})
    labels = ['file-selected'] * 5 + ['import-candidates', 'title-one', 'title-two', 'track-reordered', 'track-removed', 'hidden-lottie',
              'track-flags-height', 'reopened-flags-height', 'layered-film-preview', 'export-settings', 'save-selected', 'export-verified', 'saved-final']
    screenshots = [directory.name + '-' + str(i) + '-' + label + '.png' for i, label in enumerate(labels)]
    for name in screenshots:
        (root / name).write_bytes(b'\x89PNG\r\n\x1a\nsynthetic validator pixels')
    record = {'event': 'layered-timeline-owner', 'scale': 1.5, 'effectiveScale': 1.5, 'viewport': [960, 640], 'height': 74,
              'directory': directory.name, 'project': package.name, 'sources': sources, 'titleIDs': title_ids,
              'trackIDs': [t['id'] for t in tracks[2:]], 'movie': 'Layered film.mp4', 'outputSHA256': hashlib.sha256(movie).hexdigest(),
              'interactions': actions, 'screenshots': screenshots}
    return [record, {'event': 'completed', 'case': 'layeredtimeline', 'scale': 1.5}], directory, package


class LayeredTimelineEvidenceTests(unittest.TestCase):
    def test_complete_shape_and_required_native_actions(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); rows, _, _ = fixture(root)
            self.assertTrue(layered_timeline_evidence(rows, root, 1.5)[0])
            for index in range(len(rows[0]['interactions'])):
                changed = copy.deepcopy(rows); changed[0]['interactions'].pop(index)
                self.assertFalse(layered_timeline_evidence(changed, root, 1.5)[0], index)
            for key, value in [('viewport', [1440, 960]), ('effectiveScale', 1), ('height', float('nan')), ('screenshots', [])]:
                changed = copy.deepcopy(rows); changed[0][key] = value
                self.assertFalse(layered_timeline_evidence(changed, root, 1.5)[0], key)

    def test_frozen_lottie_missing_layers_and_stale_end_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); rows, directory, _ = fixture(root)
            path = directory / 'decoded.bgra'; original = path.read_bytes(); size = 320 * 180 * 4
            for target in (30, 60, 90):
                changed = bytearray(original); changed[target * size:(target + 1) * size] = original[:size]
                path.write_bytes(changed)
                self.assertFalse(layered_timeline_evidence(rows, root, 1.5)[0], target)
            changed = bytearray(original)
            for x, y in ((275, 20), (30, 155), (300, 155)):
                offset = (y * 320 + x) * 4; saved = changed[offset:offset + 4]; changed[offset:offset + 4] = bytes((0, 0, 0, 255))
                path.write_bytes(changed); self.assertFalse(layered_timeline_evidence(rows, root, 1.5)[0]); changed[offset:offset + 4] = saved
            path.write_bytes(original[:-size]); self.assertFalse(layered_timeline_evidence(rows, root, 1.5)[0])

    def test_muted_or_replaced_sound_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); rows, directory, _ = fixture(root)
            path = directory / 'decoded.f32'
            for pcm in (bytes(240000 * 4), array.array('f', (.1 * math.sin(2 * math.pi * 440 * i / 48000) for i in range(240000))).tobytes()):
                path.write_bytes(pcm); self.assertFalse(layered_timeline_evidence(rows, root, 1.5)[0])

    def test_changed_project_or_lost_display_state_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); rows, directory, package = fixture(root)
            for file in ('project.json', 'editor-state.json'):
                path = package / file; original = path.read_text(); value = json.loads(original)
                if file == 'project.json':
                    value['tracks'][3]['syncLocked'] = True
                else:
                    value['trackHeights']['track-2'] = 50
                path.write_text(json.dumps(value)); self.assertFalse(layered_timeline_evidence(rows, root, 1.5)[0]); path.write_text(original)
            source = package / 'media/Green corner.png'; source.write_bytes(b'replaced')
            self.assertFalse(layered_timeline_evidence(rows, root, 1.5)[0])
