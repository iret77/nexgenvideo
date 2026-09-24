# Review: Bildkachel-Beschriftungen · 20.09.2026

Der vorangegangene Abstandspass betraf nur die Medien-Werkzeugleiste und den Quellen-Picker. Der erneute Befund bei Shot 1C war berechtigt: Die Beschreibung hatte keinen oberen Innenabstand unter der farbigen Titelzeile.

Korrekturen:

- Gemeinsame 8-px-Innenkante für Bildbeschriftungen. Storyboard/Sketch-Momente: 6 px zwischen Auswahlfläche und Beschreibung, 8 px unten, Zeilenhöhe 1,4. Medien/References/Endkontrolle: 4 px zwischen Titel und Metadaten.
- ID, Titel und Dauer im Storyboard haben getrennte Bereiche mit 8 px Abstand. ID und Dauer schrumpfen nicht; lange Titel werden gekürzt. Die frühere Ausblendung von Titeln bei schmalen Fenstern entfällt. Die tatsächliche Pane-Breite und Schriftgröße begrenzen die gewählte Spaltenzahl.
- References/Shot-Anker: geerbtes horizontales Button-Flexlayout entfernt. Das vollständige Bild steht über Titel und Metadaten. Im visuellen Review entdeckt, nicht durch reine Abstandsprüfung.
- Take-Beschriftungen können umbrechen. Vergrößerte UI skaliert Titel und Metadaten konsistent. Kompakte Medienlisten behalten ihre eigenen Zeilenabstände.

Verifikation am statischen Mockup, keine native App-Verifikation:

- Storyboard bei 768, 900, 1048 und 1440 px Fensterbreite, 100/130 % UI-Größe, zwei/drei gewünschten Spalten; ausgewählte und nicht ausgewählte Kacheln, langer Titel. Keine Kachelüberschneidung; alle Shot-Titel bleiben vorhanden. Gemessene Titel-Innenkante und Abstände jeweils 8 px. Die Textoberkante der Beschreibung liegt 7–8 px unter dem Ende der Titelzeile.
- Screenshots visuell geprüft: Storyboard, Sketch-Momente, Referenzidentitäten, Shot-Anker, Takes, Medienraster/-liste, Quellen-Picker und Endkontrolle. Vergrößerte Reference-, Take- und Endkontrollbeschriftungen nach letzter Schriftkorrektur erneut geprüft.
- Auswahl → Inspector, Sketch-Momentwechsel, Medienauswahl/Listenansicht und Endkontroll-Clipwahl funktionieren. Auswahl ändert die Kachelgröße nicht. Keine JavaScript-Laufzeitfehler.
- Ein zunächst fehlgeschlagener Picker-Check lief versehentlich nach dem Wechsel in Postproduction; Reihenfolge korrigiert und Check in Schnitt bestanden.

`geometry.json` und `interaction-checks.json` enthalten die Messungen. Diese Prüfung betrifft Bildkacheln und ihre unmittelbaren Bedienpfade; sie ist keine vollständige erneute Abnahme aller Projektworkflows.
