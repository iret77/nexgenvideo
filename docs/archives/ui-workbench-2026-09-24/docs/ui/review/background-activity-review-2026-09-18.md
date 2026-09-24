# Hintergrundaktivität · Entwurf und Self-Review

Scope: bestehender Clickdummy, keine Änderungen an Swift, Harness oder Export-Engine.

## Entwurf

Zwei beständige Anzeigen am rechten Ende der vorhandenen Statusleiste: KI und Export. Keine zusätzliche Zeile. Gleiche Bedienlogik, getrennte Zustände. Ruhende Anzeigen bleiben auffindbar; aktive Anzeigen verwenden die Pack-Akzentfarbe. Ein Klick öffnet ein kleines, am Auslöser verankertes, nichtmodales Fly-out. Erneuter Klick, Escape, Fokuswechsel oder Klick außerhalb schließen es. Das Öffnen und Schließen verändert weder Arbeitsbereich noch Panels, Auswahl, Kosten oder Auftragsausführung.

KI zeigt den aktuellen Auftrag und Arbeitsschritt. Ohne gemessenen Fortschritt gibt es keine Prozentzahl. Ein Batch zeigt abgeschlossene Ergebnisse relativ zum freigegebenen Umfang sowie aufklappbare Einzelaufträge mit Shot-ID, Name und Status. Fertige Ergebnisse bleiben bei Unterbrechung erhalten. Wiederhergestellte unterbrochene Batches sind sichtbar und werden nicht automatisch neu eingereicht.

Export zeigt Dateiname, Ausgabeprofil, Zielordner, Arbeitsschritt und messbaren Fortschritt. Vorbereitung und Ausgabeprüfung sind unbestimmt; beim Schreiben zeigt der Dummy einen Beispielmesswert. Abbruch ist erreichbar. Kein Pause-/Fortsetzen-Knopf für Exporte, weil der vorhandene Exportdienst das nicht unterstützt. Fehler bleiben als Fehler sichtbar, ohne Aktivitätsanimation. Zustandswechsel werden über den vorhandenen barrierefreien Statusbereich gemeldet; keine fortlaufenden Prozentansagen.

## Quellen und Wiederverwendung

- [Apple: View background tasks in Final Cut Pro](https://support.apple.com/en-mide/guide/final-cut-pro/ver64e71609/mac): kompakter Aufruf über einen Aktivitätsindikator; Details zu Aufgaben und Fortschritt, aufklappbare Gruppen. Offizielle Abbildungen des Buttons und des Aufgabenfensters sind im Artikel verlinkt. FCP verwendet ein separates Aufgabenfenster; das hier gewünschte verankerte Fly-out ist eine bewusste Anpassung, keine Behauptung über dessen exakte Geometrie.
- `Sources/NexGenVideo/Agent/Pipeline/PipelinePhaseExecution.swift`: beobachtbarer Snapshot mit Run-ID, Projekt, Phase, Stage-ID, abgeschlossenem/gesamtem Umfang und Lauf-/Fehler-/Abschlussstatus. Diese Runner-Daten wiederverwenden; keinen zweiten Phasenjob starten und keinen künstlichen Prozentfortschritt ableiten.
- `Sources/NexGenVideo/Generation/GenerationBatch.swift`, `GenerationBatchCoordinator.swift`, `GenerationService.swift`: einzelne Generierungsaufträge und Journalzustände, fertige Ergebnisse, Unterbrechung und Wiederaufnahme. Provider-Abbruch und lokales Stoppen der Statusabfrage sind in der nativen Umsetzung zu unterscheiden; keine Kostenerstattung versprechen.
- `Sources/NexGenVideo/Agent/Tools/ToolExecutor+Export.swift`: Videoexport startet bereits in einem Hintergrund-Task und liefert sofort `started` zurück; Abschluss/Fehler über Systembenachrichtigungen. ExportCoordinator verhindert einen zweiten gleichzeitigen Export.
- `Sources/NexGenVideo/Export/ExportService.swift`: beobachtbarer Fortschritt, Fehler und Abbruch. `ExportView.swift` zeigt den Fortschritt bislang im Exportfenster. Der im Agent-Tool lokal erzeugte Dienst ist noch kein globaler UI-Auftragsbestand. Für die spätere native Anzeige müssen diese vorhandenen Instanzen gemeinsam beobachtbar gehalten werden; Export-Engine nicht neu schreiben.

## Review und Grenzen

- Behoben: der bisherige globale `running`-Schalter hätte beim Export fälschlich KI-Aktivität angezeigt. Die neuen Anzeigen lesen getrennte Auftragsquellen.
- Behoben: die bisherige Generierungs-Fortschrittsansicht war modal. Nach der Kostenfreigabe läuft ihre Anzeige jetzt im Hintergrund-Fly-out.
- Behoben: kleine Fenster ließen das Fly-out zunächst über die mehrzeilige Statusleiste ragen. Die gesamte Statusleiste ist jetzt die Unterkante; horizontale Begrenzung und Größenänderung werden berücksichtigt.
- Geprüft: nur ein Fly-out gleichzeitig, Fokus-Rückgabe, Escape, unveränderte Panelzustände, laufende Aktualisierung bei geöffnetem Fly-out, Arbeitsbereichswechsel, Abbruch ohne spätere Timer-Fertigmeldung, Einzelaufträge, Wiederherstellung, Fehlermeldung, reduzierte Bewegung und vier Vorschaugrößen.
- Die Vorschau-Einstellungen bieten explizite Beispielzustände für KI, Export und Fehler. Diese steuern keine echten Jobs; das Fly-out kennzeichnet sie. Reale Clickdummy-Aktionen nutzen ihre eigenen simulierten Auftragszustände. Es gibt keine Provider-Verbindung oder Datei-Ausgabe.
- Der vorhandene Dummy führt weiterhin nur einen mutierenden Auftrag gleichzeitig aus. Zwei getrennte Anzeigen behaupten keine neue Export-Queue oder nebenläufige Pipelineausführung. Fertige Exporthistorie und Entscheidungen bleiben in ihren bestehenden Oberflächen erreichbar.
- Statische Browserprüfungen und Screenshots sind keine native macOS-Abnahme. Keine Änderung der bestehenden partiellen Funktionsabdeckung der freien Generierung.

Prüfergebnis: 25 neue Szenarien bestanden, jeweils für die separate Prüfversion und die tatsächlich eingebettete UTF-8-Vorschau. Zusätzlich 111 bestehende Interaktionsprüfungen und 25 Arbeitsbereich-/Größenkombinationen bestanden. Visuell gesichtet: KI-Lauf und Export-Fly-out; Fehlerzustand ebenfalls als Screenshot dokumentiert.

Prüfnachweis: `background-checks.json`, `background-inline-checks.json`, `studio-workspace-checks.json`, `studio-ux-checks.json`, `studio-guard-checks.json`, `fable-regression-checks.json`. Die Fable-Datei enthält hier erneut ausgeführte Regressionstests des vorigen Reviews; für diesen Zusatz wurde kein neuer externer Fable-Review behauptet.
