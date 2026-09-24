# Medien als eigener Arbeitsbereich

Review des überarbeiteten Clickdummys vor Präsentation. Ersetzt das Bedienmodell aus `media-browser-review-2026-09-17.md`; dessen Codebelege bleiben als Recherche erhalten. Kein nativer App-Code geändert.

## Aufgaben und Grenzen

- Oben genau vier Arbeitsbereiche: **Medien · Produktion · Schnitt · Finish**. Medien hat keinen Phasenstatus, keine Freigabe und keine Timeline.
- Medienverwaltung nutzt die volle Arbeitshöhe: verschachtelte Ordner links, Dateiansicht in der Mitte, unabhängig schaltbare Vorschau/Details rechts. Import, Ordnernamen, Mehrfachauswahl, Verschieben, Filter, Sortierung und Miniaturgröße liegen hier.
- Produktion und Finish bieten einen kompakten Quellen-Reiter; der Schnitt hält einen kompakten Quellenbrowser neben dem Viewer. Dort werden Quellen gefunden, angesehen und zugewiesen bzw. in die Timeline eingefügt. Keine zweite Verwaltungsoberfläche.
- „In Medien zeigen“ findet dasselbe Asset im großen Browser. Rückkehr stellt den vorherigen Arbeitsbereich samt Auswahl, Ansicht und Zeitposition wieder her. Präsentationszustände sind getrennt, Medienmodell und Montage bleiben gemeinsam.
- Import ist weiterhin keine Workflow-Zuweisung. Texte sind Dokumente; weder Lyrics noch Treatments werden zu Titelclips. Projektdokumente lesen den aktuellen kanonischen Inhalt und verweisen zur Bearbeitung auf die zuständige Phase.

## Visuelle Prüfung

Gerenderte Medienansicht, Textvorschau und Schnitt mit Quellen-Picker geprüft. Den bereits recherchierten offiziellen Resolve-Edit-Screenshot nochmals betrachtet: durchgehende Arbeitsflächen, lokale Werkzeuge, feste Panelgrenzen und die Montage unter Viewer/Browser bleiben die Orientierung. Der Medien-Arbeitsbereich folgt der Aufgabenaufteilung; er kopiert nicht die vollständige Resolve-Werkzeugfülle.

Bei 1024 px zeigt die Dateiansicht drei Miniaturen nebeneinander; der Ordnerbaum und die ausgewählte Vorschau bleiben gleichzeitig sichtbar. Bei 736 px wird die Mitte enger; Panel-Icons und Splitter bleiben unabhängig bedienbar. Unter 650 px steht der Inspector unter der Arbeitsfläche. Die schmalen Vorschauen sind keine Vorgabe für eine mobile NGV-App.

Keine zusätzliche globale Werkzeugzeile, keine farbigen Rahmen und keine Dashboard-Karten. Music-Video-Akzent auf aktiver Arbeitsbereichswahl und ausgewählten Flächen. Kleine Panel-Icons bleiben dauerhaft erreichbar. Textvorschau enthält keine erfundenen Video-Metadaten oder Wiedergabesteuerungen.

## Gefunden und behoben

1. Zu große Standardminiaturen ließen bei 1024 px nur zwei Spalten zu. Die neue Standardgröße nutzt drei Spalten; der Größenregler bleibt verfügbar.
2. Die Suche konnte die visuelle Mehrfachauswahl und ihre Sammelaktion stehen lassen, obwohl der Auswahlzustand bereits geleert war. Treffer, Markierungen und Sammelaktion werden jetzt konsistent aktualisiert; der Suchfokus bleibt erhalten. Die zuletzt geöffnete Vorschau bleibt bewusst sichtbar und ist kein ausgewählter Stapel.
3. Wechsel zwischen Liste und Miniaturen, Sortieren und Aufklappen des Ordnerbaums löschten die Auswahl. Diese reinen Ansichtsaktionen erhalten nun die Mehrfachauswahl.
4. Beim Rückkehren konnten gespeicherte Medien-IDs inzwischen entfallene Takes referenzieren. Wiederherstellung bereinigt nicht mehr vorhandene IDs, bevor eine Quellvorschau gezeichnet wird.
5. Die Quellen-Picker enthielten zunächst noch Organisationsaktionen. Diese sind jetzt ausschließlich in Medien zugänglich. Der Schnitt behält Quellvorschau, Einfügen und Drag-and-drop in seine Timeline.
6. Alte Beschreibungen nannten noch drei Arbeitsbereiche bzw. die Sidebar-Reiter „Medien“. Die aktuelle Spezifikation benennt die vier Arbeitsbereiche und die kompakten „Quellen“-Reiter eindeutig.

## Interaktive Verifikation

**169 Ablaufprüfungen bestanden, keine Fehler.** Dazu gehören Import ohne Zuweisung, 400 zusätzliche Textdateien, Fokus bei Suche, Mehrfachauswahl, Ordneroperationen mit Undo, konsistente Filter-/Auswahlzustände, Quellen-Drag in V1 sowie unveränderte Shotplanung. Medienwechsel erhält Storyboard-/Animatic-Zeit, Quellvorschau und Montage.

30 Layoutfälle: Medien, Storyboard, Sketch-Momente, Produktions-Picker, Schnitt und Finish bei 1440, 1024, 736, 500 und 320 px. Kein horizontaler Überlauf über 1 px; die Desktop-Arbeitsfläche bleibt 850 px hoch statt von der einbettenden Framehöhe abzuhängen.

Zusätzlich acht Browserprüfungen mit echten Maus-/Tastatureingaben und Layoutmessungen: Strg-Mehrfachauswahl, Suchen ohne Fokusverlust, Asset in Medien zeigen und Rückkehr in die Quellansicht. Drag-and-drop wurde separat durch Browser-DragEvents geprüft, nicht als systemweiter Dateidrag.

Belege: `desktop-workbench-checks.json`, `desktop-workbench-layouts.json`, `media-workspace-checks.json`. Automatische Prüfungen ergänzen die vorstehende Sichtprüfung.

## Native Umsetzung und verbleibende Lücken

Der [Funktionsabgleich](native-feature-coverage-2026-09-17.md) nennt vorhandene native Implementierungen, fehlende Darstellung und passende Zielorte. Bestehende Mediensuche, Relink, Kontextaktionen, Captions, KI-Bearbeitung, Audio-Synchronisierung, Take-/Sequenzreviews und Ausgabeformate sind zu bewahren. Ihre Erwähnung ist keine Behauptung, dass sie hier schon vollständig simuliert wären.

Die native Trennung verlangt einen zusätzlichen Medien-Workspace und zwei Präsentationen des bestehenden Medienmodells; keine neue Bibliothek und keinen neuen Harness-Schritt. Rekursive Ordnersuche und die Projektdokument-Verknüpfung bleiben begrenzte zusätzliche Adapterarbeit. Die HTML-Logik ersetzt keine Writer, Lineage-, Kosten- oder Freigabeprüfungen.

Import, Beispielvorschauen, Wiedergabe und Provideraufträge bleiben simuliert. Keine nativen Builds, Tests, App-Starts oder Dev-Server ausgeführt.
