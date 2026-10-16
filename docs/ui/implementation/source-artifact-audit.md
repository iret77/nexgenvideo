# Herkunftsinventar der lokalen UI-Artefakte

Stand 21.09.2026. Dieses Inventar erfasst den vollständigen unversionierten Bestand unter `docs/ui` in der getrennten Haupt-Arbeitskopie, ohne dort Dateien zu ändern. Die Dateien besitzen keine Git-Historie; Dateizeit, Pfad und Selbstauskunft im Inhalt belegen daher nur lokalen Entstehungskontext, keine Autorenschaft oder Freigabe.

## Vollständigkeit

Der Bestand umfasst 811 Git-untracked Pfade:

| Klasse | Pfade | Umfang | Einordnung |
|---|---:|---:|---|
| Arbeitsdateien direkt unter `docs/ui` | 52 reguläre Dateien | 5.021.412 Bytes | Verträge, Plan, Mockup-Quellen, Builder und Browser-Prüfskripte |
| `docs/ui/workbench-assets` | 6 reguläre Dateien | 1.206.903 Bytes | zwei Bildmotive in JPG/WebP, ein Momentbild in WebP und ein Icon-Snapshot in JSON |
| `docs/ui/review` ohne Browserprofile | 539 reguläre Dateien | 111.765.682 Bytes | Reviewtexte, JSON/TSV/Logs und Zwischen-/Finalscreenshots |
| `docs/ui/review/.browser-*` | 211 reguläre Dateien, 3 Symlinks | 4.025.993 Bytes | Chrome-Profile, Caches, Datenbanken und drei maschinenlokale Singleton-Links |

Die 808 regulären Dateien ergeben den Sammeldigest `a61435d1cf99e007f5e3f26cb8859ee6c5a332b8c70626f2e3dbd7545bdb3e35`. Er wurde aus dem Repository-Wurzelverzeichnis mit dieser exakten, von `git ls-files` nach relativem Pfad sortierten Folge gebildet; die drei Symlinks sind ausdrücklich ausgeschlossen:

```sh
git ls-files --others --exclude-standard -- docs/ui | while IFS= read -r path; do
  if [ -f "$path" ] && [ ! -L "$path" ]; then sha256sum "$path"; fi
done | sha256sum
```

Die Symlinks zeigen auf einen lokalen Hostnamen, eine Sitzungskennung und einen `/tmp`-Socket und sind reine Laufzeitreste.

Die 52 Dateien im Wurzelverzeichnis sind vollständig durch folgende disjunkte Gruppen erfasst:

- 2 Dokumente: `UI_PARITY_CONTRACT.md`, `implementation-plan-2026-09-19.md`.
- 2 Python-Werkzeuge: `audit-native-ui.py`, `build-desktop-production-workbench.py`.
- 16 Prüfskripte: `check-desktop-production-*`.
- 23 Dateien der finalen modularen Simulation: `desktop-production-workbench.*`.
- 6 frühere Prototyp-/Testsätze: `production-stages-workbench.*`, `production-workbench.*`, `visual-production-workbench.*`.
- 3 abschließende UX-Probe-Skripte: `review-final-ux*.mjs`.

Die sechs Assets sind `lucide-panel-icons.json`, `shot-1e-moments.webp` sowie `storyboard-concept` und `storyboard-sketches` jeweils in den vorhandenen JPG-/WebP-Fassungen.

Die 753 Pfade unter `review` sind vollständig durch die folgenden Pfadgruppen erfasst. Der Wert ist die Zahl der Dateien je realem Verzeichnis; das Muster `.browser-*` fasst mehrere Laufzeitverzeichnisse zusammen:

```text
acceptance-2026-09-20 42                    all-context-menus-2026-09-20 37
audio-wording-2026-09-20 2                 chrome-spacing-2026-09-19 16
control-spacing-2026-09-19 36              final-ux-2026-09-19 38
first-use-2026-09-20 15                    inspector-scroll-2026-09-20 10
macos-menu-2026-09-20 14                   media-spacing-2026-09-20 8
navigation-2026-09-20 42                   object-selection-2026-09-20 8
optional-blocking-2026-09-19 12            polish-2026-09-19 60
project-title-2026-09-20 13                refinement-2026-09-20 38
settings-layout-2026-09-19 17              shot-context-menu-2026-09-20 12
source-viewer-2026-09-20 10                studio-screenshots 27
tile-spacing-2026-09-20 22                 visual-takes-2026-09-19 13
.browser-* 211 reguläre Dateien + 3 Symlinks
```

Weitere 47 Einzeldateien unter `review` sind: `artwork-checks.json`, `background-activity-review-2026-09-18.md`, `background-checks.json`, `background-inline-checks.json`, `code-compatibility-2026-09-17.md`, `compact-chrome-checks.json`, `compact-chrome-review-2026-09-17.md`, `desktop-research-2026-09-17.md`, `desktop-workbench-checks.json`, `desktop-workbench-layouts.json`, `edit-workbench-checks.json`, `edit-workbench-review-2026-09-17.md`, `export-artwork-review-2026-09-18.md`, `fable-5-1-review.json`, `fable-regression-checks.json`, `fable-ux-review-2026-09-18.json`, `finish-workspace-checks.json`, `finish-workspace-review-2026-09-17.md`, `generation-workspace-checks.json`, `legacy-workbench-tests-2026-09-17.js`, `macos-menu-check.log`, `manual-generation-and-edit-review-2026-09-17.md`, `media-browser-checks.json`, `media-browser-review-2026-09-17.md`, `media-workspace-checks.json`, `media-workspace-review-2026-09-17.md`, `native-feature-coverage-2026-09-17.md`, `native-ui-audit-2026-09-18.md`, `native-ui-capabilities-before-studio.tsv`, `native-ui-capabilities.tsv`, `native-ui-function-matrix-2026-09-18.md`, `native-ui-inventory-2026-09-18.json`, `prior-workbench.js`, `production-stages-verification.json`, `project-title-check.log`, `review-resolution.md`, `self-review.md`, `studio-guard-checks.json`, `studio-ux-checks.json`, `studio-workspace-checks.json`, `studio-workspace-review-2026-09-18.md`, `toolbar-symbol-checks.json`, `toolbar-symbols-review-2026-09-18.md`, `undo-redo-review-2026-09-18.md`, `ux-review-result-2026-09-18.md`, `ux-self-review-2026-09-18.md` und `visual-workbench-verification.json`.

## Inhalt und Übernahme

| Lokale Artefakte | Befund | Übernahme in diese Vorlage |
|---|---|---|
| Finaler modularer Workbench-Stand, Builder und Assets | Die Module ergeben die letzte Simulation; der Builder enthält maschinenspezifische Ausgabe- und Toolpfade. Die vollständige Standalone-Datei bindet außerdem alte lokale Reviewlinks und einen externen Test-Runner ein. | Als pfadbereinigter, eigenständiger Snapshot in `workbench.html`. Die eingebettete Simulation ist die Vorlage; die lokalen Builder-/Modulpfade sind kein Produktquellcode. |
| `UI_PARITY_CONTRACT.md`, nativer Audit, Matrix und Inventar | Dauerhafte Erhaltungsregeln und 121 Funktionsgruppen; der Rohsnapshot ist an den damaligen Main-Stand gebunden und würde nach #506/#507 absichtlich abweichen. | Regeln in `README.md`, geprüfte Gruppen in `native-function-matrix.md`. Die Matrix verweist auf den eingefrorenen Snapshot statt auf nicht versionierte JS-Module. Das alte Auditwerkzeug wird nicht als vermeintlich aktuelles Gate veröffentlicht. |
| `implementation-plan-2026-09-19.md` | Umsetzungsreihenfolge, Upstream-/Higgsfield-/Clay-Grenzen und offene Vertragsentscheidungen. | Konsolidiert in `README.md` und `issue-index.md`; der Live-Stand der ersten drei Arbeitspakete ist dort ergänzt. |
| 40 Reviewtexte, strukturierte Prüfausgaben und Bildserien | Wertvolle Herleitung, aber zahlreiche Zwischenstände und ersetzte Bedienmodelle. Rohprotokolle und einzelne Prüfausgaben enthalten maschinenlokale absolute Pfade. | Letzte Entscheidungen in `planning-review.md` und `selection-review.md`; genau zwei finale Direktwahlbilder sind bytegleich übernommen. `film-preview.png` stammt aus `object-selection-2026-09-20/05-final-film.png`, `media-preview.png` aus `06-final-source.png`. |
| Frühere Produktions-/Stufen-/Visual-Prototypen | Historische Vorgänger mit inzwischen ersetzten Workspace-, Finish- oder Auswahlmodellen. | Nicht als konkurrierende Vorlage übernommen. Relevante Funktionsanforderungen bleiben über Matrix und Erhaltungsvertrag erhalten. |
| Browserprofile, Cache, Logs, Rohprompts und 364 nicht ausgewählte PNGs | Flüchtige Laufzeitdaten, redundante Zwischenevidenz oder potenziell hostgebundener Inhalt; kein Produkt- oder Vertragsquellcode. | Nicht versioniert. Das Weglassen verliert keine freigegebene UI-Entscheidung. |

Die ursprünglichen 811 Pfade bleiben in ihrer Arbeitskopie unangetastet. Dieses Dokument ist das Provenienz- und Dispositionsprotokoll; es erhebt die lokalen Artefakte nicht nachträglich zu Produktvertrag oder nativer Abnahme.
