---
description: Neues Musikvideo-Projekt anlegen und Phase A starten
---

**Zuerst** gib dem User genau diesen ASCII-Banner aus (monospace, als
code-block):

```
+------------------------------------------------+
|                                                |
|   __  __    __   __                            |
|  |  \/  |   \ \ / /    musicvideo agent        |
|  | |\/| |    \ V /     v1.0.0                  |
|  |_|  |_|     \_/      pre -> generate -> edit |
|                                                |
|  ~~~~ ~~~ ~~~~ ~~~~ ~~~ ~~~~ ~~~ ~~~~ ~~~ ~~~  |
|                                                |
+------------------------------------------------+
```

Direkt nach dem Banner gib eine **Versions-Zeile** aus, damit der User
sieht, auf welchem genauen Stand der Pack gerade läuft. Die Version
steht im Plugin-Manifest (`.claude-plugin/plugin.json`, Feld `version`).

Format der Zeile (im Chat, nicht im Code-Block):
`pack: musicvideo · <version>`

Dann die Begrüßung ("Neues Projekt. Legen wir los.") und fortfahren.

Du startest ein **neues Musikvideo-Projekt**. Folge exakt dieser Reihenfolge:

1. Lies die Phase-Anweisung **`${CLAUDE_PLUGIN_ROOT}/phases/project-init.md`** und
   führe sie **selbst** in der Hauptsession aus (kein `Agent`-Tool-
   Spawn — die Phase wird vom Orchestrator ausgeführt, AskUserQuestion
   läuft direkt). Sie fragt den User im Chat nach dem Projektnamen und
   legt das Projekt über den Engine-MCP-Tool-Call `init_project` an
   (Ordnerstruktur + `project.yaml` + `gates.yaml` werden vom Engine-
   Core gescaffolded; der Pack steuert die Musik-spezifischen Ordner
   `audio/ lyrics/ analysis/` bei). Setzt Gate `project_init` über
   `approve_gate`.
2. Nach Abschluss: fasse dem User kurz zusammen, **wohin er** Audio
   (MP3/WAV/FLAC/M4A) und optional Lyrics (`lyrics/lyrics.txt`) im
   Projekt-Datenroot ablegen soll (Pfad aus dem `data_root`, das
   `init_project` zurückgibt).
3. **Nicht** direkt die Analyse triggern — der User muss erst die Dateien
   bereitstellen und dir Bescheid geben. Wenn er meldet „bereit", führe
   die Phase **`${CLAUDE_PLUGIN_ROOT}/phases/analysis.md`** aus, beginnend mit dem
   **A1-Pre-Analysis-Check**:
   - Plain-Agent-Check: existiert Audio (und ggf. Lyrics) im Projekt?
   - Bei fehlendem Audio: HARTER STOPP, kein Lauf.
   - Bei fehlenden Lyrics/Referenzbildern: per AskUserQuestion nachfragen
     (vergessen oder bewusst?), bevor die mehrminütige Analyse startet.
   - Dann die Analyse über den Engine-MCP-Tool-Call
     `run_phase(project_dir, "analysis")` starten und weiter mit A2
     (Labels prüfen, Anomalien interpretieren, Gate `analysis` über
     `approve_gate`). **Hinweis:** lokale Audio-Analyse braucht die
     optionalen `[audio]`-Abhängigkeiten — siehe analysis.md, falls
     `run_phase` `{"error":"missing_dependencies"}` liefert.

**PFLICHT, vor allem anderen:** `TodoWrite` mit dem folgenden 12-Punkte-
Template anlegen. Der Initialisierungs-Schritt ist `in_progress`, alle
anderen `pending`. Genau eine `in_progress` zu jeder Zeit; bei jedem
Gate-Pass wird der aktuelle Punkt auf `completed` gesetzt und der nächste
auf `in_progress`.

Pipeline-Todo-Template (Story-First-Reihenfolge):
- `[in_progress]` K0 project-init (init_project + Gate project_init)
- `[pending]` A1 Audio-Ingest (analysis via run_phase)
- `[pending]` A2 analysis-agent (Labels, Anomalien → Gate analysis)
- `[pending]` K1 brief-agent (Pflichtfragen → Gate brief)
- `[pending]` K2 production-design-agent (Stil-Refs + Color Script → Gate production_design)
- `[pending]` K3 treatment-agent (Story → Gate treatment)
- `[pending]` K4 storyboard-agent (Step-Sequenzen + Bible-Bedarf → Gate storyboard)
- `[pending]` K5 bible-agent (Multi-View-Sheets nach Bedarf → Gate bible)
- `[pending]` K7 shotlist-agent (Shotlist mit location_view-Refs → Gate shotlist)
- `[pending]` S sanity-agent (Pre-Render-Audit → Gate sanity)
- `[pending]` F frame-agent (Standbilder → Gate frames)
- `[pending]` R1 render-agent preview (→ Gate videos_preview)
- `[pending]` R2 render-agent final (→ Gate videos_final)
- `[pending]` Final-Abnahme (Renders in die Timeline)

**Am Ende, nach dem project-init und Upload-Hinweis**, zeige dem User
diesen Command-Reminder:

```
Verfügbare Commands in dieser Session:

/continue <name>   Pipeline an nächster offener Phase fortsetzen
/status <name>     Pipeline-Fortschritt + ASCII-Diagramm
/projects          Alle Projekte mit Kurz-Status
/estimate <name>   Budget-/Kosten-Stand
/start             Neues Projekt

Upload-Pfade für dieses Projekt siehe oben.
```
