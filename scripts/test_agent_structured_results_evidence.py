import base64
import hashlib
import json
from pathlib import Path
import random
import struct
import tempfile
import unittest
import uuid
import zlib

from agent_structured_results_evidence import expected_blocks, validate_owner, visible_values


def png(width=32, height=18):
    def chunk(name, data):
        return struct.pack('>I', len(data)) + name + data + struct.pack('>I', zlib.crc32(name + data))
    rng = random.Random(4)
    pixels = b''.join(b'\0' + rng.randbytes(width * 3) for _ in range(height))
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(pixels)) + chunk(b'IEND', b'')


def structured_fixture(root, uppercase_message_ids=False, scale=1.5):
    """Synthetic parser data only; never counted as native or model evidence."""
    def write(name, value):
        (root / name).write_text(json.dumps(value))
    image = png()
    (root / 'Actual result source.png').write_bytes(image)
    (root / 'actual-imported-image.bin').write_bytes(image)
    (root / 'actual-imported-image-after.bin').write_bytes(image)
    (root / 'actual-inspection-image.bin').write_bytes(image)
    calls, requests, rendered, actions, messages = [], [], [], [], []
    session = str(uuid.UUID(int=1))
    directions = [f'Show native result {n}.' for n in range(1, 4)] + [
        'Show a deliberately invalid result to verify refusal.', 'Inspect the actual imported image.']
    for number, direction in enumerate(directions, 1):
        if number <= 3:
            tone = ['info', 'warn', 'success'][number - 1]
            args, name = {'version': '1', 'blocks': expected_blocks(number, tone)}, 'show_blocks'
            content, error = [{'type': 'text', 'text': 'Rendered 6 block(s) natively in the transcript.'}], False
            values = visible_values(number, tone)
            for index, value in enumerate(values):
                actions.append({'kind': 'verified-state', 'label': 'visible structured block',
                                'evidence': {'turn': number, 'index': index, 'value': value}})
                actions.append({'kind': 'verified-state', 'label': 'reopened structured block',
                                'evidence': {'turn': number, 'index': index, 'value': value}})
        elif number == 4:
            args, name = {'version': '1', 'blocks': [{'type': 'headline', 'text': 'Invalid result', 'symbol': 'not-an-allowed-field'}]}, 'show_blocks'
            content, error = [{'type': 'text', 'text': "input.blocks[0]: unknown field 'symbol'"}], True
        else:
            args, name = {'mediaRef': 'source-image'}, 'inspect_media'
            content, error = [{'type': 'image', 'base64': base64.b64encode(image).decode(), 'mimeType': 'image/png'}], False
        input_json = json.dumps(args, sort_keys=True)
        identity = str(uuid.UUID(int=number + 5))
        calls.append({'id': identity, 'name': name, 'arguments': input_json, 'isError': error, 'content': content})
        requests.append({'sessionID': session, 'turnID': str(uuid.UUID(int=number + 10)), 'text': direction, 'textBlocks': [direction]})
        messages.extend([{'role': 'user', 'blocks': [{'kind': 'text', 'text': direction}]},
                         {'role': 'assistant', 'blocks': [{'kind': 'toolUse', 'id': identity, 'name': name, 'input': input_json}]},
                         {'role': 'user', 'blocks': [{'kind': 'toolResult', 'toolUseId': identity, 'isError': error,
                                                    'content': [({'kind': 'text', 'text': b['text']} if b['type'] == 'text' else
                                                                 {'kind': 'image', 'base64': b['base64'], 'mediaType': b['mimeType']}) for b in content]}]}])
        if number <= 3:
            rendered.append({'turn': number, 'tone': tone, 'values': values, 'toolUseID': identity})
        actions.append({'kind': 'pointer', 'id': 'agent.task.run'})
    actions.extend({'kind': 'pointer', 'id': item} for item in [
        'production.ai', 'media.action.Import', 'agent.toolrow.show_blocks', 'agent.activity.details.' + calls[4]['id'],
        'agent.tool.image', 'agent.tool.image.larger', 'agent.tool.image.fit', 'agent.tool.image.done'])
    actions.append({'kind': 'visible-group', 'viewport': [0, 0, 960, 640], 'frames': [[10, 10, 100, 25]], 'ids': ['control']})
    for number in range(1, 4):
        for index in range(6):
            actions.append({'kind': 'visible-group', 'viewport': [0, 0, 640, 480], 'frames': [[10, 10, 250, 25]],
                            'ids': [f'agent.structured.{str(uuid.UUID(int=101 + (number - 1) * 3))}.{index}']})
    actions.append({'kind': 'keyboard', 'code': 1, 'characters': 's', 'modifiers': 1 << 20})
    images = [f'actual-{i}.png' for i in range(11)] + [
        'reopened-result-1.png', 'reopened-result-2.png', 'reopened-result-3.png',
        'reopened-invalid-payload-refusal.png', 'reopened-image-detail.png']
    for image_name in images:
        (root / image_name).write_bytes(image)
    result = {'schema': 'native-agent-structured-results/v1', 'scale': scale, 'viewport': [960, 640], 'liveAgent': False,
              'progress': 'owner.json', 'interactions': actions, 'screenshots': images, 'rendered': rendered,
              'invalidToolUseID': calls[3]['id'], 'invalidError': 'error|' + calls[3]['content'][0]['text'],
              'inspectionToolUseID': calls[4]['id'], 'inspectionSHA256': hashlib.sha256(image).hexdigest(),
              'dimensions': '32x18', 'pointSize': [16, 9], 'probeDimensions': '16x9',
              'sourceFile': 'Actual result source.png', 'sourceSHA256': hashlib.sha256(image).hexdigest(),
              'sourceAfterSHA256': hashlib.sha256(image).hexdigest(), 'sessionID': session,
              'sessionFile': 'Structured results.ngv/chat/' + session + '.json', 'reopenedWithoutRuntime': True,
              'assetID': 'source-image'}
    for index, message in enumerate(messages):
        message['id'] = str(uuid.UUID(int=index + 100))
        if uppercase_message_ids:
            message['id'] = message['id'].upper()
    for row in rendered:
        row['messageID'] = messages[(row['turn'] - 1) * 3 + 1]['id']
    session_bytes = json.dumps({'id': session, 'messages': messages}).encode()
    session_path = root / result['sessionFile']
    session_path.parent.mkdir(parents=True)
    session_path.write_bytes(session_bytes)
    (root / 'actual-session.json').write_bytes(session_bytes)
    result['sessionSHA256'] = hashlib.sha256(session_bytes).hexdigest()
    write('agent-structured-result.json', result)
    write('owner.json', {'failure': None, 'interactions': actions, 'screenshots': images})
    write('actual-tool-calls.json', calls)
    write('actual-requests.json', requests)
    write('actual-messages.json', messages)
    write('reopened-messages.json', messages)
    for stem in ['timeline', 'manifest']:
        write(stem + '-before.json', {'id': stem})
        write(stem + '-after.json', {'id': stem})


class StructuredResultEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        structured_fixture(self.root)

    def edit(self, name, change):
        path = self.root / name
        value = json.loads(path.read_text())
        change(value)
        path.write_text(json.dumps(value))

    def test_valid_synthetic_parser_fixture(self):
        self.assertTrue(validate_owner(self.root, 1.5)['nativeImageDetail'])

    def test_wrong_outer_scale(self):
        with self.assertRaises(ValueError):
            validate_owner(self.root, 1.25)

    def test_missing_actual_tool_call(self):
        self.edit('actual-tool-calls.json', lambda value: value.pop())
        with self.assertRaises(ValueError):
            validate_owner(self.root, 1.5)

    def test_changed_transcript_tool_payload(self):
        self.edit('actual-messages.json', lambda value: value[1]['blocks'][0].update(input='{}'))
        with self.assertRaises(ValueError):
            validate_owner(self.root, 1.5)

    def test_wrong_actual_callout_tone(self):
        def change(value):
            args = json.loads(value[1]['arguments'])
            args['blocks'][-1]['tone'] = 'info'
            value[1]['arguments'] = json.dumps(args)
        self.edit('actual-tool-calls.json', change)
        with self.assertRaises(ValueError):
            validate_owner(self.root, 1.5)

    def test_accepted_invalid_payload(self):
        self.edit('actual-tool-calls.json', lambda value: value[3].update(isError=False))
        with self.assertRaises(ValueError):
            validate_owner(self.root, 1.5)

    def test_replaced_actual_inspection_image(self):
        (self.root / 'actual-inspection-image.bin').write_bytes(png(16, 16))
        with self.assertRaises(ValueError):
            validate_owner(self.root, 1.5)

    def test_changed_imported_source(self):
        (self.root / 'actual-imported-image.bin').write_bytes(png(16, 16))
        with self.assertRaises(ValueError):
            validate_owner(self.root, 1.5)

    def test_source_changed_after_tools(self):
        (self.root / 'actual-imported-image-after.bin').write_bytes(png(16, 16))
        with self.assertRaises(ValueError):
            validate_owner(self.root, 1.5)

    def test_missing_post_tool_source_hash(self):
        self.edit('agent-structured-result.json', lambda value: value.pop('sourceAfterSHA256'))
        with self.assertRaises(ValueError):
            validate_owner(self.root, 1.5)

    def test_saved_project_session_changed(self):
        result = json.loads((self.root / 'agent-structured-result.json').read_text())
        self.edit(result['sessionFile'], lambda value: value.update(messages=[]))
        with self.assertRaises(ValueError):
            validate_owner(self.root, 1.5)

    def test_reopened_transcript_changed(self):
        self.edit('reopened-messages.json', lambda value: value[1]['blocks'][0].update(input='{}'))
        with self.assertRaises(ValueError):
            validate_owner(self.root, 1.5)

    def test_point_dimensions_cannot_replace_pixel_dimensions(self):
        self.edit('agent-structured-result.json', lambda value: value.update(dimensions='16x9'))
        with self.assertRaises(ValueError):
            validate_owner(self.root, 1.5)

    def test_missing_reopened_block_observation(self):
        for name in ['agent-structured-result.json', 'owner.json']:
            self.edit(name, lambda value: value.update(interactions=[a for a in value['interactions']
                if not (a.get('label') == 'reopened structured block' and a.get('evidence', {}).get('turn') == 2)]))
        with self.assertRaises(ValueError):
            validate_owner(self.root, 1.5)

    def test_missing_native_save_shortcut(self):
        for name in ['agent-structured-result.json', 'owner.json']:
            self.edit(name, lambda value: value.update(interactions=[a for a in value['interactions'] if a.get('kind') != 'keyboard']))
        with self.assertRaises(ValueError):
            validate_owner(self.root, 1.5)

    def test_missing_native_detail_click(self):
        for name in ['agent-structured-result.json', 'owner.json']:
            self.edit(name, lambda value: value.update(interactions=[a for a in value['interactions'] if a.get('id') != 'agent.tool.image.done']))
        with self.assertRaises(ValueError):
            validate_owner(self.root, 1.5)

    def test_changed_native_film(self):
        self.edit('timeline-after.json', lambda value: value.update(id='changed'))
        with self.assertRaises(ValueError):
            validate_owner(self.root, 1.5)

    def test_clipped_native_result(self):
        def change(value):
            next(a for a in value['interactions'] if a.get('kind') == 'visible-group')['frames'] = [[950, 10, 100, 25]]
        for name in ['agent-structured-result.json', 'owner.json']:
            self.edit(name, change)
        with self.assertRaises(ValueError):
            validate_owner(self.root, 1.5)

    def test_missing_real_screenshot_bytes(self):
        (self.root / 'actual-0.png').write_bytes(b'not PNG')
        with self.assertRaises(ValueError):
            validate_owner(self.root, 1.5)

    def test_probe_identity_cannot_claim_another_assistant_message(self):
        foreign = str(uuid.UUID(int=999))
        for name in ['agent-structured-result.json', 'owner.json']:
            def replace(value):
                if 'rendered' in value:
                    value['rendered'][0]['messageID'] = foreign
                for action in value['interactions']:
                    if action.get('kind') == 'visible-group':
                        action['ids'] = [identity.replace(str(uuid.UUID(int=101)), foreign) for identity in action['ids']]
            self.edit(name, replace)
        with self.assertRaises(ValueError):
            validate_owner(self.root, 1.5)

    def test_missing_actual_visible_block(self):
        for name in ['agent-structured-result.json', 'owner.json']:
            self.edit(name, lambda value: value.update(interactions=[a for a in value['interactions']
                if a.get('ids') != [f'agent.structured.{str(uuid.UUID(int=104))}.5']]))
        with self.assertRaises(ValueError):
            validate_owner(self.root, 1.5)

    def test_swift_uppercase_message_ids_keep_lowercase_probe_ids(self):
        root = self.root / 'uppercase'
        root.mkdir()
        structured_fixture(root, uppercase_message_ids=True)
        self.assertTrue(validate_owner(root, 1.5)['nativeSavedTranscript'])

    def test_live_message_identity_must_match_the_saved_session(self):
        self.edit('actual-messages.json', lambda value: value[1].update(id=str(uuid.UUID(int=999))))
        with self.assertRaisesRegex(ValueError, 'live, saved and reopened transcripts differ'):
            validate_owner(self.root, 1.5)

    def test_foreign_visible_probe_cannot_pass_with_valid_rendered_values(self):
        for name in ['agent-structured-result.json', 'owner.json']:
            def change(value):
                for action in value['interactions']:
                    if action.get('kind') == 'visible-group':
                        action['ids'] = [identity.replace(str(uuid.UUID(int=101)), str(uuid.UUID(int=999)))
                                         for identity in action['ids']]
            self.edit(name, change)
        with self.assertRaisesRegex(ValueError, 'without actual native visibility'):
            validate_owner(self.root, 1.5)


if __name__ == '__main__':
    unittest.main()
