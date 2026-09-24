# NGV-Funktionsabgleich zu Medien und Finish

**Durch den [produktweiten Audit vom 18.09.2026](native-ui-audit-2026-09-18.md) ergänzt und in seiner Gesamtbewertung ersetzt.** Dieser ältere Teilabgleich ist keine vollständige Erhaltungsprüfung. Die [Funktionsmatrix](native-ui-function-matrix-2026-09-18.md) dokumentiert auch die im Dummy falsch eingeschränkte freie Timeline-Nutzung, Postproduction und bislang nicht zugeordnete Core-/Pack-Fähigkeiten.

Geprüfter Code: `8bd8fbde`. Quellen sind Implementierungen und ihre UI-Aufrufstellen, keine Produktversprechen aus Issues. Das ist ein statischer Code-/UX-Abgleich; keine Aussage über bestandene native Laufzeittests. In dieser Änderung wurden ausschließlich Clickdummy und Review-Unterlagen bearbeitet.

## Ergebnis

Der bisherige Dummy war trotz des wiederhergestellten NLEs keine vollständige Darstellung des vorhandenen Produkts. Besonders Mediensuche, Audio/KI-Bearbeitung sowie die Prüf- und Ausgabewege waren unterrepräsentiert. Ihr Fehlen im Dummy darf nicht zur Entfernung oder Neuimplementierung im nativen Refactoring führen.

„Medien“ wird ein vierter **Arbeitsbereich**, kein vierter Produktionsmodus und kein Pipeline-Gate. Produktion, Schnitt und Finish bleiben fachlich unverändert. Verwaltung und Verwendung greifen auf dieselben Asset-IDs, Ordner und Medienbindungen zu.

## In dieser Überarbeitung konkret berücksichtigt

| Vorhandene Funktion | Implementierung | Umsetzung im Dummy |
|---|---|---|
| Manuelle Bild-/Video-/Audiogenerierung mit Prompt, ausführbaren Modellen, Referenzen und Kosten | `Generation/UI/GenerationView.swift`; `Generation/GenerationRequest.swift` | Nach ergänzendem Review als „Generieren…“ im Medienbereich umgesetzt: expliziter Anbieter/Modell, Auftrag prüfen, Budget, Abbruch, freie Medien samt Herkunft. [Details und Grenzen](manual-generation-and-edit-review-2026-09-17.md) |
| Ordner, verschachtelte Ordner, Umbenennen, Verschieben, Undo | `Editor/ViewModel/EditorViewModel+Folders.swift` | In den großen Medien-Arbeitsbereich verschoben; keine Organisationswerkzeuge in den Pickern |
| Mehrfachauswahl und Bereichsauswahl | `MediaPanel/MediaTab/MediaTab.swift` (Marquee), `MediaTab+Grids.swift` | ⌘/Strg-Klick, ⇧-Bereich, ⌘/Strg-A; gemeinsames Verschieben. Marquee selbst bleibt unsimuliert |
| Drag-and-drop zwischen Medien und Ordnern | `MediaPanel/MediaTab/MediaTab+Drag.swift` | Ausgewählte Medien auf einen Ordner ziehen; Undo; kein Einfluss auf Shots |
| Dateityp, KI-Filter, Sortierung, Miniaturgröße | `MediaPanel/MediaTab/MediaTab.swift` | Typ und KI-Herkunft filtern; nach Name/Typ/Dauer sortieren; Liste/Miniaturen; skalierbare Miniaturen |
| Dokumente als Quellen, getrennt von Timeline-Titeln | `Models/ClipType.swift`, `MediaImportFlow.swift` | Lesbare Texte, explizite Lyrics-Zuweisung; Textdateien lassen sich nicht auf V1 ziehen |
| Medien-/Quellclip-Auswahl und Einfügen | `EditorViewModel+PreviewTabs.swift`, `Timeline/TimelineInputController.swift`, `EditorViewModel+Ripple.swift` | Kompakter Picker im Schnitt, eigene Quellvorschau, Einfügen auf V1, Undo. Simulierter V1-Insert verschiebt nachfolgende V1-Clips, Audio bleibt liegen; die vollständigen nativen Insert-/Overwrite-/Linking-Varianten werden damit nicht ersetzt |
| Ein Medium im Browser wiederfinden | `MediaTab.swift` (`revealAsset`) | „In Medien zeigen“ öffnet denselben Eintrag und seinen Ordner. Zurückkehren stellt Picker, Auswahl und Arbeitsstand wieder her |

Die Demo-Kategorien Sketches und References beschreiben Bildrollen. Sie sind keine neuen nativen `ClipType`-Varianten. KI-Kennzeichnungen beziehen sich auf den simulierten Projektbestand und sind kein Provenienznachweis der eingebetteten Beispieldateien.

## Neu vertiefte Lücken – weiterhin nicht vollständig simuliert

Alle Pfade im Folgenden sind relativ zu `Sources/NexGenVideo/`.

| Vorhandene Fähigkeit / tatsächlicher Umfang | Codebeleg | Fehlende Darstellung und Zielort |
|---|---|---|
| Allgemeine Bilddateien und Lottie-Animationen importieren und in der Timeline verwenden | `Models/ClipType.swift: init(fileExtension:), isPlaceable` | Allgemeine Bilder sind inzwischen als Typ und freie Generierung vorhanden. Vollständiger Bildimport, Lottie-Dateien und deren Timeline-Platzierung fehlen weiter. Rollen sind zusätzliche Metadaten, kein Ersatz für Dateitypen |
| **In Bildern und gesprochenem Inhalt suchen**, Treffer mit Zeitbereichen direkt vorhören/ansehen bzw. als Segmente ziehen | `MediaPanel/MediaTab/MediaTab+Search.swift`: `scheduleMomentSearch`, `momentCard`, `spokenRow`, `previewMoment`; `MediaTab+IndexStatus.swift` | Die Dummy-Suche sucht bislang ausschließlich Dateinamen. Im Medien-Arbeitsbereich native Treffergruppen „Moments“, „Spoken“, „Files“ und Indexzustände erhalten; kein frei erfundener Chat- oder Suchdienst |
| Fehlende Medien einzeln oder aus einem Ordner **neu verknüpfen**; Dateityp und Originaldateiname beachten | `Editor/ViewModel/EditorViewModel+Relink.swift`; `MediaPanel/MediaTab/AssetThumbnailView.swift: contextMenuItems` | Offline-Status und Relink gehören in Medien. Dummy hat keine echten fehlenden Dateien; keine vorgetäuschte Dateireparatur |
| Asset umbenennen/löschen, Finder öffnen, Pfad kopieren | `MediaPanel/MediaTab/AssetThumbnailView.swift: contextMenuItems` | Native Kontextaktionen im Medienbereich bewahren. Dummy simuliert Ordnernamen, aber noch nicht sämtliche Dateiaktionen; Löschen muss Bindungen und Undo berücksichtigen |
| **Organize with Agent** | `MediaPanel/MediaTab/MediaTab.swift: organizeWithAgent` | Aktueller Code erzeugt tatsächlich `newChat()`, befüllt `draft` und öffnet Agent-Panel. Passt nicht zum beschlossenen UI. Neuer Einstieg im Medienbereich braucht einen begrenzten, prüfbaren Vorschlag aus Ordner-/Namensänderungen und eine ausdrückliche Übernahme über vorhandene Mutationen. Das ist Adapterarbeit, keine bereits vorhandene chatfreie Funktion |
| Generierungsherkunft: Modell, Prompt, Abmessungen, Quelldatei, auflösbare Generierungsreferenzen | `Inspector/InspectorView.swift: assetDetailsContent`, `fileSection`; `Inspector/Components/GenerationReferencesStrip.swift` | Die Beispielmedien enthalten keine verlässlichen echten Modell-/Promptdaten. Inspector muss diese im nativen Produkt aus der bestehenden GenerationInput-/Medieninformation lesen. Nicht aus Dateinamen erraten |
| **Medien austauschen**, kompatible Ersatzquelle wählen und Swap abbrechen | `Editor/ViewModel/EditorViewModel+MediaSwap.swift`; `MediaTab.swift: swapBanner`; `AssetThumbnailView.swift: isSwapCompatible` | Ein klar zweckgebundener Picker im Schnitt statt eines Umwegs durch Organisation. Keine Kopie der bestehenden Swap-Logik |
| Getrimmten / beschleunigten Clip als neues Medium sichern | `Editor/ViewModel/EditorViewModel+SaveAsMedia.swift` | Schnitt-Kontextaktion; Ergebnis erscheint in derselben Medienbibliothek |
| **Untertitel** aus Speech/Transkription mit Sprach- und Stiloptionen | `MediaPanel/CaptionsTab/CaptionTab.swift`, `CaptionBuilder.swift`, `EditorViewModel+Captions.swift` | Bestehende Oberfläche im Schnitt unter Untertitel/Textwerkzeuge einordnen. Untertitel sind kein Textdokument aus dem Medienpool; aktuelle Titel-Demo ersetzt sie nicht |
| **Musik zu Bild oder aus einer Richtung erzeugen**, ausführbare Modellwahl und Kostenprüfung | `MediaPanel/MusicTab.swift: modelSection`, `generate`, `performGenerate` | Bestehende native Eingaben und Generierung in einer kontextbezogenen Ton-Funktion im Schnitt erhalten; fertige Audiodateien gehören in Medien. Kein automatisch gesetzter Projekttrack |
| KI-Edit auf Auswahl/Quelle, Upscale, Bild als Startframe oder Referenz weiterverwenden | `Inspector/Tabs/AIEditTab.swift` | Inspector-Aktionen am Medium / Clip bewahren. Der aktuelle Dummy bietet nur einen vereinfachten Zugang zu Takes. Intent weiterhin kompilieren, Modelle anhand ausführbarer Fähigkeiten, Kosten separat freigeben |
| **Audio synchronisieren**, Ergebnis-/Fehlerrückmeldung | `Timeline/TimelineView+AudioSyncMenu.swift`, `EditorViewModel+AudioSync.swift` | Kontextaktion auf geeigneter Timeline-Auswahl im Schnitt; nicht mit Sync-Lock oder stumm/laut gleichsetzen |
| **Sechs Take-Prüfgänge** mit Beobachtung und Bereich; Ablehnung und begründete Abweichung, Identität besonders geschützt | `Inspector/Cockpit/TakeReview.swift`, `TakeReviewView.swift` | „Take auswählen“ im Dummy vereinfacht diesen Vertrag stark. Im nativen Ziel muss die Auswahl einen gültigen Review des exakten Takes voraussetzen. UI-Ziel: Video-Takes, nicht Medienorganisation |
| Verwendbaren **Teilbereich retten**, separat prüfen und in den Schnitt einfügen | `TakeRangeReviewView.swift`, `ReviewedTakeRange.swift` | Eigene Reviewaktion am Take; ein Schnitt-Trim ersetzt den Bereichsreview nicht |
| **Reparatur-/Iterationsentscheidungen** anhand dokumentierter Fehlversuche | `TakeRepairView.swift`, `TakeRepairPlan.swift` | Lokal reparieren, neu versuchen oder Planung korrigieren im Takes-/Review-Kontext. Nicht blind alles neu generieren, keine automatische kostenpflichtige Schleife |
| **Sequenzreview**: benachbarte Shots / Gesamtwiedergabe, Befunde, lokale Reparatur, Reroll, Rescue, Rewind | `SequenceReviewView.swift`; `Agent/Pipeline/PipelineSequenceReviewStore.swift` | In Finish inzwischen als Film-/Übergangsprüfung an der echten Dummy-Montage ausgearbeitet: Beobachtungen, bewusste Annahme, aktuelle Sichtung, Rücksprung in den Schnitt. Reroll-/Rescue-/Rewind-Entscheidungen am Take bleiben weiter vereinfacht. [Finish-Abgleich](finish-workspace-review-2026-09-17.md) |
| Bild-/Stilbefunde und ausdrückliche Abweichungsannahme | `FrameFindingsReviewView.swift`, `ProductionStyleReviewView.swift`, `TimelineStyleReviewView.swift` | References-/Frames-Prüfung und tatsächliche Timeline-Stilprüfung erhalten. Ein grüner generischer Review-Status ersetzt keine Evidenz |
| **H.264, H.265, ProRes**, mehrere Auflösungen, Master/Ableitung, optional erforderlicher aktueller Sequenzreview | `Export/ExportOptions.swift`, `Export/ExportView.swift`, `Export/PipelineDeliveryStore.swift` | In Finish nun konfigurierbar und an den aktuellen Dummy-Schnitt gebunden; Standbildvorschau, Dateigröße und Exportlauf sind simuliert. Optionaler aktueller Review bleibt standardmäßig ausgeschaltet wie im nativen Export. Keine echten Dateihashes oder Ausgabeprüfung im Dummy |
| **Timeline-XML und selbstenthaltenes NGV-Projekt exportieren** | `Export/XMLExporter.swift`, `Export/ProjectPackageExporter.swift`, `Export/ExportView.swift` | Beide Ausgabearten sind in Finish auswählbar und als eigene simulierte Ausgaben verzeichnet. XML-Grenzen sichtbar: keine Textoverlays, Flips, Adjustments, Effekte oder Keyframe-Easing. NGV-Projektkopie benennt eingebettete Medien; kein verlustfreier XML-Roundtrip oder echtes Dateipaket vorgetäuscht |

## Schon bekannte, aber im Dummy nur teilweise abgebildete Funktionen

- `Inspector/InspectorView.swift`: Rotation, Flip, Crop samt Seitenverhältnis, Keyframe-Navigation und Keyframes-Panel. Der Dummy zeigt nur einen Teil der Transformationen.
- `Inspector/Tabs/AdjustTab.swift`: Tonwerte, Weißabgleich, Presence, RGB-/Hue-Kurven, Farbräder, LUTs, Detail, Blur, Motion Blur, Vignette, Grain, Glow, Chroma Key. Die zwei Dummy-Regler sind kein Funktionsersatz.
- `Inspector/Tabs/AudioTab.swift`: Pegel, Fade-in/out, Tempo, Pegel-Keyframes. Im Dummy fehlen unter anderem Fades und Keyframes.
- `Inspector/Tabs/TextTab.swift`: der vorhandene Text-Inspector ist umfassender als der einzelne Titel-Dialog.
- `EditorViewModel+Ripple.swift`, `+Clipboard.swift`, `+Linking.swift`, `+Tracks.swift`, `+TimelineRange.swift`: Ripple/Overwrite, Lücken, Bereiche, Clipboard, Verknüpfungen, mehrere Spuren. Native Werkzeuge bewahren; die simulierte eine V1-Spur ist keine Produktbegrenzung.
- `Settings/*`, `App/MainMenu.swift`, `EditorViewModel+ProjectSettings.swift`: Provider/Modelle, Format-Packs, Projektformat, Speicherung, Erscheinungsbild, Updates und native Menüs liegen außerhalb der Arbeitsflächen-Demo. Ihre Existenz nicht mit einem fehlenden Button im Mockup verwechseln.

## Ökonomischer Implementierungsweg

1. `EditorViewModel.WorkspaceFocus` enthält derzeit Produce/Edit/Finish. Ein eigener Medien-Focus benötigt eine begrenzte Ergänzung in Titel-/Menüauswahl, Persistenz und Split-Aufbau. **Keine neue Harness-Phase.**
2. `Editor/EditorView.swift: buildMediaLayout` ist schon ein Medien-betontes **Edit-Layoutpreset mit Timeline**. Seine Komponenten sind wiederverwendbar; das Preset ist noch kein eigenständiger Verwaltungsarbeitsbereich. `NSSplitViewController`, MediaTab, Preview und Inspector weiterhin verwenden.
3. Verwaltungsbrowser und Picker teilen dasselbe Medienmodell. Die neue Trennung ist eine begrenzte UI-Komposition mit eigenem Präsentationszustand; es darf keine zweite Import-/Folder-/Referenz-Wahrheit entstehen.
4. Native Mehrfachauswahl, Suche, Relink, Metadaten und Kontextaktionen in den großen Medienbereich mitnehmen. Im Picker bleiben Auswahl/Vorschau/Bindung/Insert und der Sprung zum Asset.
5. Die fehlenden Schnitt-/Review-/Finish-Funktionen jeweils im passenden Arbeitsbereich konkretisieren. Sie sind ein nachweisbarer Übernahmebestand, keine neuen Engine-Anforderungen. Bestehende Writers, exakte Provenienz, Phasenfreigaben und Kostenverträge behalten die Verantwortung.

Keine neuen upstream-, Provider- oder API-Fakten wurden für diese Änderung angenommen. Grundlage ist die vorhandene NGV-Implementierung; die bereits dokumentierten Upstream-Patches bleiben separate, gezielte UI-Übernahmen.
