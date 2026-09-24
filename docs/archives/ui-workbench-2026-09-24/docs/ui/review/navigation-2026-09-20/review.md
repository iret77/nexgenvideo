# Nachtrag: Projekt-Dropdown entfernt

Das im folgenden historischen Review noch beschriebene Projektmenü am Namen wurde anschließend als redundante Navigation entfernt. Projektaktionen stehen jetzt ausschließlich unter Ablage. [Nachprüfung](../project-title-2026-09-20/review.md).

# Funktionszuordnung und Desktop-Bedienung · 20.09.2026

Anlass: App-Einstellungen und der projektweite Verlauf standen in der Produktions-Sidebar. Der vorherige Review hatte funktionierende Abläufe nachgewiesen, diese falsche Informationsarchitektur aber nicht erkannt. Dieser Durchgang prüft deshalb ausdrücklich **Zuständigkeit, Auffindbarkeit und Bedeutung** der Bedienung, zusätzlich zu ihrer technischen Ausführung.

## Grundlage und Vorgehen

- Die fünf Arbeitsräume und elf Produktionsansichten wurden einzeln anhand ihrer sichtbaren Navigation, Werkzeugleiste, Inspector-Inhalte und Aufträge betrachtet. Das [Inventar](inventory.json) hält diese Ansichten fest. Zusätzlich wurden die zugehörigen Handler auf falsche Ziele und unerwartete Seiteneffekte gelesen.
- App-, Projekt-, Arbeitsraum-, Auswahl- und Auftragsfunktionen wurden getrennt zugeordnet. Kontrollen bleiben beim kleinsten sachlich passenden Kontext; dauerhafte Navigation enthält keine kontextfremden Aktionen.
- Nach den Änderungen wurden die gerenderten Ansichten visuell geprüft: Arbeitsräume, App-Menü, App-Einstellungen, Projekteinstellungen, Untertitel und schmale Vorschauen. Dabei gefundene Überlagerungen und Formularfehler wurden vor Vorlage korrigiert.
- Der vollständige Music-Video-Durchlauf wurde erneut über die sichtbare Bedienung absolviert: neues Projekt, Entwicklung, optionales Blocking, References, Korrekturschleife, Generierung, Auswahl, Schnitt, Endkontrolle und simulierter Export.

Der bestehende native Code hat die wesentliche Trennung bereits: `Sources/NexGenVideo/App/MainMenu.swift` enthält App-, Ablage-, Bearbeiten-, Ansicht- und Hilfemenüs; Settings und Updates stehen im App-Menü. Der Clickdummy war davon abgewichen. Es wurde keine neue native Menüarchitektur implementiert.

Apple nennt das App-Menü als Ort für allgemeine Einstellungen und das Ablagemenü für dokumentbezogene Optionen. Final Cut öffnet seine Einstellungen ebenfalls über das App-Menü bzw. Command-Komma. Das ist die Grundlage für die Korrektur, keine erfundene Toolbar-Konvention. [Apple HIG: Settings](https://developer.apple.com/design/human-interface-guidelines/settings), [Final Cut Pro: Einstellungen öffnen](https://support.apple.com/en-au/guide/final-cut-pro/ver8e3f2f66/mac).

## Befunde und Umsetzung

| Befund | Richtige Zuordnung und Änderung | Gegenprüfung |
| --- | --- | --- |
| App-Einstellungen in der Produktions-Sidebar | Entfernt. Die schmale obere Zeile simuliert die macOS-Menüleiste. `NexGenVideo → Einstellungen…` und `⌘,` öffnen dieselben vorhandenen Einstellungen. | In allen fünf Arbeitsräumen erreichbar. Keine Einstellungen im Produktionsworkflow. Menüs schließen mit Escape; Fokus und Tastaturbedienung bleiben erhalten. |
| Projektmenü enthielt auch Hilfe und Fensterverwaltung | Projektmenü enthält Projektaktionen und projektweiten Verlauf. Hilfe und Fensteraktionen liegen in eigenen Mac-Menüs. Updates sind im App-Menü. | Projektmenü in allen Arbeitsräumen kontrolliert; Sidebar-/Inspector-Schalter steuern weiterhin dieselben Panes. Keine neue Ansichts-Dropdownleiste in der App-Toolbar. |
| Undo/Redo waren nur per Tastatur auffindbar | Beide sind im Bearbeiten-Menü sichtbar, mit Tastenkürzeln und abhängigem Aktivierungszustand. | Undo verändert Inhalt; anschließend ist Redo verfügbar und stellt denselben Inhalt wieder her. Kein neuer Undo-Button in der Titelleiste. |
| Projektbezogene Packmigration und Inhaltssuche in App-Einstellungen | Projektformat, gebundene Packversion/Recovery und Projekt-Inhaltssuche liegen in den Projekteinstellungen. Appweit bleiben Anbieter, Modelle, installierte Packs, Cache und allgemeine Optionen. | Pack-Katalogprüfung ändert keine Projektversion. Recovery bleibt ausdrücklich. Suchstatus öffnet den aufgeklappten Projektbereich. Originalmedien bleiben bei Cache-Aktionen erhalten. |
| App-Konfiguration wurde zusammen mit Projektzustand zurückgesetzt | Anbieter, Modelle, Agent-/MCP-Konfiguration und Erscheinungsbild werden bei Neu-/Import-/Öffnen- und Undo-Aktionen als App-Konfiguration erhalten. | Ein neues Projekt und Projekt-Undo setzen die deaktivierte Anbieterwahl nicht zurück. Die Modell-/Kostenprüfung reagiert weiterhin auf bewusst geänderte Anbieter. |
| „Erneut öffnen“ im Verlauf erzeugte einen neuen allgemeinen KI-Auftrag | Historische Einträge speichern ihren Arbeitskontext. „Arbeitsbereich zeigen“ führt dorthin; Einträge ohne überlieferten Kontext behaupten keinen solchen Sprung. | Kein neuer Auftrag, keine neue Freigabe und keine automatische Wiederholung. Der Wortlaut verspricht den Arbeitsbereich, nicht die Wiederherstellung eines historischen Ergebnisses. |
| Offener Auftrag wurde in anderen Arbeitsräumen oder Werkzeugen angezeigt | Der Interaktionsbereich zeigt den Auftrag nur in seinem Arbeitsraum und bei Postproduction im passenden Werkzeug. | Wegwechsel blendet ihn aus, Rückkehr erhält den unbestätigten Stand. Ein Farbauftrag erscheint nicht im Tonwerkzeug oder in Produktion. |
| „Untertitel bearbeiten“ führte zu allgemeinen Titeln | Untertitel werden im Untertitelwerkzeug ausgewählt und bearbeitet. Titel- und Untertitellisten verwenden weiterhin dieselben Timeline-Objekte, filtern aber nach ihrer Aufgabe. | Bearbeiten eines Untertitels ändert keinen Filmtitel. Auswahl bleibt im Untertitelwerkzeug; Textänderungen erscheinen in Viewer und Timeline. Titel liegen standardmäßig mittig, Untertitel unten. |
| Montage zusätzlicher Takes in der Produktionsfläche | Montageauftrag aus dem Produktions-Inspector entfernt; im Schnitt über `Bearbeiten → Geprüfte Takes montieren…` erreichbar. | Funktion bleibt erhalten, fügt eine neue Spur hinzu und bewahrt die vorhandene Montage. Außerhalb des Schnitts bzw. ohne freigegebene Takes ist sie deaktiviert. |
| Leerer Take-Inspector zeigte allgemeine Projekteinstellungen | Entfernt; Projekteinstellungen haben ihren stabilen projektbezogenen Zugang. | Der leere Take-Bereich erhält keine kontextfremde Formatverwaltung. |
| Uneinheitliche Sprache, Popup-Überlagerung, Formularraster | Farb-/Effektbegriffe vereinheitlicht. Menü liegt über den Panes. Projekteinstellungen nutzen das gemeinsame Formularraster. | Visuelle Nachprüfung plus Hit-Test auf den unteren Menüeintrag; Layoutprüfung bis 320 px. |

Appweite Wartungsrückmeldungen erscheinen in den Einstellungen, statt neue projektbezogene Produktionsentscheidungen zu erzeugen. Die vormals doppelte Abschlussaktion im Suchstatus ist bereinigt.

## Was bewusst seinen Ort behält

| Bereich | Zuständigkeit nach der Prüfung |
| --- | --- |
| Medien | Bibliothek, Ordner, Suche, Import und freie Generierung. Andere Arbeitsräume behalten kompakte Quellenwähler. |
| Audioanalyse | Track, Messung, Interpretation und Abhören. Keine Geschichte oder vorzeitige Szenenbilder. |
| Briefing / Gestaltung / Treatment / Skript | Auftrag und Rahmen / Stilregeln / Erzählverlauf / Szenen und Handlung. Kontextbezogene Änderungsziele gehören zum jeweiligen Dokument. |
| Storyboard | Sketches, mehrere Handlungsmomente pro Shot und gemeinsames Timing. Animatic-Transport ausschließlich im Animatic-Tab. |
| Shotplanung | Kamera, Quellen, Produktionsvorgaben und Zustände. Timing verweist auf dieselben Storyboard-Shots. |
| Blocking | Optional: gemeinsame Clay-Locations, shotbezogene Inszenierung und Kameras, daraus verbindliche 2D-Vorlagen. |
| References | Gerenderte Identitätsreferenzen und Shot-Anker; keine Umdeutung zu Sketches. |
| Render-Review | Prüfung von Produktionsvorgaben, Bildreferenzen und Zustandsfolge vor Videoaufträgen. |
| Video-Takes | Modell-/Kostenentscheidung, Generierung, Sichtung und Auswahl. Montage ist im Schnitt. |
| Schnitt | Quellen, Auswahl, Spuren, Timing, Montage und kontextbezogene Clipbearbeitung. |
| Postproduction | Farbe, Ton, Titel, Untertitel, KI-Bearbeitung und Endkontrolle. Gemeinsame Editoren mit dem Schnitt bleiben erhalten; keine zweite Datenhaltung. |
| Export | Ausgabeparameter und Verlauf, generisches Vorschaubild, optionales Music-Video-Album-Cover. |
| Statusleiste | Projektbudget sowie getrennte KI- und Exportaktivität, unabhängig vom Arbeitsraum. |

## Prüfung und Grenzen

Die neuen [Zuordnungs- und Bedienungsprüfungen](checks.json), [bisherigen Interaktionsprüfungen](interactions/checks.json) und der [vollständige Bedienungsdurchlauf](walkthrough/checks.json) sind getrennt dokumentiert. Bestehende Gruppen für Schnitt, Freigaben, Layout, Hintergrundaktivität und Exportbilder wurden erneut ausgeführt. Die endgültigen Zähler und Artifact-Hashes stehen in [verification.json](verification.json).

Die Regression erfasste zunächst einen Überlauf bei 320 px. Er wurde korrigiert und die betreffende Gruppe erneut ausgeführt. Der Runner wertet Layoutfehler nun ausdrücklich als Fehler, statt nur den Prozess-Exitcode zu berücksichtigen. Zwei Provider-Gegenproben wurden auf eine bewusste Änderung über die Einstellungen umgestellt: Das Laden eines Projekts soll die globale Anbieterwahl gerade nicht mehr ändern.

Dies ist ein eigener semantischer und visueller Review, kein neuer externer Agent-Review und kein Test mit menschlichen Probanden. Modellaufrufe, Videoausgabe und Exporte bleiben simuliert. Native Quellen wurden zum Abgleich gelesen; native Anwendung, Pipeline-/Packverträge und Provider-Implementierungen wurden nicht geändert. Die Vorabprüfung erlaubt keine pauschale Behauptung, sämtliche späteren Produktionsfälle seien fehlerfrei.
