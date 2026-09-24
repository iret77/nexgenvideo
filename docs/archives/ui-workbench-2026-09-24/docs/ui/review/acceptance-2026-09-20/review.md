# UI-/UX-Abnahmestand · 20.09.2026

**Urteil des Eigenreviews: Als UI- und Interaktions-Clickdummy zur fachlichen Abnahme bereit; keine offenen bestätigten High-/Medium-Befunde im geprüften Scope.**

Prüfgegenstand ist der statische NexGenVideo-Clickdummy. Die nachfolgend dokumentierten Änderungen beheben die Bedien- und Zustandsfehler des kritischen Reviews vom 19.09.; native App, Provider und Produktionsverträge sind nicht geändert.

## Erhaltene Leitplanken

Native Mac-Arbeitsräume mit kompakten Werkzeugleisten, verstellbaren Panels, objektbezogenem Inspector, getrennten Flächen für Medien, Produktion, Schnitt, Postproduction und Export. Keine Chatpflicht, kein zusätzlicher Web-Wizard. Workflow-Gates bleiben explizit; KI bereitet vor und prüft, der Filmer entscheidet. Sketches, gerenderte References und räumliche Clay-Vorlagen bleiben verschiedene Artefakte. Pack-Akzent ist sichtbar, ohne farbige Rahmen um jede Komponente.

## Nacharbeit zum kritischen Review vom 19.09.

| Befund | Geprüfte Änderung |
|---|---|
| 1. Abbruch verliert Anker | Kostendialog ist folgenlos; erst der bestätigte Auftrag ersetzt erfolgreiche Einzelergebnisse. Stop bewahrt vorhandene Medien. |
| 2. Revision entwertet Medien pauschal | Medienarchiv, Eingabegültigkeit und Freigabe getrennt. Eindeutige Take-Kennungen bleiben über mehrere Renderläufe und Revisionen erhalten. Passende frühere Takes können bewusst wieder gewählt werden. Unveränderter Blocking-Skip bleibt bestehen. |
| 3. Falsches Bildpaar am Review-Befund | Auswahl, Bildpaar, Inspector, Zustandsdifferenz und Korrektur betreffen dieselben Shots. Story-Zeit bleibt unabhängig von Filmfolge. |
| 4. Shotstruktur nicht bearbeitbar | Einfügen, Teilen, Löschen mit Bestätigung/Undo, Umordnen über Drag oder Inspector. Stabile Shot-IDs und Motive; neue Shots beginnen ohne Sketch. |
| 5. Gemeinsame Location versetzt alle Figuren | Feste Location-Geometrie gemeinsam, bewegliche Figuren/Props mit eigenen Start-/Endposen je Shot. Kopieren ordnet keinen Shot still neu zu. |
| 6. Blocking ist ein Zahlenformular | Direkte Auswahl und Bewegung im Viewer, Draufsicht mit Kamera-/Blickzielgriffen, Zahlen nur ergänzend. Sketch-Vergleich und Wiedergabe auch bei Figurenbewegung vor statischer Kamera. |
| 7. Clay/Anker-Vergleich fehlt | References-Kontaktbogen mit Mehrfachsichtung; Vergleich Sketch/Anker oder Clay/Anker im gemeinsamen Arbeitsraum. |
| 8. Prüfungen als Pflichtcheckboxen | Maschinenresultate statt Bestätigungsliste. Take wählen/ablehnen direkt; bewusste Abweichung mit Begründung. Befund und Entscheidung bleiben getrennt sichtbar. |
| 9. Navigation verdrängt Bühne | Begrenzte scrollbare Shotwahl, lokale Shot-/Locationsuche bei großen Projekten, Location-Gruppierung. 96-Shot-Probe; gemeinsame Zeitachse mit Zoom im Animatic. |
| 10. Song und Animatic getrennt | Abschnitt abhören, seeken, loopen; Songabschnitte, Beats und Shots auf derselben Zeitachse. Songversatz explizit, tatsächliches Trackende sichtbar. |
| 11. Gestaltung verborgen | Eigene sichtbare Phase mit passendem Auswahl- und Freigabestatus. |
| 12. Batchfreigabe unkonkret | Kompakte Kostenfreigabe plus aufklappbare Shotdetails zu Route, Dauer, Eingaben und Beispielkosten. |
| 13. Wording/visuelle Priorität | Kurze Phasennamen, reduzierte Erklärungen, konsistente Toolbar-Symbole und Inspector-Achsen. Keine erneute pauschale Umgestaltung bereits passender Flächen. |

## Unabhängiger Review und Gegenprüfung

Claude Fable 5.1 wurde über `claude-high5`, Effort **high**, als strikt lesender Reviewer aufgerufen. Der erste Lauf hat weitere relevante Kombinationsfehler gefunden; sein Urteil war ausdrücklich **keine Freigabe**. Jeder Befund wurde am aktuellen Code geprüft. Die relevanten Korrekturen sind:

- Take-Nummern werden pro stabiler Shot-ID monoton vergeben. Die Eingabesignatur wird beim tatsächlichen Renderergebnis gebunden. Zwei Renderläufe und anschließender Rewind bewahren 18 verschiedene Takes im Beispiel.
- Neue Shots erhalten Kameras innerhalb der vorhandenen Location, zunächst ohne verpflichtende Clay-Ausgabe. Teilen führt Kamera und Figurenpose am Schnittpunkt fort. Löschen entfernt verwaiste Shot-Kameras.
- Ordner-/Medienzuordnung, Timeline-Quellen, Auswahl und Reviewentscheidungen bleiben bei Shot-Umordnung konsistent.
- Ankerexistenz wird pro Shot geführt. Ein Teilrender erzeugt keine Phantom-Bilder für unerledigte Shots. Generierungskosten und neue Medien verschwinden nicht durch Undo.
- Reviewbefunde folgen `stateIn`/`stateOut` in Story-Zeit; gelöschte oder neue Shots ergeben passende neue Übergänge. Eine bestätigte Korrektur ändert den konkreten Zustand und entwertet nur die betroffene Ankersichtung.
- Die Dauer gehört in die Take-/Zeitbindung; eine reine Daueränderung verlangt nicht automatisch einen neuen statischen Anker.
- Take-Ausnahmen löschen den Maschinenbefund nicht. Die konkrete Demobeobachtung ist an 1E/Take 2 gebunden; unbeteiligte Shots erhalten keinen erfundenen Handbefund.
- Song und Shots teilen denselben scrollbaren Zeitcontainer. Trackende, Beat-Versatz, Abschnittsende und temporärer Wiedergabestatus sind berücksichtigt.
- References/Review zeigen fehlende Quellen als fehlend. Identitätsbilder behalten ihr Motiv unabhängig von Shot-Umordnung.
- Fehlende Handlung und fehlender Sketch haben verschiedene Gate-Hinweise. Neue Shots besitzen einen expliziten Sketch-Auftrag mit Beispielkosten.
- Objektklicks verbrauchen keinen Undo-Schritt; erst eine tatsächliche Bewegung schreibt eine Änderung. Drag und Zahlenfelder haben gleiche Grenzen.
- Der Vorschlag zur weitgehenden Packager-Portabilität ist keine UX-Abnahmebedingung. Der vorhandene statische Packager unterstützt `NGV_MOCK_OUTPUT` und `NGV_ESBUILD`; seine lokale Vorschau ist kein Produkt-Buildsystem.

Die zusätzliche Repo-read-Nachprüfung endete technisch mit SIGTERM, ohne verwertbare Ausgabe und vor dem 900-s-Timeout. Sie gilt nicht als Review-Ergebnis. Der einmalige Wiederanlauf mit vollständig mitgegebenem, begrenztem Quelltext und deaktivierten Tools wurde erfolgreich abgeschlossen: Fable 5.1, Effort high, keine Permission-Denials. Auch dieser Lauf war keine pauschale Freigabe, sondern lieferte vier bestätigte Medium-Befunde und einen durch fehlenden Ausschnittskontext entstandenen Low-Verdacht.

| Nachbefund | Gegenprüfung am vollständigen Code und Ergebnis |
|---|---|
| Einfügen zwischen geteilten Shots verschiebt Story-Zeit | Bestätigt und behoben. Die Story-Reihenfolge wird für Strukturänderungen stabil neu nummeriert; Einfügen/Teilen liegt unmittelbar nach dem gewählten Shot in Story-Zeit. Split plus Einfügen sowie 15 wiederholte Einfügungen geprüft. Filmfolge bleibt unabhängig. |
| Loses Importvideo blendet archivierte Bilder aus | Bestätigt und behoben. Deduplication erfolgt über vorhandene, eindeutige Medien-IDs. Archivierte Anker bleiben neben ungebundenen Importvideos sichtbar. |
| Importierte Shots bekommen Phantom-Anker oder sperren Sammelsichtung | Bestätigt und behoben. Nur KI-Video-Shots bekommen eine Ankerbindung; Quellclips sind entsprechend beschriftet und von der Ankersichtung ausgenommen. Quellwechsel archiviert den bisherigen KI-Anker. |
| Songversatz bleibt nach Freigabe veränderbar | Bestätigt und behoben. Feld und Handler sind phasengeschützt; erlaubte Änderungen besitzen Revision und Undo. Zoom bleibt reine Ansicht. |
| Alte Sichtung erlaubt Freigabe eines veralteten Ankers | Im vollständigen Code nicht reproduzierbar. Die im begrenzten Reviewauszug fehlende Clay-Readiness sperrt `refs`, `review` und `takes` bei veralteten Ankern. Browserprobe bestätigt das. Alte Sichtung bleibt als historischer Stand erhalten, ist aber keine gültige aktuelle Freigabe. |

Weitere ausdrücklich als nicht prüfbar benannte Hinweise wurden gezielt angesehen: Die Clay-Checkboxen hatten tatsächlich einen Zahlenkonvertierungsfehler; Zuordnung und Kamerafahrt schalten jetzt auch über den echten DOM-Handler. Die frühere Take-Ansicht wird bei Umordnung remapped. Bestehende Timeline-Clips erhielten beim Rewind zunächst keine auflösbare Archivquelle; aktive und archivierte Takes besitzen jetzt dieselbe kanonische Medienidentität, sodass Rewind und Wiederverwendung keine Clipquelle verlieren. Der Einzelbild-Viewer zeigt fehlende Anker als fehlend; beim bloßen Anzeigen werden keine Posen angelegt. Die Animatic-Spur besitzt im gemeinsamen Zeitcontainer keinen geometrieverfälschenden Gap.

Rohbelege: `fable-result.json`, `fable-verification-result.json` (abgebrochen, leer), `fable-bounded-result.json`, Prompts und Invocation-Metadaten. Die letzten Korrekturen wurden vom Orchestrator mit konkreten Browserabläufen nachgeprüft; keine Behauptung eines weiteren externen Reviews nach diesen Korrekturen.

## Prüfbelege

**255 bestandene Prüffälle:** 88 Abnahmeszenarien, 165 bestehende Regressionstests und 2 Prüfungen des tatsächlich ausgelieferten Inline-Fragments. Keine unbehandelten Browserfehler in den Abnahmeszenarien.

Die Browserprüfungen verwenden ausschließlich die statische HTML-Datei per `file://`; kein Devserver, kein nativer Build oder App-Start. `checks.json` enthält die Arbeitswegszenarien einschließlich Greenfield, Korrekturschleife, Generierung, Take-Auswahl und Übergang in eine leere Schnitt-Timeline. `final-regression-suites.json` dokumentiert die bestehenden Prüfgruppen für Guards, Workbench, Polishing, Hintergrundaktivität und Exportbilder.

Screenshots in diesem Verzeichnis dokumentieren die zentralen Arbeitsflächen. Die visuellen Bewertungen sind Eigenreview; Fables Quellcodeprüfung ersetzt keine macOS- oder VoiceOver-Abnahme. Die Desktop-Prinzipien und Quellen des Wettbewerbsabgleichs bleiben im Review vom 19.09. dokumentiert; keine erneute Behauptung einer vollständigen Apple-HIG-Zertifizierung.

## Abgrenzung zur nativen Umsetzung

- KI-Prüfungen, Provider-Aufträge, bpy, MCP, Video-Wiedergabe und Datei-Export sind simuliert. Die hörbare Vorschau ist ausdrücklich ein synthetischer Rhythmustrack; das tatsächliche Song-Audio liegt dem Dummy nicht bei.
- Das gespeicherte Zustandsbeispiel zur Mechanik demonstriert die UX des Continuity-Reviews, keine vollständige ontologische oder semantische Filmprüfung. Native Zustände benötigen die schon vorhandenen kanonischen Writer, versionierte Daten und exakte Quellen.
- Der Dummy-Eingabevergleich ist kein nativer Herkunftsnachweis. Gesperrte Lineage-/Rewind-Verträge bleiben bindend. Notwendige Vertragsentscheidungen werden vor nativer Implementierung gesondert getroffen.
- Die 121 Funktionsgruppen des vorhandenen nativen Erhaltungsinventars bleiben Implementierungsanforderung. Diese Abnahme ist kein neuer vollständiger Engine-Paritätsnachweis.
- PR #548/#547, Epic #540/#541–#546 und die parallele Higgsfield-Anbindung bleiben Integrationskontext. Historische Code-Abgleichsstände vor Umsetzung erneut prüfen; keine konkurrierenden Änderungen durch diese Mockup-Arbeit.
