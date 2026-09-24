# Einstellungen: Layoutkorrektur

Der Screenshot des Owners zeigte drei konkrete Fehler: Das Zahlenfeld stand am rechten Rand statt auf einer Kontrollachse, Checkboxen übernahmen das Blocklayout gewöhnlicher Dialoglabels, und für die verwendete Dialogfußzeile fehlte die Flex-Ausrichtung vollständig.

## Korrektur

- Alle sechs Einstellungsbereiche verwenden eine gemeinsame Label- und Kontrollspalte. Labels sind rechtsbündig, Felder, Werte, Checkboxen und Aktionen beginnen auf derselben Achse.
- Checkbox und Beschriftung haben 8 px Abstand; mehrzeilige Beschriftungen bleiben am ersten Kontrollpaar ausgerichtet. Formulargruppen haben 16 px Abstand.
- Titel, Bereichsleiste und Fußzeile teilen dieselben Außenachsen. Schließen steht rechts; die Fußzeile hat 20 px Abstand zum Inhaltsbereich.
- Lange Inhalte scrollen innerhalb des Dialogs. Titel und Fußzeile bleiben außerhalb dieses Scrollbereichs. Auf schmalen Vorschauen werden die Formularspalten gestapelt und die Bereichstasten in zwei Reihen angeordnet.
- Die gemeinsame Dialogkorrektur umfasst auch Checkboxabstände und Fußzeilen der anderen Studio-Dialoge. Projekteinstellungen und MCP-Verbindung wurden zusätzlich gesichtet.

## Review und Verifikation

Alle sechs Einstellungsbereiche bei 1048 px visuell gesichtet; schmale Darstellung bei 390 px aufgenommen und auf Überlauf geprüft. Allgemein und Modelle zusätzlich in dieser schmalen Darstellung visuell gesichtet. Alle sechs Bereiche bei 130 % UI-Skalierung auf Überlauf geprüft. Kein horizontaler Überlauf; Checkboxabstand jeweils 8 px; Kontrollachsen innerhalb jedes Bereichs identisch. Messwerte stehen in `measurements.json`.

Die eingebettete Vorschau wurde separat aufgenommen und gesichtet (`inline-general.png`). Titel, Bereichsleiste und Fußzeile haben im Frame exakt dieselben linken und rechten Koordinaten. Checkboxbedienung, Skalierungsänderung und Schließen funktionieren.

Vorhandene statische Clickdummy-Prüfungen: 35/35 Workbench-Prüfungen und 31/31 Guard-Prüfungen bestanden, einschließlich Modell-/Provider-Auswahl und ausdrücklichem MCP-Vertrauen. Keine nativen Builds oder Tests; keine Änderungen an Swift, Engine, Pipeline oder Pack-Verträgen. Diese Prüfung betrifft die Dialogkorrektur, keinen erneuten vollständigen Produktreview.
