# Diagnose-Build

Dieser Build instrumentiert den bestehenden Produktionspfad. Er enthält keinen
nachgewiesenen Fix für den gemeldeten UI-Hänger und keinen spekulativen Layout-Umbau.
Das externe Review entfällt für diesen Build auf ausdrücklichen Wunsch des Owners;
die automatisierten Prüfungen werden nicht übersprungen.

## Bedienung

Beim ersten normalen Start zwischen verschlüsseltem Replay-Inhalt, reiner Strukturspur
und deaktivierter Aufnahme wählen. Der Hilfemenü-Eintrag zur Diagnose erlaubt Stoppen,
Export und Löschen. Nach einem Moduswechsel ist ein Neustart nötig.

Bei einem Stillstand sichert der Helfer den Vorfall automatisch. Bei Erholung oder
erneutem Start wird die gespeicherte Diagnose einmal angeboten. Bestätigte Hinweise
erscheinen nicht bei jedem Neustart erneut. Das Programm wird vom Helfer
nicht beendet oder neu gestartet. Projekte und laufende Generierungen bleiben unverändert.

Export benennt Sitzungen mit Datum und Hang-Status und wählt Hang-Aufnahmen zuerst.
Der Hinweis zu einem gespeicherten Hang exportiert direkt die betroffene Aufnahme;
bei mehreren Aufnahmen wird eine lesbare Auswahl angeboten. Der Speichern-Dialog
startet in Downloads, anschließend zeigt Finder die erzeugte ZIP-Kopie.
Bei Replay-Inhalt wird der Schlüssel separat angeboten;
er gehört nicht in dasselbe öffentliche Issue oder dieselbe öffentliche Ablage wie das
Paket. Ohne den Schlüssel ist der verschlüsselte Inhalt nicht lesbar. Es gibt keinen
automatischen Upload der Diagnoseaufnahme.

Aufnahmen liegen unter `~/Library/Logs/NexGenVideo/HangIncidents/<Start-ID>/`.
Löschen entfernt lokale Aufnahmeordner und ihre Schlüssel, nicht das Projekt, alte
Crashlogs oder bereits exportierte Kopien. Fremde laufende NGV-Instanzen werden nicht
beeinflusst. Hang-Aufnahmen, Replay-Inhalte und für Export vorgemerkte Aufnahmen werden
nicht automatisch gelöscht. Nur ungeschützte, nicht aktive Struktursitzungen werden
nach sieben Tagen beziehungsweise oberhalb von zwei älteren Sitzungen bereinigt.
Automatische Bereinigung löscht keine Schlüssel. Ab 1 GB vorhandener Diagnosedaten
startet keine weitere Aufnahme; vorhandene Evidenz bleibt erhalten.

## Analyse

`scripts/analyze_hang_diagnostics.py <entpackter-Start-ID-Ordner>` überprüft die
SHA-256-Inhaltsliste und meldet fehlende Samples, verworfene Ereignisse, letzte
beobachtete Zustände und begonnene Operationen ohne aufgezeichnetes Ende. Das Ergebnis
ist Evidenz, keine automatische Ursachenfeststellung.

Stacks enthalten Thread-IDs, Adressen sowie geladene Binary-UUIDs und Ladeadressen.
Zur Symbolisierung nur die UUID-passenden dSYMs aus dem zugehörigen Build verwenden.
Der Release-Workflow archiviert Host, Helfer, Engine und gebautes Pack zusammen mit
der exakten signierten App für 90 Tage. Die Archive vor Ablauf sichern, wenn die Analyse
noch läuft; Symbole eines abweichenden Builds sind kein Ersatz.

Offline-Replay startet mit `NGV_DIAGNOSTIC_REPLAY=<Start-ID-Ordner>` und
`NGV_DIAGNOSTIC_KEY_FILE=<separate-Schlüsseldatei>`. Er verwendet aufgezeichnete
Zeitabstände und den echten Transcript-Renderer, startet aber keinen Agenten.

## Grenzen und Abnahme

Replay erfasst gezeigte Chattexte/-bilder, Dialoge, Spend-Karten und ausgewählte
Projektzustände. Bibliotheksmedien und kanonische Pipeline-Artefaktdateien werden nicht
kopiert; Pack-Binaries werden nicht eingebettet. Fenster-/Scroll-Geometrie steht im
Journal, wird vom Replay jedoch nicht automatisch wiederhergestellt. Diese Lücken
stehen auch in `export.json`; ein identischer Owner-Hänger ist damit nicht garantiert.

Die Versandprüfung arbeitet ausschließlich mit synthetischen Daten. Am signierten
Release-Artefakt müssen Wait, CPU-Spin, zwei getrennte Stack-Erfassungen, passende
Symbolisierung, Erholung, verschlüsselter Export, normaler Replay, ein nachweislich
erreichter injizierter Replay-Hänger und Finalisierung nach Force-Quit bestehen.
Sechs zusätzliche App-Starts müssen die gesicherten Hang-Aufnahmen und den ursprünglichen
Replay-Schlüssel erhalten. Checksummen-/Pfadschutz, Secret-Schwärzung und begrenzte Ereignispuffer werden separat
getestet. Ergebnisse stehen im jeweiligen Actions-Lauf, nicht als pauschale Behauptung
in diesem Dokument. Die CPU-/RAM-/Latenz-Zielwerte des Konzepts sind noch keine
gemessenen Zusagen.
