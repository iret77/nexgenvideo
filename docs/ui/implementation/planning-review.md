# Review der Implementierungsplanung — 20.09.2026

- Main-Stand, offene PRs #548/#549, #540 samt Pipeline-Grenze und konkrete Upstream-Commits erneut über GitHub geprüft.
- 28 Aufgaben mit konkreten existierenden Code-Einstiegen; Abhängigkeitsgraph ohne Zyklen. 24 neue Teil-Issues und vier aktualisierte UI-Issues; #217/#533 zusätzlich präzisiert.
- Vier veraltete Annahmen bereinigt: drei Workspaces, Verbot kleiner Panel-Symbole, Budget-Cockpit-Tab, Timeline/Quelle-/Quelltab-Navigation.
- Neue Verträge ausdrücklich von UI-Komposition getrennt. #559/#572 liefern Entscheidungsvorlagen; #560/#561/#563/#573 dürfen vorher keine gesperrten Specs verändern.
- FilmFlow ist ein optionaler späterer Ausbau, kein Blocker für den eigenständigen UI-Batch. Keine reale Producer-Kompatibilität ohne geliefertes Schema behauptet.
- Vorhandene Cover-Utility nicht als fehlender kompletter Port ausgegeben; generische Exportbildbindung als tatsächlich neue Arbeit getrennt.
- Reale Export-Queue #528 von Aktivitätsanzeige #570 getrennt; Higgsfield- und Clay-Integration haben je einen bestehenden Eigentümer.
- 121 historische Funktionsgruppen übernommen. Native Parität wird pro Oberfläche und abschließend in #574 verlangt; Dummy-Testzahlen ersetzen sie nicht.
- Dokumentationssnapshot enthält keine Hostpfade und keine externen Runtime-Scriptabhängigkeiten. Inline-Scripts sind gegenüber dem zuletzt geprüften Stand bytegleich; nur dokumentarischer Kopf und externer Test-Runner-Verweis wurden angepasst.

Dieser Review betrifft Planung, Zuständigkeitsgrenzen und Dokumentationsintegrität. Kein neuer Fable-Aufruf und keine native App-Verifikation. Kein Swift-Code, Providerzugang oder Produktionsvertrag wurde verändert.
