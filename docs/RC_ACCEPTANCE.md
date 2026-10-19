# RC implementation and acceptance trace

Status: implementation in progress; no RC acceptance or new DMG.

The source candidate is version 1.8.0 with Music Video 0.6.0. This is a version
alignment for the pending batch, not a published release or acceptance result.
The native review-child owner fixture is prepared to produce, once executed,
separate API and CLI-protocol evidence for prepare, cancellation, explicit resume
and completion across 34 shots, including responsiveness during preparation and
execution. These fixtures use controlled transports; they do not prove live
provider or installed CLI execution. All new paths remain unexecuted.

The returned 1.7.2 delivery did not implement the complete approved desktop workflow. This trace covers the complete historical function inventory and the planned native surfaces. A checked-in control or a passing build is not evidence of an exercised user path.

## Source and scope

The approved [desktop implementation concept](https://github.com/iret77/nexgenvideo/blob/e3ea08de33ca7cf0b0d7fbe27dc96fb88561e84b/docs/ui/implementation/README.md) and [121-group inventory](https://github.com/iret77/nexgenvideo/blob/e3ea08de33ca7cf0b0d7fbe27dc96fb88561e84b/docs/ui/implementation/native-function-matrix.md) define the target. The source inventory is historical, so current code and real native interactions determine each result. VIEW-01 uses the later direct-selection contract: no source tabs or Timeline/Source switch; remembered source identity, position, In/Out and keyboard access remain.

No missing implementation is a concept defect. Any necessary concept correction is recorded with its conflicting source, concrete failure, minimal correction and consequences. NEW-02 requires an optional FilmFlow snapshot-import capability with explicit mapping and acceptance; optional use does not defer its implementation. Acceptance must verify its six read-only producer tools, explicit mapping and import path, and authenticated live import. NEW-04 is the separately proposed future automatic whole-film semantic adapter; neither entry may be claimed accepted without its actual contract and exercised working path.

## Existing evidence, limited to its actual scope

- [39085914949](https://github.com/iret77/nexgenvideo/actions/runs/39085914949), `0a510ea6`: workspace, cards, analysis, provenance, Musicvideo startup, host states and text Storyboard/Production/Activity passed at 100/125/150%. This does not prove Sketches, Animatic, or the complete production path.
- [39123913490](https://github.com/iret77/nexgenvideo/actions/runs/39123913490), `0b4a4e31`: targeted film review failed at native take text-field commit at all scales. The separate 50-item batch failed reaching the last request after resize. Neither failure has yet been demonstrated fixed.
- [39124049687](https://github.com/iret77/nexgenvideo/actions/runs/39124049687), `0b4a4e31`: build, tests, external pack load, signing, notarization and installed-DMG checks passed. These are packaging evidence, not full UI acceptance.

## Cross-cutting acceptance

Acceptance requires the complete Musicvideo path through the unchanged startup, creative planning, true visual Storyboard/Animatic, technical planning, References/Frames, current-input review, generation, real Take review, Cut, Postproduction and verified output. It also requires generic import/edit/export without a pack or generation. Required native evidence records the actual entry, selected object, mutation, persistence/Undo or revision, costs, failure/cancel path, screenshots and output files. Acceptance includes the smallest supported windows at 100/125/150% interface text size, keyboard/context menus, disabled states and source/timeline selection. Fixtures establish only the behavior they actually exercise; they do not establish live provider availability or creative quality.

An additional external XCTest journey launches the installed app without internal
acceptance flags. It exercises Home, interface text size, a new generic project,
file import, source insertion, timeline Split/Undo, save, close, reopen and export.
The prepared CI jobs reuse the existing app at 100/125/150%; a separate release
job installs the exact publication DMG and repeats this journey at 100%. Screenshots,
accessibility trees, input records, saved project snapshots and an independently
decoded exported movie are required with the XCTest result. The prepared workflow
is designed to resume a failed journey without rebuilding the app; that behavior
has not been verified. These paths have not run and establish no acceptance
yet. The current macrunner GUI image is macOS 27, so the macOS 26 runtime checks
remain required. This generic journey does not establish Musicvideo or live-provider
acceptance.

## Function trace

“Pending” below means no complete RC-specific proof has yet been attached for that group. It makes no claim about implementation being present or absent. Prior partial evidence above remains valid within its scope.

| Group | Function | Required owner-visible acceptance from the approved inventory | Current RC evidence |
|---|---|---|---|
| APP-01 | Projekt neu, öffnen, speichern, speichern unter | **Native Datei-Menüs und Startfenster**<br>Bestehendes Projekt öffnen, ändern, sichern und als Kopie sichern; Medienbindungen und Recovery erhalten. | Pending |
| APP-02 | Letzte Projekte, Finder, aus Liste entfernen, Projekt löschen | **Vorhandenes Startfenster**<br>Aus Liste entfernen löscht keine Projektdatei; Löschen bleibt ausdrücklich bestätigt. | Pending |
| APP-03 | Projektformat, Seitenverhältnis, Auflösung und FPS | **Projekteinstellungen; importbezogene Format-Rückfrage**<br>Hochkantprojekt und anderer FPS-Wert bleiben durch Viewer, Timeline und Export konsistent. | Pending |
| APP-04 | Workspace-Wechsel ohne Pipeline-Abschluss | **Medien/Produktion/Schnitt/Postproduction/Export als getrennte Arbeitsbereiche; keine zusätzlichen obligatorischen Generierungs-Gates**<br>Importierter Film lässt sich ohne Storyboard, generierte Takes oder Pipeline-Freigabe schneiden und exportieren. | Pending |
| APP-05 | Sidebar und Inspector unabhängig, Splitter, Zustandswiederherstellung | **Gemeinsame Titelleiste und native Split-Controller**<br>Jeder Schalter ändert nur sein Panel; Projektdaten bleiben unverändert. | Pending |
| APP-06 | Panel maximieren, Theater, Vollbild, Layout-Presets | **Native Menü-/Tastaturaktionen; dezente lokale Viewer-Aktion**<br>Theater/Vollbild verlassen stellt Layout, Auswahl und Wiedergabekontext wieder her; kein globales Ansichtsdropdown ergänzen. | Pending |
| APP-07 | Undo/Redo, Clipboard und Tastaturbefehle | **Native Menüs/Responder, Timeline und Formulare**<br>Text-Undo und Timeline-Undo nicht verwechseln; Command-X/C/V/A und Mehrfachauswahl behalten ihre Wirkung. | Pending |
| APP-08 | Hilfe, Tutorial, Shortcuts, Feedback, Updates und Diagnose | **Native Hilfe-/App-Menüs und vorhandene Fenster**<br>Alle Einstiegspunkte erreichbar lassen; Feedback/Screenshot nur mit ausdrücklicher Nutzereingabe senden. | Pending |
| APP-09 | Generierungsaktivität und Kostenverlauf | **Projektaktivität, vom Budget-/Statusbereich erreichbar**<br>Modell, Kosten, Zeitpunkt und Ergebnis eines früheren Auftrags wiederfinden. | Pending |
| APP-10 | Gemeinsame native Controls, Theme, Fokus und deaktivierte Zustände | **Bestehende gemeinsame UI-Komponenten und AppTheme**<br>Deaktivierte Controls eindeutig, Tastaturfokus sichtbar, Pack-Akzent und Textskalierung konsistent; keine neue parallele Komponentenbibliothek. | Pending |
| MED-01 | Import verschiedener Dateitypen, Ordnerimport, Fortschritt, Abbruch | **Medien > Import; kompakte Picker nutzen denselben Bestand**<br>Video, Audio, Bild, Lottie und Dokumente samt lesbarem Originalnamen übernehmen; Abbruch verständlich anzeigen. | Pending |
| MED-02 | Bibliotheksordner, Unterordner, Umbenennen, Löschen, Verschieben | **Medien > Ordnerbaum und Kontextmenüs**<br>Mehrere verschachtelte Ordner verschieben/löschen mit Undo; Zyklen verhindern. | Pending |
| MED-03 | Asset umbenennen/löschen, Finder, Pfade kopieren | **Medien > Datei-Kontextmenü und Inspector**<br>Originalname, Anzeigetitel und Speicherpfad auseinanderhalten; verwendete Medien und Undo korrekt behandeln. | Pending |
| MED-04 | Mehrfach-, Bereichs- und Marquee-Auswahl | **Großer Medienbrowser**<br>Ausgewählte Gruppe per Ziehen verschieben, Selektion beim Filtern nachvollziehbar halten. | Pending |
| MED-05 | Typfilter, KI-Filter, Sortierung, Thumbnailgröße, Drag-and-drop | **Medien; Picker nur Auswahl/Bindung**<br>Ordner-Drop und innerer Asset-Drop bleiben gleichzeitig erreichbar; nativen AppKit-Drop-Host erhalten. | Pending |
| MED-06 | Visuelle Inhaltssuche, Moments, zeitgebundene Segmente | **Medien > Suchergebnisse; kompakte Treffer im Picker**<br>Moment an Fundstelle ansehen und exakt den gefundenen Bereich in die Timeline ziehen. | Pending |
| MED-07 | Sprach-/Transkriptsuche, Spoken-Treffer und Segmente | **Medien > Suche und Quellvorschau**<br>Texttreffer springt zur richtigen Quellzeit; Bereichs-Drag überträgt Anfang/Ende. | Pending |
| MED-08 | Indexzustände, Download, Fehler/Retry und Speicherverwaltung | **Medien-Suchstatus; Einstellungen > Speicher**<br>Nicht indexiert, in Arbeit und fehlgeschlagen unterscheiden; Index löschen entfernt keine Medien. | Pending |
| MED-09 | Offline-Medien und Relink Datei/Ordner | **Medien-Kontextmenü und Viewer-Fehleransicht**<br>Einzelne Datei oder Ordner neu verknüpfen; Asset-ID und Timeline-Instanzen bleiben erhalten. | Pending |
| MED-10 | Metadaten, Generierungsherkunft und klickbare Referenzen | **Medien > Inspector; Quellen-Inspector**<br>Modell, kompilierten Prompt, Abmessungen, Quelldatei und Referenz-Assets aus gespeicherten Daten lesen. | Pending |
| MED-11 | Medienbrowser, Quellvorschau und Reveal derselben Asset-ID | **Medien und kompakte Quellen-Picker**<br>Workspace-Wechsel erzeugt keine zweite Bibliothek und verändert keine Pipeline-Zuweisung. | Pending |
| MED-12 | Texte als Quelldokumente, Bilder und Lottie als Timeline-Medien | **Medien > alle unterstützten Typen; NLE-Drop nach isPlaceable**<br>Dokumente bleiben nicht platzierbar; Bilder, Lottie, freie Video- und Audiomedien werden nicht ausgesperrt. | Pending |
| MED-13 | Medien mit Agent organisieren | **Medien > Organisieren > prüfbarer Änderungsplan**<br>Ordner-/Namensvorschlag ansehen, gezielt annehmen, über bestehende Mutationen mit Undo anwenden. | Pending |
| GEN-01 | Manuelle Bild-, Video- und Audiogenerierung | **Medien > Generieren; kontextgebundene Aufträge im Inspector**<br>Intention immer kompilieren; keine Rohprompt-Abkürzung zur Provider-API. | Pending |
| GEN-02 | Ausführbare Provider-/Modellbindungen und modellabhängige Optionen | **Gemeinsame native Modellwahl in jedem Generierungsdialog**<br>Nur aktivierte ausführbare Bindungen zeigen; Modellwechsel entfernt inkompatible Eingaben nachvollziehbar. | Pending |
| GEN-03 | First/Last Frames und Referenzmodus mit Bild/Video/Audio-Slots | **Generierungsdialog > modellabhängige Quellen**<br>Exklusive Frame-/Referenzmodi, Rollen und Limits beibehalten; keine heimlichen Zusatzreferenzen. | Pending |
| GEN-04 | Quellvideo, Motion-Referenz, getrimmte Quelle und Referenz-Tags | **Schnitt/Medien > KI-Bearbeitung**<br>Quellvideo und optionaler Trim sind explizit; neue Ausgabe vs Ersetzen ausdrücklich wählen. | Pending |
| GEN-05 | Audio-Optionen: Stimme, Lyrics, Stil, Instrumental und Dauer | **Gemeinsamer Audio-Generierungsdialog**<br>Optionen nur bei passendem ausführbarem Modell zeigen und an denselben Auftrag binden. | Pending |
| GEN-06 | Vorbereiteter Auftrag, Paket prüfen, kopieren, Kosten ablehnen/freigeben | **Interaktionsbereich des jeweiligen Objekts**<br>Exakte Referenzen und kompilierten Auftrag ansehen; Änderung erfordert neue Vorbereitung/Freigabe. Kompatible vorherige Provider-/Modellwahl beibehalten; Auswahl aus validiertem Snapshot und erneute Prüfung vor Ausgabe. | Pending |
| GEN-07 | Batch vorbereiten, einzelne Einträge entfernen, einmal freigeben | **Produktion/Medien > Aufträge**<br>Jedes Element und Gesamtkosten prüfbar; Freigabe nicht zwischen Revisionen wiederverwenden. | Pending |
| GEN-08 | Durable Jobs, fertige Ergebnisse, Rest abbrechen, Status fortsetzen | **Auftragsliste im Interaktionsbereich; KI-Indikator unten rechts mit Einzelaufträgen und Live-Status**<br>Nach Neustart bekannte Jobs weiter abfragen statt neu kostenpflichtig einzureichen; fehlende lokale Autorität anzeigen. | Pending |
| GEN-09 | Rerun mit Herkunft, Upscale und Quelle gezielt ersetzen | **Medien-/Clip-Inspector > KI-Bearbeitung**<br>Quelle, Modell, Kosten und Ersatzumfang zeigen; Original und Undo erhalten. | Pending |
| GEN-10 | Video-to-Music und Video-to-SFX, Platzierung auf Timeline | **Schnitt > Ton; Clip-Inspector > KI-Ton**<br>Passendes Modell, Quellbereich und Zielspur bestätigen; nicht den Projekttrack heimlich ersetzen. | Pending |
| GEN-11 | Musik aus Bild/Video oder Text, Mood-Direction | **Schnitt > Ton erzeugen; Ergebnis in Medien**<br>Vorhandenen Musikweg erhalten; chatgebundene Richtung als strukturierten Vorschlag adaptieren. | Pending |
| NLE-01 | Freie Montage importierter und erzeugter Medien | **Schnitt unabhängig von Produktion**<br>Leeres generisches Projekt: fremdes Video importieren, schneiden und exportieren ohne KI. | Pending |
| NLE-02 | Mehrere Video-, Bild-, Titel-, Lottie- und Audiospuren | **Schnitt > bestehende Mehrspur-Timeline**<br>Spuren erzeugen/entfernen, mehrere Bilder/Titel schichten, Höhe/Mute/Hidden/Sync-Lock erhalten. | Pending |
| NLE-03 | Auswahl, Mehrfach-/Marquee-Auswahl, Kopieren, Duplizieren, Verschieben | **Timeline und Kontextmenü**<br>Gruppen und verbundene Clips bewegen; Option-Duplizieren, Clipboard und Undo wirken auf dieselben Instanzen. | Pending |
| NLE-04 | Split, Rasierklinge, Trim, Ripple Delete, Lücken schließen | **Timeline-Werkzeuge und Shortcuts**<br>Trim/Entfernen mit gesperrten bzw. verknüpften Spuren prüfen; keine stillen Zeitverschiebungen. | Pending |
| NLE-05 | Insert/Overwrite und quellzeitgebundene Segment-Drops | **Timeline-Drop, Quellviewer und Kontextaktion**<br>Einfügen und Überschreiben unterscheiden; korrekte Quell-In/Outs und Typkompatibilität erhalten. | Pending |
| NLE-06 | Snapping, Zoom, Scroll, Auto-Scroll und Track-Höhen | **Timeline**<br>Framegenau an Clips/Playhead einrasten; Zoomen hält Anker; Ziehen über sichtbare Grenzen funktioniert. | Pending |
| NLE-07 | Link/Unlink, Sync-Lock, Mute/Hidden | **Track-Kopf und Clip-Kontextmenü**<br>Linking und Sync-Lock nicht gleichsetzen; Companion-Clips und Ton bei Edits korrekt behandeln. | Pending |
| NLE-08 | Bereich auswählen, Bereich als Medium sichern, Auswahl übergeben | **Timeline-Bereich und strukturierte kontextbezogene Aktion**<br>Anfang/Ende exakt erhalten; als Medium sichern und Quelldauer prüfen; Chat-Aktion durch begrenzten Auftrag ersetzen. | Pending |
| NLE-09 | Quelle austauschen und Clip als neues Medium sichern | **Clip-Kontextmenü, zweckgebundener Quellen-Picker**<br>Kompatibilität, Abbruch, Trim/Speed und bestehende Clip-Instanz erhalten. | Pending |
| NLE-10 | Audio anhand Inhalt synchronisieren | **Kontextmenü geeigneter Timeline-Auswahl**<br>Referenzquelle, ermittelten Versatz und nicht synchronisierbare Quellen verständlich behandeln. | Pending |
| VIEW-01 | Direkte Quellenauswahl, gemerkte Position/In-Out und Verlauf | **Ein kanonischer Viewer ohne Quell-Tabs oder Timeline/Source-Schalter**<br>Direkte Asset-/Clip-Auswahl wechselt den Kontext; Position, In/Out, Zurück/Vor und Tastaturzugriff bleiben je Quelle erhalten. | Pending |
| VIEW-02 | Transport, Scrub, framegenaues Steppen, Bild-Zoom/Fit/Pan | **Viewer jeder passenden Arbeitsfläche**<br>Aktive Quelle vs Timeline unterscheiden; Fit und Zoom ändern keine Ausgabegeometrie. | Pending |
| VIEW-03 | Aktuelles Bild als Medium sichern | **Kleines lokales Viewer-Symbol**<br>Exaktes angezeigtes Frame erscheint im Medienpool mit eigener Identität. | Pending |
| VIEW-04 | Offline-, Generierungs-, Fehler- und Retry-Zustände | **Viewer und Auftragsstatus**<br>Defekte Quelle nicht als schwarzes erfolgreiches Video darstellen; Relink/Fehlermeldung erreichbar. | Pending |
| POST-01 | Position, Skalierung, Rotation, Deckkraft, Flip und Crop | **Postproduction > Bild und gemeinsamer Video-Inspector; auch im Schnitt erreichbar**<br>Felder und direkte Canvas-Griffe bleiben synchron; Crop-Presets/Originalverhältnis und Reset erhalten. | Pending |
| POST-02 | Tempo und retimete Clipbereiche | **Schnitt > Clip-Inspector**<br>Dauer, Quell-In/Out, verknüpfter Ton und nachfolgende Clips nach tatsächlicher nativer Semantik behandeln. | Pending |
| POST-03 | Keyframes für Transform/Deckkraft/Lautstärke und Navigation | **Schnitt/Postproduction > gemeinsames Keyframe-Panel am Inspector**<br>Keyframe setzen/löschen/verschieben, Wert editieren und vorheriges/nächstes anspringen. | Pending |
| POST-04 | Interpolation und zeitabhängige Effektparameter | **Schnitt/Postproduction > gemeinsames Keyframe-/Timeline-Kontextmenü**<br>Vorhandene Interpolationsarten und animierte Werte bewahren; ein statischer Regler ersetzt sie nicht. | Pending |
| POST-05 | Tonwerte, Weißabgleich, Vibrance und Sättigung | **Postproduction > Farbe > vorhandener Adjust-Inspector; auch im Schnitt erreichbar**<br>Alle vorhandenen Parameter sowie Gruppen-Bypass, Reset, Undo und Mehrfachauswahl erhalten. | Pending |
| POST-06 | RGB-Kurven und Hue-Kurven | **Postproduction > Farbe > gemeinsamer Adjust-Inspector**<br>Kanäle/Punkte und Farbzielkurven bearbeiten, zurücksetzen und rendern; keine neuen unabhängigen Grade-Daten. | Pending |
| POST-07 | Farbräder | **Postproduction > Farbe > gemeinsamer Adjust-Inspector**<br>Schatten/Mitten/Lichter und vorhandene Parameter verwenden; Wirkung und Rücksetzung prüfen. | Pending |
| POST-08 | LUT laden, Intensität, Bypass und Verwaltung | **Postproduction > Farbe > LUTs**<br>Projektlokale LUT-Bindung, Intensität und Export erhalten; kein rein dekoratives Preset. | Pending |
| POST-09 | Schärfen, Entrauschen, Clarity und Dehaze | **Postproduction > Effekte > Detail**<br>Vorhandene gerenderte Parameter, Reset und Reihenfolge erhalten. | Pending |
| POST-10 | Blur und Motion Blur | **Postproduction > Effekte**<br>Menge und Richtung des vorhandenen Effekts erhalten, keine Behauptung von Bewegungsschätzung. | Pending |
| POST-11 | Vignette, Grain und Glow | **Postproduction > Effekte**<br>Alle bestehenden Teilparameter und Bypass/Reset erreichbar halten. | Pending |
| POST-12 | Chroma Key | **Postproduction > Effekte > Chroma Key**<br>Farbton, Toleranz, Softness und Spill sowie Komposition über darunterliegender Spur erhalten. | Pending |
| POST-13 | Farbmessung und referenzbezogene KI-Farbkorrektur | **Postproduction > Farbvergleich am Clip, vorhandene Mess-/Apply-Tools**<br>Gemessene Werte und Referenz unterscheiden; KI-Änderung prüfbar annehmen und rückgängig machen. Kein erfundenes Scope-Panel als Bestand zählen. | Pending |
| POST-14 | Audiopegel, Fades, Lautstärke-Keyframes und Tempo | **Postproduction > Ton; gemeinsame Audio-Inspector-/Hüllkurven-Werkzeuge auch im Schnitt**<br>Mehrere Audioclips separat bearbeiten; Fade-Knie und Interpolation prüfen. | Pending |
| POST-15 | Titel, Typografie, Farbe, Hintergrund, Kontur, Schatten, Layout | **Postproduction > Titel; gemeinsamer Text-Inspector und Canvas, auch im Schnitt erreichbar**<br>Titelclips von Textdokumenten unterscheiden; Styling, Ausrichtung, Position und mehrlagige Titel erhalten. | Pending |
| POST-16 | Automatische Untertitel mit Sprache, Quelle und Stil | **Postproduction > Untertitel, Vorschau und gemeinsamer Text-Inspector; auch im Schnitt erreichbar**<br>Quelle/Track, Sprache, Layout und Stil wählen; echte Caption-Clips erzeugen und editieren. | Pending |
| POST-17 | Füllwörter entfernen, Caption-Korrekturen und Übersetzung | **Schnitt > Untertitel > begrenzte Änderungs-/Schnittvorschläge**<br>Vorher/Nachher und betroffene Zeitbereiche prüfen; bestehendes remove_words/Ripple verwenden. | Pending |
| FIN-01 | Film-/Übergangssichtung, eigene Befunde, Aktionen und Zeitbereiche | **Postproduction > Endkontrolle**<br>Aktuelle echte Montage mit Audio prüfen; jede Befundaktion und exakte Bereiche erhalten. | Pending |
| FIN-02 | Postproduction-Korrektur mit bestehenden Edit-Werkzeugen | **Postproduction > vollständige gemeinsame Inspector-Werkzeuge; Montagekorrekturen im Schnitt**<br>Kein eigener zweiter Grade-/Audiostand; Rückkehr nach Änderung macht veralteten Review ungültig. | Pending |
| PROD-01 | Generische Phasen plus Pack-Ergänzungen/Abweichungen | **Produktion-Sidebar aus aufgelöstem Host-/Pack-Vertrag**<br>Generischer und Musicvideo-Vertrag unterschiedliche Phasen/Intakes/Oberflächen; unbekannter Pack nicht als generisch öffnen. | Pending |
| PROD-02 | Track, optionale Lyrics, Init, Analyse, danach optionales Material | **Produktion > aktueller strukturierter Schritt**<br>Medienimport ist keine Zuweisung; Lyrics überspringen möglich; Greenfield ohne vorhandene Geschichte bleibt vollständig. | Pending |
| PROD-03 | Wiederholbare vorbereitete Figuren/Orte und Stilreferenzen | **Nach bestätigter Analyse, optionaler Materialschritt**<br>Name/Bilder erforderlich, nummerierte Einträge, erstes Skip und später Done ausdrücklich; keine erfundenen Briefingbilder. | Pending |
| PROD-04 | Audioanalyse: Beats/Downbeats, Strukturhierarchie, Energie, Tempo/Tonart | **Musicvideo > Audioanalyse; generische Pack-Primitives wiederverwenden**<br>Section/Segment/Phrase-Grenzen und Messwerte aus kanonischen Daten zeigen, nicht frei neu schätzen. | Pending |
| PROD-05 | Analysequalität, ungeklärte Struktur, Remeasurement und Messdiagnose | **Audioanalyse > kontextbezogene Hinweise und Aktion**<br>Unsichere Struktur nicht als sicher freigeben; neue Messung zeigt echte Stufen und aktuellen Track. | Pending |
| PROD-06 | Brief, Production Design, Treatment und Storyboard als getrennte Artefakte | **Produktion > jeweiliges Dokument; kanonischen Writer wiederverwenden**<br>Änderung/Revision/Approval exakt demselben Artefakt zuordnen, nicht nur Text im Browser ersetzen. | Pending |
| PROD-07 | Patterns, Affect, gemessene Signatur und evidenzbasierte Empfehlung | **Brief/Treatment > visuelle Wahl mit begründeten Empfehlungen**<br>Messung, Interpretation und Präferenz trennen; Alternativen zulassen; Konfidenz nicht aus fehlenden Daten erfinden. | Pending |
| PROD-08 | Characters, Ensembles, Props, Locations und Look | **References > Identitäten/Objekte/Orte/Look mit gemeinsamem Objekt-Inspector**<br>Umbenennung Bible zu References ändert weder Schema noch Entity-IDs oder Datentypen. | Pending |
| PROD-09 | Objektgraph, Verwendung, Breadcrumbs und Shot-Provenienz | **Objektbezogener Inspector in allen Arbeitsbereichen**<br>Von Figur zur Verwendung, zum Shot, Take und Timeline-Clip navigieren ohne Selektion umzudeuten. | Pending |
| PROD-10 | Ledger-Attribute mit Sperre, Herkunft und entity-bezogener Bearbeitung | **References > Objekt-Inspector, strukturierter Änderungsauftrag**<br>Gesperrte Identitäts-/Stilattribute nicht still überschreiben; Herkunft und Auswirkungen der Änderung sichtbar. | Pending |
| PROD-11 | Hybride Shotquellen generated/live_action/ai_enhanced | **Shotplanung > Quelle und Produktionsart**<br>Importiertes/AI-enhanced Material hat exakten source_path; Frames wird passend übersprungen; kein automatisches Substituieren. | Pending |
| PROD-12 | Shot-Dauern, Kamera, Modelle, Eingabe-/Conditioning-Strategien | **Shotplanung > kontextabhängiger Inspector**<br>Planlänge, Providerdauer, Handles, Referenzrollen und ausführbare Modellfähigkeit konsistent prüfen. | Pending |
| PROD-13 | Frame-Continuation und native Video-Extension | **Shotplanung > Anschlussstrategie; Takes > exakte Quellbindung**<br>Continuation bindet letzten Frame des Vorgängers; Extension bindet echtes Vorgängervideo und ausführbaren Modus. | Pending |
| PROD-14 | Blocking, räumliche Pläne, 360-Panorama und POV-Extraktion | **Shotplanung > Blocking mit Quellen und Kameraansichten**<br>Dieselbe Geometrie für Perspektivwechsel verwenden; Extraktion lokal/deterministisch; Restyling als separater Auftrag. | Pending |
| PROD-15 | Story-Chronologie, Zustandsleiter und Kausalitätsprüfung | **Pre-Render-Review > Zustände/Anschlüsse nach Story-Weltzeit**<br>Zeitsprünge im Film nicht als Weltchronologie behandeln; echte Checks und zusätzliche semantische Prüfung unterscheiden. | Pending |
| PROD-16 | Sanity-Befunde mit Schwere, Evidenz, Quelle und Korrektur | **Produktion > Pre-Render-Review**<br>Alle registrierten Core-/Pack-Checks erhalten; Warnung/Blocker/Info und Artefaktverweis nicht auf ein Ampelsignal reduzieren. | Pending |
| PROD-17 | Frames/Anker auswählen, neu erzeugen und aus Frames remixen | **References > Shot-Anker > Auswahl/Neuversuch/Remix**<br>Sketches und gerenderte References getrennt halten; genaue Eingangsframes und Kostenfreigabe nachweisen. | Pending |
| PROD-18 | Frame-, Produktionsstil- und Timeline-Stilreview | **References/Pre-Render-Review/Postproduction jeweils am eigenen Artefakt**<br>Abweichungen mit Begründung annehmen; stale Review nach Bild-/Stil-/Timelineänderung erkennen. | Pending |
| PROD-19 | Takes: sechs Prüfgänge, Ablehnung, Abweichung, Auswahl | **Produktion > Takes > objektbezogener Review**<br>Nur gültiger Review des exakten Takes erlaubt Auswahl; abgelehntes Material nicht freigeben. | Pending |
| PROD-20 | Nutzbaren Bereich eines Takes retten und geprüft einfügen | **Takes > Bereich retten, danach gezielter Insert im Schnitt**<br>Bereich mit Start/Ende, Beobachtung und Audio-Wahl separat prüfen und exakt übernehmen. | Pending |
| PROD-21 | Iterationsentscheidungen, Reparatur, Rewrite, Simplify, Model-Limit | **Takes > Nächster Versuch / Korrekturplan**<br>Fehlversuche und Grenze berücksichtigen; kein endloses autonomes Neu-Rendern; Kosten erneut freigeben. | Pending |
| PROD-22 | Gate-Approve, Needs Revision, Rewind, Status-/Artefaktzugriff | **Produktion > aktuelle Phase und deren Kontextmenü**<br>Nur aktueller Phasezugriff; Job sperrt Mutationen; kanonische Readiness auf Klick erneut prüfen. | Pending |
| PROD-23 | Song-Anker, Render-Provenienz und deterministische Assembly | **Takes > Montage übernehmen; Schnitt bleibt frei bearbeitbar**<br>Freigegebene Take-/Bereichs-IDs, Trackbindung und Montagezeitpunkte exakt übernehmen; spätere Montage nicht heimlich überschreiben. | Pending |
| PROD-24 | Nativer oder importierter Blockout-Clip mit Kamera-/Layout-/Zustandsbindung | **Shotplanung > Blocking > Blockout-Vorschau/Import**<br>Vorhandenen deterministischen Plan-/Elevationsexport nutzen; nicht als vollständigen 3D-Editor ausgeben; importiertes MOV und exakte Hashbindungen erhalten. | Pending |
| PROD-25 | Musicvideo: Performance-Segmente, Visual Arc, Coverage und Final Mix | **Musicvideo ergänzt Shotplanung und Montage/Ton**<br>Samplegenaue Track-Segmente, Lyrics-Bindung, Coverage/Motiv-Setups und finalen Song-Mix erhalten; nicht zum generischen Pflichtworkflow machen. | Pending |
| PROD-26 | Shot-Delivery als Video oder Still mit Ken-Burns-Bewegung | **Shotplanung > Ausgabeart; Assembly übernimmt gültige Quelle**<br>Still-Delivery vermeidet unnötige Videogenerierung; Bildquelle, Dauer und Bewegung nach bestehendem Vertrag erhalten. | Pending |
| AGENT-01 | Choice, Multi-choice, Prosa, Datei-Intake, Cancel und Empfehlungen | **Kontextgebundener Interaktionsbereich der aktiven Aufgabe**<br>Alle existierenden Dialogarten einschließlich Defaults, Pflichtfeldern, Empfehlungen und Abbruch erreichbar halten. | Pending |
| AGENT-02 | Strukturierte Blocks, Artefaktvorschau und Medienanzeige | **Aktuelle Arbeitsfläche und aufgabenbezogene Ergebnisansicht**<br>Alle vorhandenen Blockarten rendern; Medien und Detailansichten öffnen; keine technische JSON-Prosa als UI. | Pending |
| AGENT-03 | Laufstatus, Tool-Fortschritt, Cancel, Wiederaufnahme und Fehler | **Kontextbezogener Auftragsstatus und beständiger KI-Indikator mit nichtmodalem Fly-out**<br>Transportverlust nicht als Phasenende interpretieren; Runtime-/Providerfehler unterscheiden; echte Stage-Grenzen zeigen. | Pending |
| AGENT-04 | Objekt-/Bereichskontext statt Mentions/Add to Chat | **Objekt-/Clip-/Bereichsauswahl > begrenzter Auftrag**<br>Exakte Objekt-/Asset-/Range-IDs übergeben; nicht mehr verdeckt eine neue freie Konversation starten. | Pending |
| AGENT-05 | Auftrags-/Entscheidungshistorie statt paralleler Chats | **Projektaktivität und objektbezogene Entscheidungen**<br>Wiederfinden, Fortsetzen, Löschen und aktueller Auftrag bleiben möglich; bestehende Gespräche nicht bei Migration verlieren. | Pending |
| AGENT-06 | Model-/Runtime-Wahl, Backendwechsel und Local MCP | **Einstellungen > Agent; Diagnose/Verbindungsstatus**<br>Embedded CLI und API-Key-Weg erhalten; Backend-Bereitschaft unabhängig vom Intake früh anzeigen, Fehler mit direktem Einstieg in Agent-Einstellungen; App-Sprache und lokale MCP-Anbindung erhalten. | Pending |
| AGENT-07 | Externe MCP-Server hinzufügen/importieren, vertrauen, bearbeiten, entfernen | **Einstellungen > Agent > Verbindungen**<br>Vertrauensbestätigung, Mehrfachimport, Namenskonflikte und Entfernen bewahren; keine automatische FilmFlow-Zuweisung. | Pending |
| FIN-03 | H.264/H.265/ProRes, Auflösungen, Master/Ableitung, Review-Option | **Export > Videoausgabe und natives Export-Menü**<br>Projektaspekt/FPS bewahren; Review-Pflicht bleibt ausdrückliche Option; vorhandener Export aus freiem NLE bleibt möglich. | Pending |
| FIN-04 | XML-Übergabe und selbstenthaltene Projektkopie | **Export > XML-/Projektübergabe; natives Exportfenster**<br>XML-Verluste benennen; Projektkopie bindet Medien ein und weist fehlende Dateien aus. | Pending |
| FIN-05 | Ausgabeauftrag, Fortschritt, Abbruch, Recovery, technische Probe | **Export > Aufträge, Ausgabeverlauf und Datei-Prüfung; eigener Exportindikator mit Live-Fly-out in allen Arbeitsbereichen**<br>Unfertige/fehlgeschlagene Exporte nicht als erfolgreich markieren; Codec/Größe/FPS/Dauer/Audio tatsächlich prüfen. | Pending |
| FIN-06 | Optionales Album-Cover mit Formatvarianten und Typografie | **Pack-spezifischer Export-Eintrag nach vollständiger Render-Freigabe**<br>Ohne neue Phase; alle bestehenden Gates erhalten; Künstler und Titel explizit; sauberes Bild bleibt erhalten; nur ausführbare und geeignete Modelle. | Pending |
| SET-01 | UI-Skalierung, Benachrichtigungen, Diagnose-Einwilligung | **Vorhandene allgemeine Einstellungen**<br>Skalierung beeinflusst Controls, nicht Filmtiming; Benachrichtigung und Telemetrie bleiben ausdrückliche Optionen. | Pending |
| SET-02 | Provider: API-Keys, OAuth-Verbindungen, Aktivierung, Prompt-Processing | **Einstellungen > Provider**<br>Vorhandene funktionierende Provider erhalten; Keys geschützt; keine unausführbaren Eingabefelder hinzufügen. | Pending |
| SET-03 | Modelle suchen/aktivieren, Capability-Recherche mit Evidenz und Annahme | **Einstellungen > Modelle**<br>Nur belegte Fähigkeitsfelder annehmen; Vergleich, Deaktivieren, Archivieren, Aktualisieren und Löschen erhalten. | Pending |
| SET-04 | Speicherort, Cache, Suchindex/-modell | **Einstellungen > Speicher**<br>Cache/Index-Löschen entfernt keine Originale; neuer Projektordner verschiebt keine bestehenden Projekte. | Pending |
| PACK-01 | Installieren, Aktualisieren, Entfernen und Neustartzustände | **Einstellungen > Format-Packs und Projektstart**<br>Alle Versions-/Ladezustände verständlich; genutzte/residente Versionen nicht still ersetzen. | Pending |
| PACK-02 | Exakte Projekt-Pins, Recovery-Kopie und explizites Upgrade | **Projekt öffnen > Auflösungskonflikt; Pack-Einstellungen**<br>Fehlender/falscher Pack stoppt Laden/Speichern; Upgrade migriert ausdrückliche Kopie, kein latest-wins. | Pending |
| PACK-03 | Pack-Akzent, deklarative Oberflächen und dynamischer UI-Vertrag | **Host-eigene Chrome/Primitives, Pack liefert Farbe und Daten**<br>Pack-Farbe deutlich ohne farbige Rahmen; generischer Workflow bleibt vollständig; keine Musicvideo-Sonderlogik in allen Panels. | Pending |
| CORE-01 | Kanonische Writer, Gates, kumulative Lineage, typisierte Dateien | **Vorhandene Host-/Engine-Dienste hinter allen neuen UI-Aktionen**<br>Keine UI-Mutation umgeht Writer/Gate oder kopiert die kanonische Wahrheit in einen zweiten State. | Pending |
| CORE-02 | Phasenjobs, idempotente Wiederaufnahme, Runtime-Dokumente und Capabilities | **Interaktions-/Fortschrittsbereich, Engine unverändert**<br>Ein Projekt führt nur einen Phasenjob aus; Reconnect/Retry startet keinen zweiten Auftrag. | Pending |
| CORE-03 | Prompt-Compile, Budget, Referenz-Snapshots, Prepared Requests | **Gemeinsame native Auftragsvorbereitung**<br>Kosten-/Quelländerung macht Freigabe ungültig; Ausgabe bindet tatsächliches Modell, Prompt und Referenzen. | Pending |
| CORE-04 | Produktionswissen und formatübergreifende Profile | **Produktionsaufgaben nutzen vorhandene Core-Profile und Pack-Ergänzungen**<br>Keine Kopie generischer Filmdoktrin in jeden Pack; Ratschläge und deterministische Pflichten unterscheiden. | Pending |
| CORE-05 | Lokale Audioanalyse-Adapter, Stem Separation, Beat/Chord/Transkription | **Audioanalyse nutzt vorhandene Engine-Adapter; Status/Fehler im Interaktionsbereich**<br>Vorhandene lokale Modelle/Adapter erhalten; OS-/Modellverfügbarkeit ehrlich; Engine-Stems nicht als fertigen DAW-Stem-Editor ausgeben. | Pending |
| NEW-01 | Mehrere Sketch-Momente pro Storyboard-Shot | **Storyboard/Animatic, gesonderte versionierte Vertragserweiterung**<br>Momente erfinden keine neuen Shot-IDs/Schnitte; Dauer bleibt eine gemeinsame Quelle. | Pending |
| NEW-02 | FilmFlow-MCP-Import als Snapshot und Abkürzung | **Projekt > expliziter Import mit Zuordnung/Annahme**<br>Die Importfähigkeit gehört zum Sollumfang; ihre Nutzung ist optional. Importiert vorhandene Arbeit und erzeugt keine fiktiven früheren Freigaben. Der tatsächliche Produzentenvertrag bleibt zu verifizieren. | Pending |
| NEW-03 | Eigenständiges Skript, Planungsreihenfolge und getrennte visuelle Nachweise | **Expliziter Core-v2-/Musicvideo-v2-Vertrag mit Script → Storyboard/Animatic → Shot Planning → Bible → Shot List → Sanity → Frames → Render Review → Render**<br>Legacy-Projekte behalten ihren gepinnten Vertrag; neue kanonische Writer, Gates und exakte Lineage getrennt prüfen. Bible und Frames bleiben eigene prüfbare Artefakte. | Pending |
| NEW-04 | Automatischer semantischer Gesamtfilm-Audit | **Begrenzter künftiger Adapter auf exaktem Review-Reel**<br>Neue Fähigkeit getrennt ausweisen; native Mess-/Reviewdaten und künstlichen Beispielbefund nicht verwechseln. | Pending |
| NEW-05 | Optionales Vorschaubild je Videoexport für alle Projektformate | **Generischer Export-Adapter auf vorhandener Frame-Aufnahme, Medienbibliothek und Bildgenerierung**<br>Exakte Bildquelle und Format je Auftrag festhalten; Quelldatei-/Versionsprüfung und atomare Video-/Bildausgabe ergänzen; XML/Projektkopie unabhängig; keine Format-Pack-Pflicht. | Pending |

## Current source follow-ups — not acceptance results

- PROD-07: the Brief now reads actual pack Pattern-fit recommendations, measured/documented/inferred signature basis, confidence, alternatives and warnings. Native selection/no-pattern uses the shared canonical Brief writer, exact byte lineage and Undo. `PatternRecommendationsAcceptance` and its independent validator are prepared; native execution remains Pending.
- POST-13: Adjust now compares the existing `inspect_color` frame images, readouts and gaps against a real library reference. A schema-validated AI proposal changes nothing until native Apply calls the existing `apply_color`; source/session/selection changes require a new comparison. `ColorReferenceComparisonAcceptance` and its independent validator are prepared; native execution remains Pending.
- POST-08: Cube input domains are applied at interpolation, preserving original output samples. Missing/tampered portable LUTs open with visible Relink/Remove recovery; saving/exporting still requires verified bytes. SDR/HDR export consumes the exact frozen LUT binding. Prepared unit/native checks do not establish runtime correctness.
- PROD-14/24: native Panorama/POV review, retained plan/elevation MOV and existing Blockout-MOV preview/selection/export now have explicit entries alongside Scene/camera/pose/Clay. Panorama sheet-alias provenance and multi-location invalid-receipt recovery corrections have prepared native and independent negative checks; their focused review and execution remain Pending. Geometry evidence never replaces appearance or final render evidence.
- MED-10/PROD-09/AGENT-04/05: current V5 Shot → exact Assembly clip → verified Take/model/submitted prompt/input → Shot navigation and focused Timeline/Source IN/OUT tasks now have native entries. The combined owner case uses one actual outer scale and includes old-format conversation search/continue/cancel/delete/save/reopen. Its isolated recorder and genuine-text initial fixture are not live backend or historic-account migration proof.
- GEN-01–04/08/11, NLE-02–04/06/08–10 and FIN-03–05: free manual Video/model-reference mode changes, Mood, generation authority loss, real process restarts, layered edits, source replacement/range export/audio sync and codec/XML/export recovery scenarios are prepared. Source existence and isolated HTTP fixtures establish no successful native execution or live-provider availability.
- POST-17: schema-bounded caption Before/After proposals and reviewed speech cuts now use explicit selection/Apply/Cancel, source and timeline fences, shared ripple edits and Undo. The prepared native helper covers names/jargon and speech cuts; an actual Translate → language → translated-text approval case remains distinct and Pending.
- The assigned narrow cases now have prepared native owners: Ledger tag details/lock/refusal/reconciliation/Undo/Redo/reopen, current-track actual Consolidator `needs_review` publication/disabled approval/remeasure/failure/Retry, and Translate → German → selective target-text approval/Cancel/Undo/reopen. Ledger details/history and uncertain-measurement publication required source fixes; Translate reuses the existing bounded proposal path. Deterministic fixture adapters prove no live analyzer or translation quality. All new cases and tests remain unrun; all 121 rows remain Pending.

## User understanding and visual acceptance

Acceptance requires an inventory of every screen, transition and applicable state
for each function group, including empty, populated, busy, decision, error/retry
and reopened states. Unexercised entries remain Pending. Each entry is assessed
from the perspective of a user who has never read the source or the concept.
A function group remains Pending until every entry has functional evidence and
all four UX criteria below pass, with no unresolved ambiguity or visual defect.
Neither a scripted successful click nor the presence of a control establishes
understandable or polished UX.

| Question | Observable acceptance |
|---|---|
| Does the user understand this screen? | The workspace, selected object, current state and purpose of the primary action are apparent from visible labels and content. Technical identifiers, hidden context and knowledge of implementation are unnecessary. |
| Is the user guided through the workflow? | The next step and its consequences are visible. An empty, waiting, failed or blocked state explains what happened and offers the applicable next action; required input and the reason an action is unavailable are clear. Optional steps offer a visible way to continue. |
| Is the UI consistent? | Navigation, inspector, content, status and action labels describe the same object and current revision. A pending operation is distinguishable from a completed one; Undo/Redo and approval controls do not imply a change that has not happened. |
| Is the screen clear and visually polished? | Screenshots show a deliberate hierarchy, legible text, consistent typography and spacing, and balanced use of the available area. Important content and primary actions remain unobscured; wrapping, scrolling, focus and disabled states remain clear at the smallest supported window and at 100/125/150% text size. |

For each assessed state, the evidence identifies the function group, actual entry
action, screenshot, visible state and next action, observed consequence, and any
remaining ambiguity or visual defect. It includes empty, populated, busy,
decision, error/retry and reopened states where the workflow has them. Screenshot
assessment by a reviewer independent of the implementation supplies the visual
judgement that source review and accessibility assertions cannot establish.
Missing evidence remains Pending; no visual or UX
acceptance has been claimed for the new candidate.
