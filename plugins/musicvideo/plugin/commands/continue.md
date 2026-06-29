---
description: Bestehendes Projekt an der nächsten offenen Phase fortsetzen
argument-hint: <projektname>
---

Projekt: $ARGUMENTS

Du setzt ein **existierendes** Musikvideo-Projekt fort.

**Wenn `$ARGUMENTS` leer ist:** liste die Projekte unter dem Projekt-Home
auf (wie in `/projects`) und stelle **eine** AskUserQuestion mit den bis
zu vier jüngsten unvollständigen Projekten als Optionen (Other für
Freitext). Fahre danach mit dem gewählten Projekt fort. Den Status pro
Projekt holst du über den Engine-MCP-Tool-Call
`get_project_state(project_dir)`.

## Architektur — wie Phasen ausgeführt werden (PFLICHT lesen)

Phase-Anweisungen liegen unter `${CLAUDE_PLUGIN_ROOT}/phases/<phase>.md`. Sie sind
**nicht** als Sub-Agents gespawnt, sondern werden **vom Orchestrator
selbst** (Claude in der Hauptsession) ausgeführt:

1. Lies die zur offenen Phase gehörige `${CLAUDE_PLUGIN_ROOT}/phases/<phase>.md`
   komplett ein.
2. Folge den dort beschriebenen Schritten in der Hauptsession.
3. `AskUserQuestion`-Calls landen direkt im User-Chat und werden
   beantwortet.
4. Read-, Write-, Edit-Operationen sowie die Engine-MCP-Tool-Calls
   (`run_phase`, `show_artifact`, `approve_gate`, …) führst du ebenfalls
   direkt aus.

**Niemals** das `Agent`-Tool mit einem Phase-Namen als
`subagent_type` aufrufen. Sub-Agents können `AskUserQuestion` nicht
zuverlässig — die ganze Phase würde im Sub-Agent-Kontext stranden.

**Stumme Worker-Jobs** ohne User-Frage (die schwere Audio-Analyse, die
Sheet-Generation der Bible) laufen als Engine-MCP-Tool-Calls
(`run_phase(project_dir, "<phase>")`), nicht über das `Agent`-Tool und
nicht über lokale Shell-Skripte. Der Orchestrator ruft sie direkt auf
und interpretiert das Ergebnis.

## Ablauf (mit Projektnamen)

1. Hole den Projekt-Snapshot — **ein** Engine-MCP-Tool-Call statt fünf
   Datei-Reads:

   `get_project_state(project_dir)`

   Der zurückgegebene Snapshot (Gate-Stand, Budget, Artefakt-Versionen,
   nächste Phase + Modell-Empfehlung, offene Shots) wird dem User im Chat
   gezeigt — das ersetzt die manuelle Status-Zusammenfassung. Wenn das
   Projekt nicht existiert: Abbruch mit klarer Meldung.
2. Das **erste offene Gate** steht im Snapshot unter `next` (inkl.
   Modell-Empfehlung — bei Opus-Empfehlung den Hinweis „Min-Modell pro
   Phase" geben). Die Reihenfolge ist fix (Story-First):
   ```
   project_init → analysis → brief → production_design → treatment →
   storyboard → bible → shotlist → sanity → frames →
   videos_preview → videos_final
   ```
   Die kanonische Reihenfolge liefert auch der Engine-MCP-Tool-Call
   `list_phases()`.
3. Lade die zugehörige Phase-Anweisung:

   | Gate | Phase-Datei |
   |---|---|
   | `analysis` | `${CLAUDE_PLUGIN_ROOT}/phases/analysis.md` (Vorbedingung: Analyse-Artefakt existiert; falls nicht, vorher `run_phase(project_dir, "analysis")`) |
   | `brief` | `${CLAUDE_PLUGIN_ROOT}/phases/brief.md` |
   | `production_design` | `${CLAUDE_PLUGIN_ROOT}/phases/production-design.md` |
   | `treatment` | `${CLAUDE_PLUGIN_ROOT}/phases/treatment.md` |
   | `storyboard` | `${CLAUDE_PLUGIN_ROOT}/phases/storyboard.md` |
   | `bible` | `${CLAUDE_PLUGIN_ROOT}/phases/bible.md` (Pass 2) |
   | `shotlist` | `${CLAUDE_PLUGIN_ROOT}/phases/shotlist.md` (Pass 2) |
   | `sanity` | `${CLAUDE_PLUGIN_ROOT}/phases/sanity.md` (Pass 2) |
   | `frames` | `${CLAUDE_PLUGIN_ROOT}/phases/frame.md` (Pass 2) |
   | `videos_preview` / `videos_final` | `${CLAUDE_PLUGIN_ROOT}/phases/render.md` (Pass 2, mit passender Phase) |

4. **Artefakt-Anzeige nach Phase-Abschluss (PFLICHT, bindend).** Sobald
   die Phase ihr Artefakt geschrieben hat, **bevor** du `AskUserQuestion`
   für die Freigabe stellst, rufe den Engine-MCP-Tool-Call
   `show_artifact(project_dir, "<gate>")` auf und gib das gelieferte
   Markdown (`markdown`-Feld) vollständig im Chat aus:

   | Gate | Aufruf |
   |---|---|
   | analysis | `show_artifact(project_dir, "analysis")` |
   | brief | `show_artifact(project_dir, "brief")` |
   | production_design | `show_artifact(project_dir, "production_design")` |
   | treatment | `show_artifact(project_dir, "treatment")` |
   | storyboard | `show_artifact(project_dir, "storyboard")` |
   | bible | `show_artifact(project_dir, "bible")` |
   | shotlist | `show_artifact(project_dir, "shotlist")` |
   | sanity | `run_sanity(project_dir)`-Report als Tabelle |
   | frames | Thumbnail-Liste + Approval-Status aus `frames/manifest.yaml` |
   | videos_* | `get_render_manifest(project_dir)` + Kostenzusammenfassung |

   Erst wenn der Inhalt sichtbar im Chat steht, darf die Freigabe-Frage
   gestellt werden.

5. **PFLICHT:** Lege ein `TodoWrite` mit dem vollständigen Pipeline-
   Status an. Alle bereits approved Gates als `completed`, die aktuelle
   Phase als `in_progress`, alle folgenden als `pending`. 13-Punkte-
   Struktur (K0 project-init, A1 Ingest, A2 analysis, K1 brief, K2
   production-design, K3 treatment, K4 storyboard, K5 bible, K7 shotlist,
   S sanity, F frames, R1 preview, R2 final, Final-Abnahme). Update den
   Todo nach jedem Gate-Approval.
6. Bevor du die Phase startest: der Snapshot aus Schritt 1 deckt
   Projekt-Name, Gate-Stand, Budget und nächste Phase ab — ergänze nur,
   was situativ fehlt (z.B. Modus-Besonderheiten).
7. Falls alle Gates approved sind: gratuliere zum Abschluss + weise auf
   den Timeline-Import hin (Audio drüberlegen).

## Anti-Workaround-Regel (bindend)

- **Keine** „Fragen selbst stellen, dann Sub-Agent spawnen"-Workarounds.
  Du **bist** die ausführende Instanz für jede Phase.
- Phase-Anweisungen sind verbindlich — Frage-Formulierungen, Optionen,
  Defaults und Konsistenz-Checks aus der `.md`-Datei nicht improvisieren.
- Bei Unklarheit in der Phase-Anweisung: User fragen, nicht raten.
