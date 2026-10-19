"""Actual same-project native rewind, reanalysis and explicit range reconfirmation."""
import hashlib
import json
from decimal import Decimal
import re
from pathlib import Path

from production_bible_entity_evidence import parsed_yaml


def validate(directory, current_gates, scale):
    root = Path(directory)

    def read(name):
        if not isinstance(name, str) or Path(name).name != name or name.startswith('.') or (root / name).is_symlink():
            raise ValueError('Invalid retained playback evidence path')
        return (root / name).read_bytes()

    def require(value, reason):
        if not value: raise ValueError(reason)

    result = json.loads(read('playback-reanalysis-result.json'))
    progress = json.loads(read(result['progress']))
    events = result['interactions']
    require(progress.get('failure') is None and progress.get('interactions') == events
            and progress.get('screenshots') == result['screenshots'], 'Playback native progress mismatch')
    observations = [e['evidence'] for e in events if e.get('kind') == 'verified-state' and e.get('label') == 'native range reanalysis confirmed']
    require(len(observations) == 1, 'Missing actual playback reanalysis observation')
    evidence = observations[0]
    require(evidence.get('liveAgent') is False and evidence.get('liveAnalyzerQualityClaim') is False
            and evidence.get('currentAnalysisGateReplacesEarlierApproval') is True, 'Incorrect playback fixture scope')
    refs = {}
    for key in ('oldSelection', 'currentSelection', 'oldAnalysis', 'currentAnalysis', 'appliedRange', 'appliedRangeFromUI', 'beforeRewind', 'afterRewind', 'afterApproval'):
        reference = evidence[key]
        data = read(reference['retained'])
        require(hashlib.sha256(data).hexdigest() == reference['sha256'], 'Retained playback source bytes changed')
        refs[key] = parsed_yaml(data) if key in ('beforeRewind', 'afterRewind', 'afterApproval') else json.loads(data)
    old, current = refs['oldSelection'], refs['currentSelection']
    track = hashlib.sha256(read('intake-track-assigned.bin')).hexdigest()
    created = json.loads(read('native-new-project-ngv.json'))
    require(evidence['projectKey'] == created['id'] and evidence['sameSourceSHA256'] == track, 'Playback reanalysis changed its actual native project/source')
    require(old['schema'] == current['schema'] == 'playback-range-selection/v1'
            and old['id'] != current['id'] and old['kind'] == 'excerpt' and current['kind'] == 'fullSong' and old['timebase'] == current['timebase']
            and old['projectID'] == current['projectID'] and old['workflowID'] == current['workflowID'] == 'musicvideo.pipeline.v2'
            and old['audio']['sha256'] == current['audio']['sha256'] == track
            and old['analysis']['sha256'] == evidence['oldAnalysis']['sha256']
            and current['analysis']['sha256'] == evidence['currentAnalysis']['sha256']
            and old['analysis']['sha256'] != current['analysis']['sha256'], 'Playback native selection did not advance to the current same-source analysis')
    for key in ('appliedRangeFromUI', 'appliedRange'):
        applied = refs[key]
        require(evidence[key]['path'] == 'brief/playback-range.v1.json' and applied['schema'] == 'playback-range/v1'
                and applied['kind'] == 'fullSong' and applied.get('selectionReceipt') is None and applied['startTicks'] == current['startTicks'] == 0
                and applied['durationTicks'] == applied['audioDurationTicks'] == current['durationTicks'] == current['audioDurationTicks']
                and applied['analysis'] == current['analysis'] and applied['timebase'] == current['timebase']
                and any(ref['path'] == evidence['currentSelection']['path'] and ref['sha256'] == evidence['currentSelection']['sha256'] for ref in applied['header']['inputs']),
                'Applied range is not bound to the new actual native receipt')
    require(refs['oldAnalysis']['song_sha256'] == refs['currentAnalysis']['song_sha256'] == track
            and refs['oldAnalysis']['project'] == refs['currentAnalysis']['project'] == current['projectID'], 'Reanalysis changed actual canonical project/source binding')
    applies = [i for i, e in enumerate(events) if e.get('kind') == 'pointer' and e.get('id') == 'playback-range.apply']
    require(len(applies) == 2, 'Missing actual native Apply actions')
    typed = [(i, event['field']) for i, event in enumerate(events) if event.get('kind') == 'text']
    for identifier, expected in (('playback-range.start', 0), ('playback-range.end', old['durationTicks'])):
        matches = [field for i, field in typed if field.get('id') == identifier and i < applies[0]]
        require(len(matches) == 1 and matches[0].get('commitInput') == 'Tab'
                and isinstance(matches[0].get('actual'), str) and re.fullmatch(r'[0-9]+(?:\.[0-9]+)?', matches[0]['actual'])
                and Decimal(matches[0]['actual']) * old['timebase']['ticksPerSecond'] == expected
                and abs(matches[0].get('fontPointSize', 0) - 13 * scale) < .5, 'Actual native range keyboard value or typography differs')
    for key, expected in (('beforeRewind', True), ('afterRewind', False), ('afterApproval', True)):
        require(refs[key]['gates']['analysis']['approved'] is expected, 'Native reanalysis gate transition differs')
    first, second = evidence['firstApproval'], evidence['secondApproval']
    final = [g for g in current_gates if g.get('phase') == 'analysis']
    require(first['phase'] == second['phase'] == 'analysis' and final == [second]
            and first['artifactSHA256'] == evidence['oldAnalysis']['sha256'] and second['artifactSHA256'] == evidence['currentAnalysis']['sha256']
            and first['handoffTurnID'] != second['handoffTurnID'] and second['gatesAfterSHA256'] == evidence['afterApproval']['sha256']
            and first['blockedBeforeApproval'] is True and first['readyBeforeClick'] is True and first['approvedPersisted'] is True
            and second['nextPhase'] == second['handoffPhase'] == 'brief' and second['handoffHidden'] is True
            and second['blockedBeforeApproval'] is True and second['readyBeforeClick'] is True and second['approvedPersisted'] is True,
            'Current phase join lost the actual second native analysis approval')
    rewinds = [i for i, e in enumerate(events) if e.get('kind') == 'menu' and e.get('id') == 'pipeline.overview.actions.analysis' and e.get('item') == 'Rewind to here…']
    confirmations = [i for i, e in enumerate(events) if e.get('kind') == 'verified-state' and e.get('label') == 'native-dialog-pointer' and e.get('evidence', {}).get('title') == 'Rewind to Audio Analysis']
    continues = [i for i, e in enumerate(events) if e.get('kind') == 'pointer' and e.get('id') == 'pipeline.overview.dock.continue']
    approvals = [i for i, e in enumerate(events) if e.get('kind') == 'pointer' and e.get('id') == 'agent.gate.approve']
    stale = [(i, e['evidence']) for i, e in enumerate(events) if e.get('kind') == 'verified-state' and e.get('label') == 'actual stale playback selection refused']
    require(len(applies) == 2 and len(rewinds) == len(confirmations) == len(continues) == len(approvals) == len(stale) == 1
            and applies[0] < rewinds[0] < confirmations[0] < continues[0] < approvals[0] < stale[0][0] < applies[1],
            'Native rewind/reanalysis/reapproval/explicit Apply actions were skipped or reordered')
    require(next(i for i, e in enumerate(events) if e.get('label') == 'native range reanalysis confirmed') > applies[1], 'Range observation precedes actual Apply')
    require(stale[0][1] == dict(oldSelectionSHA256=evidence['oldSelection']['sha256'], analysisSHA256=evidence['currentAnalysis']['sha256'],
        kind='fullSong', requiresConfirmation=True, materializeRefused=True, applyEnabled=True), 'Stale range did not require explicit native confirmation')
    require(evidence['reanalysisResultIsError'] is False and any('analysis' in text.lower() for text in evidence['reanalysisRequest']), 'Actual native reanalysis tool roundtrip missing')
    all_images = result['screenshots'] + first['screenshots']
    require(set(second['screenshots']).issubset(result['screenshots']), 'Second approval lost its actual native screenshots')
    require(len(all_images) == len(set(all_images)), 'Playback observations reuse image names')
    for name in all_images:
        data = read(name)
        require(len(data) > 1000 and data.startswith(b'\x89PNG\r\n\x1a\n'), 'Missing actual playback observation image')
    require(scale in (1, 1.25, 1.5) and evidence.get('viewport') == {'width': 960, 'height': 640, 'textScale': scale}, 'Actual outer playback viewport or scale differs')
    return [name for name in all_images if name not in second['screenshots']]
