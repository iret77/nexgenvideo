# Native Workbench: verbindliche Implementierungsvorlage

Stand 20.09.2026. Auftrag: das freigegebene Desktop-Konzept als begrenztes UI-Refactoring im bestehenden NexGenVideo umsetzen. Diese Lieferung bereitet die Implementierung vor; sie implementiert keine native Oberfläche und erteilt keine Build-/Merge-/Release-Freigabe.

- [Clickdummy herunterladen und lokal im Browser öffnen](workbench.html) — eigenständige, eingefrorene Vorlage, kein WebView-Produkt.
- [Implementierungs-Issues und Reihenfolge](issue-index.md).
- [Funktionsinventar](native-function-matrix.md) — 121 historische Gruppen, vor jedem Umbau gegen aktuellen Code prüfen.
- [Letzter Interaktionsreview: direkte Objektauswahl](selection-review.md).
- [Filmvorschau](film-preview.png) / [Medienvorschau](media-preview.png).

## Quellenstand und Geltung

GitHub-main wurde am 20.09.2026 als `8bd8fbde5cdb9a2a46b26c2441aa5035c885d1e0` verifiziert. Die parallele [Higgsfield-PR #549](https://github.com/iret77/nexgenvideo/pull/549) ist offen, Head `9b1e09fc2d9834a611d1cfbcbf6ef7d32bcd755c`. Der lokale Code-Abgleich enthielt diese Änderungen. [Wissens-PR #548](https://github.com/iret77/nexgenvideo/pull/548) ist offen, Head `e59f08d377712b58f3694383b11302fed6f5860a`; die Runtime-Migration bleibt [#547](https://github.com/iret77/nexgenvideo/issues/547). Vor Umsetzung Status und tatsächliche Integration erneut prüfen. Offene PRs sind nicht in main vorhanden.

Der Clickdummy simuliert Daten, KI, Import, Jobs und Exporte. Seine JavaScript-Bedingungen sind keine gültigen nativen Gates, seine Beispielmodelle/-preise keine aktuelle Provider-Spezifikation. Die native App bleibt SwiftUI/AppKit/AVFoundation; bestehende Engine, Writer, Bibliothek, Timeline, VideoEngine, Inspector und Provider werden weiterverwendet.

Bei Widersprüchen gilt: aktuelle ausdrückliche Owner-Vorgaben → gesperrte Verträge bis zu ihrer ausdrücklichen Änderung → diese aktuelle Implementierungsvorlage → ältere Entwürfe. Ein Konflikt mit gesperrten Verträgen wird als konkrete Entscheidung vorgelegt und nicht still gelöst. Die Zielreihenfolge im Dummy ist noch kein genehmigter nativer Phasenvertrag.

## Freigegebene Bediengrundsätze

1. Fünf feste Arbeitsbereiche: **Medien, Produktion, Schnitt, Postproduction, Export**. Medien organisiert phasenübergreifend. Die anderen Bereiche haben jeweils passende Sidebars. Ein Workspace-Wechsel ist keine Phasenfreigabe und keine Datenmutation.
2. Durchgehende native Desktop-Flächen mit präzisen Trennlinien, kompakten Pane-Köpfen und großem Bildraum. Keine Website-Navigation, Dashboard-Kartenstapel, dekorativen Farbränder oder zusätzlichen globalen Toolbarzeilen.
3. In der Titelleiste: links Panel-Symbol und reiner Projektname, mittig Arbeitsbereiche, rechts nichtinteraktiver Formatstatus und Inspector-Symbol. Panel-Symbole schalten unabhängig nur die genannte Seite. Projektbefehle im nativen Menü; kein Projekt-Dropdown, keine Back-/Undo-Knöpfe. Undo/Redo bleiben Bearbeiten-Menü und Shortcuts; Settings App-Menü/⌘,.
4. Aktiver Pack-Akzent zeigt sich an Auswahl, aktiver Phase/Workspace und Primäraktionen sowie zurückhaltend in der Titelleiste. Formatname ist ungerahmter Status, kein scheinbarer Button. Standard verwendet keine erfundene Packfarbe.
5. AppTheme trägt alle Maße/Farben/Typografie/Zustände. Schrift nicht verkleinern, um fehlerhaftes Layout zu kaschieren. Felder und Checkboxen teilen Ausrichtungsachsen; Bildlabels und Aktionen brauchen reale Abstände. Disabled ist unmissverständlich. Toolbar-Symbole haben verständliche Accessibility-Namen/Tooltips; unklare fachliche Entscheidungen brauchen lesbare Texte.
6. Kontextmenüs, Tastatur, Mehrfachauswahl, Drag/Drop, Undo und Responder-Semantik sind erstklassig. Häufige Shotaktionen gehören nicht versteckt in einen Inspector-Aufklappblock.
7. KI ist App-Engine: strukturierte Aufträge, konkrete Empfehlungen, Vorschlagsvergleich und ausdrückliche Entscheidungen. Freier Chat ist kein alternativer Weg um Gates. Prosa nur für echte kreative Textarbeit. Der Host validiert Schemata, Pflichtfelder, Kosten, Phasenrechte und Quellen; die KI liefert Urteile/Inhalte, nicht unkontrollierte UI oder Regeln.
8. Budget dauerhaft in Statusleiste mit Details. Unten rechts getrennte KI- und Exportindikatoren mit nichtmodalen Jobdetails. Tatsächliche Fortschritte und Routenfähigkeiten; keine erfundenen Prozentwerte, Pausen oder kostenfreien Retries.

## Schnitt: zuletzt freigegebener Auswahlvertrag

Es gibt **keinen Timeline/Quelle-Umschalter und keine sichtbaren Quell-Tabs**. Der Viewer-Kopf ist beschreibend, keine Navigation.

| Handlung | Viewer / Inspector | Bleibt unverändert |
|---|---|---|
| Originalmedium im Quellen-Picker wählen | Medienvorschau; Originalmedium mit Quellbereich und Insert/Overwrite bei geeigneter Quelle | Timeline-Zeit/Clips, Quellenfilter/Scrollposition |
| Timeline-Clip wählen | Filmvorschau; Timeline-Clip mit Instanzwerkzeugen | Gemerkte Quellauswahl, Quell-In/Out und Quellposition |
| Quellen suchen/filtern/sortieren | Nur Trefferliste ändert sich | Aktives Vorschau-/Inspector-Objekt und Timeline |
| Kontextmenü auf gemerktem Objekt öffnen | Genau dieses Objekt wird aktiver Handlungskontext | Andere Daten und fremde Parameter |
| Workspace wechseln/zurückkehren | Gespeicherter Arbeitszustand des Bereichs | Kanonische Projekt-/Pipelinedaten |

Nur aktive Auswahl trägt Packfarbe; gemerkte Auswahl anderer Bereiche ist neutral. Native `InspectedObject`, Auswahlsets, `PreviewTab`-Medienidentitäten und VideoEngine bleiben die Grundlage. Sichtbare alte Navigation wird ersetzt, ihre nützlichen Fähigkeiten (Quellpositionen/mehrere Quellen/Keyboard) bleiben über direkte Objektauswahl und passende native Menübefehle erhalten. Clip-Overlays, Titel und Transform wirken nicht auf Originalvorschau; Frame-Capture nimmt die tatsächliche Quelle und Zeit. Gesperrte Clips sperren keine fremden Quellfelder.

## Fachliche Grenzen der Produktionsflächen

| Bereich | Aufgabe / tatsächliches Ergebnis |
|---|---|
| Briefing | Absicht und Rahmen. Greenfield hat noch keine Storybilder. |
| Gestaltung / Treatment / Skript | Stilregeln, dann Handlung/Kausalität, dann Szenenhandlung. Kein vorgezogenes Storyboard; Skriptvertrag ist noch zu entscheiden. |
| Storyboard | Erzählerische Shotfolge mit günstigen Sketches, Uploads oder passenden Clay-Snapshots. Mehrere Momente je Shot, keine zusätzlichen Cuts. |
| Animatic | Geplantes Timing und Schnitte aus derselben Shotdauer. Transport ausschließlich im aktiven Animatic-Tab; Verlassen stoppt Playback. |
| Shotplanung | Technische Produktionsentscheidungen für dieselben IDs/Dauern. Ziel: Timing im Storyboard bearbeiten, hier lesen; keine zweite unabhängige Dauer. |
| Optionales Blocking | Wiederverwendete Clay-Location, Geometrie, Positionen, Sichtachsen und shotbezogene Kameras/Bahnen. Tags/nachts/lookabhängige Varianten über andere Referenzen und Prompt; nicht geometrisch kopieren. |
| References | Gerenderte Identitäts-/Location-/Prop-/Lookreferenzen und Shot-Anker. Sketch bleibt Sketch; Bildrollen und echte Provenienz nicht umetikettieren. |
| Render-Review | Tatsächliche aktuelle Text-/Bildinputs und Zustandsfolgen vor teuerem Video. Weltchronologie, nicht Filmreihenfolge. |
| Video-Takes | Ausgewählte Inputs generieren, konkrete Ergebnisse sichten, ganze Takes/verifizierte Bereiche wählen. Draft und Produktion getrennt. |
| Schnitt | Reihenfolge/Timing/Trims von Timeline-Instanzen, echte Mehrspur-Timeline. Keine Mutation genehmigter Produktionsplanung durch Cliptrim. |
| Postproduction | Vorhandene Bild/Farbe/Effekte/Audio/Titel/Captions/KI-Werkzeuge und Film-/Übergangsreview auf derselben Sequenz. |
| Export | Gebundener Filmstand, Ausgabeinstellungen, Aufträge/Verlauf, technische Dateiprüfung. Generisches optionales Vorschaubild; zusätzlich Musicvideo-Album-Cover. |

Der generische Workflow funktioniert vollständig ohne Pack, ohne KI-Generierung und ohne externen Import. Musicvideo ergänzt Audioanalyse, Song-/Beatbezug und passende Utilities. FilmFlow liefert optional angenommene Vorarbeit als Snapshot und Abkürzung, keine zweite dauerhafte Wahrheit. Kein Nachbau eines vollständigen externen Drehbuchsystems.

## Was heute schon besteht und was gesonderte Vertragsarbeit braucht

**Vorhandene Grundlagen:** wiederverwendete NSHosting-/NSSplitView-Panels, `WorkspaceFocus`, `InspectedObject`, AppTheme/PackAccent; MediaTab/Ordner/Suche/Relink; GenerationView samt echten Eingabeslots; native Mehrspur-Timeline und Inspector einschließlich Kurven/LUT/Keyframes/Audio/Text/Captions/AI-Edit; strukturierte AgentDialog-/Gate-/Spend-/Batch-Karten; Audio-Pack-Surfaces; Pipeline-/Take-/SequenceReview- und Exportdienste.

**Keine bloßen Layoutänderungen:** eigenständiges Skript, Storyboard-Timing/Sketch-Momente, Entwurfsplanung vor vorhandenen Referenzen, finaler revisionsgebundener Bild/Text-Review, Clay-Provenienz und FilmFlow-Adoption. Diese brauchen konkrete genehmigte additive Verträge und danach deren Implementierung. `Step` hat heute keine Dauer oder Sketch-Sequenz. `SpatialProductionPlan` ist kein fertiger Storyboard-Momentvertrag. `ExportCoordinator` ist derzeit ein Aktivitätsguard, keine vollständige Queue.

Bis zur genehmigten Migration bleibt nativ:

`project_init → analysis → brief → production_design → treatment → storyboard → bible → shotlist → sanity → frames → render`

Bible und Frames sind eigene Artefakte und Gates. Gemeinsame Presenter dürfen sie nicht zu einer erfundenen Freigabe verschmelzen. Sanity liegt vor Frames und prüft damit nicht automatisch spätere Bilder. Der Zielablauf ist erst nach genehmigter vollständiger Migration erfüllt; eine nur umbenannte alte Pipeline ist keine Endabnahme.

**Unverändert verbindlich:** Musicvideo-Start Track → optionale Lyrics → Init → genehmigte Analyse → optionale Vorarbeit → Story; aktuelle Phase allein ausführbar/freigebbar; explizites Rewind, exakte Lineage/Quellenbindung; ein Phase-Job trotz Reconnect; Pack-Pinning/Fail-closed/Recovery/ABI; Prompt-Compiler und providerneutraler ausführbarer Katalog. Die gesperrten Specs aus AGENTS.md bleiben maßgeblich.

## Bestehende Arbeit und Upstream

| Arbeit | Wiederverwenden / Grenze |
|---|---|
| #462 | Appweiter Designauftrag; dieses Paket operationalisiert den später freigegebenen Workbench-Entwurf. |
| #506, #507, #508 | Bestehende UI-Issues werden präzisiert, nicht dupliziert. Frühere drei Workspaces und Verbot kleiner Panel-Icons sind überholt. |
| #476 | Budget dauerhaft unten + Detailansicht ersetzt alten Cockpit-Tab-Auftrag. |
| #509, #510–#528 | Bestehende Upstream-Pakete bleiben ihre eigenen Implementierungsaufträge. UI erschließt aktuelle Funktionen und später gelieferte Erweiterungen; kein pauschaler Cherry-pick. |
| #533 | Engine-/Reviewvertrag für Shotzustände/Weltchronologie/Text-Bild-Continuity. Eigener neuer UI-Consumer schließt daran an. |
| #540–#546 | Echte optionale bpy-/Clay-Fähigkeit, unveränderte Zuständigkeit. Gemeinsame Auswahl-/Writer-/Inspectorverträge; keine zweite 3D-Engine. |
| #548 / #547 | Wissensimport vs Runtime-Migration unterscheiden. Prompttechniken, Draft/Rescue/Iteration nach tatsächlichem Vertrag, nicht Dummy-Konstanten. |
| PR #549 | Higgsfield REST neben MCP. Keine parallele Providerimplementierung; Auth, Katalog, Slots, Kosten, Cancellation und Submission-Recovery aus tatsächlicher Route. |
| #217 | Bestehenden optionalen Musicvideo-Cover-Starter/Utility aus `phases/cover.md` erschließen und verbleibende Lücken nachweisen. Kein behaupteter neuer lokaler Schrift-Renderer. |
| #528 | Export-Queue separat; UI-Hintergrundanzeige allein erzeugt keine Queue. |
| #529–#532 | Preis-/Batch-/Revision-/Resume-Regressionen in passenden Abnahmeszenarien, kein Ersatz der Bugfix-Aufträge. |

Die folgenden Upstream-Commits wurden am 20.09.2026 über GitHub erneut verifiziert: [89ce887e](https://github.com/palmier-io/palmier-pro/commit/89ce887e) Chrome, [6f4d1643](https://github.com/palmier-io/palmier-pro/commit/6f4d1643) Flächen, [cfe9c18f](https://github.com/palmier-io/palmier-pro/commit/cfe9c18f) Inspector-Komponenten, [3026f72e](https://github.com/palmier-io/palmier-pro/commit/3026f72e) Ausrichtungsachsen, [6aafb867](https://github.com/palmier-io/palmier-pro/commit/6aafb867) Medien-Inspector und [49841f35](https://github.com/palmier-io/palmier-pro/commit/49841f35) Modell/Kosten. Nur passende Muster adaptieren; keine Palmier-Accounts/Credits/fal-only-Annahmen oder öffentliche Pack-Layoutänderungen.

## Arbeitsauftrag für GPT-5.6 Sol pro Issue

1. Aktuellen main/PR-Stand und tatsächliche Abhängigkeiten lesen. Ein abgeschlossenes Mockup oder genehmigtes Konzept ist kein Beleg für bereits implementierte Services.
2. Verlinkte native Dateien und verwendete Mutationen lesen. Je Issue einen zusammenhängenden, reviewbaren PR; keine opportunistischen Provider-/Harness-/Storage-Rewrites.
3. Betroffene Inventar-IDs zuordnen. Vor Entfernen eines alten Einstiegs dessen vollständig funktionierenden Ersatz belegen.
4. Datenlogik und UI-Komposition trennen, vorhandene native Komponenten wiederverwenden. Stabile IDs statt Arrayindices; kein JavaScript-Dummystate als Engine.
5. Gemeinsame Datei-Ownership abstimmen: Editor/Shell vor Kontext/Workspace-Presentern; Inspector-Komponenten vor Pane-Umstellungen; PR #549 besitzt Provider-/Routing-Code; #540 besitzt Clay; #547 besitzt Wissens-Runtime. Keine konkurrierenden Vollersetzungen.
6. Gesperrte Vertragsänderung: erst genauen Entwurf und Entscheidung, dann Implementierungsissue. Sol darf ein blockiertes Ticket nicht durch erdachte Modellfelder oder Gate-Ausnahmen fertigmelden.
7. Sinnvolle semantische Regressiontests ergänzen, native Verifikation ausschließlich GitHub Actions. `xcode-27` für Build/Unit/Bundle; passende aktuelle Runtime bei benötigten macOS-APIs. Keine lokalen Builds/Tests/App-Starts und kein Devserver.
8. UI vor Vorstellung visuell und interaktiv prüfen. PR beschreibt tatsächliche Verifikation und Grenzen; Mockup-Tests sind keine native Evidenz. Keine kostenpflichtige Probe ohne eigene Autorisierung.
9. Ein abgestimmter Release-Batch. Kein Merge/Release ohne ausdrückliches „build now“; ein Ticket/PR-Abschluss genehmigt dies nicht.

## Funktions- und UX-Abnahme

Für jeden umgebauten Einstieg sind Bestand, neue Aktion, Objekt, Handler, Wirkung, Undo/Revision/Persistenz/Kostenfolgen sowie Fehler-/Abbruchzustände mit Evidenz zu erfassen. Neues Feature ersetzt keinen verlorenen alten Arbeitsweg.

Pflichtfälle: generischer Import→Schnitt→Post→Export; Musicvideo-Greenfield; genehmigte Phase revidieren ohne bezahlte Dateien zu verlieren; mixed source modes; realer Take-/Range-Review; optionales Blocking für mehrere Shots; externe Vorarbeit; bestehendes Projekt mit Effekten/Keyframes/Text/Audio; Offline/Relink; Multi-Selection/Locks; falsche Pack-Version; Reconnect/Teilabbruch; veraltete Referenzen/Sequenzreviews; Video-/Sidecar-Schreibfehler.

Der eingefrorene Mockupstand wurde zuletzt im Schnitt auf 25 verknüpfte Auswahl-/Vorschauabläufe und 56 Kontextmenü-/Lock-Regressionschecks geprüft; die beigelegten Screenshots dokumentieren diesen Stand. Dies ist kein neuer Fable-Review und keine native Vollabnahme. Alle nativen Arbeitswege müssen im abschließenden Paritätsissue erneut geprüft werden.
