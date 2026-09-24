# Optionales Blocking — UI-/UX-Review

Geprüft: statischer Desktop-Clickdummy, 19.09.2026. Kein nativer Build, kein App-Start, keine Provider- oder Blender-Ausführung. Die parallelen Higgsfield-Änderungen wurden nicht bearbeitet.

## Verbindlicher Produktvertrag

Blocking ist optional. Eine Clay-Szene ist eine Location für einen oder mehrere Shots; Geometrie und Objektpositionen werden gemeinsam verwendet, Kameras sind shotbezogen. Aus den Kameras abgeleitete 2D-Snapshots binden Positionierung und Perspektive für spätere Bild-/Videomodelle. Andere Anker-Referenzen und das kompilierte Prompt bestimmen Look, Licht, Identität und visuelle Zustände. Tag/Nacht verlangt keine Kopie der räumlichen Location.

## Geprüfte Gestaltung und Bedienung

- Eigener optionaler Eintrag zwischen Shotplanung und References; keine zusätzliche Blocking-Ansicht innerhalb der Shotliste. Überspringen ist ein regulärer Weg und erzeugt keine räumlichen Pflichtartefakte oder Kosten. Bereits begonnene Szenen bleiben nach ausdrücklich bestätigtem Überspringen als Entwurf erhalten.
- Arbeitsfläche folgt dem bestehenden Desktop-Fenster: Modusnavigation, Workflow-Seitenleiste, zentrale Szene, kontextbezogener Inspector und gemeinsame Status-/Auftragsfläche. Kein freier Chat, zusätzliche Website-Navigation oder dauerhafte Textübersicht.
- Raum, Kamera und Vorlagen trennen Betrachtung, Shot-Setup und Ableitungen. Die freie Ansicht verändert keine Shot-Kamera. Nur die Kameraansicht einer Kamerafahrt besitzt die dafür zuständige Wiedergabe. Das Storyboard-Animatic bleibt unabhängig.
- Location-Zuordnung und ihre Verwendung sind im Inspector sichtbar. Duplizieren ist eine ausdrückliche geometrische Variante; andere Licht-/Look-Zustände benötigen diesen Vorgang nicht. Objekte lassen sich über den Inspector bewegen, drehen und skalieren. Undo stellt den vorherigen gemeinsamen Szenenstand wieder her.
- Optik und Timing behalten ihre Herkunft aus Shotplanung beziehungsweise Storyboard. Die Optik ist im Blocking lesbar und nur über ausdrücklichen Rewind der Shotplanung änderbar.
- Raum- und Shotansicht verwenden dieselben geometrischen Daten. Die Kameraansicht und 2D-Ableitung zeigen dasselbe Projektformat und denselben Bildausschnitt. Start und Ende einer Kamerafahrt sind als getrennte Snapshots einsehbar.
- Vorlagen bleiben an Location, Geometrie, Shot-Kamera, Dauer und Ausgabeformat gebunden. Änderungen markieren betroffene Ableitungen als veraltet. „Vorlagen aktualisieren“ erneuert nur ungültige Ableitungen; gültige Sichtungen bleiben erhalten. Nach Freigabe ist die Szene schreibgeschützt. Referenzen und Render-Review zeigen die separate räumliche Quelle; veraltete Quellen sperren Produktionsaufträge.
- Frische Beispiele starten im Blocking. Gespeicherte Benutzersitzungen werden weiterhin wiederhergestellt. Bestehende Projekte erhalten keine nachträgliche Blocking-Pflicht. Ein FilmFlow-Import mit Shotplanung landet bei der optionalen Blocking-Entscheidung.

## Im Self-Review korrigiert

1. Falscher Bildausschnitt durch den variablen Viewer: Kameraansicht jetzt im Projektformat, gleiche Projektion wie die Ableitung.
2. Mehrdeutige Verantwortung für Kameraoptik: keine zweite Brennweiten-/Bildwinkel-Wahrheit im Blocking.
3. Doppelte Ableiten-Aktion und unnötiger Zwischenschritt: eine primäre Ableitung am Phasenabschluss; bei vorhandenen Vorlagen folgt Sichtung/Freigabe.
4. Zu enger Abstand zwischen Checkbox und Beschriftung: einheitliche 8 px, explizit gegen bestehende Inspector-Styles abgesichert.
5. Farbig wirkende Kachelränder: Auswahl als Fläche unter dem Bild; keine dekorativen Konturen.
6. Ein globaler Raum für alle Shots: Locations sind ausdrücklich wiederverwendbare Objekte mit Zuordnung pro Shot.
7. Verwechslung von Clay-Clips mit bestätigten Provider-Eingaben: der Dummy bindet 2D-Snapshots. Seine Kamerafahrt ist eine Vorschau; daraus folgt keine behauptete Video-Input-Fähigkeit eines Providers.

## Verifikation

- `check-desktop-production-blocking.mjs`: 34 Prüfungen bestanden — Greenfield, Import, Generic/Music Video, Skip/Reaktivierung, mehrere Locations, Kamera/Scrubbing, Undo, Bindung/Aktualität, Freigaben, Kosten-/Produktionssperren, fehlendes Pack und 130 % UI-Skalierung.
- `check-desktop-production-guards.mjs`: 32 Prüfungen bestanden.
- `check-desktop-production-polish.mjs`: 32 Prüfungen bestanden.
- `check-desktop-production-workbench.mjs`: 35 Prüfungen bestanden.
- Die drei bisherigen Prüfungen des ersetzten schematischen Blockouts wurden auf denselben fachlichen Zweck in der neuen Blocking-Oberfläche umgestellt: Shot-Auswahl bleibt erhalten, Raumansicht besitzt keinen Animatic-Transport, Kamerafahrt-Scrubbing speichert numerische Zeit.
- Standalone-Screenshots bei 1048 px Breite sowie 130 % UI-Skalierung und tatsächliche eingebettete Vorschau visuell geprüft. Inline: 850 px Arbeitshöhe, kein horizontaler Überlauf, alle Icons aufgelöst, sichtbare Clay-Geometrie in Raum-/Kamera-/Vorlagenansicht. Ergebnisse in `checks.json` und `inline-checks.json`.

## Grenzen und native Anbindung

Die Projektion verwendet einfache Volumen und Beispieldaten. Kein vollständiger DCC-Editor, keine echten bpy-Renderings, keine Dateien/Clips, keine Geometrieerzeugung durch einen Agenten und kein semantischer Bildaudit. Keine neuen ausführbaren Provider-Modelle behauptet. Die Bestands-Referenzbilder sind weiterhin illustrative Bilder, keine tatsächlich aus den Clay-Snapshots generierten Resultate.

Die native bpy-Komponente, echte Dateiprovenienz und Provider-Bindung folgen Epic #540 / #541–#546. PR #548 und Runtime-Migration #547 werden in der Implementierungsplanung berücksichtigt; die Providerfähigkeit stammt aus dem tatsächlichen Client/Katalog, einschließlich der parallelen Higgsfield-Integration. Änderungen gesperrter nativer Phasenverträge benötigen weiterhin ihren ausdrücklichen Vertragsentwurf. Der Clickdummy allein erteilt dafür keine Freigabe.
