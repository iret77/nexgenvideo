"""Independent actual-owner evidence checks; synthetic parser fixtures are not native proof."""
import base64
import hashlib
import json
import math
import struct
import uuid
from pathlib import Path


def local(root, name):
    if not isinstance(name, str) or not name or Path(name).is_absolute():
        raise ValueError('Missing local structured result evidence')
    path = (root / name).resolve(strict=True)
    if not path.is_relative_to(root.resolve(strict=True)) or not path.is_file():
        raise ValueError('Structured result evidence leaves its directory')
    return path


def sha(data):
    return hashlib.sha256(data).hexdigest()


def finite(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def dimensions(data):
    if data[:8] == b'\x89PNG\r\n\x1a\n' and len(data) >= 24:
        return struct.unpack('>II', data[16:24])
    if data[:2] == b'\xff\xd8':
        i = 2
        while i + 4 <= len(data):
            if data[i] != 255:
                raise ValueError('Invalid JPEG marker')
            while i < len(data) and data[i] == 255:
                i += 1
            if i >= len(data):
                break
            marker = data[i]
            i += 1
            if marker in (0xD8, 0xD9) or 0xD0 <= marker <= 0xD7:
                continue
            if i + 2 > len(data):
                break
            size = struct.unpack('>H', data[i:i + 2])[0]
            if size < 2 or i + size > len(data):
                break
            if marker in (0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF) and size >= 8:
                height, width = struct.unpack('>HH', data[i + 3:i + 7])
                return width, height
            if marker == 0xDA:
                break
            i += size
    raise ValueError('Actual image has no supported dimensions')


def visible_values(number, tone):
    return [json.dumps(block, sort_keys=True, ensure_ascii=False, separators=(',', ':'))
            for block in expected_blocks(number, tone)]


def expected_blocks(number, tone):
    return [{'type': 'headline', 'text': 'Native result'},
            {'type': 'text', 'body': 'Read | compare = actual source before editing.'},
            {'type': 'status', 'badges': [{'label': 'State', 'value': 'Ready'}, {'label': 'Items', 'value': '1'}]},
            {'type': 'keyvalue', 'title': 'Source', 'rows': [['Filename', 'Actual result source.png']]},
            {'type': 'keyvalue', 'title': 'Timing', 'rows': [['Duration', 'Still image']]},
            {'type': 'callout', 'tone': tone, 'text': f'Native {tone} observation.'}]


def validate_owner(directory, expected_scale):
    root = Path(directory)
    read = lambda name: json.loads(local(root, name).read_text())
    result = read('agent-structured-result.json')
    if (result.get('schema') != 'native-agent-structured-results/v1' or not finite(result.get('scale'))
            or not finite(expected_scale) or result.get('scale') != expected_scale
            or expected_scale not in (1, 1.25, 1.5) or result.get('viewport') != [960, 640]
            or result.get('liveAgent') is not False):
        raise ValueError('Wrong structured owner identity, actual viewport or claim')
    progress = read(result['progress'])
    actions = progress.get('interactions', [])
    if progress.get('failure') is not None or actions != result.get('interactions') or progress.get('screenshots') != result.get('screenshots'):
        raise ValueError('Actual native actions differ from the retained progress file')
    calls = read('actual-tool-calls.json')
    requests = read('actual-requests.json')
    if (len(calls) != 5 or len(requests) != 5 or len({x['id'] for x in calls}) != 5
            or len({x['turnID'] for x in requests}) != 5 or len({x['sessionID'] for x in requests}) != 1):
        raise ValueError('Missing actual independent native turns/tool calls')
    for call, request in zip(calls, requests):
        for identity in (call['id'], request['turnID'], request['sessionID']):
            uuid.UUID(identity)
    directions = [f'Show native result {n}.' for n in range(1, 4)] + [
        'Show a deliberately invalid result to verify refusal.', 'Inspect the actual imported image.']
    session_bytes = local(root, 'actual-session.json').read_bytes()
    session = json.loads(session_bytes)
    session_id = str(uuid.UUID(result['sessionID']))
    if (str(uuid.UUID(session['id'])) != session_id
            or any(str(uuid.UUID(request['sessionID'])) != session_id for request in requests)
            or result.get('sessionFile') != 'Structured results.ngv/chat/' + result['sessionID'] + '.json'
            or local(root, result['sessionFile']).read_bytes() != session_bytes
            or result.get('sessionSHA256') != sha(session_bytes)
            or result.get('reopenedWithoutRuntime') is not True):
        raise ValueError('The transcript was not retained from the actual saved project session')
    messages = session['messages']
    for copy in [read('actual-messages.json'), read('reopened-messages.json')]:
        if ([{key: message[key] for key in ('id', 'role', 'blocks')} for message in copy]
                != [{key: message[key] for key in ('id', 'role', 'blocks')} for message in messages]):
            raise ValueError('The live, saved and reopened transcripts differ')
    blocks = [b for m in messages for b in m.get('blocks', [])]
    tool_blocks = [b for b in blocks if b.get('kind') == 'toolUse']
    result_blocks = [b for b in blocks if b.get('kind') == 'toolResult']
    if len(tool_blocks) != 5 or len(result_blocks) != 5:
        raise ValueError('The actual persisted transcript lost tool events')
    seen = [a['evidence'] for a in actions if a.get('label') == 'visible structured block']
    reopened_seen = [a['evidence'] for a in actions if a.get('label') == 'reopened structured block']
    expected_rendered = []
    actual_message_ids = []
    for index, tone in enumerate(('info', 'warn', 'success'), 1):
        call = calls[index - 1]
        args = json.loads(call['arguments'])
        values = visible_values(index, tone)
        if call['name'] != 'show_blocks' or call['isError'] is not False or args != {'version': '1', 'blocks': expected_blocks(index, tone)}:
            raise ValueError('The actual schema tool did not present the intended block grammar')
        expected_seen = [{'turn': index, 'index': i, 'value': value} for i, value in enumerate(values)]
        if (expected_seen != [x for x in seen if x.get('turn') == index]
                or expected_seen != [x for x in reopened_seen if x.get('turn') == index]):
            raise ValueError('Missing actual visible block values')
        owners = [m for m in messages if m.get('role') == 'assistant' and any(b.get('kind') == 'toolUse' and b.get('id') == call['id'] for b in m['blocks'])]
        if len(owners) != 1:
            raise ValueError('The structured probe has no unique actual assistant message')
        message_id = str(uuid.UUID(owners[0]['id']))
        actual_message_ids.append(message_id)
        expected_rendered.append({'turn': index, 'tone': tone, 'values': values, 'toolUseID': call['id'], 'messageID': owners[0]['id']})
    if result['rendered'] != expected_rendered:
        raise ValueError('Visible structured result list differs from the real tool payloads')
    for call, request, direction in zip(calls, requests, directions):
        if direction not in request['textBlocks'] or request['text'] != '\n'.join(request['textBlocks']):
            raise ValueError('The native composer request lost its actual direction')
        matches = [b for b in tool_blocks if b['id'] == call['id']]
        actual_results = [b for b in result_blocks if b['toolUseId'] == call['id']]
        expected_content = [({'kind': 'text', 'text': c['text']} if c['type'] == 'text' else
                             {'kind': 'image', 'base64': c['base64'], 'mediaType': c['mimeType']}) for c in call['content']]
        if (len(matches) != 1 or matches[0]['name'] != call['name'] or matches[0]['input'] != call['arguments']
                or len(actual_results) != 1 or actual_results[0]['isError'] != call['isError']
                or actual_results[0]['content'] != expected_content):
            raise ValueError('The transcript does not bind the actual tool arguments/result bytes')
    invalid, inspected = calls[3:]
    if (invalid['name'] != 'show_blocks' or invalid['isError'] is not True
            or json.loads(invalid['arguments']) != {'version': '1', 'blocks': [
                {'type': 'headline', 'text': 'Invalid result', 'symbol': 'not-an-allowed-field'}]}
            or result['invalidToolUseID'] != invalid['id'] or result['invalidError'] != 'error|' + '\n'.join(c['text'] for c in invalid['content'] if c['type'] == 'text')
            or 'symbol' not in result['invalidError']):
        raise ValueError('No actual unknown-field schema refusal')
    if (inspected['name'] != 'inspect_media' or inspected['isError'] is not False
            or json.loads(inspected['arguments']) != {'mediaRef': result['assetID']}
            or result['inspectionToolUseID'] != inspected['id']):
        raise ValueError('The actual media inspection selected a different source')
    images = [base64.b64decode(c['base64'], validate=True) for c in inspected['content'] if c['type'] == 'image']
    image = local(root, 'actual-inspection-image.bin').read_bytes()
    width, height = dimensions(image)
    if len(images) != 1 or images[0] != image or result['inspectionSHA256'] != sha(image) or result['dimensions'] != f'{width}x{height}' or min(width, height) <= 0:
        raise ValueError('The displayed actual image does not match its real inspection output')
    points = result.get('pointSize')
    if (not isinstance(points, list) or len(points) != 2 or not all(finite(value) and value > 0 for value in points)
            or result.get('probeDimensions') != f'{int(points[0])}x{int(points[1])}'):
        raise ValueError('The native point-size probe was confused with decoded image pixels')
    original = local(root, result['sourceFile']).read_bytes()
    if (sha(original) != result['sourceSHA256'] or local(root, 'actual-imported-image.bin').read_bytes() != original
            or local(root, 'actual-imported-image-after.bin').read_bytes() != original
            or result.get('sourceAfterSHA256') != sha(original)):
        raise ValueError('The actual imported source bytes changed')
    if read('timeline-before.json') != read('timeline-after.json') or read('manifest-before.json') != read('manifest-after.json'):
        raise ValueError('Read-only tool results mutated project truth')
    pointers = [a['id'] for a in actions if a.get('kind') == 'pointer']
    for control in ['production.ai', 'media.action.Import', 'agent.toolrow.show_blocks',
                    'agent.activity.details.' + inspected['id'], 'agent.tool.image', 'agent.tool.image.larger',
                    'agent.tool.image.fit', 'agent.tool.image.done']:
        if control not in pointers:
            raise ValueError('Missing actual native result/detail interaction: ' + control)
    if pointers.count('agent.task.run') != 5:
        raise ValueError('The five real composer submissions were not native')
    if not any(action.get('kind') == 'keyboard' and action.get('code') == 1
               and action.get('characters') == 's' and action.get('modifiers', 0) & (1 << 20) for action in actions):
        raise ValueError('The real project session was not saved with the native shortcut')
    snapshots = result['screenshots']
    if len(snapshots) < 16 or len(set(snapshots)) != len(snapshots):
        raise ValueError('Missing distinct actual block/detail captures')
    for suffix in ['reopened-result-1.png', 'reopened-result-2.png', 'reopened-result-3.png',
                   'reopened-invalid-payload-refusal.png', 'reopened-image-detail.png']:
        if not any(name.endswith(suffix) for name in snapshots):
            raise ValueError('A saved transcript result was not recaptured after reopening')
    for name in snapshots:
        data = local(root, name).read_bytes()
        if len(data) <= 1000 or data[:8] != b'\x89PNG\r\n\x1a\n' or min(dimensions(data)) <= 0:
            raise ValueError('Missing actual native screenshot pixels')
    visible = [a for a in actions if a.get('kind') == 'visible-group']
    visible_ids = {identity for row in visible for identity in row['ids']}
    required_blocks = {f'agent.structured.{message_id}.{index}' for message_id in actual_message_ids for index in range(6)}
    if not required_blocks <= visible_ids:
        raise ValueError('A structured block was recorded without actual native visibility')
    for row in visible:
        viewport = row['viewport']
        if len(viewport) != 4 or not all(finite(v) for v in viewport):
            raise ValueError('Invalid native viewport evidence')
        for x, y, w, h in row['frames']:
            if (not all(finite(v) for v in (x, y, w, h))
                    or w <= 0 or h <= 0 or x < viewport[0] or y < viewport[1] or x + w > viewport[0] + viewport[2] or y + h > viewport[1] + viewport[3]):
                raise ValueError('A native result or detail control is clipped')
    return {'schema': 'native-agent-structured-results-verified/v1', 'scale': expected_scale,
            'nativeStructuredVariants': 5, 'calloutTones': ['info', 'warn', 'success'],
            'actualInspectionSHA256': sha(image), 'nativeInvalidRefusal': True,
            'nativeImageDetail': True, 'nativeSavedTranscript': True,
            'sourceUnchangedAfterTools': True, 'liveAgent': False, 'images': snapshots}
