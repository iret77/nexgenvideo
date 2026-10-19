"""Synthetic independent-oracle fixtures; never native playback evidence."""
import hashlib
import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from playback_reanalysis_evidence import validate


def fixture(root, scale=1, analysis_gate=None):
    def put(name, value):
        raw = json.dumps(value, sort_keys=True).encode(); (root / name).write_bytes(raw)
        return {'path': name, 'retained': name, 'sha256': hashlib.sha256(raw).hexdigest()}
    track_path = root / 'intake-track-assigned.bin'
    if not track_path.exists(): track_path.write_bytes(b'controlled parser-only audio')
    sha = hashlib.sha256(track_path.read_bytes()).hexdigest()
    settings_path = root / 'native-new-project-ngv.json'
    if not settings_path.exists(): put(settings_path.name, {'id': '00000000-0000-4000-8000-000000000001'})
    key = json.loads(settings_path.read_bytes())['id']
    old_analysis = put('old-analysis.json', dict(project='Native Music Video', song_sha256=sha, generated='before'))
    new_analysis = put('new-analysis.json', dict(project='Native Music Video', song_sha256=sha, generated='after'))
    clock = dict(ticksPerSecond=30, fpsNumerator=30, fpsDenominator=1)
    selection = dict(schema='playback-range-selection/v1', id='old', projectID='Native Music Video', workflowID='musicvideo.pipeline.v2',
        audio=dict(sha256=sha), analysis=old_analysis, timebase=clock, audioDurationTicks=240, kind='excerpt', startTicks=0, durationTicks=120)
    old = put('old-selection.json', selection)
    current = dict(selection, id='new', analysis=new_analysis, kind='fullSong', durationTicks=240)
    new = put('new-selection.json', current)
    applied = put('applied.json', dict(schema='playback-range/v1', kind='fullSong', startTicks=0, durationTicks=240,
        audioDurationTicks=240, analysis=new_analysis, timebase=clock, header=dict(inputs=[new])))
    native_applied = put('native-applied.json', json.loads((root / applied['retained']).read_bytes()))
    applied['path'] = native_applied['path'] = 'brief/playback-range.v1.json'
    gates = {name: put(name + '.yaml', dict(gates=dict(analysis=dict(approved=value))))
        for name, value in [('before', True), ('rewound', False), ('approved', True)]}
    images = ['actual-' + name + '.png' for name in ('excerpt', 'blocked', 'ready', 'approved', 'stale', 'applied')]
    historical = ['old-blocked.png', 'old-ready.png', 'old-approved.png']
    for name in images + historical: (root / name).write_bytes(b'\x89PNG\r\n\x1a\n' + b'only unit data' * 100)
    first = dict(phase='analysis', artifactSHA256=old_analysis['sha256'], handoffTurnID='first', screenshots=historical,
        blockedBeforeApproval=True, readyBeforeClick=True, approvedPersisted=True)
    second = dict(analysis_gate or {}, phase='analysis', nextPhase='brief', artifactSHA256=new_analysis['sha256'],
        handoffTurnID=analysis_gate['handoffTurnID'] if analysis_gate else 'second',
        screenshots=images[1:4], gatesAfterSHA256=gates['approved']['sha256'], handoffPhase='brief', handoffHidden=True,
        blockedBeforeApproval=True, readyBeforeClick=True, approvedPersisted=True)
    observation = dict(projectKey=key, viewport=dict(width=960, height=640, textScale=scale), sameSourceSHA256=sha,
        oldSelection=old, currentSelection=new, oldAnalysis=old_analysis, currentAnalysis=new_analysis, appliedRange=applied, appliedRangeFromUI=native_applied,
        beforeRewind=gates['before'], afterRewind=gates['rewound'], afterApproval=gates['approved'],
        firstApproval=first, secondApproval=second, currentAnalysisGateReplacesEarlierApproval=True,
        liveAgent=False, liveAnalyzerQualityClaim=False, reanalysisRequest=['Continue analysis'], reanalysisResultIsError=False)
    def click(identifier): return dict(kind='pointer', id=identifier)
    events = [dict(kind='text', field=dict(id='playback-range.' + name, actual=value, commitInput='Tab', fontPointSize=13 * scale))
              for name, value in [('start', '0'), ('end', '4')]]
    events += [click('playback-range.apply'), dict(kind='menu', id='pipeline.overview.actions.analysis', item='Rewind to here…'),
        dict(kind='verified-state', label='native-dialog-pointer', evidence=dict(title='Rewind to Audio Analysis')),
        click('pipeline.overview.dock.continue'), click('agent.gate.approve'),
        dict(kind='verified-state', label='actual stale playback selection refused', evidence=dict(oldSelectionSHA256=old['sha256'],
            analysisSHA256=new_analysis['sha256'], kind='fullSong', requiresConfirmation=True, materializeRefused=True, applyEnabled=True)),
        click('playback-range.apply'), dict(kind='verified-state', label='native range reanalysis confirmed', evidence=observation)]
    result = dict(progress='progress.json', interactions=events, screenshots=images)
    write_result(root, result)
    return result, [second]


def write_result(root, result):
    (root / 'playback-reanalysis-result.json').write_text(json.dumps(result))
    (root / result['progress']).write_text(json.dumps({**result, 'failure': None}))


class PlaybackReanalysisEvidenceTests(unittest.TestCase):
    def test_complete_controlled_oracle_fixture(self):
        for reuse_intake in (False, True):
            with self.subTest(reuse_intake=reuse_intake), TemporaryDirectory() as temp:
                root = Path(temp)
                template = None
                if reuse_intake:
                    track = b'previously assigned intake audio'
                    settings = json.dumps({'id': '00000000-0000-4000-8000-000000000009',
                                           'activePlugin': 'musicvideo'}).encode()
                    (root / 'intake-track-assigned.bin').write_bytes(track)
                    (root / 'native-new-project-ngv.json').write_bytes(settings)
                    template = {'handoffTurnID': '00000000-0000-4000-8000-000000000010',
                                'surface': 'production', 'packagedInstructions': True}
                _, gates = fixture(root, analysis_gate=template)
                self.assertEqual(len(validate(root, gates, 1)), 6)
                if reuse_intake:
                    self.assertEqual((root / 'intake-track-assigned.bin').read_bytes(), track)
                    self.assertEqual((root / 'native-new-project-ngv.json').read_bytes(), settings)
                    self.assertTrue(all(gates[0][key] == value for key, value in template.items()))

    def test_explicit_apply_and_current_gate_join_required(self):
        for fault in ('missing-apply', 'apply-before-reapproval', 'old-gate', 'wrong-scale', 'late-keyboard', 'early-observation', 'wrong-viewport'):
            with self.subTest(fault=fault), TemporaryDirectory() as temp:
                root = Path(temp); result, gates = fixture(root)
                if fault == 'missing-apply': result['interactions'].pop(-2)
                elif fault == 'apply-before-reapproval': result['interactions'].insert(0, result['interactions'].pop(-2))
                elif fault == 'old-gate': gates = [result['interactions'][-1]['evidence']['firstApproval']]
                elif fault == 'late-keyboard': result['interactions'].insert(-1, result['interactions'].pop(0))
                elif fault == 'early-observation': result['interactions'].insert(0, result['interactions'].pop())
                elif fault == 'wrong-viewport': result['interactions'][-1]['evidence']['viewport']['textScale'] = 1.5
                write_result(root, result)
                with self.assertRaises(ValueError): validate(root, gates, 1.5 if fault == 'wrong-scale' else 1)

    def test_rehashed_foreign_source_is_not_same_source_reanalysis(self):
        with TemporaryDirectory() as temp:
            root = Path(temp); result, gates = fixture(root)
            observation = result['interactions'][-1]['evidence']; ref = observation['currentAnalysis']
            value = json.loads((root / ref['retained']).read_bytes()); value['song_sha256'] = 'f' * 64
            raw = json.dumps(value, sort_keys=True).encode(); (root / ref['retained']).write_bytes(raw)
            ref['sha256'] = hashlib.sha256(raw).hexdigest()
            selected_ref = observation['currentSelection']
            selected = json.loads((root / selected_ref['retained']).read_bytes()); selected['analysis'] = ref
            selected_bytes = json.dumps(selected, sort_keys=True).encode(); (root / selected_ref['retained']).write_bytes(selected_bytes)
            selected_ref['sha256'] = hashlib.sha256(selected_bytes).hexdigest()
            for key in ('appliedRange', 'appliedRangeFromUI'):
                applied_ref = observation[key]
                applied = json.loads((root / applied_ref['retained']).read_bytes()); applied['analysis'] = ref; applied['header']['inputs'] = [selected_ref]
                applied_bytes = json.dumps(applied, sort_keys=True).encode(); (root / applied_ref['retained']).write_bytes(applied_bytes)
                applied_ref['sha256'] = hashlib.sha256(applied_bytes).hexdigest()
            observation['secondApproval']['artifactSHA256'] = ref['sha256']
            next(e['evidence'] for e in result['interactions'] if e.get('label') == 'actual stale playback selection refused')['analysisSHA256'] = ref['sha256']
            write_result(root, result)
            with self.assertRaisesRegex(ValueError, 'actual canonical project/source binding'): validate(root, gates, 1)

    def test_brief_writer_cannot_hide_an_unapplied_native_range(self):
        for fault in ('old-native-range', 'excerpt-receipt', 'wrong-path'):
            with self.subTest(fault=fault), TemporaryDirectory() as temp:
                root = Path(temp); result, gates = fixture(root)
                ref = result['interactions'][-1]['evidence']['appliedRangeFromUI']
                value = json.loads((root / ref['retained']).read_bytes())
                if fault == 'old-native-range': value.update(kind='excerpt', durationTicks=120)
                elif fault == 'excerpt-receipt': value['selectionReceipt'] = {'id': 'old'}
                else: ref['path'] = 'unrelated/range.json'
                raw = json.dumps(value, sort_keys=True).encode(); (root / ref['retained']).write_bytes(raw)
                ref['sha256'] = hashlib.sha256(raw).hexdigest(); write_result(root, result)
                with self.assertRaisesRegex(ValueError, 'Applied range is not bound'): validate(root, gates, 1)
