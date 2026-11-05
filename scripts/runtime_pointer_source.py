"""Select production style dependencies verbatim for the framework fixture."""
import hashlib
import json
import math
from pathlib import Path
import struct
import zlib


ROOT = Path(__file__).resolve().parents[1]
PRODUCTION_FILES = ('Sources/NexGenVideo/UI/AppTheme.swift', 'Sources/NexGenVideo/UI/DesignSystem.swift',
                    'Sources/NexGenVideo/ThreeD/SpatialSceneView.swift', 'Sources/NexGenVideo/UI/CapsuleButton.swift',
                    'scripts/runtime_pointer_source.py', 'scripts/runtime_pointer_diagnostic.swift')


def block(text, marker):
    if text.count(marker) != 1:
        raise ValueError('Ambiguous production dependency: ' + marker)
    start = text.index(marker)
    opening = text.index('{', start)
    depth = 1
    for index in range(opening + 1, len(text)):
        depth += (text[index] == '{') - (text[index] == '}')
        if depth == 0:
            return text[start:index + 1]
    raise ValueError('Unclosed production dependency: ' + marker)


def prepare(output):
    theme = (ROOT / 'Sources/NexGenVideo/UI/AppTheme.swift').read_text()
    design = (ROOT / 'Sources/NexGenVideo/UI/DesignSystem.swift').read_text()
    names = ('Background', 'BorderWidth', 'Accent', 'Status', 'Text', 'Opacity', 'Radius', 'Spacing', 'FontWeight', 'Anim')
    parts = ['import AppKit\nimport SwiftUI\nenum AppTheme {']
    parts += [block(theme, '    enum ' + name + ' {') for name in names]
    parts += [block(design, '    enum Typography {'), block(design, '    enum Control {'), '}']
    palette = block(design, 'struct ProjectPalette: Equatable {')
    palette = palette[:palette.index('    static func resolve(')] + '}\n'
    parts.append(palette)
    parts += [block(design, 'private struct ProjectPaletteKey: EnvironmentKey {'),
              block(design, 'private struct InterfaceScaleKey: EnvironmentKey {'),
              block(design, 'extension EnvironmentValues {'),
              block(design, 'private struct InterfaceFont: ViewModifier {'),
              'extension View {\n' + block(design, '    func interfaceFont(') + '\n}']
    output.write_text('\n\n'.join(parts) + '\n')
    manifest = {'schema': 'nexgenvideo/pointer-production-dependencies/1',
                'sourceFiles': {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in PRODUCTION_FILES},
                'selectedSupportSHA256': hashlib.sha256(output.read_bytes()).hexdigest(),
                'capsuleStyleCompiledVerbatim': True, 'projectPalette': 'neutral',
                'unverifiedOriginalDependencies': ['project-specific accent palette', 'entire cockpit view hierarchy',
                    'prior responder and editing history', 'original physical pointer position',
                    'parent layout allocations and inherited control size'],
                'classification': 'framework-pointer-reproduction-only', 'appAcceptance': False}
    output.with_suffix('.json').write_text(json.dumps(manifest, indent=2) + '\n')
    return output


def require(value, message):
    if not value:
        raise ValueError(message)


def rectangle(value):
    require(type(value) is list and len(value) == 4
            and all(type(v) in (int, float) and math.isfinite(v) for v in value)
            and value[2] > 0 and value[3] > 0, 'Missing, empty or nonfinite measured rectangle')
    return value


def comparable(first, second):
    return all(abs(a - b) <= 0.5 for a, b in zip(rectangle(first), rectangle(second)))


def assess_sample(sample):
    kind, route = sample['control'], sample['route']
    require(kind in {'undo', 'apply', 'native'} and route in {'queued', 'separated', 'hid'}, 'Unknown matrix cell')
    variant, size = ('native-system', 'native-system') if kind == 'native' else ('secondary', 'regular' if kind == 'apply' else 'small')
    require((sample.get('configuredVariant'), sample.get('configuredSize')) == (variant, size), 'Wrong production control style')
    original = rectangle(sample['originalFrame'])
    matching = True
    for phase in ('before', 'after'):
        value = sample[phase]
        probe, screen = rectangle(value['probeTopFrame']), rectangle(value['originalScreenFrame'])
        ax = value['ax']
        require(ax.get('traversalComplete') is True and type(ax.get('visitedCount')) is int
                and 0 < ax['visitedCount'] <= ax.get('budget', 0) == 2048, 'Incomplete accessibility traversal')
        targets = [target for target in ax['targets'] if target.get('role') == 'AXButton']
        title = 'Apply transform' if kind == 'apply' else 'Undo'
        require(len(targets) == 1 and title in (targets[0].get('label'), targets[0].get('title'))
                and targets[0].get('enabled') is True and isinstance(targets[0].get('help'), str),
                'Missing, disabled or ambiguous button accessibility target')
        target = rectangle(targets[0]['frame'])
        window_point = [original[0] + original[2] / 2, 640 - original[1] - original[3] / 2]
        require(value['windowPoint'] == window_point and value.get('hitClass') not in (None, '', 'nil'),
                'Intended window point or hit target is missing')
        bounds, frame = rectangle(value['contentBounds']), rectangle(value['rootFrame'])
        root_point = value['rootPoint']
        require(type(root_point) is list and len(root_point) == 2
                and all(type(v) in (int, float) and math.isfinite(v) for v in root_point), 'Missing root coordinates')
        parent_x = frame[0] + (root_point[0] - bounds[0]) * frame[2] / bounds[2]
        parent_y = (root_point[1] - bounds[1]) * frame[3] / bounds[3]
        if value['rootIsFlipped'] != value['superviewIsFlipped']:
            parent_y = frame[3] - parent_y
        parent_y += frame[1]
        require(all(abs(a - b) <= 0.001 for a, b in zip(value['hitTestSuperviewPoint'], [parent_x, parent_y]))
                and len(value['hitTestSuperviewPoint']) == 2, 'Hit-test point does not use superview coordinates')
        in_view = (0 <= probe[0] and 0 <= probe[1] and probe[0] + probe[2] <= 960 and probe[1] + probe[3] <= 640)
        matching &= (comparable(original, probe) and comparable(screen, target) and in_view
                     and value.get('probeHidden') is False and value.get('windowIsVisible') is True
                     and value.get('windowIsKey') is True)
        measured = value.get('measuredStyle', {})
        require(all(key in measured and measured[key] is None
                    for key in ('paintedFont', 'paintedForeground', 'internalStyleHoverState'))
                and type(measured.get('physicalCursorInsideOriginalTarget')) is bool,
                'Unobservable painted style must remain explicitly unknown')
        require(type(value.get('configuredSwiftUIStyle')) is dict
                and (kind != 'native' or not value['configuredSwiftUIStyle']),
                'Native style must not copy SwiftUI configured assumptions')
    events, delivery = sample['events'], sample['delivery']
    down = [event['observedUptime'] for event in events if event['type'] == 1]
    up = [event['observedUptime'] for event in events if event['type'] == 2]
    require(len(down) <= 1 and len(up) <= 1 and len(events) == len(down) + len(up), 'Ambiguous local monitor observation')
    pair = bool(down and up)
    require(sample.get('localMonitorPairComplete') is pair, 'Local monitoring completeness is misstated')
    observed = sample.get('observedDownUpIntervalSeconds')
    require(observed == (up[0] - down[0] if pair else None), 'Unseen Up timing must not be invented')
    posted = [delivery.get('downPostedUptime'), delivery.get('upPostedUptime')]
    require(all(type(v) in (int, float) and math.isfinite(v) for v in posted)
            and posted[1] >= posted[0], 'Missing posted event timing')
    require(delivery.get('syntheticTimestampDeltaSeconds') == {'queued': 0.001, 'separated': 0.03, 'hid': None}[route]
            and delivery.get('cursorMovePosted') is (route == 'hid'), 'Posted route differs from declared route')
    require(route != 'hid' or sample['after']['measuredStyle']['physicalCursorInsideOriginalTarget'] is True,
            'HID pointer was not observed inside the target')
    if route != 'queued':
        require(len(down) == 1 and posted[1] - down[0] >= 0.03
                and delivery.get('enqueueDurationSeconds') is None, 'Release did not follow observed Down by30ms')
    else:
        require(type(delivery.get('enqueueDurationSeconds')) in (int, float)
                and delivery['enqueueDurationSeconds'] >= posted[1] - posted[0] >= 0, 'Queue duration is not enqueue time')
    before, after = sample['before'], sample['after']
    require(before['callbackCount'] == 0 and not before['callbackUptimes']
            and type(after['callbackCount']) is int and 0 <= after['callbackCount'] <= 1
            and len(after['callbackUptimes']) == after['callbackCount']
            and sample['callbackObserved'] is (after['callbackCount'] == 1), 'Callback counter was not reset or is inconsistent')
    if after['callbackCount']:
        require(after['callbackUptimes'][0] >= posted[1], 'Callback preceded the posted release')
    require(kind != 'native' or after['callbackCount'] == 1, 'Native positive control did not activate')
    return {'control': kind, 'route': route, 'geometryComparable': bool(matching),
            'routeComparison': 'COMPARABLE_GEOMETRY' if matching else 'INCONCLUSIVE_GEOMETRY',
            'callbackObserved': after['callbackCount'] == 1, 'localMonitorPairComplete': pair,
            'originalUndoCause': 'INCONCLUSIVE: direct original App callback and environment are unobserved'}


def png_dimensions(raw):
    require(8 < len(raw) <= 32 * 1024**2 and raw[:8] == b'\x89PNG\r\n\x1a\n', 'Missing or corrupt PNG')
    offset, dimensions, ended, compressed, header = 8, None, False, [], None
    while offset < len(raw):
        require(offset + 12 <= len(raw), 'Truncated PNG chunk')
        size = struct.unpack('>I', raw[offset:offset + 4])[0]
        tag = raw[offset + 4:offset + 8]
        end = offset + 12 + size
        require(end <= len(raw) and zlib.crc32(raw[offset + 4:end - 4]) == struct.unpack('>I', raw[end - 4:end])[0], 'Corrupt PNG chunk')
        if offset == 8:
            require(tag == b'IHDR' and size == 13, 'Missing PNG header')
            dimensions = list(struct.unpack('>II', raw[offset + 8:offset + 16]))
            require(all(0 < value <= 16384 for value in dimensions), 'Invalid PNG dimensions')
            header = raw[offset + 8:offset + 8 + size]
        if tag == b'IDAT': compressed.append(raw[offset + 8:end - 4])
        offset = end
        if tag == b'IEND':
            require(size == 0 and offset == len(raw), 'Trailing PNG content')
            ended = True
    require(ended and compressed, 'Incomplete PNG image')
    bits, color, compression, filtering, interlace = header[8:]
    require(bits == 8 and color in (2, 6) and (compression, filtering, interlace) == (0, 0, 0), 'Unsupported screenshot PNG encoding')
    decoder = zlib.decompressobj()
    try:
        pixels = decoder.decompress(b''.join(compressed), 32 * 1024**2 + 1)
    except zlib.error as error:
        raise ValueError('Corrupt screenshot compression') from error
    stride = dimensions[0] * (3 if color == 2 else 4) + 1
    require(len(pixels) <= 32 * 1024**2 and decoder.eof and not decoder.unused_data and not decoder.unconsumed_tail
            and len(pixels) == stride * dimensions[1] and all(pixels[i] <= 4 for i in range(0, len(pixels), stride)),
            'Corrupt or oversized screenshot pixel data')
    return dimensions


def validate_measurement(output):
    value = json.loads((output / 'pointer-measurement.json').read_bytes())
    require(value.get('schema') == 'nexgenvideo/runtime-pointer-measurement/1'
            and value.get('classification') == 'framework-pointer-reproduction-only'
            and value.get('appAcceptance') is False and value.get('originalUndoCause', '').startswith('INCONCLUSIVE'),
            'Framework measurement must not claim original App acceptance or cause')
    samples = value['samples']
    original = json.loads((output / 'pointer-input.json').read_bytes())
    require(value.get('input') == original, 'Measurement input differs from original failure geometry')
    expected = {(kind, route) for kind in ('undo', 'apply', 'native') for route in ('queued', 'separated', 'hid')}
    require(len(samples) == 9 and {(sample['control'], sample['route']) for sample in samples} == expected, 'Incomplete9cell matrix')
    results = []
    for sample in samples:
        key = 'spatial.transform.apply' if sample['control'] == 'apply' else 'spatial.undo'
        require(sample['originalFrame'] == original['controls'][key]['frame'], 'Original control frame was relabelled')
        name = sample['control'] + '-' + sample['route'] + '.png'
        require(sample.get('screenshot') == name and (output / name).is_file()
                and not (output / name).is_symlink(), 'Wrong or missing screenshot identity')
        raw = (output / name).read_bytes()
        require(png_dimensions(raw) == sample.get('screenshotPixels'), 'Screenshot dimensions differ')
        result = assess_sample(sample)
        result.update(screenshot=name, screenshotSHA256=hashlib.sha256(raw).hexdigest())
        results.append(result)
    manifest = json.loads((output / 'pointer-support.json').read_bytes())
    require(manifest.get('capsuleStyleCompiledVerbatim') is True
            and manifest['selectedSupportSHA256'] == hashlib.sha256((output / 'pointer-support.swift').read_bytes()).hexdigest()
            and set(manifest['sourceFiles']) == set(PRODUCTION_FILES)
            and all(hashlib.sha256((ROOT / name).read_bytes()).hexdigest() == digest
                    for name, digest in manifest['sourceFiles'].items()), 'Compiled production dependency bytes changed')
    result = {'schema': 'nexgenvideo/runtime-pointer-validation/1', 'samples': results, 'nativePositiveControls': 3,
              'appAcceptance': False, 'originalUndoCause': 'INCONCLUSIVE: framework fixture only'}
    (output / 'pointer-validation.json').write_text(json.dumps(result, indent=2) + '\n')
    return result
