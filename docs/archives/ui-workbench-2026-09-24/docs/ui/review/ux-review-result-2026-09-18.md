# Ergebnis: UI/UX-Review und Fable-Nachprüfung

18.09.2026 · nativer Quellenstand `8bd8fbde` · ausschließlich Mockup-Dateien geändert.

## Urteil

Das Grundlayout bleibt ein dichter Desktop-Arbeitsplatz mit gemeinsamer Sequenz, festen Panels und kontextbezogenen Werkzeugen. Fable bestätigt diese Richtung ausdrücklich. Seine Prüfung bewertet die damalige Interaktionslogik als **noch nicht abnahmereif** und nennt zwölf konkrete Befunde. Diese wurden anschließend am Quellcode verifiziert, korrigiert beziehungsweise für die eigenständige Testdarstellung eingegrenzt und durch gezielte Browserprüfungen nachgestellt. Es gab keinen zweiten Fable-Lauf; die Nachprüfung der Korrekturen erfolgte durch Codex.

**CLICKDUMMY und der Szenario-Wähler sind aus der Statusleiste entfernt.** Links stehen Arbeitskontext und Auswahl; Aufträge und Budget bleiben erreichbar. Testzustände werden über die äußeren Vorschauoptionen gewählt. **Transkript** ersetzt „Gesprochenes“; die Suche arbeitet tatsächlich auf Transkriptsegmenten statt auf Dateinamen.

## Unabhängiger Reviewer

Angeforderter Aufruf: `claude-high5`, `--model fable`, `--effort high`. Tatsächlich verwendetes Reviewmodell: **claude-fable-5-1**. Nur Read/Glob/Grep, keine Änderungen, keine Delegation, keine Permission-Denials. Sechs aktuelle Screenshots sowie die relevanten Mockup-Module wurden zur visuellen und funktionalen Prüfung freigegeben. [Originalbefunde und Aufrufnachweis](fable-ux-review-2026-09-18.json).

## Verifizierte Befunde und Behandlung

| Nr. | Befund | Korrektur / Entscheidung |
|---|---|---|
| 1 | Widersprüchliche Clipauswahl; Teilen/Löschen trifft falsche Hälfte | Primärauswahl bleibt Teil der markierten Menge. Split, Cmd-Abwahl, Titelwahl und Löschen halten Auswahl/Inspector zusammen. Leere Auswahl hat kein verstecktes Löschziel. |
| 2 | Ausgeblendete Bildspuren umgehen Exportprüfung | Endkontrolle und Videoexport lesen reale Spurzustände. Sind alle belegten Bildspuren verborgen, erscheint ein Befund und Videoexport ist gesperrt. Bewusste einzelne Schwarzpausen bleiben ein Reviewthema. |
| 3 | Titelwahl bearbeitet/löscht vorherigen Videoclip | Eigene Titelauswahl, richtiger Inspector-Kopf, eigene Löschaktion und Spurbindung. Verbergen/Sperren wirkt auf Titel; eine Titelspur ist nicht leer. |
| 4 | Insert/Drag erzeugt uneindeutige Überlappungen | Insert teilt einen überspannten Clip und verschiebt den hinteren Teil. Kollisionen beim Clip-Drag werden mit Erklärung abgewiesen; explizites Overwrite bleibt im Schnitt. |
| 5 | Sperren nur bei manchen Reglern wirksam | Gemeinsame Änderungsprüfung für Clipfelder, Keyframes, Kurven, LUT, Reset, Quelltausch und direkte/indirekte Aufträge. Entsprechende Controls sind sichtbar gesperrt. |
| 6 | Mehrfachauswahl wirkt je nach Feld unvorhersehbar | Bildparameter wirken auf ausgewählte Videoclips, Tonparameter auf ausgewählte Clips. In/Out/Spur sind bei Mehrfachauswahl gesperrt. Unterschiedliche numerische Werte erscheinen als „Gemischt“. |
| 7 | Animierte Werte konkurrieren mit statischen Feldern | Animierte Felder zeigen/schreiben den Wert am Abspielkopf. Keyframe-Gruppen erscheinen nur im zugehörigen Bild-/Tonkontext; Wechsel des Clips verwirft den alten Keyframe-Index. |
| 8 | Postproduction ändert Montage, hat aber tote Tastatur | Dort bleibt die Timeline für Auswahl, Navigation und Post-Arbeit. Rasierklinge, Split, Clip-Delete/Ripple/Paste/Move gehören zum Schnitt. Transport funktioniert auch per Tastatur. Titel lassen sich weiterhin in Post erstellen/löschen. Doppelte Endkontrolle-Navigation entfernt. |
| 9 | Aufträge ignorieren gewählte Option/Objekt | Referenzänderungen werten das gewählte und ungesperrte Attribut aus. Neue Anker werden am gebundenen Shot gespeichert und neu gesichtet. Sync benötigt ein Bild-/Tonpaar und verändert nur den gebundenen Audioclip. Veraltete Vorschläge nennen den Grund und lassen sich neu prüfen. |
| 10 | Unverständliche Ersatzglyphen, verteilte Viewer-Werkzeuge, abgeschnittenes Label | Viewer-Werkzeuge gruppiert; Bild passt in verfügbare Höhe; redundantes Label entfernt. Die Inline-Fassung verwendet die bereitgestellten Lucide-Symbole. Nur die eigenständige Browser-Testfassung hat für neun zusätzliche Symbole explizite Textlabels statt mehrdeutiger Unicode-Glyphen. Das ist keine Vorgabe für die Mac-App. |
| 11 | Mehrdeutige dreiteilige Zeitcodes | Zeitcodes einheitlich HH:MM:SS:FF; Audioübersicht/Lineal behalten ausdrücklich minuten-/sekundenbezogene Kurzskalen. |
| 12 | Testschalter im Produkt, Rechtsklick startet Rename, modale Menüs | Testschalter außerhalb der App; Medien-/Clip-Kontextmenü am Zeiger, Projektmenü am Titel. Dokumentaufgaben wie Umbenennen öffnen danach ein begrenztes Sheet. |

Zusätzliche eigene Korrekturen: kanonische Medien-/Take-Verwendungsanzeige, modellgebundene Wiederverwendung von Generierungsvorgaben, keine erfundenen Conditioning-Slots am Text-zu-Video-Modell, historische Export-Bildrate, Tonstatus aus tatsächlichen Spuren, kontextgerechte Audio-/Bildwerkzeuge und Suchbereiche.

## Desktop- und Apple-Abgleich

Die am 18.09.2026 gelesenen [Apple-HIG für macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos/) betonen parallelen Arbeitskontext, anpassbare Fenster und Tastaturbedienung. [Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars?changes=la) verlangen logisch gruppierte Aktionen und klare Symbole. [Kontextmenüs](https://developer.apple.com/design/human-interface-guidelines/context-menus?changes=_1) gehören zum gewählten Objekt; [Sheets](https://developer.apple.com/design/human-interface-guidelines/sheets?changes=_1_1) sind kein Ersatz für dauerhaft benötigten Arbeitskontext.

Darauf beruhen integrierte Titelleiste, unabhängige Sidebar-/Inspector-Schalter, neutrale Trenner, Auswahlfarben des Packs, objektbezogene Menüs und die durchgehende Timeline. Die [Wettbewerbsanalyse](desktop-research-2026-09-17.md) mit FCP, Resolve und LTX bleibt Grundlage. Native SF Symbols, Systemmaterialien, Menüleiste und vollständige Responderkette sind Anforderungen an die spätere App-Umsetzung; HTML belegt keine vollständige Apple-HIG-Konformität.

## Nachprüfung

- 35 Arbeitsbereichprüfungen und 25 Layoutkombinationen.
- 31 Prüfungen zu Freigaben, Jobs, Zuständen und Generierungsprovenienz.
- 16 gezielte Self-Review-Regressionen.
- 29 gezielte Fable-Regressionen einschließlich physischer Menü-/Dialogklicks.
- Ergebnisse: [Arbeitsbereiche](studio-workspace-checks.json), [Schutzregeln](studio-guard-checks.json), [Self-Review](studio-ux-checks.json), [Fable-Fälle](fable-regression-checks.json).
- Visuell nachgesehen: Medien, Audio, Storyboard, Schnitt, Postproduction, Export, Kontextmenü und Titel. Screenshots unter `studio-screenshots/ux-*.png`.

Die Tests mischen DOM-Ereignisse, reale Browserklicks und einen Testzugang zur Einrichtung von Ausgangszuständen. Sie belegen die genannten Fälle, keine vollständige native Runtime-Abnahme. Native Swift-Dateien bleiben unverändert; keine App-Builds, Provider-Aufrufe oder echten Render-/Exportläufe.

## Verbleibende Simulations- und Integrationsgrenzen

Kein echter Audio-/Videorenderer und keine vollständig nachgebildete Grading-Pipeline. Echte KI-Ergebnisse, Suchindizes, Dateioperationen, Providerfähigkeiten und Kosten werden nicht behauptet. Zwei Gruppen sind im [Erhaltungsinventar](native-ui-function-matrix-2026-09-18.md) ausdrücklich **teilweise** abgebildet: vollständige modellabhängige Endframe-/Mehrfachreferenz-Eingaben und Quellvideo-/Trim-Profile im freien Generator. Das ist eine offene Ausarbeitung im Clickdummy; vorhandene native Funktionen bleiben zwingend zu erhalten. Unbelegte Slots an einem unpassenden Modell sind keine Lösung dafür.

Gesicherte Phasenverträge, Pack-ABI, bestehende Writers/Gates und der native Funktionsbestand werden durch diesen UI-Entwurf nicht geändert. Der Erhaltungsvertrag bleibt bindende Umsetzungshilfe; die Inventarabdeckung ist keine Behauptung, sämtliche Unterfunktionen seien interaktiv fehlerfrei nachgebaut.
