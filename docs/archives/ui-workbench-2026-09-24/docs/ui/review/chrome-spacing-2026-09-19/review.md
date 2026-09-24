# Titelleiste und Abstände der Leerzustände

Zwei gemeldete Befunde, ausschließlich im Clickdummy korrigiert.

## Ursache und Änderung

Die Titelleiste mischte 12-px-Projektnamen, 13-px-Arbeitsbereiche und 11-px-Formatstatus mit unterschiedlichen Zeilenhöhen. Ihre Container waren zentriert, die Textmetriken jedoch verschieden. Projektname, Arbeitsbereiche und Formatstatus teilen jetzt dieselben Größen und Zeilenhöhen. Der textförmige Projektmenü-Pfeil wurde durch das vorhandene Chevron-Icon ersetzt; Sidebar-Symbole bleiben mittig in ihren Bedienelementen.

Die leere Schnittsequenz setzte beide Buttons unmittelbar in einen spaltenförmigen Flex-Container ohne Abstand. Eine gemeinsame Aktionsgruppe setzt jetzt 8 px Abstand. Die beiden weiteren Leerzustände mit mehreren Aktionen — optionale Vorarbeit und Lyrics — verwenden dieselbe Gruppe.

## Review

Gerenderte Leerzustände und Titelleiste bei 960 und 1048 px sowie 130 % UI-Skalierung visuell geprüft. Zusätzlich Messung bei 768 und 390 px; schmale Ansichten behalten die bestehende mehrzeilige Titelleiste. Sämtliche sichtbaren Titeltexte einer Zeile haben dieselbe gemessene vertikale Textmitte. Die Buttons liegen jeweils 8 px auseinander. Formatstatus bleibt rein informativ; Projektmenü, Workspacewechsel und Sidebar-Schalter behalten ihre Aktionen.

Die 390-px-NLE hatte schon vor dieser Korrektur horizontalen Überlauf außerhalb der Titelleiste; diese Änderung ist kein allgemeiner NLE-Responsive-Review.

`before.json` / `after.json` und zugehörige Browserbilder dokumentieren die Messungen. Die eingebettete Fassung wurde zusätzlich mit leerem Schnitt und Medienansicht visuell geprüft: gleiche Textmitte in allen Titeltexten, 8 px Buttonabstand, 850 px Arbeitshöhe und kein horizontaler Überlauf bei der geprüften Desktopbreite. Keine nativen Quellen geändert, keine Builds oder App-Starts.
