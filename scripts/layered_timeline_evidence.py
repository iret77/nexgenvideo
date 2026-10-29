import array
import copy
import hashlib
import json
import math
from pathlib import Path


def local(root, name):
    if not isinstance(name, str) or not name or Path(name).is_absolute():
        raise ValueError('Missing local layered evidence')
    path = (root / name).resolve()
    if not path.is_relative_to(root.resolve()):
        raise ValueError('Layered evidence leaves its directory')
    return path


def finite(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def decoded_layers(directory):
    facts = json.loads((directory / 'decoded.json').read_text())
    if (facts['sourceSamples'] != 240000 or not 239000 <= facts['audioSamples'] <= 242048
        or not finite(facts['duration']) or abs(facts['duration'] - 5) > .001
        or not finite(facts['audioStart']) or abs(facts['audioStart']) > .03
        or len(facts['frames']) != 150
        or any(not finite(pts) or abs(pts - index / 30) > .00001 for index, pts in enumerate(facts['frames']))):
        raise ValueError('Incomplete output clock')
    pixels = (directory / 'decoded.bgra').read_bytes()
    size = 320 * 180 * 4
    if len(pixels) != size * 150:
        raise ValueError('Missing decoded frame bytes')
    def rgb(frame, x, y):
        offset = frame * size + (y * 320 + x) * 4
        b, g, r = pixels[offset:offset + 3]
        return r, g, b
    def count_white(frame, y0, y1):
        return sum(all(v > 210 for v in rgb(frame, x, y)) for y in range(y0, y1) for x in range(5, 85))
    centers = []
    for frame in range(150):
        r, g, b = rgb(frame, 275, 20)
        if not (g > 200 and r < 40 and b < 40):
            raise ValueError('The transparent green layer is absent or underneath the background')
        r, g, b = rgb(frame, 30, 155)
        if not (r > 200 and g > 200 and b < 40):
            raise ValueError('The second independent image layer is absent')
        r, g, b = rgb(frame, 300, 155)
        if not (180 < r < 245 and 20 < g < 95 and b < 45):
            raise ValueError('Transparency lost the actual warm video background')
        first = count_white(frame, 5, 40)
        second = count_white(frame, 40, 76)
        if (frame < 90 and (first < 60 or second < 60)) or (frame >= 90 and (first > 5 or second > 5)):
            raise ValueError('Both native titles must appear independently and end at frame ninety')
        if frame in (0, 30, 59, 60, 89, 90, 149):
            colored = [(x, y) for y in range(45, 135) for x in range(85, 255)
                       if (lambda c: c[2] > 80 and c[2] > c[1] + 20)(rgb(frame, x, y))]
            if frame in (0, 30):
                if len(colored) < 300:
                    raise ValueError('The actual moving Lottie pixels are missing')
                centers.append(sum(x for x, _ in colored) / len(colored))
            if frame >= 60 and colored:
                raise ValueError('Lottie continued beyond its actual sixty-frame source interval')
    if not (105 < centers[0] < 116 and 203 < centers[1] < 214 and centers[1] - centers[0] > 90):
        raise ValueError('The actual Lottie source motion was frozen, stretched or misplaced')
    background_centers = []
    for frame in (90, 149):
        white = [x for x in range(85, 270) if all(v > 215 for v in rgb(frame, x, 90))]
        if len(white) < 35:
            raise ValueError('The video beneath the transparent layers has no moving object')
        background_centers.append(sum(white) / len(white))
    if not 40 < background_centers[1] - background_centers[0] < 55:
        raise ValueError('The underlying video is frozen or retimed')
    original, actual = array.array('f'), array.array('f')
    original.frombytes((directory / 'source.f32').read_bytes())
    actual.frombytes((directory / 'decoded.f32').read_bytes())
    if len(original) != 240000 or len(actual) != facts['audioSamples']:
        raise ValueError('Missing source or decoded PCM')
    indices = range(48000, 192000, 16)
    reference = [original[index] for index in indices]
    reference_power = sum(value * value for value in reference)
    if not all(math.isfinite(x) for x in actual) or reference_power < .01:
        raise ValueError('Invalid or silent original audio')
    best = -1
    for offset in range(-1024, 1025, 8):
        values = [actual[index + offset] for index in indices]
        power = sum(value * value for value in values)
        if power <= 0:
            continue
        correlation = sum(a * b for a, b in zip(reference, values)) / math.sqrt(reference_power * power)
        if .65 < power / reference_power < 1.4:
            best = max(best, correlation)
    if best < .9:
        raise ValueError('The exported audio is muted, doubled or does not contain the original source')


def layered_timeline_evidence(rows, output, scale):
    try:
        records = [r for r in rows if r.get('event') == 'layered-timeline-owner']
        complete = [r for r in rows if r.get('event') == 'completed' and r.get('case') == 'layeredtimeline']
        if (len(records) != 1 or len(complete) != 1 or any(r.get('event') == 'failed' for r in rows)
            or any(r.get('scale') != scale for r in records + complete)):
            return False, []
        row = records[0]
        if row.get('viewport') != [960, 640] or row.get('effectiveScale') != scale or not finite(row.get('height')) or not 70 < row['height'] < 80:
            return False, []
        directory = local(output, row['directory']); package = local(directory, row['project'])
        def read(name):
            return json.loads(local(directory, name + '.json').read_text())
        layered = read('layered'); tracks = layered['tracks']; track_ids = row['trackIDs']; title_ids = row['titleIDs']
        if (layered['fps'] != 30 or layered['width'] != 320 or layered['height'] != 180 or len(tracks) != 7
            or len(set(t['id'] for t in tracks)) != 7 or len(track_ids) != 5 or len(set(title_ids)) != 2
            or [t['id'] for t in tracks[2:]] != track_ids or [t['type'] for t in tracks] != ['video', 'video', 'video', 'video', 'video', 'video', 'audio']
            or any(len(t['clips']) != 1 or t['muted'] or t['hidden'] or not t['syncLocked'] for t in tracks)):
            return False, []
        clips = [t['clips'][0] for t in tracks]
        if ([c['id'] for c in clips[:2]] != title_ids[::-1] or len(set(c['id'] for c in clips)) != 7
            or [c['mediaType'] for c in clips] != ['text', 'text', 'lottie', 'image', 'image', 'video', 'audio']
            or [c['durationFrames'] for c in clips] != [90, 90, 60, 150, 150, 150, 150]
            or any(c['startFrame'] != 0 or c['trimStartFrame'] != 0 or c['trimEndFrame'] != 0 or c['speed'] != 1 or c['opacity'] != 1 for c in clips)):
            return False, []
        for clip, title, y in ((clips[0], 'TWO', 42), (clips[1], 'ONE', 8)):
            style, transform = clip['textStyle'], clip['transform']
            if (clip['textContent'] != title or style['fontSize'] != 144 or style['shadow']['enabled']
                or abs((transform['centerX'] - transform['width'] / 2) * 320 - 8) > .1
                or abs((transform['centerY'] - transform['height'] / 2) * 180 - y) > .1):
                return False, []
        manifest = json.loads(local(package, 'media.json').read_text())['entries']
        expected_files = ['Bouncing dot.lottie', 'Green corner.png', 'Yellow corner.png', 'Moving background.mov', 'Original sound.wav']
        if [s['file'] for s in row['sources']] != expected_files or len(manifest) != 5:
            return False, []
        for source, clip in zip(row['sources'], clips[2:]):
            entry = next(item for item in manifest if item['id'] == source['id'])
            source_path = local(directory, source['file']); imported = local(package, entry['source']['project']['relativePath'])
            if (source['id'] != clip['mediaRef'] or source['type'] != clip['mediaType'] or source_path.stat().st_size < 100
                or source_path.read_bytes() != imported.read_bytes() or hashlib.sha256(imported.read_bytes()).hexdigest() != source['sha256']):
                return False, []
        reordered = copy.deepcopy(layered); reordered['tracks'][3], reordered['tracks'][4] = reordered['tracks'][4], reordered['tracks'][3]
        removed = copy.deepcopy(layered); removed['tracks'].pop(4)
        flagged = copy.deepcopy(layered); flagged['tracks'][2]['hidden'] = True; flagged['tracks'][6]['muted'] = True; flagged['tracks'][3]['syncLocked'] = False
        final = copy.deepcopy(layered); final['tracks'][3]['syncLocked'] = False
        if read('reordered') != reordered or read('removed') != removed or read('flags') != flagged or read('final') != final:
            return False, []
        if json.loads(local(package, 'project.json').read_text()) != final:
            return False, []
        state = json.loads(local(package, 'editor-state.json').read_text())
        if state['schema'] != 1 or set(state['trackHeights']) != set(t['id'] for t in tracks):
            return False, []
        if any(state['trackHeights'][t['id']] != (row['height'] if t['id'] == track_ids[0] else 50) for t in tracks):
            return False, []
        if hashlib.sha256(local(directory, row['movie']).read_bytes()).hexdigest() != row['outputSHA256']:
            return False, []
        actions = row['interactions']
        clicks = [a.get('id') for a in actions if a.get('kind') == 'pointer']
        for source in row['sources']:
            if 'source.overwrite.' + source['id'] not in clicks or 'media.asset.' + source['id'] not in clicks:
                return False, []
        if clicks.count('editing.add-text') != 2 or 'export.start' not in clicks:
            return False, []
        panels = [a for a in actions if a.get('kind') == 'file-panel']
        if [a.get('path') for a in panels] != expected_files or any(a.get('selectedURLVerified') is not True or a.get('nativePathEditorVerified') is not True for a in panels):
            return False, []
        saves = [a for a in actions if a.get('kind') == 'save-panel']
        if len(saves) != 1 or saves[0].get('filename') != row['movie'] or saves[0].get('exactURLVerified') is not True or saves[0].get('nativeDirectoryAndFilenameTyped') is not True:
            return False, []
        expected_fields = [('text.content', 'ONE'), ('inspector.value.Text size', '144'), ('inspector.value.Position X', '8'), ('inspector.value.Position Y', '8'),
                           ('text.content', 'TWO'), ('inspector.value.Text size', '144'), ('inspector.value.Position X', '8'), ('inspector.value.Position Y', '42')]
        fields = [a['field'] for a in actions if a.get('kind') == 'text']
        if [(f.get('id'), f.get('expected')) for f in fields] != expected_fields or any(f.get('actual') != value or f.get('focusLeftTarget') is not True for f, (_, value) in zip(fields, expected_fields)):
            return False, []
        menus = [a['evidence']['item'] for a in actions if a.get('label') == 'native-clip-menu']
        if len(menus) != 2 or menus[0] != 'Move Track Down' or not menus[1].startswith('Remove Track ') or not menus[1].endswith(' and 1 Clip'):
            return False, []
        native = [a.get('evidence', {}).get('target') for a in actions if a.get('kind') == 'verified-state' and a.get('label') in ('native-pointer', 'native-drag')]
        if any(native.count(label) != count for label, count in [('layered.hidden', 2), ('layered.muted', 2), ('layered.syncLocked', 1), ('layered.track-height', 1)]):
            return False, []
        keys = [(a.get('code'), a.get('modifiers')) for a in actions if a.get('kind') == 'keyboard']
        if keys.count((6, 1048576)) != 5 or keys.count((6, 1179648)) != 3 or keys.count((1, 1048576)) != 2:
            return False, []
        decode_action = next(a['evidence'] for a in actions if a.get('label') == 'layered film independently decoded')
        if (decode_action['filmHashBeforeResize'] != decode_action['filmHashAfterResize']
            or len(decode_action['filmHashBeforeResize']) != 64 or decode_action['trackHeightBefore'] != 50
            or decode_action['trackHeightAfter'] != row['height']):
            return False, []
        labels = ['file-selected'] * 5 + ['import-candidates', 'title-one', 'title-two', 'track-reordered', 'track-removed', 'hidden-lottie',
                  'track-flags-height', 'reopened-flags-height', 'layered-film-preview', 'export-settings', 'save-selected', 'export-verified', 'saved-final']
        images = row['screenshots']
        if len(images) != len(labels) or any(not image.endswith('-' + label + '.png') for image, label in zip(images, labels)):
            return False, []
        if any(not local(output, image).read_bytes().startswith(b'\x89PNG\r\n\x1a\n') for image in images):
            return False, []
        decoded_layers(directory)
        return True, images
    except (OSError, KeyError, ValueError, TypeError, IndexError, StopIteration, OverflowError, ZeroDivisionError):
        return False, []
