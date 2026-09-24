# Funktionserhalt beim NGV-UI-Refactoring

Diese Umsetzungsvorgabe konkretisiert den Auftrag des Nutzers, vorhandene Funktionalität beim UI-Rework zu erhalten. Sie ist keine Freigabe für Änderungen an gesperrten Produktverträgen und kein Ersatz für `AGENTS.md`.

Maßgeblicher Abgleich: [Audit vom 18.09.2026](review/native-ui-audit-2026-09-18.md) und [Funktionsmatrix](review/native-ui-function-matrix-2026-09-18.md). Der überarbeitete Clickdummy bildet die Arbeitsbereiche und Funktionsgruppen als Simulation ab; [Review und Grenzen](review/studio-workspace-review-2026-09-18.md) sind Bestandteil der Umsetzungsvorlage. Er ist **kein Ersatz für native Funktionsabnahme**.

## Regeln für jede umgebaute Fläche

1. **Vom Bestand ausgehen.** Die betroffenen Matrix-IDs benennen; Quellkomponente, ausführende Mutation/Service und bisherigen Einstieg lesen. Nicht allein das HTML nachbauen.
2. **Fähigkeit und Darstellung trennen.** Jede bestehende Fähigkeit bleibt erreichbar. Bewusst abgelöste Interaktionsformen, insbesondere freier Chat, erhalten einen funktionsfähigen strukturierten Ersatz. Keine stillen Streichungen.
3. **Bestehende Bausteine weiterverwenden.** MediaTab, Inspector-Tabs, Timeline, GenerationView, Review-Komponenten, ViewModel-Mutationen und Engine-Dienste bleiben die Basis. Oberfläche neu zusammensetzen, nicht deren gesamte Logik neu implementieren.
4. **Ein Datenbestand.** Asset-/Entity-/Shot-/Take-/Clip-Identitäten, Undo, Projektpersistenz und exakte Provenienz erhalten. Keine zweite Bibliothek, Grade-/Audiowahrheit oder kanonische Artefaktkopie im UI.
5. **Projektphasen mit eigenen Arbeitsbereichen sind keine automatischen Pipeline-Gates.** Produktion, Schnitt, Postproduction und Export sind fachlich getrennt; Medien ist die phasenübergreifende Verwaltung. Freies Schneiden und Exportieren importierten Materials bleibt möglich. Produktionsgates kontrollieren weiterhin ihre eigenen Artefakte und Aktionen. Ein Workspace-Wechsel genehmigt keinen Produktionsauftrag und erzwingt keinen vorherigen.
6. **Generischen Workflow erhalten.** Der Host löst Core und Pack-Beiträge auf. Keine fest codierte Musicvideo-Phasenfolge als Host-Ersatz, keine stillschweigende Pack-Degradierung, keine Änderung der Pin-/ABI-/Recovery-Verträge.
7. **Gates und Kosten bleiben nativ.** Vorhandene Writer, Readiness, aktuelle Phasenjob-Identität, Schema-Validierung und Prepared Requests verwenden. Ein deaktivierter Button oder eine HTML-Bedingung ersetzt keine Mutationvalidierung.
8. **Erst prüfen, dann präsentieren.** Neue UI visuell und mit echten Interaktionen prüfen: kompakte Desktop-Flächen, unabhängige Panel-Icons, lesbare Zustände, klarer Objektkontext, keine farbigen Rahmen. Kein bloßes Kontrollensammelsurium als Reaktion auf diese Inventarliste.

## Postproduction und Export getrennt

Nutzervorgabe: „Postproduction und Export sollten zudem unterschiedliche Projektphasen sein.“ Die bisherige Sammelphase „Finish“ wird im Zielkonzept aufgeteilt. Navigation: **Medien · Produktion · Schnitt · Postproduction · Export**. Medien bleibt phasenübergreifend; die vier übrigen Bereiche bilden die Projektarbeit ab. Die Trennung ist im Clickdummy umgesetzt und interaktiv geprüft.

| Phase | Aufgabe | Ergebnis |
|---|---|---|
| Schnitt | Auswahl, Reihenfolge, Timing, Trims und Montage | Montierte Sequenz |
| Postproduction | Bildkorrektur, Grading, Effekte, Tonbearbeitung, Titel, Untertitel und abschließende Film-/Übergangssichtung | Veredelter, überprüfter Filmstand |
| Export | Ausgabevarianten, Codec/Auflösung/Ziel, Aufträge und Verlauf, technische Prüfung erzeugter Dateien; XML-/Projektübergabe | Dateien mit nachvollziehbarer Quelle und Ausgabeeinstellungen |

Postproduction bearbeitet denselben Filmstand wie Schnitt. Der vorhandene Inspector, Effekt-Stack, Audio-/Text-/Caption-Weg und die Review-Dienste werden in einem eigenen Arbeitsbereich zugänglich. Es entsteht keine zweite Timeline oder Kopie der Clipparameter. Vorhandene Korrekturen bleiben auch aus dem Schnitt erreichbar. Aktionen, die die Montage verändern, etwa Füllwörter entfernen, bleiben am Schnittkontext verankert.

Die kreative Endkontrolle gehört zur Postproduction. Export zeigt den Status der übernommenen Version; die technische Prüfung der erzeugten Datei gehört zum Export. Eine gewünschte Korrektur führt mit demselben Clip-/Zeitkontext zurück zur Postproduction oder zum Schnitt. Ausgaben binden den jeweils übernommenen Filmstand. Spätere Änderungen machen dessen Review gegebenenfalls veraltet und ändern nicht rückwirkend frühere Ausgaben. Die native Option „aktuellen Sequenzreview voraussetzen“ bleibt eine ausdrückliche Wahl.

Code-Abgleich: `EditorViewModel.WorkspaceFocus` enthält derzeit `produce`, `edit`, `finish`. `FinishReviewPane` verbindet Review und Export, während die Postproduction-Werkzeuge überwiegend im Schnitt-Inspector liegen. Die Trennung erfordert eine UI-Ergänzung in Navigation, Workspace-Komposition und gespeicherten Ansichten; bestehende Inspector-/Review-/Exportdienste werden wiederverwendet. Gespeicherte alte `finish`-Ansichten müssen eindeutig migriert werden. Dies ist keine Anweisung zur Änderung der gesperrten Produktionsphasen-/Pack-Verträge.

Review der Zuordnung: Jede bisherige Finish-Funktion ist entweder Postproduction (FIN-01/02) oder Export (FIN-03/04/05) zugeordnet. Sämtliche POST-Funktionsgruppen bleiben erhalten. Die FIN-IDs bleiben als stabile Audit-Referenzen bestehen; sie bezeichnen keinen weiter vorgesehenen gemeinsamen Finish-Arbeitsbereich. Die getrennten Flächen wurden visuell und interaktiv geprüft; erneute native Abnahme bleibt vor Ablösung bestehender UI erforderlich.

## Was ein Erhaltungsnachweis pro Funktion enthält

| Feld | Erforderlicher Inhalt |
|---|---|
| Bestand | Matrix-ID, Quellkomponente und Handler/Service |
| Einstieg | Konkrete Aktion im neuen Arbeitsbereich oder nachweislich erhaltenes natives Fenster/Menü |
| Kontext | Betroffenes Asset, Shot, Take, Clip oder Projekt; erwartete Auswahl |
| Wirkung | Dieselbe fachliche Operation über vorhandene Mutationen/Writers |
| Zustände | Bereit, deaktiviert, fehlende Eingabe, laufend, Fehler, Abbruch; soweit für die Funktion zutreffend |
| Datenfolgen | Undo/Revision, Persistenz, Review-Invalidierung, Kosten-/Quellenbindung |
| Nachweis | Ausgeführtes fachliches Szenario; bei reiner Simulation ausdrücklich deren Grenze |

„Nicht im Mockup“ bedeutet offen, nicht verzichtbar. „Native Oberfläche erhalten“ muss mit erreichbarem Menü-/Fensterpfad belegt werden. „Teilweise“ und „Ersatzinteraktion fehlt“ erfüllen keinen Erhaltungsnachweis. Neue Fähigkeiten werden getrennt bewertet; sie kompensieren keinen Verlust bestehender Funktionen.

## Mindestfälle gegen die wichtigsten Regressionen

| Szenario | Erwartetes Verhalten |
|---|---|
| Leeres generisches Projekt; Video, Bild, Audio und Lottie importieren | Ohne KI-Pipeline auf geeignete Spuren legen, trimmen, bearbeiten, speichern und exportieren |
| Bestehendes Projekt mit Kurven, LUT, Effekten, Keyframes, Fades und Titeln öffnen | Werte, Wirkung und alle bisherigen Bearbeitungsmöglichkeiten bleiben erhalten |
| Mehrere verbundene Clips und mehrere Spuren bearbeiten | Auswahl, Clipboard, Ripple/Overwrite, Linking und Sync-Lock behalten ihre native Semantik |
| In Bild-/Sprachinhalt suchen und ein Segment verwenden | Trefferzeit, Quell-In/Out und Asset-ID stimmen; Offline-Datei kann neu verknüpft werden |
| Manuelle Generierung und KI-Edit | Ausführbares Modell, richtige Eingabeslots, kompilierter Auftrag, ausdrückliche Kostenfreigabe und eindeutiges Ausgabeziel |
| Strukturierter Auftrag statt Chat | Empfehlung prüfen, Pflichtfelder ergänzen, abbrechen, Ergebnis annehmen und später wiederfinden; kein verlorener Objektkontext |
| Generisches und Musicvideo-Projekt öffnen | Unterschiedliche deklarierte Phasen/Oberflächen; Track-/Lyrics-Intake und Analysevertrag korrekt; Pack-Farbe klar sichtbar |
| Approved Phase ändern, Job unterbrechen oder neu verbinden | Explizite Revision, keine parallele Ausführung, keine doppelte kostenpflichtige Submission, aktuelle Readiness |
| Generated, imported, AI-enhanced, continued und Still-Shots verwenden | Jeweilige exakte Quellen-/Frames-/Render-Verträge bleiben erhalten |
| Take vollständig bzw. nur im nutzbaren Bereich übernehmen | Gültiger spezifischer Review; Reparatur-/Iterationsgrenzen bleiben zugänglich |
| Schnitt nach Sequenzreview verändern | Review wird veraltet; optionaler Review-Zwang wirkt nur bei entsprechender Exportwahl |
| Zwischen Schnitt, Postproduction und Export wechseln | Gleiche Sequenz, Auswahl und Parameter; getrennte Aufgaben; keine zusätzliche generative Produktionspflicht |
| Hochkant/andere Bildrate; XML, Video und NGV-Kopie ausgeben | Richtige Projektgeometrie; bekannte Formatgrenzen; echte Ausgabe-/Fehlerzustände |
| Fehlender Pack oder Upgrade | Fail-closed und explizite Recovery-Kopie; kein stiller Wechsel auf generischen/latest Workflow |

Native Builds und Laufzeittests ausschließlich über die vorgesehenen GitHub-Actions-Runner. Ein HTML-Clickdummy oder statischer Inventarcheck ist keine native Produktabnahme.

## Arbeitsstand des Audits prüfen

`python3 docs/ui/audit-native-ui.py` prüft Zuordnungen, Quellbelege und Snapshot-Änderungen. Nach einer bewusst geprüften Änderung aktualisiert `--write` Inventar und lesbare Matrix. Der Prüfer erkennt nicht selbst, ob ein neuer Button fachlich richtig arbeitet; dafür bleibt der einzelne Erhaltungsnachweis erforderlich.
