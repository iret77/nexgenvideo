# Review: visueller Video-Takes-Arbeitsbereich

## Anlass und Umfang

Der abgelehnte Screenshot zeigte einen leeren Generic-Workflow, doppelte Statusmeldungen und einen technischen Modellauftrag im Produktionsbereich. Diese Überarbeitung betrifft die Video-Takes-Fläche, leere Phasen, die zugehörige Auftragsbedienung und die Zuordnung der Modellprüfung. Sie behauptet keine vollständige Neugestaltung aller Phasen. Native Swift-Quellen bleiben unverändert.

## Korrigierte Befunde

- Ein vorhandener Shot besitzt eine Bildreihe: tatsächliche Eingabe links, seine Takes rechts. Auswahl und Review erfolgen an diesen Bildern. Die zusätzliche Shotleiste entfällt.
- Vorhandene Storyboard-Sketches bleiben ausdrücklich Planungsstand; ohne freigegebenen Anker erscheinen sie nicht als fertige Produktionsvorlage. Ein neues Projekt erhält keine erfundenen Bilder oder Shots.
- Leere Video-Takes zeigen zwei neutrale Bildplätze und eine kurze Herkunftsangabe. Nur der Phasendock öffnet den tatsächlich aktuellen Schritt. Der Inspector zeigt das Projektformat statt desselben Status ein zweites Mal.
- Die Auftragsauswahl sitzt an den Shotbildern. Während Vorbereitung, Kostenfreigabe und Ausführung ersetzt sie den Phasendock; es gibt keine zweite Startaktion. Fertige Ergebnisse erscheinen laufend. Abbruch und Fortsetzen erhalten sie.
- Bei veraltetem Auftrag wird der Grund angezeigt und eine erneute Prüfung angeboten. Die Kostenfreigabe kann weder aus einer früheren Phase noch vor der Prüfung ausgelöst werden.
- Modellfähigkeiten werden in Einstellungen → Modelle geprüft und ausdrücklich übernommen. Ihr Zustand ist vom Produktionsauftrag getrennt, sodass auch ein pausierter Videolauf erhalten bleibt. Frühere gespeicherte Modellaufträge werden in diesen Bereich übertragen.
- Die Modellprüfung verwendet vorhandene native Verantwortlichkeiten: `Sources/NexGenVideo/Settings/ModelCapabilityResearchPane.swift` enthält bereits den optionalen Recherche- und Übernahmeweg. Der Dummy simuliert Evidenz ausdrücklich; er führt keine Live-Recherche durch.

## Visuelles Review

Leeres Projekt, vorhandene Sketches, Anker ohne Takes, vollständige Take-Reihen, Auftragsauswahl, Kostenfreigabe und 130-%-Darstellung als Browserbilder geprüft. Zusätzlich die eingebettete Fassung mit leerem und gefülltem Projekt geprüft: volle Arbeitshöhe, kein horizontaler Canvas-Überlauf. Durchgehende Flächen, neutrale Trenner und Inspector-Gruppen erhalten die bisher recherchierte Desktop-Grammatik; keine neue Benchmark-Recherche in diesem Durchgang.

Im visuellen Review fiel zunächst die doppelte Leiste bei aktiver Kostenfreigabe auf; sie wurde vor Präsentation entfernt. Die zuletzt geprüften Screenshots liegen im selben Verzeichnis.

## Interaktive Prüfung

- `check-desktop-production-takes.mjs`: 19/19 Prüfungen, einschließlich Wiederherstellung alter Zustände, Take-Zuordnung, Kostenfreigabe, Teilabbruch, Fortsetzen und unabhängiger Modellprüfung.
- `check-desktop-production-polish.mjs`: 32/32 Prüfungen, darunter gemeinsame Pane-Höhen und erhaltene Inspector-/Auswahlregeln.
- `check-desktop-production-guards.mjs`: 32/32 Prüfungen.
- `check-desktop-production-workbench.mjs`: 35/35 Prüfungen, keine Layoutfehler.
- Hintergrundprüfung: 25/25; AI- und Exportanzeige bleiben erhalten.

Zwei ältere Testaufbauten hatten einen Videolauf trotz ungeklärtem Render-Review vorbereitet. Die Aufbauten wurden auf eine tatsächlich freigegebene Review-Fixture korrigiert; ein zusätzlicher negativer Test prüft die Ablehnung in der falschen Phase.

Alle Prüfungen beziehen sich auf statische Mockup-Dateien. Kein nativer Build, kein App-Start, kein Provideraufruf. Takebilder bleiben vorhandene illustrative Standbilder, keine neu erzeugten Videovarianten.
