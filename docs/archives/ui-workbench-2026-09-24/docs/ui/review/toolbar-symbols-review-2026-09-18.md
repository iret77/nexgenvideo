# Symbol- und Textbuttons — Recherche und Review

## Apple-Regeln

Die aktuellen [HIG für Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars?changes=la) bevorzugen einfache, erkennbare Symbole. Aktionen ohne eindeutiges Symbol dürfen Text tragen. Standardsymbole brauchen keinen zusätzlichen dekorativen Rahmen. Verwandte Aktionen werden gruppiert; Textaktionen und Symbolaktionen müssen erkennbar getrennt bleiben.

Die [HIG für Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons?changes=latest_1__8) lassen Symbol, Text oder beides zu und empfehlen kurze Textlabels, wenn sie die Handlung verständlicher vermitteln. macOS bietet ergänzende Tooltips. Daraus folgt kein allgemeines Verbot von Textbuttons außerhalb von Menüs und Dialogen. Navigationsreiter und Filter behalten verständliche Bezeichnungen; konkrete Dialoghandlungen wie Entfernen oder Abbrechen bleiben Text.

## Vergleich der Referenzen

- **Final Cut Pro:** Das aktuelle [Import-Handbuch](https://support.apple.com/en-ie/guide/final-cut-pro/ver418155a4/mac) beschreibt den Import-Button in der Werkzeugleiste, den Menüweg und die ausgeschriebenen Abschlussbuttons im Importfenster. Der bereits gesicherte offizielle Screenshot wurde erneut visuell geprüft: kompakte Symbolwerkzeuge neben beschrifteten Auswahl- und Suchfunktionen. Der [Aktivitätsbutton](https://support.apple.com/en-mide/guide/final-cut-pro/ver64e71609/mac) öffnet Details zu Hintergrundaufträgen. Übernahme: direkte Werkzeuge und aufklappbare Auftragsdetails.
- **DaVinci Resolve 21:** Den bereits gesicherten offiziellen Edit-Screenshot erneut geprüft; die aktuelle [Medien-Seite](https://www.blackmagicdesign.com/products/davinciresolve/media) gegengeprüft. Ansicht, Suche und Schnittwerkzeuge verwenden kompakte Symbole; Bereiche wie Media Pool und Inspector bleiben benannt. Übernahme: Werkzeuge dort platzieren, wo ihre Objekte liegen. Resolve ist kein Beleg für ausschließlich unbeschriftete Controls.
- **LTX Desktop:** Den [offiziellen Editor-Screenshot](https://github.com/Lightricks/LTX-Desktop/blob/main/images/video-editor.png) erneut visuell geprüft und mit dem aktuellen [Repository](https://github.com/Lightricks/LTX-Desktop) abgeglichen. Ordner, Import und Ansichten sind kleine Symbole im Assets-Bereich; Modi und Export tragen Text. Übernahme: kompakte lokale Medienwerkzeuge. Der Screenshot zeigt Windows und ist kein Nachweis für Apple-Konformität.

Die konkreten NGV-Zuordnungen sind Entwurfsentscheidungen. Weder Ordnerhierarchie als Sortierwerkzeug noch Funken als KI-Kennung werden als von Apple vorgeschriebene Symbole ausgegeben.

## Änderungen im Clickdummy

| Bereich | Darstellung und Verhalten |
| --- | --- |
| Medienkopf | Import als Pfeil in Ablage; Generierung als Zauberstab; Ordnen als Ordnerhierarchie. Jeweils eigener Tooltip und zugänglicher Name. |
| Suche | Regler-Symbol neben dem Suchindexstatus öffnet die vorhandenen Suchindex-Einstellungen. |
| Ordnerbaum | Anlegen, Umbenennen und Entfernen zusammen in einer kompakten unteren Werkzeuggruppe. Umbenennen und Entfernen ohne konkreten Ordner deaktiviert. |
| Datei-Inspector | Der doppelte, sachlich falsch zugeordnete Ordner-entfernen-Button entfällt. Dateiaktionen bleiben erhalten. |
| Hintergrund | Funken-Symbol im KI-Aktivitätskreis, sichtbares „KI“ rechts daneben. Export bleibt separat beschriftet. Kreise stellen Auftragsaktivität dar. |

Import und Generierung öffnen weiterhin ihre bestehenden Eingaben. Ordnen öffnet erst einen Vorschlag. Ordner entfernen fragt nach und nennt jetzt den ausgewählten Ordner; Medien bleiben erhalten. Bestehende Bestätigungen, Kostenfreigaben und Auftragsfunktionen werden nicht durch unmittelbare Symbolaktionen umgangen. Die native App wurde nicht verändert.

## Self-Review vor Präsentation

- Offizielle Referenz-Screenshots und aktuelle Apple-Regeln gegen die geänderte Oberfläche geprüft.
- Symbole aus der vom Vorschau-System gelieferten Lucide-Bibliothek, keine selbst gezeichneten Ersatzzeichen. Für die native Umsetzung entsprechende SF Symbols verwenden.
- Darstellung im tatsächlichen Vorschau-Rahmen und als eigenständige Testansicht geprüft. 16-px-Symbole in 28-px-Zielen; 44-px-Ziele bei Touch-Eingabe.
- Die geänderten Controls haben eindeutige Namen und Tooltips. „Medien nach Typ ordnen“ benennt die konkrete Funktion statt des früheren allgemeinen „Organisieren“.
- Ordnerwerkzeuge bleiben auch in schmaler Vorschau sichtbar; keine zusätzliche globale Werkzeugzeile, keine farbigen Rahmen.
- 17 gezielte Browserprüfungen für Symbole, Dialogwege, Vorschlagszustand, Ordnerkontext, KI-Beschriftung und Layout bei 1.048 / 768 / 390 px bestanden. Eine anfänglich falsche Dialogkennung in der Prüfung wurde an den vorhandenen Dialog angepasst.
- Alle 25 bestehenden Hintergrundprüfungen bestanden: Anzeige, Fortschritt, Abbruch, Wiederaufnahmezustand, Fokus, reduzierte Bewegung und Fly-out-Grenzen.

Nachweise: `toolbar-symbol-checks.json`, `background-checks.json`, `studio-screenshots/media-toolbar-symbols.png`. Dies prüft den Clickdummy; kein nativer App-Start oder macOS-Accessibility-Test.
