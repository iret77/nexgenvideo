# Shot-Aktionen am Objekt · 20.09.2026

Der Inspector enthielt Verschiebepfeile in einer aufklappbaren Gruppe. Das bisherige Kontextmenü bot nur Ansichtswechsel. Diese Zuordnung war für die Storyboard-Arbeit unzureichend.

## Bedienung

- Shotfolge-Gruppe entfernt. Name ist bei Handlung bearbeitbar und nutzt die verfügbare Inspector-Breite.
- Kontextmenü direkt an der Kachel: Sketches öffnen, Umbenennen, einen Platz nach vorn/hinten, an den Anfang/das Ende, Einfügen, Teilen, Löschen. Freigegebene Storyboards bieten die ausdrückliche Revision; Schreibaktionen bleiben gesperrt.
- Dieselben Aktionen in Bearbeiten; dort verwendet Löschen den vorhandenen Standardbefehl, ohne doppelten Eintrag.
- Rechtsklick erhält eine bestehende Mehrfachauswahl, wenn der angeklickte Shot dazugehört. Ein Klick auf einen anderen Shot wählt diesen als Ziel.
- Drag zeigt eine neutrale Einfügemarke vor/hinter der Zielkachel. Mehrere Shots behalten ihre relative Reihenfolge. Einzelne Vor-/Zurückbewegungen bewegen ausgewählte Shots über ihre jeweils angrenzenden, nicht ausgewählten Nachbarn.
- Escape/Klick außerhalb schließen das Kontextmenü. Pfeiltasten und Enter bedienen es; Control-Klick und die Kontextmenütaste/Shift-F10 öffnen es ebenfalls. Randaktionen bleiben deaktiviert.
- Filmfolge, stabile Shot-IDs und Story-Welt-Zeit bleiben getrennt. Vorhandene Reindexierung und Rückgängig-Historie werden weiterverwendet.

## Review und Prüfung

17 Bedienprüfungen bestanden (`checks.json`), einschließlich Mehrfachauswahl, Datenbindung, Undo/Redo, Umbenennen, Freigabesicherheit, Tastaturbedienung und Positionierung bei 130 Prozent UI-Skalierung. Zusätzlich echter Maus-Rechtsklick und echtes Ziehen im Browser geprüft (`final-checks.json`): Shot 1A wurde hinter 1C eingefügt; die Einfügemarke erschien während des Ziehens und verschwand danach. Der erste Maus-Drag-Test hatte bei den Bewegungen den gedrückten Button nicht mitgesendet; nach Korrektur der Eingabesimulation bestand der Test ohne weitere Produktänderung.

Im visuellen Review wurden eine fehlende Shortcut-Vorbelegung (sichtbares „undefined“), ein doppelter Löschbefehl im Menü Bearbeiten und die Button-Umrandung innerhalb des Kontextmenüs korrigiert. Die Fokusmarkierung erfolgt als gefüllte Auswahl. Einzel-/Mehrfachauswahl, freigegebener Stand, Umbenennen und Drag wurden visuell geprüft. Keine JavaScript-Laufzeitfehler.

Statischer Clickdummy; keine native App gebaut oder gestartet. Keine Freigabe zur Änderung gesperrter Pipeline-Verträge.

## Referenzen

- [Apple HIG: Context menus](https://developer.apple.com/design/human-interface-guidelines/context-menus): objektbezogene Aktionen, entsprechende Befehle auch in der macOS-Menüleiste, destruktive Aktionen am Ende.
- [Final Cut Pro: Arrange clips](https://support.apple.com/en-in/guide/final-cut-pro/verc147f195/mac): direkte Anordnung per Drag mit sichtbarer Zielposition.
