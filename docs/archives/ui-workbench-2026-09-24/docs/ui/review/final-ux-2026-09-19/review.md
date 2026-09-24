# Abschließender kritischer UI-/UX-Review · 19.09.2026

**Urteil: Der Clickdummy ist als vollständige Implementierungsvorlage noch nicht freigabereif.** Die Desktop-Grundstruktur trägt. Zwischen Shotplanung, Blocking, References, Render-Review und Take-Auswahl bestehen jedoch reproduzierbare Zustandsfehler und wesentliche Bedienlücken. Weitere kosmetische Korrekturen lösen diese Probleme nicht.

Eigenreview plus unabhängiger Review durch **Claude Fable 5.1, Effort high**, aufgerufen über `claude-high5`. Der externe Review hat erfolgreich abgeschlossen, ohne Berechtigungsablehnungen. Fable prüfte den Quellcode; seine Aussagen zum Laufzeitverhalten wurden anschließend hier überprüft. Sein pauschales Teilurteil „Medien freigeben“ übernehmen wir nicht: Revisionsfehler wirken bis in die Medienbibliothek hinein.

Dieser Review verändert weder den Clickdummy noch die native App. Er ersetzt frühere pauschale Aussagen zur UX-Reife des hier geprüften Standes. Bestandene Verhaltenstests bleiben nützlich, sind aber keine UX-Abnahme.

## Prüfgrundlage und Grenzen

- 18 Bildschirmzustände erfasst: Medien, Audioanalyse, leeres und gefülltes Briefing, Treatment, Skript, Storyboard, Animatic, Shotplanung, Blocking/Raum, Blocking/Kamera, References, Render-Review, Takes, Schnitt, Postproduction, Export und manuelle Generierung.
- Kernflächen visuell geprüft; zwölf zusätzliche Browser-Szenarien für Abbruch, Revision, Zuordnung, Pflichtprüfungen, Bearbeitbarkeit und größere Projekte ausgeführt. Nur statisches HTML über `file://`, kein nativer Build und kein Entwicklungsserver.
- Das große Blocking-Projekt enthält 96 künstlich vervielfältigte Shots. Es prüft die Platzverteilung, nicht semantische Korrektheit einer solchen Produktion.
- Simulierte Renderings, fehlende echte Provider-Aufträge und Demo-Preise sind für sich keine Fehler eines Clickdummys. Fehlende Bedienmöglichkeiten, widersprüchliche Zustände und irreführende Bestätigungen sind dagegen relevant, weil genau sie zur Implementierungsvorlage werden sollen.
- Kein erneuter vollständiger nativer Funktionsparitätsnachweis und keine macOS-/VoiceOver-Abnahme. Native Audioanalyse wurde gezielt zum Abgleich herangezogen. Ein solcher Review kann keine „vollständige Apple-HIG-Konformität“ bescheinigen.
- Geprüfte Dateien sind mit SHA-256 in `reviewed-files.json` festgehalten. Parallel laufende native Higgsfield-Arbeit wurde nicht verändert. PR #548 und Epic #540 bleiben Integrationskontext; ihre Erwähnung ist kein Nachweis, dass alle im Dummy gezeigten Abläufe bereits nativ existieren.

## 1. P1 · Abbrechen verwirft den sichtbaren Ankerstand

**Befund:** „Shot-Anker erneuern…“ setzt bereits beim Öffnen des Kostendialogs `anchors=false`, `anchorCount=0` und leert die Sichtungen. „Schließen“ stellt diesen Stand nicht wieder her. Die bestehenden Anker verschwinden auch aus der vom Zustand abgeleiteten Medienansicht. Es werden keine echten Dateien gelöscht; der Fehler betrifft den Projektzustand der Simulation.

**Nachweis:** References → Blocking revidieren → Blocking verwenden, Vorlagen ableiten und sichten → freigeben → Anker erneuern → Kostendialog schließen. Vorher sechs Anker, danach null sichtbare Anker bei unveränderten Kosten. Quelle: `desktop-production-workbench.clay.js:90`; Browserprobe `cancel-renewal`.

**Folge:** Ein Abbruch ist nicht folgenlos. Auch ein nicht bezahlbarer Auftrag kann die vorhandene Arbeit aus der aktiven Ansicht entfernen.

**Erforderlich:** Auftrag zunächst nur vorbereiten. Bisherige Anker bis zum erfolgreichen, ausdrücklich übernommenen Ersatz erhalten; einen überholten Stand kennzeichnen. Abbrechen muss den Ausgangsstand bewahren. Erst Kostenfreigabe startet den Auftrag, erst eine erfolgreiche Übernahme ersetzt die aktive Variante.

## 2. P1 · Revisionen entwerten pauschal Material und erzeugen falschen Renderbedarf

**Befund A:** Selbst Blocking ohne Geometrieänderung erneut zu überspringen setzt vorhandene Anker auf veraltet. Das Gate verlangt „Shot-Anker nach Blocking-Änderung erneuern“, obwohl keine Location existiert und keine solche Änderung stattfand. Auch eine Korrektur der Shotplanung reaktiviert die bereits abgeschlossene Skip-Entscheidung.

**Befund B:** Eine Planrevision leert sämtliche aktiven Takes und Auswahlen. Im geprüften Projekt wechseln zwölf Takes und sechs Auswahlen auf null; die zwölf früheren Takes bleiben nur in einer nicht auswählbaren Historie. In der Medienbibliothek fehlen sie anschließend. Das ist nicht dasselbe wie Freigaben deterministisch zurückzusetzen.

**Nachweis:** `desktop-production-workbench.clay.js:67`, `desktop-production-workbench.js:55`, `:168`, `desktop-production-workbench.media.js:17`. Browserproben `unchanged-skip` und `rewind-take-retention`.

**Erforderlich:** Drei Dinge getrennt darstellen: vorhandenes Medium, Gültigkeit für die aktuellen Eingaben, aktuelle Freigabe. Projektmedien bleiben erhalten. Vor Revision die betroffenen Shots, Gründe und erwarteten Folgeaufträge zeigen. Skip bleibt erhalten, solange seine Voraussetzungen unverändert sind. Eine technische Wiederverwendung braucht einen überprüfbaren Nachweis der passenden Eingaben; sie darf nicht bloß durch UI-Klick behauptet werden.

**Vertragsgrenze:** Das native Harness verlangt kumulative exakte Herkunftsnachweise und erneute Freigaben nach Rewind. Dieser Review autorisiert keine Lockerung dieses gesperrten Vertrags. Shotgenaue Wiederverwendung ist gegen ihn zu spezifizieren; falls dafür eine Vertragsänderung nötig ist, muss sie ausdrücklich entschieden werden. Medienbewahrung darf schon vorher nicht mit Freigabegültigkeit verwechselt werden.

## 3. P1 · Render-Review zeigt Befund und Bildpaar unterschiedlicher Shots

**Befund:** Nach Auswahl von 1A zeigen Viewer und Inspector 1B → 1A, während darunter weiterhin „Befund 1D → 1E“ samt Korrekturaktion steht. Diese korrigiert 1E. Der Befund ist global, seine optische Platzierung suggeriert aber einen Befund zu den gerade gezeigten Bildern.

**Nachweis:** Fixture Review → 1A wählen. `desktop-production-workbench.js:161–162`, `:193`, `:305`; Browserprobe `review-selection`.

**Erforderlich:** Die Auswahl eines Befunds muss dessen konkrete Shots, Zustände, Bildquellen und Korrektur gemeinsam aktivieren. Ein globaler Hinweis braucht einen eindeutig getrennten „Befund zeigen“-Weg. „Nicht geprüft“, „bestanden“ und „Befund“ müssen unterscheidbar bleiben. Ein Wechsel der Ansicht darf die chronologische Prüfreihenfolge der Story-Welt nicht verändern.

## 4. P1 · Der Filmer kann die Shotstruktur nicht bearbeiten

**Befund:** Nach der Erzeugung kann man Handlung, Dauer und Sketch-Momente ändern, aber keinen Shot einfügen, löschen, teilen oder umordnen. Es gibt auch keinen alternativen Menü- oder Tastaturweg. Mehrere Sketches innerhalb eines Shots ersetzen diese Operationen nicht.

**Nachweis:** Storyboard-Toolbar, Inspector, Kontextmenü und Tastaturhandler geprüft; keine passenden Aktionen. Der alte Drag-Pfad betrifft `data-edit-shot`, nicht die Storyboard-Struktur. `desktop-production-workbench.js:186–188`, `:232`, `:340–343`; Browserprobe `storyboard-editability`.

**Erforderlich:** Diese vier Operationen direkt am Storyboard mit stabilen Shot-IDs und Undo vorsehen. Das Animatic nutzt dieselbe Struktur und dieselben Dauern. Neue technische Planung und spätere Freigaben folgen nachvollziehbar daraus. Sonst bleibt die zentrale kreative Entscheidung faktisch der KI-Aufteilung überlassen.

## 5. P2 · Gemeinsame Location und shotbezogene Figurenposition sind nicht getrennt

**Befund:** Alle Objektpositionen, auch Maus und Katze, liegen ausschließlich an der gemeinsamen Location. Shotbezogen sind nur Kamera und deren Bewegung vorhanden. Versetzt man die Maus für 1E, steht sie auch in 1A dort. Eine getrennte Positionierung wäre derzeit nur über eine unverbundene Location-Kopie möglich; die Kopieraktion hängt den aktuellen Shot zudem sofort um.

**Nachweis:** `desktop-production-workbench.clay.js:24`, `:84`, `:96`; Browserprobe `shared-actor-position`.

**Erforderlich:** Gemeinsame räumliche Grundlage und Inszenierung eines konkreten Shots unterscheiden. Architektur, feste Props und räumliche Beziehungen gehören zur Location; Figurenpositionen und ausdrücklich bewegliche Props brauchen shotbezogene Zustände und bei Bedarf Bewegungsverläufe. Die UI muss anzeigen, ob eine Änderung einen oder mehrere Shots betrifft. Die genaue Speicherung ist noch zu spezifizieren.

**Unveränderte Vorgabe:** Clay bleibt Geometrie. Tageszeit, Licht, Oberflächen, Identität und visuelle Zustandsvarianten kommen über die übrigen Anker und den Prompt. Dafür keine neue Location-Kopie erzwingen. Blocking bleibt optional und für einzelne oder mehrere Shots nutzbar.

## 6. P2 · Blocking sieht räumlich aus, wird aber wie ein Zahlenformular bedient

**Befund:** In der Bühne lässt sich die freie Ansicht drehen und zoomen. Objekte und Kamera werden jedoch ausschließlich über Listenwahl und Zahlenfelder positioniert. Es fehlen direkte Auswahl in der Szene, Ziehen von Objekt/Kamera/Blickziel und eine hilfreiche Draufsicht. Die Kameravorschau zeigt keinen Vergleich mit dem freigegebenen Sketch.

**Nachweis:** `desktop-production-workbench.clay.js:44–45`, `:99–100`; visuell `blocking-space.png` und `blocking-camera.png`.

**Erforderlich:** Begrenzte direkte Manipulation im Raum, mit Zahlen als Feineinstellung. Sketch bei Bedarf als Vergleich oder Overlay. Kein vollständiger Blender-Ersatz: Auswahl, Platzierung, Blickrichtung und Start-/Endposition einer Bewegung reichen als Kern. Diese Bedienung sollte bereits der Clickdummy erklären und simulieren, auch ohne echtes bpy-Backend.

## 7. P2 · Referenzprüfung zeigt die verbindliche Clay-Vorlage nicht im geeigneten Vergleich

**Befund:** Der große Vergleich kann Sketch und Anker gegenüberstellen. Die Clay-Quelle bleibt ein kleines Inspector-Bild. Damit ist die ausdrücklich verbindliche Positionierungsvorlage ausgerechnet dort schwer prüfbar, wo ihre Einhaltung bestätigt werden soll. Für Shot-Anker fehlt außerdem ein gemeinsamer Kontaktbogen mit Sichtungsstatus.

**Nachweis:** `desktop-production-workbench.js:126`, `:152`; `desktop-production-workbench.clay.js:29`, `:54`; Browserprobe `reference-clay-compare` und References-Screenshot.

**Erforderlich:** Die tatsächlichen Eingaben eines Shots im selben Viewer vergleichen können: Sketch für Intention, Clay für räumliche Bindung, gerenderter Anker für das konkrete Bild. Nur vorhandene Quellen anbieten. Kontaktbogen für Übersicht und gezielte Mehrfachsichtung ergänzen. Die bestehenden Unterschiede zwischen Sketch, Clay und Rendering dabei ausdrücklich erhalten.

## 8. P2 · Prüfungen werden zur Checkbox-Arbeit statt zur Entlastung durch KI

**Befund A:** Einen Take auszuwählen erfordert sechs manuelle Bestätigungen. Selbst „Ablehnen“ verlangt alle sechs Häkchen und einen Text. Bei 60 Shots sind allein für je eine Prüfung 360 Checkbox-Klicks nötig. Ein offensichtlicher Fehler kann nicht sofort zur Ablehnung führen.

**Befund B:** „Befunde & Evidenz“ zeigt drei bereits ausgewählte, aber vom Nutzer veränderbare Checkboxen. „Vorschlag prüfen“ und „Übernehmen“ schreiben einen Verlaufseintrag; `reviewRun`, `reviewFixed` und `reviewVersion` bleiben unverändert. Das ist eine irreführende Ergebnisinteraktion, nicht lediglich ein fehlendes echtes KI-Backend. Ähnliche generische Aufträge dienen weiteren bloßen Informationsanzeigen.

**Nachweis:** `desktop-production-workbench.studio.js:93–95`, `:135`, `:202`, `:209`, `:213–230`; Browserproben `take-manual-checks` und `evidence-user-attestation`.

**Erforderlich:** Maschinenbefunde als Ergebnisse darstellen, mit Beleg und Stand. KI prüft vor, der Nutzer entscheidet über relevante Befunde und kreative Abweichungen. Take-Auswahl, Prüfung und Freigabe sind unterscheidbare Vorgänge. Ablehnen muss sofort möglich sein. Der Nutzer darf einen maschinellen Befund nicht durch Abwählen eines Häkchens in ein positives Ergebnis verwandeln. Renderbarkeit, Text/Bild-Konsistenz und Continuity benötigen erkennbare, zusammenhängende Prüfresultate.

## 9. P2 · Die Shotnavigation skaliert nicht auf größere Projekte

**Befund:** Bei 96 Shots wächst die Blocking-Shotwahl auf 461 Pixel Höhe. Die eigentliche Bühne wird innerhalb der Arbeitsfläche abgeschnitten; ein äußerer Overflow-Test meldet trotzdem keinen Fehler. Animatic- und Chronologie-Leisten komprimieren ihre Shots ohne ausreichenden Mindestplatz. Einzelbestätigungen für jede räumliche Vorlage und jeden Anker vervielfachen die Arbeit zusätzlich.

**Nachweis:** `desktop-production-workbench.clay.css:9–10`, `desktop-production-workbench.clay.js:34`; `.sequence-lane` und `.chronology` im zentralen CSS; Browserprobe und Screenshot `blocking-96-shots`.

**Erforderlich:** Shotnavigation räumlich begrenzen, nach Szene/Location gruppieren und scrollbar bzw. zoombar halten. Aktuelle Auswahl sichtbar halten. Mehrfachauswahl für gleichartige Sichtungen, ohne Einzelbefunde zu verbergen. Blocking-Zuordnung soll den tatsächlich benötigten Shots folgen; ein einmaliges Aktivieren darf nicht ungefragt das gesamte Projekt zur Pflichtsichtung machen.

## 10. P2 · Audioanalyse und Musicvideo-Animatic bleiben voneinander getrennt

**Befund:** Die Analyse zeigt musikalische Abschnitte und Beat-Raster, bietet aber kein geeignetes Abhören und Loopen des ausgewählten Abschnitts. Das Musicvideo-Animatic zeigt nur die Shotzeiten: keine Song-Lane, Abschnittsgrenzen oder Beat-Orientierung. Im Beispiel stehen 20 Sekunden Shots einem analysierten Track von 199 Sekunden gegenüber, ohne eine sichtbare Zuordnung als Ausschnitt. Unterschiedliche Demo-Längen allein sind kein Fehler; die fehlende Mapping-Interaktion ist es.

**Nachweis:** `desktop-production-workbench.js:154–160`, `:173`; Browserprobe `animatic-song-timing`, Screenshots Audio und Animatic. Die vorhandene native `AnalysisPanelView.swift` / `PackSurfacePrimitives.swift` wurde dagegen gelesen: Wir behaupten ausdrücklich nicht, dass dort bereits ein vollwertiger Analyse-Transport existiert und entfernt wurde.

**Erforderlich:** Abschnitt wählen, hören, loopen und zeitlich verorten. Im Musicvideo-Pack ergänzen Songabschnitte und Beats das generische Animatic; passende Schnittpunkte lassen sich daran ausrichten. Timing bleibt ein gemeinsamer Datenbestand, nicht eine zweite Shotdauer im Pack. Das ist eine notwendige Weiterentwicklung des Konzepts, kein belegter Funktionsabbau gegenüber dem nativen Analysepanel.

## 11. P2 · Briefing wird als fertig gezeigt, während Gestaltung noch aussteht

**Befund:** Ein leeres generisches Projekt erreicht nach Freigabe des Briefings die gesondert freizugebende Phase „Gestaltung“. In der Sidebar steht Briefing bereits mit Haken, eine passende Gestaltung-Zeile fehlt. Erst Toolbar und Gate zeigen den tatsächlichen Arbeitsschritt.

**Nachweis:** `desktop-production-workbench.js` Phasenordnung und Navigation; Browserprobe `hidden-design-phase`.

**Erforderlich:** Entweder Gestaltung als sichtbaren Unterpunkt von Briefing inklusive korrektem Gesamtstatus behandeln oder als eigene Phase führen. Kein zusätzlicher Web-Wizard nötig; die bestehende kompakte Sidebar muss den tatsächlichen Zustand wiedergeben. Zuordnung zur nativen Production-Design-Phase ausdrücklich dokumentieren.

## 12. P2 · Die teuerste Kostenfreigabe ist weniger konkret als die manuelle Generierung

**Befund:** Der Videobatch zeigt Anzahl und Beispielsumme, aber keine unmittelbar prüfbare Zusammenstellung aus Modell/Provider, Dauer und Eingaben pro Shot. Die Simulation rechnet pauschal je Shot. Demo-Preise sind zulässig; die reduzierte Entscheidungsgrundlage sollte nicht in die native Implementierung übernommen werden.

**Nachweis:** `desktop-production-workbench.studio.js:95`, `:294`; `desktop-production-workbench.js:194`, `:239`. Vergleich: die manuelle Generierungsfläche besitzt Anbieter, Modell und Dauer.

**Erforderlich:** Kompakte Summenzeile, bei Bedarf aufklappbare Shotdetails: ausführbare Route, Dauer, konkrete Quellen, Kosten und Wiederholungsumfang. Nur verfügbare Provider-/Modellfähigkeiten zeigen. Eine Hintergrundanzeige ersetzt diese Freigabe nicht. Den parallelen Higgsfield-Client erst an dessen geprüften Fähigkeiten anbinden.

## 13. P3 · Wording und visuelle Priorität weiter vereinheitlichen

**Befund:** „Core“, „Creative Brief“, „PRODUCTION DESIGN“, „Produktionsplan · derselbe Shot“ und mehrere erklärende Nachsätze sprechen teils die Entwickler des Konzepts statt den Filmer an. Die zwei Ebenen aus Phasenstatus und globalem Status sind grundsätzlich sinnvoll, wiederholen aber gelegentlich Kontext. In der Blocking-Kamera wird etwa die Optik mehrzeilig im schmalen Inspector ausgegeben.

**Erforderlich:** Kurze Bezeichnungen für Objekt, Zustand und Handlung; konzeptionelle Erklärungen in Hilfen. „References“ bleibt als vereinbarter Begriff bestehen. In den erfassten Standardscreens wurde kein neuer flächendeckender Ausrichtungsfehler belegt; deshalb nicht erneut pauschal alle Abstände umbauen. Die belegte Platzverschwendung betrifft besonders die skalierende Shotleiste und den formularlastigen Arbeitsablauf.

## Was erhalten bleiben sollte

- Die fünf Arbeitsräume Medien, Produktion, Schnitt, Postproduction und Export; kontextbezogene Sidebars und ein stabiler Inspector.
- Eigener Medienbereich mit Ordnern, Suche, Vorschau und manueller Generierung; kompakte Picker im jeweiligen Arbeitskontext.
- Klare Trennung von Textentwicklung, Storyboard-Sketches, technischem Shotplan, Clay-Geometrie und gerenderten References. Keine vorgezogenen Filmillustrationen im leeren Briefing.
- Mehrere Sketch-Momente innerhalb eines Shots; Animatic-Transport ausschließlich im Animatic.
- Sichtbare Pack-Akzente ohne farbige Rahmen um jede Komponente; Formatkennzeichnung als Status.
- Getrennte Hintergrundanzeigen für KI und Export sowie die getrennten Projektphasen Postproduction und Export.
- Album-Cover als Musicvideo-Ergänzung und generisches Export-Vorschaubild.

Diese Punkte sind eine brauchbare Grundlage, keine Einzelabnahme aller darunterliegenden Funktionen.

## Abgleich mit den Desktop-Vorbildern

- **Final Cut Pro:** Eigene ein-/ausblendbare Bereiche und verstellbare Grenzen stützen die vorhandene Desktop-Hülle. Die verbleibenden Probleme liegen vor allem in den Aktionen innerhalb dieser Bereiche. [Apple: Fenster anordnen](https://support.apple.com/en-ca/guide/final-cut-pro/ver2a27194eb/mac).
- **DaVinci Resolve:** Direkte Bearbeitung im Viewer und ergänzende präzise Inspector-Eingaben bilden ein passendes Vorbild für das Verhältnis zwischen Blocking-Bühne und Zahlenfeldern. Daraus folgt keine Forderung, einen vollständigen 3D-Editor nachzubauen. [Blackmagic: Edit](https://www.blackmagicdesign.com/products/davinciresolve/edit).
- **LTX Desktop:** Generierung und Timeline gehören in eine gemeinsame kreative Arbeitsumgebung. Der im offiziellen Projekt dokumentierte kontextuelle Bezug etwa beim Ergänzen von Timeline-Lücken ist als Inspiration brauchbar. Daraus übernehmen wir weder ein Chat-Paradigma noch einen fremden Produktionsharness. [Lightricks: LTX Desktop](https://github.com/Lightricks/LTX-Desktop).

Die Empfehlungen sind unsere Designableitungen aus diesen Quellen und den geprüften NGV-Abläufen. Keine dieser Quellen begründet die hier gefundenen Checkbox-Pflichten, globalen Materialverluste oder falschen Bild-/Befund-Zuordnungen.

## Verifikation der zwölf Fable-Befunde

| Fable-Befund | Eigenprüfung | Einordnung hier |
|---|---|---|
| Anker vor Kostenfreigabe verworfen | Im Browser bestätigt | 1, P1 |
| Skip durch Plan-Rewind aufgehoben | Unverändert erneut überspringen im Browser geprüft; identischer Invalidierungspfad | 2, P1 |
| Alle Takes nach Revision nicht wieder verwendbar | 12 → 0 aktive Takes; Historie vollständig disabled; keine Takes in Medien | 2, P1; keine Behauptung echter Dateilöschung |
| Sechs Pflichtprüfungen auch zum Ablehnen | Dialog und Speicherbedingung bestätigt | 8, P2; hohe Relevanz, aber kein tatsächlicher Datenverlust |
| Numerisches Blocking ohne Sketch-Bezug | Screenshot und Pointer-/Inspector-Code geprüft | 6, P2 |
| Keine Figurenpositionen je Shot | Shared-Location-Probe und Modell geprüft | 5, P2; Zielinvariante klar, Datenvertrag noch offen |
| Skalierung und Einzelbestätigungen | 96-Shot-Probe bestätigt Bühnen-Clipping; weitere Leisten statisch geprüft | 9, P2 |
| Shotstruktur nicht bearbeitbar | Gesamte relevante UI, Kontextmenü, Keybindings und Aktionen geprüft | 4, P1 wegen zentraler kreativer Sackgasse |
| Musicvideo-Timing ohne Songbezug | Animatic-Probe und Analyseoberfläche geprüft | 10, P2; 20/199 s allein kein Defekt |
| Clay/Anker nicht groß vergleichbar | Vergleich mit aktivem Blocking durchgeklickt; Quellenwahl fehlt | 7, P2 |
| Evidenzdialog nur vorangekreuzter Auftrag | Übernehmen ändert keinen Reviewstatus; nur Verlauf | 8, P2 |
| Batchkosten ohne konkrete Route je Shot | Kosten-/Auftragsdarstellung gegen manuellen Generator geprüft | 12, P2 wegen Bedeutung der Freigabe |

Zusätzlich im Eigenreview: falsches Bildpaar am Befund (3), versteckte Gestaltung (11), Abhörbarkeit der Analyse (10), Wording (13). Fables Nebenbefund zum alten 2D-Blocking-Code ist eine Wartungsaufgabe, kein zusätzlicher belegter Nutzerfehler. Er darf bei Umsetzung nicht als paralleles Zielkonzept missverstanden werden.

## Reihenfolge der Nacharbeit

1. **Vertrauen und Zustand:** Abbrechen, Medienbewahrung, nachvollziehbare Revisionen und exakte Befundzuordnung korrigieren. Vorher keine vollständige native UI-Übernahme.
2. **Kreative Kontrolle:** Shotstruktur bearbeitbar machen; Shared Location und Shot-Inszenierung trennen; räumlich direkt arbeiten und Quellen vergleichen.
3. **KI-Entlastung:** Echte Befunde statt Checkbox-Aufträge; Take-Auswahl und Freigabe verständlich verbinden; Kosten konkret machen.
4. **Alltagstauglichkeit:** 60–100 Shots, Songbezug, sichtbare Unterphasen und kurze konsistente Begriffe prüfen.

Kein Rewrite der Desktop-Hülle. Die Arbeit betrifft gezielt den Produktionsablauf und seine Übergänge. Native Vertragsänderungen getrennt kennzeichnen und nicht als bloßes UI-Refactoring verstecken.

## Nachweise

- `fable-result.json`: unverändertes strukturiertes Ergebnis des unabhängigen Reviews.
- `surface-inventory.json` und 18 Oberflächen-Screenshots.
- `adversarial-probes.json`: sieben eigene Gegenproben.
- `fable-verification-probes.json`: fünf zusätzliche Prüfungen der externen Befunde.
- `probe-*.png`: zugehörige sichtbare Zustände.
- `reviewed-files.json`: Hashes des geprüften Clickdummy-Standes.
- Reproduktionsskripte unter `docs/ui/review-final-ux*.mjs`.
