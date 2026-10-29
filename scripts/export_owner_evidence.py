"""Independent export-file, native-action and real-process recovery evidence checks."""
import array
import hashlib
import json
import math
from pathlib import Path
import struct
import sys
from fractions import Fraction
from urllib.parse import unquote, urlparse
import xml.etree.ElementTree as ET

VARIANTS = (
    ('h264-720', 'H.264', '720p', 'master', 'avc1', 720, 1280, 'mp4'),
    ('hevc-1080', 'H.265', '1080p', 'derivative', 'hvc1', 1080, 1920, 'mp4'),
    ('prores-original', 'ProRes', 'Match Timeline', 'master', 'apcn', 180, 320, 'mov'),
    ('h264-2k', 'H.264', '2K', 'derivative', 'avc1', 1440, 2560, 'mp4'),
    ('hevc-4k', 'H.265', '4K', 'master', 'hvc1', 2160, 3840, 'mp4'))
XML_WARNING = "Text, blend modes, flips, adjustments, effects, and keyframe easing aren't included in XMEML."


def local(root, name):
    if not isinstance(name, str) or not name or Path(name).is_absolute():
        raise ValueError('Export evidence must be local')
    path = root / name
    if path.is_symlink() or not path.resolve().is_relative_to(root.resolve()):
        raise ValueError('Export evidence leaves its root')
    return path


def load(root, name):
    return json.loads(local(root, name).read_text())


def sha(path):
    with path.open('rb') as file:
        digest = hashlib.sha256()
        for block in iter(lambda: file.read(1024 * 1024), b''): digest.update(block)
        return digest.hexdigest()


def finite(value):
    return isinstance(value, (float, int)) and not isinstance(value, bool) and math.isfinite(value)


def pcm(data):
    values = array.array('f'); values.frombytes(data)
    if sys.byteorder != 'little': values.byteswap()
    if not values or not all(math.isfinite(x) for x in values): raise ValueError('Invalid decoded PCM')
    return values


def wave(path):
    raw = path.read_bytes()
    if raw[:4] != b'RIFF' or raw[8:12] != b'WAVE': raise ValueError('Missing actual WAV source')
    offset, fmt, data = 12, None, None
    while offset + 8 <= len(raw):
        name, size = struct.unpack_from('<4sI', raw, offset); offset += 8
        chunk = raw[offset:offset + size]
        if len(chunk) != size: raise ValueError('Truncated WAV')
        if name == b'fmt ': fmt = chunk
        if name == b'data': data = chunk
        offset += size + size % 2
    if fmt is None or len(fmt) < 16 or data is None: raise ValueError('Missing WAV chunks')
    code, channels, rate = struct.unpack_from('<HHI', fmt)
    bits = struct.unpack_from('<H', fmt, 14)[0]
    if code == 0xFFFE and len(fmt) >= 40: code = struct.unpack_from('<H', fmt, 24)[0]
    if channels != 1 or rate != 48000 or code != 3 or bits != 32: raise ValueError('The actual source PCM format changed')
    return pcm(data)


def audio_matches(original, decoded):
    if len(decoded) < len(original) - 1024 or len(decoded) > len(original) + 2048: return False
    indices = range(4800, len(original) - 4800, 64)
    reference = [original[i] for i in indices]
    reference_power = sum(x * x for x in reference)
    if reference_power < .001: return False
    for offset in range(-1024, 1025, 8):
        values = [decoded[i + offset] for i in indices]
        power = sum(x * x for x in values)
        if power and .6 < power / reference_power < 1.4:
            correlation = sum(a * b for a, b in zip(reference, values)) / math.sqrt(reference_power * power)
            if correlation > .90: return True
    return False


def decode_proof(directory, stem, filename, codec, width, height, count):
    proof = load(directory, stem + '.json')
    if (proof['filename'] != filename or proof['sha256'] != sha(local(directory, filename))
        or proof['codec'] != codec or (proof['width'], proof['height'], proof['fps']) != (width, height, 24)
        or not finite(proof['duration']) or abs(proof['duration'] - count / 24) > .05
        or len(proof['frames']) != count or not finite(proof['audioStart']) or abs(proof['audioStart']) > .04):
        raise ValueError('Actual codec, dimensions, clock or complete decoding is wrong')
    for index, frame in enumerate(proof['frames']):
        if (frame['width'], frame['height']) != (width, height) or frame['timescale'] <= 0:
            raise ValueError('Actual decoded frame dimensions/timebase changed')
        if abs(frame['value'] / frame['timescale'] - index / 24) > .00001 or len(frame['pixelSHA256']) != 64:
            raise ValueError('Output dropped, duplicated or retimed frames')
        line = frame['centerLine']
        if len(line) != 960 or any(type(value) is not int or not 0 <= value <= 255 for value in line):
            raise ValueError('Actual frame pixels are absent')
        white = [x for x in range(320) if min(line[x * 3:x * 3 + 3]) > 215]
        if not 40 <= len(white) <= 60 or abs(sum(white) / len(white) - (105 + 120 * index / (count - 1))) > 4:
            raise ValueError('The actual source motion is frozen, stretched or replaced')
        for x in (10, 305):
            b, g, r = line[x * 3:x * 3 + 3]
            if not (150 < r < 245 and 15 < g < 100 and b < 65): raise ValueError('The actual source picture disappeared')
    if len({f['pixelSHA256'] for f in proof['frames']}) < count * .8: raise ValueError('Repeated output frames')
    audio = local(directory, proof['audioFile'])
    samples = pcm(audio.read_bytes())
    original = wave(local(directory, 'Original sound.wav'))
    if proof['audioSHA256'] != sha(audio) or len(samples) != proof['audioSamples'] or len(original) != count * 2000 or not audio_matches(original, samples):
        raise ValueError('The actual original sound was removed, replaced, shifted or rescaled')
    return proof


def interactions(directory, name):
    evidence = load(directory, name + '.json')
    if evidence.get('failure') is not None or not evidence['interactions'] or not evidence['screenshots']:
        raise ValueError('Missing complete native interaction evidence')
    for screenshot in evidence['screenshots']:
        if local(directory, screenshot).read_bytes()[:8] != b'\x89PNG\r\n\x1a\n': raise ValueError('Missing actual screenshot')
    return evidence


def exact_save(actions, filename):
    return any(a.get('kind') == 'save-panel' and a.get('filename') == filename
        and a.get('exactURLVerified') is True and a.get('nativeDirectoryAndFilenameTyped') is True for a in actions)


def menu(actions, identifier, title):
    return any(a.get('kind') == 'menu' and a.get('id') == identifier and a.get('item') == title and a.get('closed') is True for a in actions)


def check_job(directory, name, target, width, height, count, filename):
    job = load(directory, name + '-job.json'); attempt = job['attempt']; qc = attempt['probe_qc']; spec = attempt['spec']
    if (job['status'] != 'completed' or job['kind'] != 'video' or job['output'] != filename
        or job['outputSHA256'] != sha(local(directory, filename)) or attempt['id'] != job['id']
        or attempt['status'] != 'succeeded' or attempt['output_sha256'] != job['outputSHA256']
        or spec['target_kind'] != target or (spec['width'], spec['height'], spec['fps_numerator'], spec['fps_denominator']) != (width, height, 24, 1)
        or qc['passed'] is not True or (qc['width'], qc['height'], qc['fps_numerator'], qc['fps_denominator']) != (width, height, 24, 1)
        or not qc['audio_codec'] or qc['audio_channels'] < 1 or abs(qc['duration_value'] / qc['duration_timescale'] - count / 24) > .05):
        raise ValueError('Actual delivery/QC receipt is absent or inconsistent')
    return job


def media_reference(url, directory, permitted):
    parsed = urlparse(url)
    if parsed.scheme != 'file' or parsed.netloc not in ('', 'localhost'): raise ValueError('Interchange lacks actual file media')
    path = Path(unquote(parsed.path))
    digest = sha(path)
    if digest not in permitted or 'NexGenVideoExportQueue' in path.parts or '.partial' in path.name:
        raise ValueError('Interchange references a changed or disposable source')
    return digest


def interchange(directory):
    original_hashes = {sha(local(directory, 'Export source.ngv/media/Moving source.mov')), sha(local(directory, 'Original sound.wav'))}
    xml_file = local(directory, 'handoff.xml'); xml = ET.fromstring(xml_file.read_bytes())
    clips = xml.findall('.//clipitem')
    if xml.tag != 'xmeml' or len(clips) != 2 or {c.findtext('start') for c in clips} != {'0'} or {c.findtext('end') for c in clips} != {'48'}:
        raise ValueError('XML lost actual clip timing')
    if {media_reference(node.text, directory, original_hashes) for node in xml.findall('.//pathurl')} != original_hashes:
        raise ValueError('XML media is missing')
    report = load(directory, 'xmeml-job.json')
    if report['status'] != 'completed' or report['outputSHA256'] != sha(xml_file) or XML_WARNING not in report['warnings']:
        raise ValueError('XML loss warning or actual output is absent')
    for version, target in [('1.10', 'final-cut-pro'), ('1.14', 'resolve')]:
        name = 'handoff-' + version; path = local(directory, name + '.fcpxml'); doc = ET.fromstring(path.read_bytes())
        report = load(directory, name + '-job.json'); proof = report['fcpxml']
        if (doc.tag != 'fcpxml' or doc.get('version') != version or proof['version'] != version or proof['target'] != target
            or report['status'] != 'completed' or proof['outputSHA256'] != sha(path)
            or proof['validation']['schemaProfile'] != 'apple/fcpxml-dtd/' + version or len(proof['mediaBindings']) != 2):
            raise ValueError('FCPXML profile, DTD validation or actual output is missing')
        refs = [node.get('src') for node in doc.findall('.//media-rep')]
        if {media_reference(url, directory, original_hashes) for url in refs} != original_hashes:
            raise ValueError('FCPXML actual media is missing')
        for binding in proof['mediaBindings']:
            if binding['mediaSHA256'] not in original_hashes or media_reference(binding['sourceURL'], directory, original_hashes) != binding['mediaSHA256']:
                raise ValueError('FCPXML media proof differs from bytes')
        sequence = doc.find('.//project/sequence')
        if sequence is None or Fraction(sequence.get('duration').rstrip('s')) != 2:
            raise ValueError('FCPXML lost complete sequence duration')
        if not any(Fraction(f.get('frameDuration').rstrip('s')) == Fraction(1, 24) and f.get('width') == '180' and f.get('height') == '320'
                   for f in doc.findall('./resources/format')): raise ValueError('FCPXML lost portrait or FPS')


def export_formats_evidence(rows, output, scale):
    try:
        records = [r for r in rows if r.get('event') == 'export-formats-owner']
        if len(records) != 1 or records[0].get('scale') != scale or any(r.get('event') == 'failed' for r in rows): return False, []
        completions = [r for r in rows if r.get('event') == 'completed' and r.get('case') == 'exportformats']
        if len(completions) != 1 or completions[0].get('scale') != scale: return False, []
        row = records[0]; directory = local(Path(output), row['directory'])
        if row['viewport'] != [960, 640] or row['effectiveScale'] != scale or len(row['deliveries']) != len(VARIANTS): return False, []
        native = interactions(directory, 'export-owner'); actions = native['interactions']
        if row['interactions'] != actions or row['screenshots'] != native['screenshots']: return False, []
        clicks = [a.get('id') for a in actions if a.get('kind') == 'pointer']
        if clicks.count('export.require-sequence') != 2 or not exact_save(actions, 'Review required.mp4') or local(directory, 'Review required.mp4').exists(): return False, []
        if not any(a.get('label') == 'explicit review requirement blocks publication' and a.get('evidence', {}).get('outputExists') is False
                   and a.get('evidence', {}).get('jobCount') == 0 for a in actions): return False, []
        if not any(a.get('label') == 'application-menu' and a.get('evidence', {}).get('path') == ['File', 'Export…'] for a in actions): return False, []
        for item, variant in zip(row['deliveries'], VARIANTS):
            name, codec, resolution, target, subtype, width, height, extension = variant; filename = name + '.' + extension
            if any(item.get(k) != v for k, v in [('name', name), ('codec', codec), ('resolution', resolution), ('target', target), ('width', width), ('height', height), ('output', filename)]): return False, []
            if not all(menu(actions, key, value) for key, value in [('export.codec', codec), ('export.resolution', resolution), ('export.target', target.title())]) or not exact_save(actions, filename): return False, []
            proof = decode_proof(directory, name + '-decoded', filename, subtype, width, height, 48)
            job = check_job(directory, name, target, width, height, 48, filename)
            if item['jobID'] != job['id'] or item['sha256'] != proof['sha256']: return False, []
        interchange(directory)
        for filename in ['handoff.xml', 'handoff-1.10.fcpxml', 'handoff-1.14.fcpxml', 'Portable copy.ngv']:
            if not exact_save(actions, filename): return False, []
        for version, target in [('1.10', 'Final Cut Pro'), ('1.14', 'DaVinci Resolve')]:
            if not menu(actions, 'export.fcpxml.version', version) or not menu(actions, 'export.fcpxml.target', target): return False, []
        copied = local(directory, 'Portable copy.ngv'); source = local(directory, 'Export source.ngv')
        if load(copied, 'project.json') != load(source, 'project.json') or load(copied, 'ngv.json')['id'] == load(source, 'ngv.json')['id']: return False, []
        manifest = load(copied, 'media.json')
        original = {'export-picture': sha(local(source, 'media/Moving source.mov')), 'export-sound': sha(local(directory, 'Original sound.wav'))}
        if {entry['id'] for entry in manifest['entries']} != set(original): return False, []
        for entry in manifest['entries']:
            if set(entry['source']) != {'project'} or sha(local(copied, entry['source']['project']['relativePath'])) != original[entry['id']]: return False, []
        report = load(directory, 'portable-job.json')['package']
        if report['collected'] != ['export-sound'] or report['copiedInternal'] != 1 or report['missing']: return False, []
        reopen = interactions(directory, 'export-copy-reopen'); negative = interactions(directory, 'export-missing-media')
        missing = load(directory, 'missing-copy-job.json')
        if missing['package']['missing'] != [{'id': 'missing-card', 'name': 'Absent card'}] or missing['warnings'] != ['1 media file could not be included.']: return False, []
        if not exact_save(negative['interactions'], 'Copy with missing media.ngv') or not exact_save(negative['interactions'], 'Stale destination.ngv') or local(directory, 'Stale destination.ngv').exists(): return False, []
        stale = [a['evidence'] for a in negative['interactions'] if a.get('label') == 'deliberate source-owner invalidation refuses publication']
        if len(stale) != 1 or not stale[0]['previousOwner'] or not stale[0]['currentOwner'] or stale[0]['previousOwner'] == stale[0]['currentOwner'] or stale[0]['outputExists'] is not False: return False, []
        images = [str(Path(row['directory']) / name) for evidence in (native, reopen, negative) for name in evidence['screenshots']]
        return True, images
    except (KeyError, TypeError, ValueError, OSError, IndexError, ZeroDivisionError, struct.error, ET.ParseError):
        return False, []


def restart_processes(processes, state, row, scale):
    return (len(processes) == 2 and [p.get('stage') for p in processes] == ['prepare', 'resume']
        and all(p.get('scale') == scale for p in processes)
        and all(type(p.get('processID')) is int and p['processID'] > 0 for p in processes)
        and processes[0].get('observedSIGSTOP') is True and processes[0].get('exitCode') == -9
        and processes[1].get('exitCode') == 0 and processes[1].get('observedSIGSTOP') is False
        and processes[0]['processID'] == state.get('processID') and processes[1]['processID'] == row.get('processID')
        and processes[0]['processID'] != processes[1]['processID']
        and finite(state.get('progress')) and 0 < state['progress'] < 1)


def export_recovery_evidence(rows, output, scale):
    try:
        records = [r for r in rows if r.get('event') == 'export-recovery-owner']
        processes = [r for r in rows if r.get('event') == 'export-recovery-process']
        if len(records) != 1 or records[0].get('scale') != scale or any(r.get('event') == 'failed' for r in rows): return False, []
        completions = [r for r in rows if r.get('event') == 'completed' and r.get('case') == 'exportrecovery']
        if len(completions) != 1 or completions[0].get('scale') != scale: return False, []
        row = records[0]; directory = local(Path(output), row['directory']); state = load(directory, 'restart-state.json')
        if row['viewport'] != [960, 640] or row['effectiveScale'] != scale or row['stage'] != 'resume': return False, []
        if not restart_processes(processes, state, row, scale): return False, []
        prepared = interactions(directory, 'export-recovery-prepare'); resumed = interactions(directory, 'export-recovery-resume')
        if row['interactions'] != resumed['interactions'] or row['screenshots'] != resumed['screenshots']: return False, []
        cancelled = load(directory, 'cancelled-job.json'); completed = load(directory, 'completed-before-restart-job.json')
        interrupted = load(directory, 'interrupted-after-restart-job.json'); running = load(directory, 'running-attempt.json')
        renewed = check_job(directory, 'explicit-new-export', 'master', 1280, 720, 192, state['output'])
        if (cancelled['status'] != 'cancelled' or cancelled['attempt']['status'] != 'cancelled'
            or completed['status'] != 'completed' or completed['id'] != state['completedID']
            or completed['outputSHA256'] != state['completedSHA256'] or sha(local(directory, 'Completed before restart.mp4')) != state['completedSHA256']
            or running['status'] != 'running' or running['id'] != state['interruptedID'] or running.get('output_sha256') is not None
            or (running['spec']['width'], running['spec']['height']) != (3840, 2160)
            or interrupted['id'] != running['id'] or interrupted['status'] != 'interrupted' or interrupted['attempt']['status'] != 'interrupted'
            or interrupted['outputSHA256'] is not None or renewed['id'] in (running['id'], completed['id'], cancelled['id'])
            or len({running['id'], completed['id'], cancelled['id']}) != 3): return False, []
        actions = prepared['interactions']; clicks = [a.get('id') for a in actions if a.get('kind') == 'pointer']
        if clicks.count('export.job.' + cancelled['id'] + '.cancel') != 1 or clicks.count('export.job.' + cancelled['id'] + '.retry') != 1: return False, []
        if clicks.count('production.export') != 6 or clicks.count('production.export.open') != 5: return False, []
        for workspace in ('media', 'production', 'postproduction', 'edit', 'export'):
            if 'editor.workspace.' + workspace not in clicks or not any('pending-export-' + workspace in name for name in prepared['screenshots']): return False, []
        if not all(exact_save(actions, name) for name in ('Completed before restart.mp4', 'Interrupted film.mp4')): return False, []
        if not exact_save(resumed['interactions'], 'Interrupted film.mp4'): return False, []
        before = [a['evidence'] for a in actions if a.get('label') == 'real encoder interrupted before publication']
        after = [a['evidence'] for a in resumed['interactions'] if a.get('label') == 'real process restart recovered interrupted export']
        if (len(before) != 1 or len(after) != 1 or before[0]['jobID'] != running['id'] or before[0]['progress'] != state['progress']
            or before[0]['partialExists'] is not True or before[0]['snapshotExists'] is not True or before[0]['published'] is not False
            or after[0]['jobID'] != running['id'] or after[0]['partialExists'] is not False or after[0]['snapshotExists'] is not False
            or after[0]['published'] is not False or after[0]['previousProcessID'] != state['processID']
            or after[0]['processID'] != row['processID'] or after[0]['completedSHA256'] != state['completedSHA256']): return False, []
        if local(directory, state['partial']).exists() or Path(state['snapshotRoot']).exists(): return False, []
        decode_proof(directory, 'restarted-decoded', state['output'], 'avc1', 1280, 720, 192)
        images = [str(Path(row['directory']) / name) for evidence in (prepared, resumed) for name in evidence['screenshots']]
        return True, images
    except (KeyError, TypeError, ValueError, OSError, IndexError, ZeroDivisionError, struct.error):
        return False, []
