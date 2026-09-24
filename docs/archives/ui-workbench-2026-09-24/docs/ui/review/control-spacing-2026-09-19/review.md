# Gemeinsame Auswahlfelder und Interaktionsbereich

Der vorherige Review war zu eng: Er korrigierte die Einstellungen, ließ aber den nachgelagerten Interaktionsbereich mit eigenen abweichenden Regeln bestehen. Im gezeigten Modellfähigkeiten-Auftrag fehlte der Abstand zwischen Checkbox und Text. Radio-Buttons erhielten zusätzlich den Einzug gewöhnlicher Texteingaben.

## Änderungen

- Eine gemeinsame Auswahlkomponente für Checkboxen und Radio-Buttons: 16 px Kontrolle, 8 px Textabstand, Ausrichtung an der ersten Textzeile und passende Einrückung umbrochener Beschriftungen. Dialoge und Inspector bestimmen nur noch ihre äußeren Gruppenabstände.
- Aufgaben besitzen eine gemeinsame linke Achse für Überschrift, Beschreibung und erste Optionsspalte. Optionen stehen im gleichen responsiven Raster; optionale Eingaben in einer eigenen Formularzeile. Aktionen bleiben in einer getrennten rechten Spalte und umbrechen in schmalen Vorschauen.
- Nach Auswahl bleibt der Tastaturfokus an derselben Option. Die Auswahl- und Freigabelogik bleibt erhalten.
- Der Medienfilter verwendet dieselbe Komponente. Bei wenig Platz erhält das Suchfeld eine eigene Reihe, abhängig von der Pane-Breite. „KI-generiert“ wird nicht mehr vom Sortierfeld abgeschnitten.

## Prüfung

Der Bedienweg Einstellungen → Modelle → Fähigkeiten prüfen wurde im eingebetteten Clickdummy geöffnet und visuell geprüft (`inline-model-research.png`). Ebenfalls gesichtet: Checkbox- und Radio-Aufträge, optionale Eingabe, schreibgeschützte Vorschau, abgeschlossenes Ergebnis, Video-Batch, Einstellungen, MCP, Take-Review, Generator, Schnitt-Inspector, Export und Medienfilter. Schmale Aufträge bei 130 % sind in `narrow-full-model-research.png` und `narrow-full-music.png` dokumentiert; der Aufgabenbereich bleibt scrollbar.

Der vollständige Aufgaben-Katalog umfasst 30 Varianten. Bei 1048, 768 und 390 px sowie 100 und 130 % Skalierung wurden deren Auswahlabstände gemessen. Zusammen mit den zusätzlichen Dialog-/Inspector-/Exportzuständen: 193 Zustände und 388 sichtbare Auswahlkontrollen, ohne Abweichungen bei Abstand, Kontrollgröße, Zeilenmitte oder Labelbegrenzung (`measurements.json`). Die Media-Beschriftung wurde zusätzlich anhand ihrer tatsächlichen Textfläche und der Nachbarcontrols bei vier Breiten und beiden Skalierungen geprüft (`final-visual-checks.json`).

Klick auf die Beschriftung, Leertaste, Fokus nach Änderung, exklusive Radio-Auswahl, optionale Ergänzung, schreibgeschützte Vorschau und Übernahme des Modellergebnisses wurden bedient. Alle Prüfungen bestanden. Vorhandene Prüfungen: 31 Guard-Prüfungen und 32 Polishing-Prüfungen bestanden. Diese Zahlen belegen die genannten Prüfbereiche, keine vollständige Prüfung aller denkbaren Produktzustände.

Nur Clickdummy und seine Spezifikation geändert. Keine native App gestartet oder gebaut; keine Änderung der Engine- oder Pipeline-Verträge.
