# Vollständiger Funktionsbereich-Abgleich: NGV und Clickdummy

**Historischer Ausgangsbefund vor der Überarbeitung.** Den aktuellen Stand dokumentieren [Studio-Review](studio-workspace-review-2026-09-18.md) und aktualisierte Funktionsmatrix. Die folgenden Lückenzahlen beziehen sich auf den Vorgänger.

Stand: 18.09.2026 · nativer Quellenstand `8bd8fbde5cdb9a2a46b26c2441aa5035c885d1e0`.

**Ergebnis: Der bisherige Clickdummy bildet den vorhandenen Funktionsumfang nicht ausreichend ab und ist keine vollständige Implementierungsvorlage.** Insbesondere die Schnitt-/Postproduction-Werkzeuge, freie Medienverwendung und strukturierte Agent-Funktionen würden bei einer wörtlichen Umsetzung verloren gehen. Die bisherigen Teilreviews haben diese Lücken teilweise erwähnt, aber daraus keine hinreichende Erhaltungsprüfung gemacht. Das war der methodische Fehler.

Diese Prüfung ändert keinen nativen Produktcode. Sie korrigiert die Umsetzungsvorgabe und dokumentiert die offenen Dummy-Lücken. Sie behauptet ausdrücklich nicht, diese Lücken bereits im Clickdummy geschlossen zu haben.

**Ergänzte Nutzervorgabe: Postproduction und Export sind getrennte Projektphasen.** Die Zielorte der Funktionsmatrix wurden entsprechend zugeordnet: FIN-01/02 und die vorhandenen Postproduction-Werkzeuge gehören zu Postproduction, FIN-03/04/05 zu Export. Die FIN-IDs bleiben als Querverweise stabil. Aussagen über den bisherigen gemeinsamen „Finish“-Bereich beschreiben weiterhin den geprüften Bestand. Die [Phasenabgrenzung](../UI_PARITY_CONTRACT.md#postproduction-und-export-getrennt) benennt Verantwortung, Wiederverwendung und offene UI-Arbeit; die Trennung ist noch nicht in der interaktiven Simulation umgesetzt.

## Umfang und Nachweis

Die [Funktionsmatrix](native-ui-function-matrix-2026-09-18.md) enthält **119 Funktionsgruppen**: 115 zum vorhandenen Produkt einschließlich seiner Engine-/Tool-Fähigkeiten sowie vier gesondert ausgewiesene Erweiterungsvorschläge. Jede Gruppe nennt Codebelege, den tatsächlichen Dummy-Befund, den zu erhaltenden Einstieg und ein Abnahmeszenario.

Berücksichtigt sind App-/Dateimenüs, Startfenster, Einstellungen, Panelsteuerung, Medienbrowser und Kontextmenüs, Generatoren, Timeline samt Tastatur-/Bereichsaktionen, Viewer, vollständige Inspector-Werkzeuggruppen, Produktionsartefakte, Reviews, Export, dynamische Agent-Oberflächen und Core-/Pack-Verträge. Die Abgrenzung erfolgt nicht anhand der im Dummy sichtbaren Tabs, sondern vom vorhandenen Produkt aus.

| Erfasster Bestand | Nachweis |
|---|---|
| 672 Swift-Dateien in Host, Engine und Packs | Pfad-/Hashinventar; keine Behauptung, jede Implementierungszeile manuell gelesen zu haben |
| 768 Runtime-Quellen und Vertrags-/Ressourcendateien | Hashinventar unter `Sources` und `Engine/Sources` |
| 124 statisch gefundene UI-/Kontrolldateien | Jede Datei einer oder mehreren Funktionsgruppen zugeordnet |
| 709 Kontroll-/Interaktionsanker | Datei, Zeile und Text im Inventar; konservativer Textscan einschließlich Hilfs-/Testtreffern |
| 85 Einträge in `AgentToolName` | Vollständige explizite Zuordnung zu den Funktionsgruppen |
| Zusätzliche dynamische Eingaben und Pack-Funktionen | Dialog-/Blockschemas, Generationseingaben, UIContract, Pack-Surfaces und spezialisierte Writer separat untersucht |

Das maschinenlesbare [Inventar](native-ui-inventory-2026-09-18.json) bindet diese Erfassung an den Code- und Dummy-Stand. Der [Prüfer](../audit-native-ui.py) meldet fehlende Quellbelege, unzugeordnete UI-Dateien/Tools und Änderungen gegenüber dem Snapshot. Das ist eine Kontrolle der Erfassung, keine automatische semantische Vollständigkeits- oder Laufzeitgarantie. Ein Funktionsgruppen-Eintrag kann mehrere Controls und Parameter enthalten.

## Abdeckung des bisherigen Dummys

| Befund | Gruppen | Bedeutung |
|---|---:|---|
| Fehlt | 40 | Kein ausreichender Einstieg bzw. keine Darstellung |
| Teilweise | 51 | Nur Ausschnitt, vereinfachte Zustände oder fehlende native Bindung |
| Widerspricht Bestand | 4 | Entwurfslogik würde vorhandene Nutzung einschränken; einige Befunde betreffen denselben Grundfehler |
| Ersatzinteraktion fehlt | 8 | Bestehende Fähigkeit hängt an Chat; neue strukturierte Bedienung fehlt |
| Native Oberfläche erhalten | 10 | Vorhandene Fenster/Menüs konkret übernehmen und beim Refactoring prüfen; keine Ausnahme vom Funktionserhalt |
| Im Dummy illustriert | 2 | Grundprinzip dargestellt; keine Aussage über native Implementierungsgleichheit |
| Neue Fähigkeit/Vertragsarbeit | 4 | Nicht als bereits vorhandene NGV-Funktion zählen |

Die früher dokumentierten 217 Dummy-Assertions und die visuellen/physisch geklickten Finish-Prüfungen prüfen die damalige Simulation. **Sie belegen keine Funktionsparität mit NGV.** Sie wurden in diesem statischen Audit nicht erneut als Paritätsnachweis ausgeführt.

## Kritische Befunde

### 1. Freier Schnitt wird fälschlich an die Produktionspipeline gebunden

Nativ hängt `allowsTimelineEditChrome` ausschließlich von `workspaceFocus == .edit` ab ([EditorViewModel](../../../Sources/NexGenVideo/Editor/ViewModel/EditorViewModel.swift#L737)). Ein Benutzer darf vorhandenes Material importieren und schneiden, ohne Geschichte, Storyboard oder KI-Takes zu erzeugen.

Im Dummy verlangt `isEdit()` dagegen die aktuelle, nicht abgeschlossene Pipelinephase ([Dummy](../desktop-production-workbench.js#L20)). Der NLE-Insert verlangt zusätzlich ein Video mit Demo-Shot-Zugehörigkeit. `finishReady()` verlangt die erfundene aktuelle Phase `finish` ([Finish-Dummy](../desktop-production-workbench.finish.js#L15)). Das betrifft APP-04, MED-12 und NLE-01 sowie FIN-03.

**Korrektur der Vorgabe:** Medien, Produktion, Schnitt und Finish sind Arbeitsbereiche. Nur die echten Produktionsphasen haben deren Gates. Freier Schnitt und Export importierter Video-/Audio-/Bild-/Lottie-Quellen bleiben möglich. Dokumentdateien sind weiterhin Quellen, keine Timeline-Clips. Produktionsfreigaben bleiben dort bindend, wo tatsächlich Produktionsartefakte verändert oder erzeugt werden.

### 2. Vorhandene Postproduction wurde stark verkürzt

Der echte Inspector enthält Transformation/Crop/Rotation/Flip, Tempo und Keyframes; Tonwerte, Weißabgleich, RGB-/Hue-Kurven, Farbräder, LUTs, Detail-, Blur- und Stil-Effekte sowie Chroma Key; Audioparameter, Fades und Pegelautomation; umfassende Titelgestaltung. Captions, Audiotranskription und KI-Bearbeitung ergänzen dies. Die Matrix trennt diese Gruppen unter POST-01 bis POST-17 und GEN-09 bis GEN-11.

Die zwei Dummy-Farbregler und ein A1-Pegel sind dafür kein Ersatz. **Der bestehende Inspector einschließlich seiner nativen Mutationen bleibt der Ausgangspunkt.** Finish darf gezielt zum betroffenen Clip und diesen Werkzeugen führen. Ein zweiter unabhängiger Grade-/Audiostand oder ein neuer Effekt-Stack ist nicht erforderlich.

Vorhandene `ColorScopes` sind Mess-/Tool-Funktionalität. Daraus folgt nicht, dass NGV schon ein vollständiges Resolve-artiges Scope-Panel besitzt. Ebenso sind Analyse-Stems keine nachgewiesene fertige DAW-Mischoberfläche.

### 3. Timeline und Viewer verlieren wesentliche Desktop-Funktionen

Mehrspurmontage, Mehrfach-/Marquee-Auswahl, Clipboard, Insert/Overwrite/Ripple, Snapping, Linking/Sync-Lock, Bereichsauswahl, „als Medium sichern“, Medienaustausch und inhaltsbasierte Audiosynchronisation sind vorhanden. Auch mehrere Quell-Tabs, Frame-Capture und echte Offline-/Fehlerzustände dürfen nicht auf die vereinfachte Einspur-Simulation reduziert werden. Siehe NLE-02 bis NLE-10 und VIEW-01 bis VIEW-04.

Projektgeometrie und Bildrate sind konfigurierbar. Die durchgehenden 16:9-/24-fps-Annahmen des Dummys sind Beispieldaten, keine Produktgrenze.

### 4. Medienverwaltung ist mehr als Ordner plus Dateinamenfilter

NGV besitzt visuelle Inhaltssuche/Moments und Suche in gesprochenem Inhalt mit zeitgebundenen Treffern, Indexzustände, Relink einzelner Dateien bzw. Ordner, Datei-Kontextaktionen und Generierungsherkunft. Diese Funktionen fehlen größtenteils im Dummy. Der neue große Medien-Arbeitsbereich muss sie aus dem vorhandenen `MediaTab` übernehmen. Die kleinen Quellen-Picker dürfen den gemeinsamen Bestand verwenden, ohne eine zweite Bibliothek einzuführen. Siehe MED-01 bis MED-13.

### 5. „Kein Chat“ braucht vollständige Ersatzinteraktionen

Die beschlossene Ablösung freier paralleler Chats bleibt richtig für dieses Konzept. Sie hebt aber keine vorhandene Fähigkeit auf: Choice/Multi-choice, Prosa nach Bedarf, wiederholbare Datei-Intakes, Empfehlungen, Defaults, Abbruch, strukturierte Blocks, Kosten- und Batch-Freigaben, laufende Aufträge und Entscheidungsverlauf müssen erreichbar bleiben.

Heute starten unter anderem Medienorganisation, objektbezogene Änderungen, Musikrichtung und Caption-Aufgaben teilweise Chat-Interaktionen. Ein leerer neuer Arbeitsbereich ersetzt diese Funktionen nicht. Dafür braucht es begrenzte, kontextgebundene Aufträge mit den bestehenden Tool-/Writer-Verträgen. Bestehende Gesprächsdaten dürfen bei der Umstellung nicht verschwinden. Siehe AGENT-01 bis AGENT-07, MED-13, POST-13/17 und PROD-10.

### 6. Produktionsumfang und Pack-Verträge sind breiter als die Demo

Zu erhalten sind insbesondere:

- Gemessene Audio-Strukturhierarchie, Qualitäts-/Remeasurement-Zustände und tatsächliche lokale Analyseadapter.
- Pattern-Fit mit Messung, Interpretation und Präferenz; alle Reference-Entitäten samt Ensemble, Props, Orten und Look, Objektgraph, Ledger-Sperren und Herkunft.
- Hybride Shotquellen, Conditionings, exakte Quellen, Frame-Continuation und native Video-Extension.
- Räumliche Pläne, 360°-/POV-Extraktion sowie **bereits vorhandener nativer/importierter Blockout-Clip**. Der native Exporter erzeugt deterministische Plan-/Elevationsdarstellungen; er ist kein vollständiger 3D-Editor.
- Weltchronologie, Zustandsleiter, bestehende Sanity-/Frame-/Stilprüfungen, sechs Take-Prüfgänge, Bereichsrettung und begrenzte Reparatur-/Iterationsentscheidungen.
- Still-/Ken-Burns-Delivery ohne unnötige Videogenerierung sowie Musicvideo-spezifische Performance-Segmente, Visual Arc, Coverage und Final Mix.

Die native Produktion endet nicht in den zusätzlich erfundenen Edit-/Finish-Gates. `UIContract`, die aufgelösten Pack-Beiträge und die tatsächlichen Host-Verträge bleiben maßgeblich. Eine umbenannte „References“-Fläche darf Bible und Frames nicht als Artefakte/Gates verschmelzen. Ein harter Demo-Phasenplan ist kein zulässiger Ersatz für den generischen Workflow mit Pack-Ergänzungen.

### 7. Generierung, Finish und App-Rahmen brauchen ihre vollständigen Wege

Modellabhängige Bild-/Video-/Audio-Eingaben, ausführbare Provider, Prompt-Compile, Prepared Packages, Batch-Prüfung, Kostenfreigaben und Wiederaufnahme gehören zum Bestand. Das gilt auch für native Menüs, Einstellungen, Hilfe, Updates, Pack-Versionen und explizite Recovery-Upgrades.

Finish muss den echten Sequenzreview samt allen Befundentscheidungen, optionaler Review-Voraussetzung, Exportformaten und technischen Ergebnisprüfungen erhalten. Ein Timer mit „fertig“ ist nur eine Simulation. Das native TODO für einzelne Finish-AI-Enhance-Shots ist umgekehrt keine vorhandene fertige Funktion.

## Was weiterhin neue Arbeit ist

Mehrere Storyboard-Sketch-Momente, FilmFlow-Snapshot-Import, die geänderte Dokument-/Phasenfolge und ein automatischer semantischer Gesamtfilm-Audit werden als NEW-01 bis NEW-04 separat geführt. Bestehende Engine-Bausteine erleichtern diese Arbeiten, beweisen aber keine fertige Endfunktion. Gesperrte Verträge werden durch diesen Entwurf nicht geändert.

Die früher untersuchten Upstream-UI-Patches können Gestaltung und vorhandene Komponenten verbessern. Sie sind kein Ersatz für den Funktionsbestand dieser NGV-Version. Dieser Audit prüft die lokale NGV-Codebasis; er behauptet keinen neuen Live-Abgleich mit inzwischen verändertem Upstream.

## Konsequenz für die Umsetzung

Die [Erhaltungs- und Abnahmevorgabe](../UI_PARITY_CONTRACT.md) ergänzt die Mockup-Spezifikation. Erst muss jeder bestehende Bedienweg einen erhaltenen oder überprüften Ersatz haben. Danach kann eine Fläche als Refactoring-Vorlage gelten. Ein funktionierender bestehender Inspector, Generator oder Reviewer wird nicht durch eine schmalere Neuschöpfung ersetzt, nur weil diese im Dummy leichter zu zeichnen war.

Offene Implementierungsarbeit bleibt offen sichtbar. Das Audit legitimiert keine Funktionsstreichung und macht den aktuellen Dummy nicht vollständig. Es ersetzt die bisherige pauschale Erhaltungszusage durch prüfbare Einzelpunkte.
