# Export: Vorschaubild und Album-Cover

## Zuständigkeit und Code-Abgleich

- **Vorschaubild:** optionales Bild für jede Videoausgabe, unabhängig von Format-Pack und Produktionspipeline. Filmframe, vorhandenes Projektbild oder generiertes Bild. Eine ausdrückliche Übernahme ordnet es dem nächsten Videoexport zu. Jeder Auftrag speichert seinen eigenen Stand; spätere Änderungen wirken nur auf weitere Ausgaben. XML und Projektkopien benötigen kein Vorschaubild.
- **Album-Cover:** optionale Music-Video-Utility. `Sources/MusicvideoPlugin/Resources/MusicvideoPack/phases/cover.md` und `MusicvideoPack.starters(for:)` bieten sie bereits nach Freigabe aller Phasen einschließlich Render an. Der Dummy erhält diese Voraussetzung. Es entsteht keine zusätzliche Pflichtphase und keine Exportvoraussetzung.
- **Wiederverwendung:** `EditorViewModel+MediaLibrary.captureCurrentFrameToMedia()` nimmt bereits einen Frame mit Video-Composition und TextLayer-Snapshot als PNG in die Medienbibliothek auf. Der Kamera-Button im PreviewContainerView erschließt diese Funktion. Anbieterwahl, Bildgenerierung und Projektmedien bestehen bereits.
- **Begrenzte neue native Arbeit:** Zuordnung eines Vorschaubilds zum konkreten Exportauftrag und Ausgabe als PNG-Begleitdatei. Exakte Quelle/Revision, Seitenverhältnis und Ausschnitt müssen vor Start feststehen. Video und Bild gehören in eine konsistente Ausgabe-Transaktion mit vorhandener Überschreibbestätigung und verständlichem Teilergebnis bei Fehlern. Der Dummy schreibt keine Dateien und beweist diese Dateisystem-Eigenschaften nicht.
- **Album-Varianten:** 1:1, 16:9, 9:16; Bild ohne Schrift behalten, dann optional separate Schriftvariante. Künstler und Titel werden ausdrücklich eingegeben. Kein Ersetzen des sauberen Bilds, keine Ableitung der Namen aus Lyrics/Dateinamen. Alle Varianten sind gewöhnliche Projektmedien. Im nativen System ausschließlich tatsächlich ausführbare Bildmodelle verwenden; für Schriftvarianten müssen Referenzverarbeitung und Textfähigkeit geeignet sein.

## UI-/UX-Self-Review

Die Erweiterung nutzt die bestehende Desktop-Aufteilung: lokale Aufgaben in der Export-Sidebar, große Bildfläche, Werkzeuge im Inspector, Kontextreiter im Bildkopf. Keine zusätzliche globale Toolbar, Web-Zurücknavigation oder dekorativen Farbränder. Album-Formate und Quellen-Reiter wechseln ausschließlich ihren eigenen Inhalt. Die Filmposition erscheint nur bei Filmframe-Auswahl; hier ist sie die Bildauswahl, kein Animatic-Transport.

Vor Präsentation behoben:

- Preview-Framewechsel macht die vorherige Übernahme erkennbar ungültig. Eine veraltete, eingeschaltete Vorschau sperrt die Videoausgabe; Ausschalten erlaubt die Ausgabe ohne Bild.
- Frame-Scrubbing ersetzt den aktiven Slider nicht während des Ziehens. Das abschließende Change-Ereignis übernimmt ebenfalls die Position.
- Bildformat bleibt bei 390–1440 px geometrisch korrekt. Andere Ausschnitte werden zentriert beschnitten und ausdrücklich so beschrieben; keine gestauchten Bilder.
- Zu langes Formatlabel und Formatauswahl verkürzt. Typografie-Ausführung heißt „Mit Schrift“, die Eingaben heißen „Künstler“ und „Titel“.
- Übersprungene Album-Formate bleiben sichtbar gekennzeichnet und können erst nach Wiederaufnahme generiert werden.
- Texteingabe ersetzt beim Fokusverlust keine Aktion mehr; Klick auf Kostenprüfung bleibt wirksam.
- Modellwahl verwendet nur aktivierte Demo-Modelle. Fehlende Modelle sperren die Kostenprüfung.
- Vorübergehende Kostenfreigabe-Kontexte werden nicht in Bildmetadaten übernommen. Das verhindert unnötig verschachtelte Historien beim Erzeugen weiterer Vorschauen.

Die vorhandenen Beispielbilder zeigen Layout und Auswahl, keine neuen echten Renderings. Die sichtbare Album-Typografie ist ausdrücklich Layoutsimulation; es wird kein nativer Text-Overlay-Renderer vorausgesetzt. Native Cover-Typografie folgt weiter dem vorhandenen generativen Utility-Weg. Echte Bildgenerierung, Anbieterfähigkeiten/-preise, Prompt-Compiler und Datei-Transaktionen sind nicht durch diesen Mock ausgeführt oder verifiziert.

## Verifikation

- 41 gezielte Browserprüfungen: unterschiedliche Zuständigkeiten, Filmposition, Quellenwechsel, Kostenfreigabe, Abbruch, saubere/Schriftvarianten, Generic-Projekt, gespeicherte Bildauswahl, unveränderte frühere Exportaufträge, XML-Unabhängigkeit und Bildformate bei 1440/1048/768/390 px.
- 25 bestehende Hintergrundprüfungen bestanden: KI/Export getrennt, Zustände, Stopp, laufende Aufträge bei Workspace-Wechsel, Fly-out, Fokus und reduzierte Bewegung.
- 35 bestehende Workbench-Prüfungen sowie Layoutprüfungen bestanden: freier Schnitt/Export, Postproduction, Medien, Provider und Packs.
- Standalone-Bilder und tatsächlicher Visualisierungsrahmen visuell geprüft. Für den Inline-Rahmen ist der Scriptinhalt komprimiert; Bilder behalten ihre bestehende Qualität. Dekompression/Initialisierung und gelieferte Icons funktionieren im tatsächlichen Vorschau-Rahmen; die Vorschau liegt unter 1 MB.
- Statischer Funktionsabgleich: bestehendes Album-Cover als FIN-06, neuer Vorschaubild-Exportadapter als NEW-05. Weiterhin kein Anspruch vollständiger nativer Funktionsparität.

Nachweise: `artwork-checks.json`, `background-checks.json`, `studio-workspace-checks.json`, `studio-screenshots/export-preview.png`, `studio-screenshots/export-album.png`. Kein nativer App-Build, App-Start oder Anbieteraufruf.
