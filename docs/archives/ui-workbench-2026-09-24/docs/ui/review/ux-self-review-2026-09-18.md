# UI/UX-Review vor unabhängiger Prüfung

Stand: 18.09.2026. Nur Clickdummy, keine Änderung an der nativen App.

## Prüfmaßstab

Mac-Arbeitsfenster für Filmschaffende: eine integrierte Titelleiste, feste Arbeitsräume, direkte Auswahl, kontextbezogener Inspector, gemeinsame Timeline, kompakte Symbolschalter für unabhängige Seitenbereiche. Kein Dashboard, keine Chatoberfläche, keine dekorativen farbigen Ränder. Pack-Akzent dient aktiver Auswahl und Werkzeugzuständen. Produktion, Schnitt, Postproduction und Export haben unterschiedliche Aufgaben; Medien ist der gemeinsame Organisationsraum.

Aktuell nachgelesen: [Apple HIG: Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars?changes=la), [Focus and selection](https://developer.apple.com/design/human-interface-guidelines/focus-and-selection/), [FCP: Transcript search](https://support.apple.com/en-ph/guide/final-cut-pro/ver65764b45/mac). Apple empfiehlt logisch gruppierte, häufig verwendete Aktionen, integrierte Titel-/Werkzeugleisten sowie Sidebar links und Inspector rechts. Der spätere native Entwurf verwendet Systemkomponenten; die HTML-Darstellung behauptet keine native Liquid-Glass-Implementierung.

Wettbewerbsgrundlage bleibt die visuelle [Untersuchung von FCP, Resolve und LTX Desktop](desktop-research-2026-09-17.md). Versionsangaben darin beziehen sich auf den Recherchetag.

## Verifizierte und korrigierte Befunde

1. **Statusleiste durch Teststeuerung belegt:** CLICKDUMMY und Beispielauswahl entfernt. Links stehen Medienauswahl oder Clip-/Arbeitskontext, rechts Aufträge und Budget. Beispielprojekte sind in den äußeren Vorschauoptionen erreichbar. Kein zweiter Wechsel zu Postproduction/Export in der Fußleiste.
2. **Unverständliche Suchbegriffe und falsche Semantik:** Dateiname, Bildinhalt und Transkript bezeichnen drei Suchbereiche. Suchfeld und Ergebnisse folgen der Auswahl. Transkriptsuche durchsucht ausschließlich hinterlegte Transkriptstellen an Audio/Video. Keine Dokument-/Dateinamentreffer als Sprachbefund. Bildinhalte sind pro Beispielmotiv zugeordnet. Keine erfundenen Zeitbereiche für Standbilder. Treffer ändern nicht ungefragt den Arbeitsbereich.
3. **Auswahl und Vorschau widersprechen sich:** Clipauswahl bringt den Abspielkopf in den Clip, wenn er außerhalb liegt. Audioclips öffnen Tonwerkzeuge; Bildkorrekturen und Bild-Keyframes werden dafür nicht angeboten.
4. **Timeline-Drag blockiert:** Der frühere Storyboard-Handler hat Ziehen der neuen Timeline-Clips abgebrochen. Die Zuständigkeiten sind getrennt.
5. **Interne Bezeichner sichtbar:** Keyframe-Parameter, Interpolation, Titelausrichtung und Schriftwahl verwenden verständliche Beschriftungen. Farbräder, Chroma-Key, Untertitel, Erzählmuster und Zustandsverlauf ersetzen verkürzte oder technische Bezeichner.
6. **Falsche Medienaktionen:** Neu verknüpfen ist nur bei Offline-Medien verfügbar; Wiederverwendung eines Generierungsprompts nur bei vorhandenen Generierungsdaten. Quelltab schließen erscheint nur bei einer geöffneten Quelle.
7. **Erfundene Modellfähigkeiten:** Das Text-zu-Video-Demoprofil bot irrtümlich Quellvideo-/Endbild-Slots an. Entfernt. Native modellabhängige Referenz-/Extension-Fähigkeiten bleiben Erhaltungsanforderung; sie brauchen im Dummy passende, belegte Profile und sind nicht durch beliebige Zusatzfelder implementiert.
8. **Export vom falschen Zustand abgeleitet:** Tonstatus folgt tatsächlichen Audiospuren. Stummgeschaltete belegte Tonspuren erscheinen in der Endkontrolle. Exporthistorie behält die Bildrate des jeweiligen Auftrags, auch nach einer Projektänderung.

## Selbstprüfung

35 bestehende Interaktionsprüfungen und 25 Layoutkombinationen bestanden. Zusätzlich 16 gezielte Regressionen in `check-desktop-production-ux.mjs` bestanden. Letztere unterscheiden Suchdaten, Arbeitsbereich/Quellkontext, Audio-/Bildwerkzeuge, Drag-Ereignis, Tonstatus und historische Exportwerte. Screenshots vor Fremdreview: `studio-screenshots/ux-*.png`.

## Ehrliche Grenze

Standbild-/Zustandssimulation: kein Videodecoder, kein Audiorenderer, keine echten KI-/Provider-/Dateiaufträge. Grading enthält weiterhin bedienbare Parameter ohne vollständige Bildberechnung. Vorhandene native Funktionen dürfen deswegen nicht entfallen. Der Funktionsinventar ist ein Erhaltungsnachweis für die Planung, keine pauschale Behauptung vollständiger interaktiver oder nativer Abnahme. Ein unabhängiger Reviewer soll insbesondere verbleibende Fehlzuordnungen und Scheininteraktionen aufdecken.
