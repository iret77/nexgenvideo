# Review: vollständiger Arbeitsbereich-Entwurf

Quellenstand `8bd8fbde`. Umsetzung ausschließlich im HTML-Clickdummy. Keine native Datei geändert, keine native App gebaut, gestartet oder getestet, kein Provider aufgerufen.

## Ergebnis

Die bisherige Sammelfläche Finish ist durch **Postproduction** und **Export** ersetzt. Medien, Produktion, Schnitt, Postproduction und Export besitzen jeweils ihre eigene Sidebar und verwenden gemeinsame Medien-, Shot-, Clip- und Sequenzdaten. Schnitt und Export bleiben auch ohne KI-Produktion möglich.

Die aktualisierte [Funktionsmatrix](native-ui-function-matrix-2026-09-18.md) ordnet alle 119 erfassten Gruppen zu: 115 Bestandsgruppen und vier gesonderte Vertragsvorschläge. Der [vorherige Befund](native-ui-capabilities-before-studio.tsv) bleibt erhalten. „Im Clickdummy abgebildet“ bedeutet eine Beispieloberfläche bzw. einen nachvollziehbaren Integrationsort, **keine bestandene native Funktionsabnahme**. Eine Gruppenzeile bedeutet nicht, dass jede native Unterfunktion im Browser nachgebaut wurde.

## Umgesetzte Flächen

- **Schnitt:** freie Medien, mehrere Spuren, Quellen, Transport, Split/Trim, Insert/Overwrite, Mehrfachauswahl, Clipboard, Ripple, Linking, Sync-Lock, Bereich und Medienaustausch. Eine Sequenz für Schnitt und Postproduction.
- **Postproduction:** Transformation, Bildpositionierung, Tempo und Keyframes; Tonwerte, RGB-/Hue-Kurven, Farbräder, LUT und Effektparameter; Ton/Fades; mehrere Titel und Untertitel; kontextgebundene KI-Aufträge; Film-/Übergangssichtung.
- **Export:** Videoformate, Master/Ableitung, Projektgeometrie und FPS, optionale Review-Voraussetzung, XML-/Projektübergabe, Ausgabehistorie und Abbruch. Kreative Endkontrolle bleibt in Postproduction.
- **Medien:** Ordner und Texte, alle platzierbaren Quelltypen, manuelle Bild-/Video-/Audiogenerierung, Provider-/Modellfilter, Herkunft, Inhaltssuche und zeitgebundene Beispieltreffer, Offline/Relink und Organisationsvorschlag.
- **Produktion:** Audiohierarchie/Messdetails, Wiederholungs-Intake, getrennte Story-Artefakte, Sketch-Momente/Animatic, hybride Shotquellen, Blocking/Blockout/POV, gerenderte Referenz-Entitäten und Attributsperren, Take-Review mit sechs Prüfgängen, Bereichsrettung und Reparatur-/Montageaufträge.
- **App und Engine-Interaktion:** Projekt-/Einstellungsmenüs, Pack-Konflikt/Recovery, MCP-Vertrauen, Backend-Bereitschaft, Aufgaben-/Entscheidungsverlauf, Kostenprüfung, Batch-Abbruch/Fortsetzung und Wiederherstellung des Clickdummy-Zustands.

## Kritische Review-Befunde und Korrekturen

1. Die neue Timeline hatte im ersten Browserbild keine Breite. Ihre Scrollfläche erhält jetzt explizit den verbleibenden Platz.
2. Ein Take-Klick konnte die Sichtung umgehen. Er öffnet jetzt die sechs Prüfgänge; Ablehnung/Abweichung verlangen eine Beobachtung. Nur ein gültiger Review übernimmt die Auswahl.
3. Deaktivierte Provider/Modelle blieben auswählbar. Der Generator filtert dieselbe Aktivierungsmenge und behandelt eine leere Menge mit gesperrter Vorbereitung.
4. Kostenfreigaben waren nicht vollständig an Zusatzquellen gebunden. Quelländerungen verwerfen die Quote; Übernahme prüft Revision und Kontext erneut.
5. Der Sequenzreview übersah Ton- und Spuränderungen. Seine Bindung umfasst jetzt alle Clips, Titel, Spuren, Audio und Projektgeometrie.
6. Editierbare Kontrollen blieben bei laufenden Aufträgen aktiv. Sie zeigen den gesperrten Zustand; Stoppen und Navigation bleiben erreichbar.
7. Split teilte veränderliche Effektobjekte. Die zweite Instanz erhält jetzt eigene Werte. Gesperrte Spuren widerstehen Split und Löschen.
8. Postproduction-Wiedergabe hing noch am alten Finish-Modus. Der Review-Transport besitzt nun auch in Postproduction einen fortlaufenden Cursor.
9. Referenz-/Projektgeometrie und 24-fps-Annahmen waren inkonsistent. Bildrate und Aspekt werden gemeinsam verwendet; ein 30-fps-Schritt wurde geprüft.
10. In sehr schmalen Ansichten liefen Navigation/Status über. Die jeweiligen Zeilen umbrechen; die Hauptarbeitsfläche wird nicht auf ein Viertel der Höhe reduziert.
11. Aufgabenoptionen waren nach Vorbereitung noch veränderbar. Der geprüfte Vorschlag ist fixiert; Änderung erfolgt durch Verwerfen und erneute Vorbereitung. Unvereinbare Ersatzentscheidungen verwenden eine Einfachauswahl.

## Prüfungen

- `check-desktop-production-workbench.mjs`: 35 Interaktionsfälle und 25 Layoutkombinationen (fünf Arbeitsbereiche bei 1440, 1024, 736, 500 und 320 px).
- `check-desktop-production-guards.mjs`: 30 zusätzliche Fälle für Freigaben, leere Modellkataloge, Kosten, Stop/Fortsetzen, Audio-/Spur-Invalidierung, Lock, Split, Bildrate, Exportabbruch und komprimierte Wiederherstellung.
- Browserklicks an kritischen Bedienwegen; übrige Fälle kombinieren DOM-Eingaben und den Testzugang für Fixture/Setup. Keine Behauptung, alle 65 Fälle seien ausschließlich physische Klicks.
- Visuell angesehen: Schnitt, Postproduction/Basis/Kurven, Endkontrolle, Medien, Storyboard und Export. Gemeinsame kompakte Titelleiste, modusspezifische Sidebar, neutrale Trenner, Pack-Akzent als Füllung, keine dekorativen farbigen Ränder. Die Standalone-Vorschau verwendet für zusätzliche Icons Text-Fallbacks; die Inline-Fassung nutzt die vorhandenen Lucide-Icons.
- Maschinenlesbare Ergebnisse: [Arbeitsbereiche](studio-workspace-checks.json), [Freigaben und Wiederaufnahme](studio-guard-checks.json). Historische Tests des alten Finish-/Einspur-Modells sind separat archiviert und gelten nicht für die neue Fassung.

## Simulationsgrenzen und native Umsetzung

Der Clickdummy decodiert weder Videos noch Ton. Er simuliert Transport und Arbeitszustände mit Standbildern. Nur ein Teil der Bildparameter hat eine vereinfachte Vorschau; Kurven, Farbräder und Effektparameter sind bedienbare Zustandsmodelle, kein Ersatz für NGVs Renderer. Suchen, Transkripte, Synchronisierung, KI-Vorschläge, Providerkosten, Dateidialoge, Pack-Updates und technische Exportproben verwenden Beispieldaten. Es werden keine Medien generiert und keine Ausgabedateien geschrieben. Die Demo bewahrt keine echten API-Keys.

Native Finder-/Dokument-/Updater-/Diagnoseoperationen, vollständige Provider-/MCP-Verbindungskonfiguration, sämtliche Modellgrenzen und Indexzustände sowie die vollständige Responder-/Ripple-/Compositing-Semantik bleiben an die vorhandenen Komponenten gebunden. Ihre Benutzerwege dürfen bei der späteren Umsetzung nicht auf die vereinfachte HTML-Simulation reduziert werden. Siehe [Erhaltungsvertrag](../UI_PARITY_CONTRACT.md).

Die bestehenden Komponenten `MediaTab`, `InspectorView` mit seinen Tabs, Timeline-/Clip-Mutationen, `GenerationView`, Review-Komponenten, `ExportView`, Provider-/Pack-/Settings-Dienste sind die Umsetzungsvorlage für Verhalten. Dieses HTML ist die Vorlage für Anordnung und Interaktion. Aus den früher untersuchten Upstream-Änderungen bleiben Paneltrennung, einklappbare Inspector-Gruppen sowie Medien-/Modell-/Kosteninformationen übernommen; Palmier-Accounts/Credits sind kein Bestandteil des Entwurfs.

Der native Phasenplan bleibt unverändert. Die Zielreihenfolge, ein eigenständiges Skript, mehrere Storyboard-Momente und FilmFlow-Adoption benötigen die separat gekennzeichnete Vertragsarbeit. Bible und Frames bleiben zwei Artefakte/Gates, obwohl die UI den gemeinsamen Begriff References verwendet. Postproduction/Export als Arbeitsbereiche schaffen keine zusätzlichen obligatorischen Produktionsgates. Kein gespeichertes Pack-Struct und keine Engine-ABI wurde verändert.
