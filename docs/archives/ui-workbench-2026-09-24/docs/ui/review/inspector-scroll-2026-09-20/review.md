# Inspector: gemeinsame Scrollfläche · 20.09.2026

Befund: Der Studio-Inspector bündelte seine Inhalte bereits, bevor Clay-, Workflow- und Interaktionsmodule ihre zusätzlichen Abschnitte einfügten. „Shotfolge“ stand als direktes Kind neben `.inspector-scroll` im vertikalen Flexlayout. Dadurch blieb es am unteren Rand stehen und verkürzte den sichtbaren Inhalt von „Bildquelle“. Das war eine falsche Inhaltsstruktur, kein fehlender CSS-Abstand.

Korrektur: Die endgültige Inspector-Anordnung läuft nach sämtlichen Modulbeiträgen und nach jedem direkten Inspector-Aufruf. `layoutInspector` verwendet die bestehende Scrollfläche erneut. Kopf und Reiter bleiben außerhalb; alle Inhaltsgruppen sind darin enthalten. Wiederholte Aufrufe erzeugen keine verschachtelten Scrollflächen. Dies erfasst auch Sketch-Erzeugung, Zustände, Abhören und Clay-Inhalte.

Verifikation des statischen Mockups:

- Zwölf Demoansichten: genau eine Scrollfläche, keine Inhaltsgruppen außerhalb, keine verschachtelten Scrollflächen (`checks.json`).
- Der gemeldete Zustand wurde aus dem Schnitt-Beispiel mit geöffnetem, bereits freigegebenem Storyboard und Shot 1C nachgestellt. Bildquelle einschließlich Einsatz sowie Shotfolge sind nach Scrollen zum Ende vollständig zugänglich, bei 100 und 130 Prozent UI-Skalierung.
- Auf-/Zuklappen verschiebt nachfolgende Abschnitte im selben Inhaltsfluss. Die Shot-Reihenfolge bleibt im bearbeitbaren Storyboard bedienbar. Wiederholtes Rendern, Shot- und Moduswechsel erzeugen keine zusätzlichen Scrollflächen. Nachträglich angebotene Sketch-Erzeugung wird ebenfalls aufgenommen.
- Screenshots für Storyboard, Audio, Shotplanung, Blocking und fehlenden Sketch visuell geprüft. Keine JavaScript-Laufzeitfehler.
- Der freigegebene Stand bleibt absichtlich schreibgeschützt; seine Felder werden erst nach expliziter Revision bearbeitbar. Keine Änderung an Phasenfreigaben.

Kein nativer App-Build/-Start; kein erneuter vollständiger Workflow-Abnahmetest.
