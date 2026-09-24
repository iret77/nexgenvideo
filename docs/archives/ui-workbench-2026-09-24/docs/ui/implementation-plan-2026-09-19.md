# Native Umsetzung des Produktionsarbeitsplatzes

Stand: 19.09.2026. Geprüfter nativer Quellenstand: `8bd8fbde5cdb9a2a46b26c2441aa5035c885d1e0`. Dieser Plan beschreibt die Umsetzung des Clickdummys, keine bereits erteilte Freigabe zur Änderung gesperrter Verträge. Kein nativer Code wurde beim Polishing geändert.

## Vorgehen

Das Konzept wird in der vorhandenen SwiftUI-/AppKit-App umgesetzt. Keine HTML-Oberfläche in einem WebView, kein neuer Editor, keine zweite Medienbibliothek, kein zweiter Pipeline-Runner. `EditorView` besitzt bereits wiederverwendbare Hosting-Controller für Bibliothek, Viewer, Inspector, Cockpit, Timeline und Review. Diese werden neu angeordnet und erhalten klar abgegrenzte Presenter.

Die Etappen sind getrennt prüfbare Änderungen in einem abgestimmten Arbeitsumfang, keine Zwischenreleases. Die bestehende Oberfläche bleibt intern erreichbar, bis ihre Erhaltungsnachweise erfüllt sind. Native Verifikation läuft ausschließlich in GitHub Actions. Merge und Release benötigen weiterhin das ausdrückliche „build now“ des Eigentümers.

## Abgleich mit Skill 3.4 und Higgsfield

[PR #548](https://github.com/iret77/nexgenvideo/pull/548) wurde einschließlich `migration-3.4.spec.md` am Head `e59f08d377712b58f3694383b11302fed6f5860a` gelesen. Er erweitert Wissen und Spezifikationen; die Runtime-Migration ist separat in [#547](https://github.com/iret77/nexgenvideo/issues/547) beauftragt. Den Wissensimport nicht als bereits ausgeführte Compiler-, Harness- oder UI-Migration behandeln. Vor nativer Umsetzung den dann aktuellen Stand erneut abgleichen.

Für die UI-Anbindung daraus berücksichtigen:

- Die drei Prompttechniken sind eine projektbezogene kreative Entscheidung mit Empfehlung und begründetem Wechsel. Die Engine kompiliert daraus; keine drei Prompteditoren und keine neue Abfrage vor der Musicvideo-Analyse. Ein Vergleichslauf braucht eigene Kostenfreigabe.
- Animatic prüft geplantes Timing vor teurer Generierung. Planungszeiten, tatsächlich beobachtete Cuts und Positionen im Schnitt bleiben verschiedene Daten. Die bestehenden gesperrten Phasenverträge werden nicht durch die Beispielreihenfolge des Skills überschrieben.
- Draft- und Produktions-Takes sowie ein ausdrücklich geretteter/abgeleiteter Draft benötigen sichtbaren Status, Herkunft und Abnahme. Ein Draft wird nicht durch Umbenennen oder Wahl als final zum Produktions-Take.
- Take-Prüfung und Montageprüfung bleiben getrennt. Reine Schnittbefunde (`[edit]` im Wissen) führen zum Schnittkontext, nicht zu einer erneuten Videogenerierung. Retake-Empfehlungen müssen nach #547 dessen tatsächliche Iterations- und Reparaturzustände verwenden; die bisherige Dummy-Formulierung „nach zwei Fehlversuchen“ ersetzt diesen Vertrag nicht.
- Render-Slate und Promptprüfungen werden aus realen Compiler-/Reviewdaten bezogen. Technische Messwerte und Crew-Entscheidungen sind Details zum jeweiligen Shot/Auftrag, keine zusätzliche dauerhafte Textfläche. Semantische Befunde dürfen nicht allein aus Zählwerten als bestanden erscheinen.

Die laufende Aufgabe **„Higgsfield API recherchieren“** ergänzt den API-Zugang. Der vorhandene [Recherche- und Integrationsplan](../HIGGSFIELD_API_RESEARCH.md) ist eine Abstimmungsgrundlage, kein Beleg für bereits ausführbare Modellangebote. Provider-Client, Authentifizierung, Katalog und Routing bleiben bei dieser Implementierung; dieser UI-Plan erzeugt keinen zweiten Integrationsweg.

Die UI übernimmt deren fertige Verträge: Higgsfield als Provider mit getrenntem API- und MCP-Zugang, jeweils passendem Anmeldestatus, Angebot und Abrechnung. Eingabeslots, Kostenfreigabe, Wiederaufnahme und zulässige Abbruchaktionen richten sich nach dem tatsächlich ausgeführten Zugang. Insbesondere dürfen ein unklares Submission-Ergebnis keinen stillen kostenpflichtigen Neuversuch und eine nur wartende Jobs betreffende Cancel-Fähigkeit keinen universellen „Stoppen“-Button ergeben. Konkrete Modelle, Limits und ausführbare API-Key-Eingaben erst nach Abgleich mit dem gelieferten Client/Katalog anbieten. Die bisherige Dummy-Anbieterliste bleibt eine Simulation und ist keine abschließende Anbieterliste für die native Umsetzung.

## Abgleich mit Clay-Blocking: Epic #540

[Epic #540](https://github.com/iret77/nexgenvideo/issues/540) und alle sechs Teil-Issues #541–#546 wurden gelesen. Das Epic beschreibt eine **optionale native 3D-Fähigkeit innerhalb NGV**, mit verwalteter bpy-Laufzeit, persistenter Location und echten perspektivischen Clay-Ausgaben. Der Dummy zeigt inzwischen eine interaktive perspektivische Clay-Simulation. Das ist kein Nachweis einer bpy-Integration oder Engine-Parität. Die Clay-Arbeitsfläche kann gemäß #544 auch unabhängig vom vollständigen appweiten UI-Refactoring entstehen; beide müssen dieselben Auswahl-, Inspector- und Writer-Verträge nutzen.

| Teil-Issue | Anschluss an das UI-Konzept und seine Abnahme |
|---|---|
| [#541 – Laufzeit](https://github.com/iret77/nexgenvideo/issues/541) | NGV besitzt Bereitschaft, Job, Abbruch und Recovery. Keine Blender-App oder manuelle Python-/MCP-Einrichtung im Benutzerablauf. Lokale Clay-Berechnung und bezahlte Mediengenerierung erhalten ihre tatsächlichen Status- und Kosteninformationen. |
| [#542 – Szenenquelle](https://github.com/iret77/nexgenvideo/issues/542) | Agent und Benutzer bearbeiten dieselbe bestätigte Location-Revision mit stabilen Objekt-/Kamera-IDs. Auswahl, Inspector, Undo/Redo, Wiederöffnen und Recovery zeigen diesen Stand. Veraltete Ableitungen bleiben als solche erkennbar; keine parallel editierbare Kamera- oder Skriptwahrheit. |
| [#543 – Agent-Werkzeuge](https://github.com/iret77/nexgenvideo/issues/543) | Strukturierte Aufträge beziehen sich auf ausgewählte Location, Objekte oder Kameras; der Agent erhält tatsächliche Perspektivbilder zur Korrektur. Fachliche Änderungsfelder und direkte Manipulation passen zum Interaktionsbereich. Keine Blender-Konsole und kein freier Chat als Voraussetzung. |
| [#544 – Arbeitsfläche](https://github.com/iret77/nexgenvideo/issues/544) | Native Szene mit Orbit/Pan/Zoom, Auswahl, Verschieben/Drehen/Skalieren, Snaps und kontextbezogenem Inspector. Freie Betrachtung und produktive Shot-Kamera eindeutig unterscheiden. Kamerabahn mit zeitgebundenen Keyframes, Blickziel, Scrubbing und Wiedergabe; Start/Mitte/Ende visuell prüfen. Keine vollständige DCC-Oberfläche nachbauen. |
| [#545 – Clay-Ausgaben](https://github.com/iret77/nexgenvideo/issues/545) | Schnelle Arbeitsvorschau und verbindliche bpy-Ausgabe sichtbar unterscheiden. Stills und Clips bleiben an Szene, Kamera, Zeit und Ausgabe gebunden. Panorama-Crops, schematische Blockouts oder ein einzelnes Still dürfen keine echte räumliche Kamerafahrt behaupten. |
| [#546 – Pipeline-Anbindung](https://github.com/iret77/nexgenvideo/issues/546) | Frühe Location-/Prüfkameras von endgültigen Shot-Setups unterscheiden. Referenzrolle, Herkunft, Aktualität und tatsächliche Modelleignung vor Kostenfreigabe zeigen. Änderungen führen zum betroffenen Artefakt/Shot und erforderlichen Rewind; bestehende Writer und Freigaben bleiben Eigentümer. |

**Phasen und Zuständigkeit:** Im bestätigten UI-Ziel ist Blocking ein optionaler Schritt zwischen Shotplanung und References, mit ausdrücklichem Überspringen. Diese UI-Reihenfolge ist noch keine Änderung der gesperrten nativen Phasenverträge. Frühes Location-Blocking muss vor daraus erzeugten Location-Ankern möglich sein. #546 klärt dafür die Zuständigkeit in Production Design/Bible; endgültige Shot-Kamera, Bahn und Zeit hängen am Shot-List-Writer. Das ist keine neue globale Pflichtphase und keine Verschiebung des Musicvideo-Starts. Die konkrete deterministische Clay-Provenance und zusätzliche Phase-Capabilities bedürfen des gesonderten Vertragsentwurfs aus #546, bevor gesperrte Verträge geändert werden. Die heutige Planung darf Clay-Bilder weder als KI-generiert noch als bestätigten Import umetikettieren.

**Verbindung zu #533, #548/#547 und Higgsfield:** #533 bleibt der gemeinsame Pre-Render-/Continuity-Review und konsumiert die räumlichen Quellen/Befunde. Skill 3.4 ergänzt Animatic, Blockout- und Take-Regeln; seine Beispielreihenfolge ändert keine NGV-Gates. Clay-Stills steuern Geometrie/Komposition, Look-/Identitätsbilder das Aussehen; Clay-Clips dienen Bewegung/Timing nur bei einem genau passenden ausführbaren Video-Input. Die parallele Higgsfield-Anbindung liefert dafür echte routebezogene Fähigkeiten, keine pauschale Unterstützung aller Bild-/Video-/Depth-/Mask-Eingaben. Kein stiller Wechsel des Modells, kein Ersatz eines Clips durch ein Still und keine Umdeutung zum AI-enhanced-Quellvideo.

**Räumlicher Vertrag:** Eine Clay-Szene ist eine Location für einen oder mehrere Shots. Shots referenzieren deren stabile Geometrie und Objektpositionen, erhalten aber eigene Kameras/Bahnen. Ein anderer Look, Tageszeit oder visueller Zustand erfordert keine geometrische Kopie. Verbindliche 2D-Snapshots bestimmen Positionierung, Sichtachsen und Kameraperspektive für Bild-/Videomodelle; andere Anker und das kompilierte Prompt bestimmen Aussehen, Look und Licht. Clay ist kein Ersatz für Look- oder Identitätsreferenzen.

**Stand des Clickdummys:** Raumansicht mit Orbit/Zoom, Transformationen im Inspector, wiederverwendbare Locations, shotbezogene Start-/Endkameras, Scrubbing/Wiedergabe, sichtbare 2D-Ableitungen, Einzelabnahme und Aktualitätsprüfung sind simuliert. Die Kameravorschau verwendet dasselbe Projektformat und dieselbe Optik wie die Ableitung. Die Optik bleibt der Shotplanung zugeordnet und ist nur über Rewind änderbar. Ungültig gewordene räumliche Ableitungen werden gezielt neu erstellt; weiterhin gültige Sichtungen bleiben erhalten. References führt den Clay-Snapshot als Positionierungsquelle getrennt von Look-/Identitätsankern. FilmFlow-Vorarbeit landet beim ersten fehlenden Schritt, gegebenenfalls der optionalen Blocking-Entscheidung.

**Offene native Umsetzung:** Keine echte bpy-Laufzeit, freie Geometrieerzeugung, Datei-/Videoausgabe, 3D-Gizmos/Snapping oder schema-validierten Agenttransaktionen im Dummy. Er zeigt einfache perspektivisch projizierte Volumen; sie sind keine ausgeführten Blender-Renderings. Die Simulationsabnahme bestätigt keinen semantischen Raum- oder Bildaudit. Verbindliche Provider-Eingaberollen und Clipfähigkeit müssen aus dem tatsächlichen Client/Katalog der parallelen Integration stammen. Kein stiller Clip-zu-Still- oder Modellwechsel. Die reale End-to-End-Abnahme aus #540 bleibt erforderlich, einschließlich Gegenansicht, Fahrten, manueller/agentischer Änderungen und veralteter Ausgaben in Generic und Musicvideo.

## 1. Gemeinsame Oberfläche und Auswahl

- `AppTheme`, `TitleBarView`, `EditorView` und `PaddedDividerSplitViewController` weiterverwenden. Gemeinsame Pane-Köpfe, Inspector-Zeilen, Abschnittsköpfe, deaktivierte Zustände und SF Symbols als native Komponenten vereinheitlichen. Alle Maße werden AppTheme-Tokens; der Dummy verwendet einen gemeinsamen 40-px-Kopf.
- `WorkspaceFocus` von Produce/Edit/Finish auf Medien/Produktion/Schnitt/Postproduction/Export erweitern. Gespeicherte Ansichten gezielt migrieren; eine reine Ansichtsänderung verändert keine Produktionsphase. Auswahl, Playhead, Panelbreiten und Sichtbarkeit je Arbeitsbereich wiederherstellen.
- Genau eine Auswahlquelle pro Kontext: Asset, Szene/Abschnitt, Shot, Take oder Timeline-Clip. Workspace-Wechsel darf keine neue Projektwahrheit erzeugen. Native Menüs, Responder, Undo/Redo, Tastatur und Mehrfachauswahl erhalten.
- Übernahme aus [#506](https://github.com/iret77/nexgenvideo/issues/506): passende Teile der Chrome-Commits `89ce887e` / `6f4d1643`. Aus [#507](https://github.com/iret77/nexgenvideo/issues/507): Inspector-Bausteine und Achsen aus `cfe9c18f` / `3026f72e`. Keine kompletten Upstream-Dateien über die NGV-Funktionen kopieren.

Abnahme: gleiche Kopflinie bei Phasen-/Tabwechsel, vollständige Bedienbarkeit bei schmalem Inspector, unabhängige Panel-Schalter, keine Änderungen an Daten oder Undo durch Layoutaktionen. Die ältere Issue-Forderung nach drei Workspaces und beschrifteten Panel-Schaltern ist durch die ausdrücklichen späteren Owner-Vorgaben überholt; vor Umsetzung die Issue-Kriterien entsprechend abgleichen.

## 2. Medien, Schnitt, Postproduction und Export aus dem Bestand

- `MediaTab` / `MediaPanelView` zum bildschirmfüllenden Medien-Arbeitsbereich zusammensetzen. Kompakte Picker verwenden dieselbe Bibliothek. Ordner, Texte, Inhaltssuche, Transkript, Relink, Multi-Selection und Drop-Semantik bleiben erhalten.
- [#508](https://github.com/iret77/nexgenvideo/issues/508), Commit `6aafb867`: Asset-Identität, Provenienz und vorhandene Asset-Aktionen adaptieren. Kosten/Modelldarstellung aus `49841f35` nur providerneutral übernehmen. Keine Palmier-Accounts, Credits oder fal-only-Annahmen.
- Den vollständigen nativen `GenerationView`-Eingabeteil samt `GenerationPackageInputs` und Validatoren einbetten. GEN-03/04 im Dummy bleiben ausdrücklich teilweise dargestellt: dessen einzelner Bild-Slot darf First/Last-Frames, Referenzrollen, Video-/Audio-Slots und Quellvideo-Trim nicht ersetzen.
- Vorhandene Mehrspur-Timeline, Viewer und Clip-Inspector bleiben der Schnitt. Postproduction nutzt dieselben Clips, Parameter, Keyframes, Kurven, Farbräder, LUTs, Effekte, Audio-, Titel-, Caption- und AI-Edit-Werkzeuge. Kein Duplizieren einer Sequenz beim Workspace-Wechsel.
- `SequenceReviewView` / `PipelineSequenceReviewStore` in Postproduction; Ausgabeanteile aus `FinishReviewPane` und bestehende `ExportCoordinator` / `ExportService` in Export. Zwei getrennte Aktivitäts-Presenter lesen reale KI- bzw. Exportjobs. Keine erfundenen Fortschrittswerte oder zusätzliche Queue-Semantik.

Abnahme: alle betroffenen Einträge der [Funktionsmatrix](review/native-ui-function-matrix-2026-09-18.md) mit konkretem alten und neuen Einstieg, gleicher fachlicher Mutation und nativer Evidenz gemäß [Paritätsvertrag](UI_PARITY_CONTRACT.md). Besonders bestehendes Projekt mit Effekten/Keyframes öffnen und unverändert ausgeben; leeres generisches Projekt ohne generative Pipeline schneiden/exportieren.

## 3. Produktion: strukturierte Bedienung vor dem bestehenden Harness

`AgentDialogCard`, `AgentBlocksView`, Gate-, Spend- und Batch-Karten liefern bereits strukturierte Interaktionen. Diese werden als objektbezogener Interaktionsbereich dargestellt. Pipeline und Engine bestimmen verfügbare Aktionen und Pflichtfelder; der Agent liefert innerhalb der Schemata Vorschläge und Ergebnisse. Freie Unterhaltung wird nicht der alternative Weg um Freigaben herum. Textfelder erscheinen für tatsächliche Textarbeit, beispielsweise Briefing oder eine Änderungsbeobachtung.

Audioanalyse verwendet `AnalysisSurfaceData`, `BeatTimeline` und `StructureHierarchyList`; keine textuelle Ersatzansicht. Jeder Schritt zeigt sein eigenes Artefakt, Auswahlkontext und nächste zulässige Aktion. Freigabe, Übernahme eines Vorschlags und kostenpflichtiger Start bleiben verschiedene Aktionen.

Die aktuelle native Reihenfolge bleibt zunächst exakt:

`project_init → analysis → brief → production_design → treatment → storyboard → bible → shotlist → sanity → frames → render`

Die Sidebar in dieser internen Umsetzungsstufe folgt unverändert der tatsächlichen Gate-Reihenfolge: **Referenzstudien** (`bible`) → **Shotliste** (`shotlist`) → **Plausibilitätsprüfung** (`sanity`) → **Shot-Anker** (`frames`) → **Video-Takes** (`render`). Die Referenzstudien umfassen Figuren, Ensembles, Orte, Props und Look. Referenzstudien und Shot-Anker dürfen denselben References-Presenter nutzen, behalten aber getrennte Navigationseinträge, Ausführungsidentität und Freigaben. „Render-Review“ wird erst mit dem in Etappe 4 beschlossenen vollständigen Vertrag aus #533 verwendet; Sanity erhält dieses Label ausdrücklich nicht. **Sanity liegt heute vor Frames.** Daher darf ein Sanity-Ergebnis niemals als abschließende semantische Prüfung später erst erzeugter Ankerbilder dargestellt werden. Frame-Audit/Acceptance und exakte Render-Quellenbindung bleiben zusätzlich sichtbar und wirksam.

Abnahme: Musicvideo-Start Track → optionale Lyrics → Init → freigegebene Analyse → optionale Vorarbeit; Greenfield ohne Import; Rewind mit vollständiger Folgewirkung; ein Phase-Job trotz Reconnect; strukturelle Readiness vor Anzeige und erneut beim Klick; fehlender Pack stoppt die Ausführung. Sanity trägt keinen abschließenden Bildprüfungs-Wortlaut; die Sidebar-Reihenfolge wird unabhängig vom Mockup gegen die realen Gates geprüft. Diese Fläche kann auf bestehenden Verträgen aufgebaut werden, entspricht allein aber noch nicht vollständig der Zielreihenfolge des Dummys.

## 4. Begrenzte neue Produktionsverträge ausdrücklich entscheiden

Diese Punkte sind notwendig, um das **gesamte** bisherige Zielkonzept umzusetzen. Die zusätzliche optionale Clay-Fähigkeit und ihre Vertragsanpassungen werden im Abgleich mit #540/#546 oben geführt. Sie sind keine kosmetischen UI-Änderungen und dürfen nicht stillschweigend in Etappe 3 verschwinden:

| Entscheidung | Begrenzte Umsetzung | Erhaltungsregel |
|---|---|---|
| Skript und kanonisches Shot-Timing | Versioniertes Szenen-/Storyboard-Zusatzartefakt, stabile Shot-/Step-Zuordnung; mehrere Sketch-Momente mit Zeiten innerhalb einer Einstellung. Eindeutigen Besitzer der Dauer festlegen und auf Shotlist-Writer abbilden. | Heute hat `Storyboard.Step` keine eigene Dauer. Kein zweiter unabhängiger Zeitwert; Änderungen freigegebener Erzählung/Timing benötigen Rewind. |
| Shotplanung vor fertigen References | Entwurfsplanung von ausführbarer, bildgebundener Shot List unterscheiden; Referenzbedarf aus der Planung ableiten, finale Bindungen vor Render deterministisch validieren. | Keine Dummy-Bilder oder fehlenden Dateipfade in den aktuellen kanonischen Writer schmuggeln. Bible/Frames bleiben bis zur beschlossenen Migration eigene Artefakte. |
| Finaler Review vor Video | [#533](https://github.com/iret77/nexgenvideo/issues/533): bestehende Causality-/Spatial-/State-Ladder-, Sanity- und Frame-Audit-Daten verbinden; KI erstellt prüfbare Input/Output-Vorschläge pro Shot, deterministische Gates binden Befunde an exakte Artefaktrevisionen. | Prüfung in Weltchronologie; Zeitsprünge und unbestimmte Zeit explizit. Text **und tatsächlich aktuelle** Referenzbilder müssen vor teurem Render geprüft sein. Kreative Ausnahme mit Begründung darf keine strukturellen Fehler umgehen. |
| FilmFlow-Snapshot | Importadapter für Story, Objekte, Shots und Sketches mit Herkunft, IDs, Version und Konflikt-/Adoptionsprüfung. Einstieg am ersten tatsächlich fehlenden Schritt. | Keine erfundenen Freigaben früherer Phasen, kein Live-Sync als Voraussetzung, generischer Greenfield bleibt vollständig nutzbar. Kein zweiter FilmFlow-Drehbucheditor. |

Vertragsänderungen erfolgen versioniert über neue/additive Carrier und gemeinsame Writer/Gates/Lineage. Keine neuen gespeicherten Felder in kompatibel gehaltenen Pack-Structs. Pack-Version, Schema, Migration und Recovery-Kopie müssen vor Aktivierung geklärt sein. Der generische Kern besitzt allgemeine Shot-, Referenz- und Review-Funktionen; Musicvideo ergänzt Audioanalyse, Songbezug und seine Utilities.

## 5. Exportbilder und abschließende Abnahme

Das Album-Cover bindet die vorhandene optionale Musicvideo-Utility ein. Das generische Vorschaubild benötigt eine kleine neue Exportzuordnung: ausdrücklich übernommene Quelle, eingefrorener Snapshot pro Auftrag und transaktionale PNG-Begleitdatei. Video und Begleitdatei dürfen nicht widersprüchlich als erfolgreich gemeldet werden. XML-/Projektübergabe bleibt unabhängig.

Vor Ablösung jeder Bestandsfläche: alle 121 Inventargruppen zuordnen; die 114 Dummy-Simulationen sind kein nativer Paritätsnachweis, zwei Modellprofilgruppen bleiben teilweise simuliert und fünf Gruppen sind Vorschläge. Aktuelle statische Erfassung erneut ausführen, gezielte native Tests auf GitHub Actions, dann visuelle Abnahme der vollständigen Arbeitswege. Erst ein gemeinsam abgenommener Batch wird zur Veröffentlichung vorgelegt.

## Benchmark-Abgleich je Arbeitsweg

Primärquellen und offizielle Screenshots am 19.09.2026 erneut geprüft: [Final Cut Pro](https://support.apple.com/en-ca/guide/final-cut-pro/ver2a27194eb/mac), [Resolve Edit](https://www.blackmagicdesign.com/products/davinciresolve/edit), [Resolve Media](https://www.blackmagicdesign.com/products/davinciresolve/media), [LTX Desktop](https://github.com/Lightricks/LTX-Desktop). Die folgende Zuordnung ist unsere Designableitung, keine Behauptung identischer Funktionen.

| NGV-Arbeitsweg | Übernommenes Prinzip / klare Grenze |
|---|---|
| Medien, Suche, manueller Generator | FCP-Browser und Resolve-Bins: Organisation und Auswahl. LTX: Generierung nahe dem Asset. Zwei kompakte Werkzeugzeilen; Suchbereich im Suchfeld. |
| Track/Lyrics/Audioanalyse | Zeitbezogene visuelle Orientierung wie bei Audio-/Timeline-Werkzeugen; Analysehierarchie und deterministisches Intake sind NGV-spezifisch. |
| Briefing, Gestaltung, Treatment, Skript | Stabile Dokumentfläche und objektbezogener Inspector. Kein gleichwertiger generativer Phasenablauf in den drei Benchmarks belegt; keine vorgezogenen Bilder im Briefing. |
| Storyboard, Momente, Animatic | Visuelle Sequenz und eindeutige Auswahl; Transport nur im Animatic. Die Sketch-Moment-Verträge sind NGV-Erweiterungen. |
| Shotplanung, Blocking | Derselbe Shot, jetzt technische Produktionsentscheidungen; räumlicher Plan statt erneutem Storytelling. Keine Behauptung eines entsprechenden Resolve-/FCP-Produktionsharness. |
| References und Render-Review | Gerenderte Produktionsinputs und revisionsgebundene Prüfung. LTX liefert Inspiration für gezielte Input-Bindung; Weltchronologie/Continuity-Gates sind NGV-eigen. |
| Video-Takes, Review, Retake | LTXs Generierung/Retake im Arbeitskontext plus NLE-Auswahlprinzip. Begrenzte Iteration, Kostenfreigabe, geprüfte Bereiche und kanonische Quellen bleiben NGV-Verträge. |
| Schnitt | FCP/Resolve/LTX: Medienquelle, Viewer, Clip-Inspector und echte Timeline. Der vorhandene NGV-NLE bleibt Grundlage. |
| Postproduction, Endkontrolle | Resolve-Aufgabentrennung und vorhandene NGV-Inspector-Werkzeuge; Auswahl in derselben Timeline. FCPs kontextbezogene Inspektoren. Kein Anspruch auf vollständige Resolve-Farb-/Fairlight-Parität. |
| Export, Verlauf, Bilder | Aufgabe Ausgabe von Bearbeitung trennen; Start am Ausgabe-Kontext, Hintergrundaktivität separat. Album-Cover und generische Preview-Bindung sind NGV-spezifisch. |

## Präzisierung aus dem Abnahmelauf vom 20.09.2026

Der überarbeitete Clickdummy ist eine UI- und Interaktionsvorlage; seine In-Memory-Prüfungen sind ausdrücklich keine Implementierung des nativen Harness. Die Ergänzungen schließen konkrete Bedien- und Zustandslücken des Reviews vom 19.09.:

- Medienidentität, Gültigkeit der Eingaben und Freigabe sind getrennte Zustände. Ein Rewind bewahrt Dateien und Timeline-Quellen. Wiederverwendung braucht nativ einen überprüfbaren Nachweis innerhalb des gesperrten Lineage-Vertrags. Dummy-Eingabesignaturen oder wieder gewählte UI-Haken reichen nicht. Die explizite Entscheidung über gegebenenfalls erforderliche Vertragsarbeit bleibt offen.
- Die native Implementierung adressiert Shot, Kamera, Take und Medium mit stabilen IDs. Index-Reparaturen des Dummys sind kein Persistenzformat. Generierungen bekommen eigene, unveränderliche Kennungen; eine spätere Revision überschreibt keine frühere Herkunft.
- Storyboard und Animatic verwenden eine gemeinsame Shotdauer. Split teilt die lokale Zeit und ggf. Bewegungsverläufe; eine räumliche Location bleibt erhalten. Neue Shots erhalten ausdrücklich zugewiesene, zunächst optionale Clay-Kameras. Figuren-/Prop-Inszenierung ist shotbezogen; feste Geometrie ist gemeinsam. Diese Verträge mit #540/#546 und den vorhandenen SpatialProductionPlan-Daten abgleichen.
- Ein Review-Befund verweist auf konkrete Shots, Quellen und Zustandsdifferenzen in Story-Zeit. Eine bestätigte Korrektur ändert genau das ausgewiesene Artefakt und stößt dessen fachliche Folgeprüfung an. Maschinenbefund und kreative Nutzerentscheidung bleiben getrennt; bewusste Ausnahmen löschen keine Befunde.
- Song- und Shotspuren teilen Koordinatensystem, Zoom und Scrollposition. Ein Ausschnitt beginnt an einer ausdrücklichen Songposition; das Songende bleibt eine tatsächliche Grenze. Diese Erweiterung gehört in den Musicvideo-Adapter, der generische Animatic-Kern bleibt songunabhängig.
- Leere Schnitt-Timelines können die freigegebene Auswahl als Ausgangsmontage übernehmen. Bestehende Montagen werden bewahrt; eine alternative Montage verlangt eine eigene Übernahme. Postproduction und Export bleiben getrennt.

Die im früheren Code-Abgleich genannten PRs/SHAs sind historische Prüfpunkte. Vor nativer Umsetzung die tatsächlichen aktuellen Heads einschließlich #548/#547 und Higgsfield erneut prüfen. Diese Mockup-Änderungen autorisieren keinen Build, Merge, Release oder stillen Umbau gesperrter Verträge.
