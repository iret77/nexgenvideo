# Medienpool: Ordner und Texte

Historische Zwischenstufe. Das Bedienmodell wurde durch den [eigenen Medien-Arbeitsbereich mit kompakten Quellen-Pickern](media-workspace-review-2026-09-17.md) ersetzt. Die folgenden Codebelege bleiben gültige Recherche; Breiten und Anordnung beschreiben die frühere Fassung.

## Abgleich mit NGV

- `Sources/NexGenVideo/Models/ClipType.swift`: `.document` ist bereits ein dateigebundenes Textdokument, ausdrücklich von `.text` (Titel im Schnitt) getrennt und nicht auf der Timeline platzierbar. Unterstützt TXT, MD/Markdown, RTF und Fountain. Keine neue Medien-Engine erforderlich.
- `MediaPanel/MediaTab/MediaImportFlow.swift`: Import akzeptiert diese Textformate bereits. Der Dummy ergänzt die sichtbare Kategorie „Texte“ und einen Lyrics-Beispielimport.
- `MediaPanel/MediaTab/MediaTab.swift`: Ordneransicht, flache/gruppierte Ansichten, Typfilter, Suche, Sortierung und Breadcrumbs bestehen schon.
- `Editor/ViewModel/EditorViewModel+Folders.swift`: Ordner sind verschachtelt; Anlegen, Umbenennen, Verschieben sowie Undo existieren. Diese Operationen wiederverwenden. Kein neues Dateisystem oder paralleler Medienbestand.
- Der Dummy filtert ausgewählte Ordner ausdrücklich einschließlich Unterordner. Nativ liefert `assetsIn(folderId:)` direkte Kinder. Rekursive Sammlung ist eine begrenzte Erweiterung des Browsers; Ordneridentitäten und Medienreferenzen bleiben erhalten.
- Die live gelesenen Briefing-/Treatment-/Skript-Einträge simulieren einen Index der kanonischen Phasendokumente. Diese Verknüpfung ist noch separat anzubinden, statt eine zweite editierbare Kopie in der Mediathek zu schaffen. Änderungen erfolgen weiterhin im jeweiligen Phasen-UI über bestehende Writer/Gates. Die Kategorie „Texte“ bildet `.document` ab; Sketches/References sind Bildrollen, keine vorgeschlagenen neuen nativen ClipTypes.

## Bedienmodell

Ein gemeinsamer Projektbestand, keine separate Bibliothek je Workspace. Links Ordner, daneben Medien; bei sehr schmalem Panel gestapelt. Schnitt startet mit einem 340 px breiten Browser, maximal 36 % des sichtbaren Fensters. Der Splitter erlaubt bis 480 px. Die übrigen Workspaces behalten ihre kompakte Phasennavigation. Ein Reiterwechsel verändert keine Panelbreite automatisch.

Ordnerwahl, Dateityp und Namenssuche kombinieren sich sichtbar. Ordnerzähler zählen alle enthaltenen Medien, der Fuß zählt die aktuellen Treffer. Eine leere Kombination bietet „Filter zurücksetzen“, statt stillschweigend den Typ zu ändern. Listen-/Miniaturansicht und Sortierung gelten für denselben Bestand. Import erfolgt im gewählten Ordner; Zuweisung als Lyrics, Track oder Shotquelle ist separat. Ordnerbewegungen ändern weder Shotidentität noch Phase oder Freigabe.

Dokumentauswahl öffnet lesbaren Text im vorhandenen Viewer. Timeline, Trims und ausgewählte Takes bleiben erhalten. Dokumente haben keinen Video-Transport, keine Bildrate und keinen Timeline-Einfügen-Button. Der Editor-Titel-Button erzeugt weiterhin einen separaten Titelclip.

## Visuelles und interaktives Review vor Präsentation

Verglichen mit dem bereits recherchierten offiziellen Resolve-Edit-Screenshot: Bin-Hierarchie neben dem Dateibrowser, kleine lokale Icons, feste Panelgrenzen und durchgehende Timeline. Keine zusätzliche globale Werkzeugzeile, keine farbigen Rahmen, keine Dashboard-Karten.

Gefunden und behoben:

1. Ein zunächst oberhalb der Dateien angeordneter Ordnerbaum ließ im Schnitt nur zwei Dateizeilen übrig. Bei ausreichender Panelbreite stehen Baum und Browser nun nebeneinander; mehr als 240 px nutzbare Dateilistenhöhe bei der geprüften 1024-px-Ansicht.
2. Die bisherige Quellansicht zeigte Video-Metadaten auch bei Nicht-Videomedien. Texte bekommen eine eigene lesbare Darstellung und typspezifische Information, einschließlich der Viewer-Werkzeugzeile.
3. Neurendern bei Dateiauswahl setzte die Scrollposition zurück. Dateiliste und Ordnerbaum behalten ihre Position. Suche behält Eingabefokus.
4. Editor-Tastaturkürzel reagierten auch aus dem Medienbrowser heraus. Ordner-/Dateinavigation ist nun auf den Browser begrenzt und verschiebt keinen Timeline-Abspielkopf.
5. Alte gespeicherte Mockup-Zustände hätten den zu schmalen Browser wiederhergestellt. Schema 7 ergänzt Medienorganisation und migriert alte Standardbreiten im Schnitt; neue Einstellungen bleiben erhalten.

Verifiziert: 155 Ablaufprüfungen einschließlich 400 zusätzlicher Textdateien, gezielter Suche, Scope-Leerzustand, Lesen freigegebener Dokumente, expliziter Lyrics-Zuweisung, Ordneroperationen und Undo. Browserlayouts in 1440, 1024, 736, 500 und 320 px. Zusätzlich echte Maus-/Tastatureingaben für Textauswahl und Suche sowie Sichtprüfung von Text- und Miniaturansicht. Automatisierte Belege stehen in `desktop-workbench-checks.json`, `desktop-workbench-layouts.json` und `media-browser-checks.json`.

## Grenzen

Nur Clickdummy-Dateien geändert. Import, Dateivorschau und Dokumentinhalte sind simuliert; keine nativen App-Builds oder Starts. Native Mehrfachauswahl und Drag-and-drop bleiben erhalten, werden hier nicht vollständig simuliert. Der 400-Dateien-Bestand ist ein lokaler Prüffall, kein künstlich aufgeblähtes Demoprojekt. Große Testzustände werden nicht in die begrenzte Widget-Persistenz geschrieben.
