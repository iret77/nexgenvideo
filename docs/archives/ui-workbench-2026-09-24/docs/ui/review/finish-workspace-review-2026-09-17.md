# Finish — Endkontrolle und Ausgabe

**Dieses Review beschreibt nur die Finish-Simulation.** Es ist keine Freigabe als vollständige NGV-Umsetzungsvorlage. Der [produktweite Audit vom 18.09.2026](native-ui-audit-2026-09-18.md) weist fehlende Postproduction-Werkzeuge und einen unzulässigen Edit-/Finish-Phasenzwang im Dummy nach. Dafür gilt die [Erhaltungs- und Abnahmevorgabe](../UI_PARITY_CONTRACT.md); die Simulation ist noch entsprechend zu vervollständigen.

Finish ist im Clickdummy ausgearbeitet. Es übernimmt die tatsächliche Montage aus Schnitt einschließlich Reihenfolge, Trims, Lücken, Bildkorrekturen, Titel und Tonspurzustand. Kein Swift-Code geändert. Die Überarbeitung verwendet dieselben Arbeitsbereiche, Seitenleisten und Medienquellen wie der bestehende Dummy.

## Klare Aufgabe

Produktion erzeugt und prüft Takes. Schnitt montiert und bearbeitet sie. Finish prüft den montierten Film und erzeugt seine Ausgaben. Der Review vor teuren Generierungen bleibt ein anderer Vorgang: Er prüft geplante Vorgaben und Referenzen, nicht fertige Anschlüsse im Schnitt.

Die zentrale Fläche bleibt ein großer Viewer. Film und Übergänge sind zwei Ansichten derselben Sequenz. Der Filmstreifen dient der Navigation; er ist keine zweite editierbare Timeline. Im Übergangsvergleich stehen das letzte Bild des ausgehenden Clips und das erste Bild des folgenden Clips nebeneinander. Der Dummy verwendet Standbilder und gibt keinen Ton wieder; dies steht am Viewer.

Links liegen Endkontrolle, Ausgabe und Ausgabenverlauf. Der Quellen-Picker bleibt kompakt; Organisation liegt weiterhin in Medien. Rechts stehen die zur Auswahl passenden Review- bzw. Ausgabewerkzeuge. Panel-Icons wirken unabhängig. Keine neue globale Werkzeugzeile, kein Chat, keine farbigen Umrandungen.

## Abgleich mit vorhandenem Code

Quellenstand des untersuchten nativen Codes: `8bd8fbde`. Alle folgenden Pfade relativ zu `Sources/NexGenVideo/`. Statischer Code-Abgleich, keine Aussage über native Laufzeittests.

| Vorhandener Baustein | Wiederverwendung und Grenze |
|---|---|
| `Editor/FinishReviewPane.swift` | Vorhandene Finish-Fläche aus großem Player, kanonischem Review und Export neu komponieren. Generierung gehört weiterhin nicht hierher. Der dortige TODO für einzelne AI-Enhance-Shots wird nicht als implementierte Funktion verkauft. |
| `Inspector/Cockpit/SequenceReviewView.swift` | Benachbarte Schnitte und Gesamtwiedergabe mit Ton ausdrücklich sichten; Beobachtungen mit Kategorie, Schwere und Position an die Sequenz binden. Der Dummy bietet eigene Befunde, bewusste Annahme und Rücksprung zur Schnittkorrektur. Die nativen Entscheidungen Local Repair, Reroll, Rescue und Rewind bleiben im Produkt erhalten; der Dummy bildet nicht alle Take-Reparaturwege aus. |
| `Agent/Pipeline/PipelineSequenceReviewStore.swift` | Native Prüfungen müssen weiter den exakten aktuellen Quellenstand nachweisen. Die lokale JSON-Zustandsbindung und der kleine Vergleichshash des Dummys sind kein Ersatz für native Quellen-, Medien- und Byte-Provenienz. |
| `Export/ExportOptions.swift`, `Export/ExportView.swift` | Video: H.264/H.265 als MP4, ProRes als MOV; Timeline-Auflösung, 720p, 1080p, 2K und 4K; Master/Ableitung. Bildrate und Seitenverhältnis aus der Timeline. Der Demo-Schnitt hat 1920 × 1080 bei 24 fps. Größenabschätzung verwendet die vorhandenen codecabhängigen Faktoren. Speicherziel im Produkt weiter über NSSavePanel. |
| `Export/PipelineDeliveryStore.swift` | Bestehende Timeline übernehmen, Ausgabeauftrag einfrieren, aktuellen Review bei gewählter Voraussetzung prüfen, Exportversuche erfassen und Ausgabe technisch prüfen. Der Mockup-Verlauf zeigt diese Zustände als lokale Simulation. Native Prüfung umfasst Codec, Bildgröße, Bildrate, Dauer und Audio-Presence/Kanäle; keine erfundenen LUFS-, True-Peak- oder Gamut-Prüfungen. |
| `Export/XMLExporter.swift`, `Export/ProjectPackageExporter.swift` | Timeline-XML und NGV-Projektkopie bleiben eigene Ausgabearten. XML überträgt keine Textoverlays, Flips, Bildkorrekturen, Effekte oder Keyframe-Easing. Die native Projektkopie bettet Medien ein und weist fehlende Dateien aus. Der Dummy produziert weder XML noch ein Projektpaket. |

Der native Schalter `requireSequenceReview` steht standardmäßig auf `false`. Das bleibt hier erhalten. Ist er aktiv, verhindern ein veralteter Review oder blockierende Befunde die Videoausgabe. Ihn zu einer obligatorischen Produktregel zu machen wäre eine gesonderte Entscheidung. Wiederholte Exporte benötigen keine erneute Pipeline-Freigabe und verändern keine Shotplanung.

Der Lichtanschluss-Befund ist ausdrücklich ein **KI-Beispielbefund**. Die existierende Review-Datenhaltung und das Sichten beweisen noch keinen fertigen automatischen semantischen Filmaudit. Für echte KI-Befunde wäre ein begrenzter Adapter nötig, der den exakten Review-Reel untersucht und strukturierte Befunde liefert. Technische Mockup-Befunde wie Schwarzbildlücken, ausgeblendetes V1 oder stummes A1 werden dagegen aus der Dummy-Timeline abgeleitet.

## Verhalten und Grenzen

- Ein Klick auf einen Befund zeigt seine Position bzw. den zugehörigen Übergang. Die bewusste Annahme eines Hinweises hält einen ausgewählten Entscheidungsgrund fest. Eigene Beobachtungen sind eine optionale Texteingabe.
- Übergänge lassen sich einzeln markieren oder gemeinsam ausdrücklich bestätigen. Gesamtfilm mit Ton ist eine getrennte Bestätigung. Sichtung und gespeicherter Review gelten für genau den geprüften Schnittstand.
- Erneute Prüfung desselben Standes erhält eigene Beobachtungen und bewusst angenommene Befunde. Eine tatsächliche Schnittrevision macht alte Ergebnisse ungültig.
- „Im Schnitt korrigieren“ bestätigt die Wiederöffnung, erhält Clips und Trims und springt an die relevante Stelle. Exportgeschichte bleibt sichtbar; ältere Ausgaben zeigen ihren abweichenden Schnittstand.
- Export hält Einstellungen und Schnittstand fest. Ein zweiter Auftrag ist währenddessen gesperrt; Abbruch erzeugt keinen erfolgreichen Ausgabeeintrag. Nach Abschluss kann sofort eine weitere Ausgabe vorbereitet werden. Der Demo-Verlauf hält die letzten sechs Aufträge vor; das ist eine Speicherbegrenzung der Vorschau, keine Produktvorgabe.
- Kein echter Providerlauf, keine Audiodatei, kein bewegtes Quellvideo, keine Speicherung und keine technische Prüfung einer realen Exportdatei. Ein abgeschlossener Lauf ist sichtbar als Simulation bezeichnet.

## Review vor Präsentation

Den bereits recherchierten offiziellen Resolve-Edit-Screenshot erneut betrachtet; dessen feste Flächen, kompakte Inspector-Gruppen und aufgabenbezogene Arbeitsbereiche bleiben die Orientierung. Gerenderte Finish-Einstiegsansicht, Übergangsvergleich, Ausgabeoptionen, Speicherdialog, Verlauf sowie schmale Ansichten tatsächlich visuell geprüft.

Im Review behoben:

1. Wechsel aus Übergänge zur Ausgabe ließ den Wiedergabeknopf zunächst ohne Wirkung. Ausgabe spielt jetzt unabhängig vom zuletzt benutzten Review-Modus ab.
2. Scrubbing/Einzelbildschritt stoppt Wiedergabe und aktualisiert das Transport-Icon sofort.
3. Erneute Prüfung verlor zunächst eigene Befunde und Annahmen. Derselbe Schnittstand erhält diese Entscheidungen.
4. Checkboxen und Auswahlfelder verloren nach Zustandswechsel ihren Tastaturfokus. Fokus und normale Tab-Reihenfolge bleiben erhalten.
5. Ein frei geänderter Exportname konnte die gewählte Dateiendung widersprechen. Unpassende Endungen und Pfadangaben verhindern jetzt die Einreichung.
6. Allgemeine Label-Regeln übersteuerten die Checkbox-Abstände und kompakten Ausgabezeilen. Die Finish-spezifische Anordnung ist nun korrekt; der Dateiname im Speicherdialog nutzt eine ganze Eingabezeile.

Verifikation: **217 bestandene Ablaufprüfungen**, 30 allgemeine Layoutprüfungen; zusätzlich **15 bestandene Maus-/Tastatur- und Finish-Prüfungen**, einschließlich 1024/736/500/320 px, Exportabbruch, erneuter Ausgabe und gespeicherter Zustandsgröße. Keine horizontal überlaufende Finish-Fläche. Screenshots wurden zusätzlich zu den DOM-Messungen betrachtet.

Belege: `desktop-workbench-checks.json`, `desktop-workbench-layouts.json`, `finish-workspace-checks.json`. Ausgeführt ausschließlich gegen die lokale HTML-Vorschau im Browser, ohne Dev-Server, native App, lokalen Build oder echte Exporte.
