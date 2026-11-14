# Schnitt: direkte Objektauswahl statt Viewer-Modus

Der Besitzer hat den Timeline/Quelle-Umschalter auch nach Entfernung der zusätzlichen Quell-Tabs abgelehnt. Ein als lokale Vorschauwahl erklärtes Steuerelement änderte zusätzlich Auswahlhervorhebung und Inspector. Der vorherige Review prüfte Zustandskonsistenz, akzeptierte aber dieses irreführende Bedienmodell. Dieses Review ersetzt die Bedienentscheidung aus `../source-viewer-2026-09-20/review.md`.

## Überarbeitung

Der Umschalter entfällt. Der Benutzer wählt das konkrete Objekt: ein Originalmedium links oder eine Clip-Instanz in der Timeline. Der Viewer-Kopf beschreibt nur „Medienvorschau“ beziehungsweise „Filmvorschau“. Der Inspector nennt „Originalmedium“ oder „Timeline-Clip“ mit Name und bietet die Werkzeuge dieses Objekts. Ein Klick auf die Beschriftung löst nichts aus.

Die Quellenliste bleibt während der Schnittarbeit dieselbe Liste. Der redundante Eintrag „Sequenz 01“, dessen Auswahl vom Viewer-Modus abhing, entfällt dort; die Montage bleibt unten sichtbar. Suche, Medientyp und Ordner filtern nur die Quellenliste. Sie verlassen nicht die aktuelle Vorschau und wählen kein anderes Objekt. Die aktive Auswahl erhält die Pack-Akzentfarbe; eine gemerkte Auswahl des anderen Bereichs bleibt neutral. Quellen-Cursor und Quellbereich bleiben von Timeline-Cursor und Montage getrennt.

Zusätzlich behoben: Kontextmenüs auf bereits gemerkten Objekten aktivierten bislang teilweise nicht deren sichtbaren Kontext. Eine gesperrte Timeline-Auswahl konnte fremde Quellbereichsfelder deaktivieren. Lange Quellenbezeichnungen dürfen die beiden Hintergrundanzeigen nicht aus der rechten unteren Ecke verdrängen.

## Abgleich

- [Apple: Viewer](https://support.apple.com/en-ae/guide/final-cut-pro/ver917099bf/mac) beschreibt die Wiedergabe von Browser-Clip oder Timeline-Projekt im selben Viewer. Die direkte Auswahl dient hier als Vorbild. Daraus wird keine pauschale HIG-Zertifizierung des Mockups abgeleitet.
- [Apple: Fensteraufteilung](https://support.apple.com/en-lamr/guide/final-cut-pro/ver2a27194eb/mac): Browser, Viewer, Timeline und Inspector behalten ihre räumlichen Rollen.
- `Sources/NexGenVideo/Inspector/InspectorView.swift` hat bereits ein `inspectedObject` sowie Reaktionen auf Medien- und Clip-Auswahl. Die Überarbeitung knüpft an dieses vorhandene Objektmodell an. Native Engine, Provider und Pipeline wurden nicht geändert.

## Tatsächliche Prüfung

Self-Review, kein neuer Fable-Aufruf. `check-desktop-production-viewer.mjs`: 25 Checks erfolgreich, keine Laufzeitfehler. Zusammenhängender Ablauf mit echten Mausklicks: Original auswählen, Quellbereich festlegen, Timeline-Clip auswählen und bearbeiten, Original erneut auswählen, Suche/Typ/Ordner ändern, Quelle abspielen, Ausschnitt einfügen und rückgängig machen, Timeline-Lineal verwenden, Kontextmenüs auf gemerkten Auswahlen, Spur sperren/entsperren, Titel auswählen, Quellframe sichern und Arbeitsbereich wechseln. Die Prüfungen kontrollieren ausdrücklich auch die jeweils anderen Bereiche.

Visuell geprüft: die Review-Aufnahmen in normaler und vergrößerter Darstellung; zwei finale Ansichten liegen diesem Snapshot bei. Beide normalen Ansichten haben dieselbe Quellenliste. Objektart und zugehörige Werkzeuge sind erkennbar. Die Skalierungsvariante und absichtlich schmale Vorschau behalten sichtbare Beschriftungen und zugängliche Kernaktionen. Ein bei der Bildprüfung entdecktes Umbruchproblem im Footer wurde korrigiert und erneut geprüft.

Die bestehende Kontextmenü-Suite hat 56 erfolgreiche Checks ohne Laufzeitfehler, einschließlich Mehrfachauswahl, gesperrter Spuren, Drag-and-drop und Inspector-Scrollcontainer. Anschließend änderten sich nur Footer-Darstellung und Tooltip; der Objektauswahl-Ablauf wurde auf dem endgültigen Stand erneut ausgeführt.

Geprüft wurde der statische Schnitt-Clickdummy. Die Bilder bleiben Standbildsimulationen. Dies ist keine native Laufzeitprüfung und keine pauschale Abnahme sämtlicher Projektphasen.
