# Review der Kontextmenüs · 20.09.2026

## Befund und Korrektur

Der vorherige Stand war nicht konsistent: Storyboard-Kontextmenüs verwendeten eine eigene Bedienung, Medien und Timeline ein anderes Popover. Der Rechtsklick reduzierte Medien-/Clip-Mehrfachauswahlen; viele Clip-Befehle erschienen unabhängig von Auswahl, Spurensperre und Arbeitsbereich aktiv. Ordner, Titel und weitere Objekte hatten keine eigenen Kontextmenüs. Außerhalb des Storyboards bestand das Shot-Menü überwiegend aus allgemeinen Ansichtswechseln.

Die überarbeitete Workbench verwendet eine gemeinsame Menükomponente mit objektbezogenen Befehlen. Sie greift auf die vorhandenen Aktionen, Daten und Bestätigungsdialoge zurück. Dieselben Befehle und Verfügbarkeiten stehen im Menü Bearbeiten. Die Ausführung prüft den aktuellen Zustand erneut. Es wurde keine native Pipeline oder Produktionsfunktion geändert.

| Oberfläche / Objekt | Kontext |
|---|---|
| Medien und Inhaltssuchtreffer | Inspector, Produktionszuordnung, Umbenennen, Verschieben, Dateiort, gegebenenfalls Relink, Entfernen |
| Medienordner / Leerfläche | Import, Generierung, Ordner anlegen; am Ordner zusätzlich Umbenennen und Entfernen |
| Kompakter Quellen-Picker | Vorschau, Produktion/Medien zeigen, im Schnitt Einsetzen/Überschreiben; keine zweite Medienverwaltung |
| Storyboard-Shots | Sketches, Umbenennen, Verschieben, Einfügen, Teilen, Löschen; ausdrückliche Revision bei Freigabe |
| Sketch-Momente | Handlung/Zeitpunkt, Bildzuordnung, weiterer Moment, Projektmedium |
| Shotplanung | Eigenschaften, Quellen, Blocking, Storyboard, gegebenenfalls Revision |
| References | Identitätsänderung als Vorschlag; Ankervergleich, Medienzuordnung und Sichtung am konkreten Shot |
| Video-Takes | Exakter Take im Viewer, Projektmedium, weiterer Take über Kostenprüfung; keine stillschweigende Auswahl |
| Blocking | Objekt-/Anfangs-/Endposition, Szene/Draufsicht, Kamera, Location-Kopie und konkrete Clay-Vorlage |
| Audioanalyse | Abschnitt abhören, Schleife mit Checkmark, Messdetails |
| Schnitt-Clips | Auswahlbezogene Schnittbefehle; Einzelbefehle bei Mehrfachauswahl deaktiviert; keine Teilmutation einer teilweise gesperrten Auswahl |
| Titel / Spuren / Keyframes | Jeweils eigene Aktionen; belegte/gesperrte Spur nicht entfernbar; Sperre und Stummstatus mit Checkmark |
| Postproduction | Copy, Inspector, Quelle, Sichern; Montagebefehle gehören zum Schnitt |
| Endkontrolle | Befund/Korrektur/Abweichungsdialog; Filmstreifen führt zum exakten Clip im Schnitt |
| Exportverlauf | Details, weitere Ausgabe; Stoppen ausschließlich am aktuell laufenden Auftrag; kein simulierter Finder-Erfolg |
| Textfelder, Einstellungen, normale Buttons | Keine künstlichen Objektmenüs; vorhandene Text-Systemmenüs beziehungsweise explizite Aktionen bleiben zuständig |

## Im Review zusätzlich behoben

- Verzögerte Scroll-Ereignisse konnten ein frisch geöffnetes Menü schließen. Das Schließen reagiert jetzt auf eine tatsächliche Positionsänderung seit der Öffnung.
- Rechtsklick beziehungsweise Control-Klick darf keinen Trim, Auswahlrahmen oder Clay-Drag beginnen.
- Menü- und Inspector-Verfügbarkeit für Medienaktionen waren unterschiedlich; Einzeldatei-Aktionen sind bei Mehrfachauswahl in beiden Flächen gesperrt.
- Eine Workflow-Datei lässt sich nicht durch die Medienverwaltung aus ihrer laufenden Artefaktzuordnung entfernen.
- Quellen-Picker enthalten keine wirkungslosen Verwaltungsbefehle. Navigation zur Medienverwaltung erhält die exakte Medienauswahl.
- Fokus kehrt nach Escape zum Objekt zurück und folgt beim Wechsel zum Schnitt dem betreffenden Clip.
- Postproduction-Menüs enthalten keine lange Liste deaktivierter Montagebefehle. Destruktive Einträge stehen getrennt am Ende, Toggle-Zustände sind explizit.

## Nachweis

`check-desktop-production-context.mjs`: **56 Szenarien bestanden, keine JavaScript-Laufzeitfehler**. `checks.json` enthält die Einzelbefunde; `inventory.json` die erfassten Menüs der Hauptoberflächen. Die visuellen Nachweise liegen im selben Ordner.

Geprüft wurden unter anderem Mehrfachauswahl, Einzelaktionen, gesperrte Spuren, freigegebene Storyboards, Medien-/Take-/Clip-Zuordnung, Ordner-Umbenennung, Clay-Bestätigung nur des Zielshots, Keyframe-Löschen mit Undo, Auswahl per Tastatur, Tastaturöffnung und Escape, Control-Klick, Konsistenz zum Menü Bearbeiten, Menüränder bei 130 Prozent Schriftgröße sowie echte Maus-Rechtsklick- und Drag-Ereignisse. Der Storyboard-Drag zeigt weiterhin die Einfügemarke und erreicht die erwartete Reihenfolge; die einheitliche Inspector-Scrollfläche bleibt erhalten.

Screenshots wurden auf Kompaktheit, Ausrichtung, Gruppierung, Auswahlmarkierung, deaktivierte Einträge und Überlagerungen geprüft. Der Render-/Export-Szenario verwendet eine simulierte Ausgabe. Die Bibliotheks-Kachel und Listenzeile verwenden dieselbe Objektbindung; die visuelle Prüfung der Medienmenüs erfolgte in der Kachelansicht.

Grenze: Das ist die Prüfung des statischen Clickdummys, keine Abnahme von AppKit, VoiceOver oder nativen Datei-/Renderoperationen. Die native Umsetzung soll die Befehlsdefinitionen mit NSMenu/SwiftUI, bestehender Auswahl und Harness-Gates verbinden. Die Prüfungen behaupten keine erneute vollständige Funktionsparität aller nativen Module.

## Primärquellen

- [Apple HIG: Context menus](https://developer.apple.com/design/human-interface-guidelines/context-menus): objektbezogene, kompakte Aktionen; Befehle auch in der Menüleiste; destruktive Aktionen am Ende.
- [Final Cut Pro: Select clips](https://support.apple.com/en-mide/guide/final-cut-pro/ver28912fd/mac): clipbezogene Einzel-/Mehrfachauswahl und die Rolle der Auswahl für Bearbeitungsbefehle.

Die allgemeine Workbench bleibt an der dokumentierten Wettbewerbsanalyse von Final Cut Pro, DaVinci Resolve und LTX orientiert. In diesem Review wurden die oben genannten Apple-Primärquellen neu geprüft; keine neue vollständige Wettbewerbsanalyse behauptet.
