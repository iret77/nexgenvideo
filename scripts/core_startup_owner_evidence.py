"""Check actual Generic New, explicit enrollment/source decision and four early gates."""
import hashlib
import json
from pathlib import Path
import uuid


def _file(root, name):
    if not isinstance(name, str) or not name or Path(name).name != name:
        raise ValueError('Invalid Core startup evidence path')
    path = root / name
    if not path.is_file() or path.is_symlink():
        raise ValueError('Missing Core startup evidence')
    return path.read_bytes()


def _record(root, name):
    result = json.loads(_file(root, name))
    progress = json.loads(_file(root, result['progress']))
    if progress.get('failure') is not None or progress.get('interactions') != result['interactions'] or progress.get('screenshots') != result['screenshots']:
        raise ValueError('Core startup progress/result mismatch')
    return result


def validate(directory, owner, scale):
    directory = Path(directory)
    if owner.get('coreStartup') != 'core-enrollment-result.json':
        raise ValueError('Core owner skipped native enrollment')
    new = _record(directory, 'core-new-project-result.json')
    start = _record(directory, 'core-enrollment-result.json')
    actions = new['interactions']
    decisions = [a.get('id') for a in actions if a.get('kind') == 'pointer']
    if decisions not in (['home.new'], ['home.new', 'home.format.generic', 'home.format.create']):
        raise ValueError('Core project was not actually created at Home')
    saves = [i for i, a in enumerate(actions) if a.get('kind') == 'save-panel']
    if len(saves) != 1 or saves[0] <= max(i for i, a in enumerate(actions) if a.get('kind') == 'pointer'):
        raise ValueError('Core New omitted its actual Save panel')
    save = actions[saves[0]]
    if save.get('filename') != 'Native Core Film.ngv' or save.get('nativeDirectoryAndFilenameTyped') is not True or save.get('exactURLVerified') is not True:
        raise ValueError('Core New did not save the actual requested project')
    observations = [a['evidence'] for a in actions if a.get('kind') == 'verified-state' and a.get('label') == 'native Generic New remains outside production']
    final = [a['evidence'] for a in start['interactions'] if a.get('kind') == 'verified-state' and a.get('label') == 'native Core startup reached Script']
    if len(observations) != 1 or len(final) != 1:
        raise ValueError('Missing Core enrollment observations')
    before, after = observations[0], final[0]
    initial_bytes, enrolled_bytes = _file(directory, 'core-before-enrollment-ngv.json'), _file(directory, 'core-enrolled-ngv.json')
    initial, enrolled = json.loads(initial_bytes), json.loads(enrolled_bytes)
    identity = str(uuid.UUID(initial['id'])).lower()
    if (initial['id'].lower() != identity or enrolled['id'].lower() != identity or before.get('projectID', '').lower() != identity
        or after.get('projectID', '').lower() != identity or after.get('enrolledProjectID', '').lower() != identity
        or initial.get('productionContract') is not None
        or any(initial.get(k) is not None or enrolled.get(k) is not None for k in ('activePlugin', 'activePluginVersion', 'activePluginProjectSchema'))
        or enrolled.get('productionContract') != {'id': 'core.production.v2', 'version': '2.0.0'}
        or before.get('settingsSHA256') != hashlib.sha256(initial_bytes).hexdigest() or after.get('settingsSHA256') != hashlib.sha256(enrolled_bytes).hexdigest()
        or before.get('viewport') != {'width': 960, 'height': 640, 'textScale': scale} or after.get('viewport') != before['viewport']
        or after.get('sourceDisposition') != 'greenfield' or after.get('liveAgent') is not False or after.get('fixtureCanonicalWrites') is not True):
        raise ValueError('Core enrollment changed identity, mode or scale')
    actions = start['interactions']
    workspace = [i for i, a in enumerate(actions) if a.get('kind') == 'pointer' and a.get('id') == 'editor.workspace.production']
    starts = [i for i, a in enumerate(actions) if a.get('kind') == 'pointer' and a.get('id') == 'dock.start']
    confirms = [i for i, a in enumerate(actions) if a.get('label') == 'native-dialog-pointer' and a.get('evidence', {}).get('title') == 'Start Production']
    choices = [i for i, a in enumerate(actions) if a.get('kind') == 'pointer' and a.get('id') == 'story-source.greenfield']
    approvals = [i for i, a in enumerate(actions) if a.get('kind') == 'pointer' and a.get('id') == 'agent.gate.approve']
    if len(workspace) != 1 or len(starts) != 1 or workspace[0] >= starts[0] or len(confirms) != 1 or len(choices) != 1 or len(approvals) != 4 or not starts[0] < confirms[0] < approvals[0] < choices[0] < approvals[1] < approvals[2] < approvals[3]:
        raise ValueError('Core confirmation/source choice/visible approvals were skipped or reordered')
    observed = [(i, a['evidence']) for i, a in enumerate(actions) if a.get('kind') == 'verified-state' and a.get('label', '').startswith('native approval ')]
    gates = [gate for _, gate in observed]
    if len(observed) != len(approvals) or any(not approvals[n] < index < (approvals[n + 1] if n + 1 < len(approvals) else len(actions)) for n, (index, _) in enumerate(observed)):
        raise ValueError('Core approval observations are not ordered after their actual clicks')
    if gates != owner.get('nativeGateApprovals', [])[:4] or [g.get('phase') for g in gates] != ['project_init', 'brief', 'production_design', 'treatment']:
        raise ValueError('Core early approvals are not joined to the actual owner gate sequence')
    all_gates = owner.get('nativeGateApprovals', [])
    if len(all_gates) == 13:
        native = owner.get('nativeEvidence', {})
        progress = json.loads(_file(directory, native['progress']))
        if progress.get('failure') is not None or progress.get('interactions') != native['interactions'] or progress.get('screenshots') != native['screenshots']:
            raise ValueError('Core later gate progress/result mismatch')
        later = native['interactions']
        clicks = [i for i, event in enumerate(later) if event.get('kind') == 'pointer' and event.get('id') == 'agent.gate.approve']
        records = [(i, event['evidence']) for i, event in enumerate(later) if event.get('kind') == 'verified-state' and event.get('label', '').startswith('native approval ')]
        if ([gate for _, gate in records] != all_gates[4:] or len(clicks) != 9
            or any(not clicks[n] < index < (clicks[n + 1] if n + 1 < len(clicks) else len(later)) for n, (index, _) in enumerate(records))):
            raise ValueError('Core later approvals lack their actual ordered native clicks')
    requests = after.get('phaseRequests', [])
    distinct = [p for i, p in enumerate(requests) if not i or p != requests[i - 1]]
    if distinct != ['project_init', 'brief', 'production_design', 'treatment', 'script']:
        raise ValueError('Core actual runtime skipped or received a different phase document')
    retained = {}
    for artifact in after['artifacts']:
        data = _file(directory, artifact['retained'])
        if artifact['path'] in retained or hashlib.sha256(data).hexdigest() != artifact['sha256']:
            raise ValueError('Core canonical artifact bytes changed')
        retained[artifact['path']] = data
    source = json.loads(retained['brief/story-source.v1.json'])
    receipt = source.get('declineReceipt', {})
    selection_bytes = retained[receipt['path']]
    selection = json.loads(selection_bytes)
    if (source.get('schema') != 'story-source/v1' or source.get('source') is not None
        or hashlib.sha256(selection_bytes).hexdigest() != receipt['sha256']
        or retained['brief/story-source-selection.v1.json'] != selection_bytes or selection.get('source') is not None
        or selection.get('schema') != 'story-source-selection/v1' or selection.get('workflowID') != 'core.production.v2'
        or selection.get('projectID') != source.get('header', {}).get('projectID')):
        raise ValueError('Core greenfield choice lacks its actual current/archive selection bytes')
    required = {'project.yaml', 'brief.yaml', 'production_design/production_design.yaml', 'treatment/current.md', 'script/current.v1.json', 'gates.yaml'}
    if not required.issubset(retained):
        raise ValueError('Core startup omitted canonical initial artifacts')
    images = new['screenshots'] + start['screenshots']
    if len(images) != len(set(images)) or len(images) < 8 or not any('explicit-greenfield-selection' in n for n in images):
        raise ValueError('Missing actual Core startup images')
    for name in images:
        data = _file(directory, name)
        if len(data) <= 1000 or not data.startswith(b'\x89PNG\r\n\x1a\n'):
            raise ValueError('Invalid Core startup screenshot')
    return images
