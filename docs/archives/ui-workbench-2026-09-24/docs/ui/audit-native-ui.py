from pathlib import Path
from collections import Counter
import argparse
import csv
import hashlib
import json
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'docs/ui/review'
BASELINE = OUT / 'native-ui-inventory-2026-09-18.json'
MATRIX = OUT / 'native-ui-capabilities.tsv'
STATUS = {
    'simulated': 'Im Clickdummy abgebildet (Simulation)',
    'illustrated': 'Im Dummy illustriert',
    'partial': 'Teilweise',
    'missing': 'Fehlt',
    'regression': 'Widerspricht Bestand',
    'adapter': 'Ersatzinteraktion fehlt',
    'native-shell': 'Native Oberfläche erhalten',
    'proposal': 'Neue Fähigkeit/Vertragsarbeit',
}
TOOL_GROUPS = {
    'APP-07': 'undo',
    'APP-08': 'sendFeedback',
    'MED-01': 'importMedia',
    'MED-02': 'listFolders createFolder moveToFolder renameFolder deleteFolder',
    'MED-03': 'renameMedia deleteMedia',
    'MED-06': 'searchMedia',
    'MED-07': 'getTranscript',
    'MED-10': 'inspectMedia',
    'MED-11': 'getMedia',
    'GEN-01': 'generateVideo generateImage generateAudio',
    'GEN-02': 'listModels resolveModel runProviderTool',
    'GEN-07': 'prepareGenerationBatch getGenerationBatches',
    'GEN-09': 'upscaleMedia',
    'NLE-01': 'getTimeline addClips moveClips setClipProperties',
    'NLE-02': 'removeTracks',
    'NLE-04': 'removeClips splitClip rippleDeleteRanges',
    'NLE-05': 'insertClips',
    'NLE-10': 'syncAudio',
    'POST-03': 'setKeyframes',
    'POST-05': 'applyColor',
    'POST-09': 'applyEffect',
    'POST-13': 'inspectColor',
    'POST-15': 'addTexts',
    'POST-16': 'addCaptions',
    'POST-17': 'removeWords',
    'PROD-01': 'getUIContract listPhases',
    'PROD-02': 'initProject attachSong',
    'PROD-04': 'writeAnalysisInterpretation',
    'PROD-06': 'writeBrief writeProductionDesign writeTreatment writeStoryboard',
    'PROD-07': 'suggestPatterns recordAffect getPattern',
    'PROD-08': 'getBible writeBible',
    'PROD-10': 'getLedger setLedgerAttribute lockLedgerAttribute removeLedgerAttribute',
    'PROD-11': 'writeShotlist',
    'PROD-14': 'extractScene3dPovs',
    'PROD-16': 'runSanity',
    'PROD-17': 'getFramesManifest saveFrameAudit getFrameAudit cropToAspect',
    'PROD-19': 'nextRenderShot recordRender getRenderManifest',
    'PROD-22': 'getProjectState approveGate rewind setGateState showArtifact estimateCost runPhase',
    'PROD-23': 'assembleTimeline',
    'AGENT-01': 'showDialog',
    'AGENT-02': 'showBlocks inspectTimeline',
    'FIN-03': 'exportProject',
    'CORE-01': 'writePhaseExtension listProjectFiles copyProjectFile',
    'CORE-03': 'compilePrompt',
    'CORE-04': 'getProductionKnowledge',
}
UI_SUPPORT = {
    'AppRelaunchSelfTest.swift': ['APP-08'],
    'SplashScreen.swift': ['APP-02'],
    'SettingsView.swift': ['SET-01', 'SET-02', 'SET-03', 'SET-04', 'PACK-01', 'AGENT-06', 'AGENT-07'],
    'AgentInputBox.swift': ['AGENT-01', 'AGENT-04', 'AGENT-05'],
    'MarkdownText.swift': ['AGENT-02'],
    'ThinkingDots.swift': ['AGENT-03'],
    'AgentTranscriptLayout.swift': ['AGENT-02', 'AGENT-03'],
    'AgentTranscriptProjection.swift': ['AGENT-02', 'AGENT-03'],
    'GateApprovalCard.swift': ['PROD-22'],
    'LibraryAssetPicker.swift': ['MED-11', 'PROD-03'],
    'PluginLauncherPopover.swift': ['PROD-01', 'AGENT-05'],
    'StoryboardReviewSheet.swift': ['PROD-06'],
    'PipelineStoryboardReviewSheet.swift': ['PROD-06'],
    'GateReviewModel.swift': ['PROD-22'],
    'UpdateBadgeView.swift': ['APP-08'],
    'EditorWindowContentView.swift': ['APP-03', 'APP-05', 'APP-06'],
    'ExportButton.swift': ['FIN-03'],
    'LeftSidebarView.swift': ['APP-05', 'MED-11', 'PROD-01'],
    'CockpitStateView.swift': ['PROD-01', 'PROD-22'],
    'PluginPickerView.swift': ['PACK-01', 'PACK-02'],
    'AdjustSlider.swift': ['POST-05', 'POST-09'],
    'ColorField.swift': ['POST-15'],
    'FontPickerField.swift': ['POST-15'],
    'ScrubbableNumberField.swift': ['POST-01', 'POST-14'],
    'TextContentField.swift': ['POST-15'],
    'ColorWheelPad.swift': ['POST-07'],
    'InspectorPositionFields.swift': ['POST-01', 'POST-15'],
    'InspectorRow.swift': ['APP-10'],
    'InspectorSection.swift': ['APP-10'],
    'MediaPanelView.swift': ['MED-01', 'GEN-01', 'POST-16', 'GEN-11'],
    'MediaPanelToast.swift': ['MED-01'],
    'NewProjectFormatSheet.swift': ['APP-01', 'PACK-01'],
    'AIEditMenu.swift': ['GEN-09', 'GEN-10'],
    'TimelineView+AIEditMenu.swift': ['GEN-09', 'GEN-10'],
    'DropZoneView.swift': ['GEN-03', 'MED-05'],
    'ClipGeneratingOverlay.swift': ['GEN-08'],
    'TimelineContainerView.swift': ['NLE-01', 'NLE-06'],
    'PlayheadOverlay.swift': ['VIEW-02'],
    'SnapIndicatorOverlay.swift': ['NLE-06'],
    'AppTheme.swift': ['APP-10'],
    'CapsuleButton.swift': ['APP-10'],
    'InlineActionButton.swift': ['APP-10'],
    'NativeChoicePicker.swift': ['APP-10'],
    'SegmentedTabBar.swift': ['APP-10'],
    'SidebarRowButton.swift': ['APP-10'],
    'DesignSystem.swift': ['APP-10'],
    'HoverHighlight.swift': ['APP-10'],
    'MouseWheelScroll.swift': ['APP-10'],
    'ScopeChip.swift': ['APP-10', 'AGENT-04'],
    'WrapLayout.swift': ['APP-10'],
}
CONTROL = re.compile(r'\b(?:Button|Toggle|Menu|Picker|Slider|TextField|SecureField|TextEditor|NSMenuItem)\b|\.contextMenu|\.keyboardShortcut|\.onTapGesture|\.help\(')
VIEW = re.compile(r'\b(?:struct|class)\s+\w+(?:<[^\n]*?>)?\s*:\s*(?:View\b|NSView\b|NSViewRepresentable\b|NSViewControllerRepresentable\b)')


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def inventory():
    swift = sorted(set((ROOT / 'Sources').rglob('*.swift')) | set((ROOT / 'Engine/Sources').rglob('*.swift')))
    candidates = swift + list((ROOT / 'docs').glob('*.md'))
    rows = list(csv.DictReader(MATRIX.open(), delimiter='\t'))
    ids = {r['id'] for r in rows}
    assert len(ids) == len(rows), 'Duplicate capability id'
    refs = {}
    for row in rows:
        assert row['mock_status'] in STATUS and all(row.values()), row
        evidence = []
        for ref in row['sources'].split(';'):
            name, _, anchor = ref.partition('@')
            exact = ROOT / name
            matches = [exact] if exact.is_file() else [p for p in candidates if p.name == name]
            assert len(matches) == 1, (row['id'], 'Ambiguous/missing source', ref, matches)
            path = matches[0]
            lines = path.read_text().splitlines()
            assert not anchor or any(anchor in l for l in lines), (row['id'], 'Missing symbol', ref)
            line = next((i for i, l in enumerate(lines, 1) if anchor and anchor in l), 1)
            relative = str(path.relative_to(ROOT))
            evidence.append({'path': relative, 'line': line, 'anchor': anchor})
            refs.setdefault(relative, set()).add(row['id'])
        row['evidence'] = evidence

    controls = []
    for path in swift:
        relative = str(path.relative_to(ROOT))
        source = path.read_text()
        hits = [{'line': n, 'text': line.strip()} for n, line in enumerate(source.splitlines(), 1) if CONTROL.search(line)]
        if not hits and not VIEW.search(source):
            continue
        if 'FixtureFictionPlugin' in relative:
            continue
        assigned = sorted(refs.get(relative, set()) | set(UI_SUPPORT.get(path.name, [])))
        controls.append({'path': relative, 'capabilities': assigned, 'anchors': hits})
    unmapped = [c['path'] for c in controls if not c['capabilities']]
    assert not unmapped, ('Unmapped UI candidate files', unmapped)
    assert all(set(c['capabilities']) <= ids for c in controls), 'Unknown UI capability mapping'

    tool_path = ROOT / 'Sources/NexGenVideo/Agent/Tools/ToolDefinitions.swift'
    tools = re.findall(r'^    case (\w+) = "([a-z0-9_]+)"', tool_path.read_text(), re.M)
    mapping = {}
    for cap, names in TOOL_GROUPS.items():
        assert cap in ids
        for name in names.split():
            assert name not in mapping, name
            mapping[name] = cap
    assert set(mapping) == {name for name, _ in tools}, ('Tool mapping drift', set(mapping) ^ {name for name, _ in tools})
    runtime = []
    for directory in ['Sources', 'Engine/Sources']:
        for path in (ROOT / directory).rglob('*'):
            if path.is_file() and path.suffix in {'.swift', '.metal', '.json', '.yaml', '.yml', '.md', '.plist'}:
                runtime.append({'path': str(path.relative_to(ROOT)), 'sha256': digest(path)})
    mock = [{'path': str(p.relative_to(ROOT)), 'sha256': digest(p)} for p in sorted((ROOT / 'docs/ui').glob('desktop-production-workbench.*'))]
    return {
        'schema': 1,
        'scope': 'Static UI/function preservation audit; inventory coverage is not semantic or runtime proof.',
        'head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
        'summary': {'capabilities': len(rows), 'status': dict(Counter(r['mock_status'] for r in rows)), 'swift_files': len(swift), 'runtime_files': len(runtime), 'ui_candidate_files': len(controls), 'control_anchors': sum(len(c['anchors']) for c in controls), 'agent_tools': len(tools), 'mock_parity_complete': False},
        'runtime_files': sorted(runtime, key=lambda r: r['path']),
        'mock_files': mock,
        'ui_candidates': controls,
        'agent_tools': [{'symbol': n, 'name': name, 'capability': mapping[n]} for n, name in tools],
        'capabilities': rows,
    }


def markdown(data):
    s = data['summary']
    out = ['# Funktionsmatrix: nativer Bestand → Clickdummy → zu erhaltender Einstieg', '',
           f"Quellenstand `{data['head'][:8]}`. {s['capabilities']} Funktionsgruppen; keine Paritätsfreigabe.", '',
           'Die Matrix unterscheidet UI-Bestand, Engine-/Tool-Fähigkeiten, Dummy-Abdeckung und neue Vorschläge. „Im Clickdummy abgebildet“ bezeichnet erreichbare Beispieloberflächen und Zustandsmodelle, keine native Implementierungsgleichheit. Die jeweilige Beobachtung nennt Simulationsgrenzen. „Native Oberfläche erhalten“ ist ein konkreter Übernahmeauftrag für bestehende Fenster/Menüs, keine nachträgliche Ausnahme von Funktionserhalt.', '',
           'Neue Zielorte ändern keine gesperrten Verträge. Fehlende Funktionen bleiben offene Umsetzungspunkte; diese Tabelle macht sie nicht automatisch implementiert.', '']
    for area in dict.fromkeys(r['area'] for r in data['capabilities']):
        out += [f'## {area}', '', '| ID / Funktion / Codebeleg | Dummy-Befund | Erhalten / Abnahmeszenario |', '|---|---|---|']
        for r in data['capabilities']:
            if r['area'] != area:
                continue
            links = ', '.join(f"[{Path(e['path']).name}](../../../{e['path']}#L{e['line']})" for e in r['evidence'])
            cells = [f"**{r['id']} · {r['capability']}**<br>{links}", f"**{STATUS[r['mock_status']]}**<br>{r['mock_observation']}", f"**{r['preserve_at']}**<br>{r['acceptance']}"]
            out.append('| ' + ' | '.join(c.replace('|', '\\|') for c in cells) + ' |')
        out.append('')
    out += ['## Nachvollziehbarkeit der Erfassung', '',
            f"Alle {s['ui_candidate_files']} statisch gefundenen UI-/Kontrolldateien sind Funktionsgruppen zugeordnet. {s['control_anchors']} Kontroll-/Interaktionsanker sind mit Zeile und Text im JSON-Inventar enthalten. Der Scan ist absichtlich konservativ und enthält auch wiederverwendbare Primitives und Kommentar-/Typ-Treffer. Er ist kein Swift-Parser und kein Beweis für die Semantik jeder Aktion.", '',
            f"Alle {s['agent_tools']} expliziten AgentToolName-Einträge sind zugeordnet. Pack-Beiträge, dynamische Eingabeschemas und die zusätzlichen räumlichen/Musicvideo-Writer sind separat unter PROD/PACK/CORE erfasst. Alle {s['swift_files']} Swift-Dateien sowie weitere Runtime-Verträge/Ressourcen sind mit Hash inventarisiert; nicht jede Implementierungszeile wurde manuell geprüft.", '',
            'Validierung: `python3 docs/ui/audit-native-ui.py` prüft Quellbelege, Zuordnungslücken sowie Änderungen gegenüber dem Snapshot. `--write` aktualisiert den Snapshot nach erneutem Review. Das ist eine statische Dokumentationsprüfung, kein App-Build und kein nativer Laufzeittest.', '']
    return '\n'.join(out)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--write', action='store_true')
    args = parser.parse_args()
    data = inventory()
    report = OUT / 'native-ui-function-matrix-2026-09-18.md'
    if args.write:
        BASELINE.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n')
        report.write_text(markdown(data))
    else:
        prior = json.loads(BASELINE.read_text())
        assert data == prior, 'Audit snapshot changed: inspect sources/mappings/prototype and renew the review before --write.'
        assert report.read_text() == markdown(data), 'Generated matrix differs from reviewed inventory'
    print(json.dumps(data['summary'], ensure_ascii=False))
