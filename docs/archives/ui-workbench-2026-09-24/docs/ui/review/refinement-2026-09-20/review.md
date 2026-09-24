# Überarbeitung nach dem Erstbenutzungs-Review

Grundlage ist der [beobachtete Erstbenutzungsdurchlauf](../first-use-2026-09-20/review.md). Alle elf Befunde wurden in konkrete Interaktionsänderungen übersetzt. Überarbeitet wurde ausschließlich der statische Clickdummy. Die native Anwendung, ihre Pipeline-Verträge und die parallel bearbeiteten Provider-Module wurden nicht geändert.

## Konzeptionelle Entscheidung

Das Hauptproblem war nicht die Menge vorhandener Funktionen, sondern der verlorene Zusammenhang zwischen Auftrag, Ergebnis, Entscheidung und nächster Handlung. Deshalb bleibt die Desktop-Struktur erhalten: fünf Arbeitsräume, passende Seitenleisten, zentrale Arbeitsfläche und kontextbezogener Inspector. Verbesserungen führen innerhalb dieser Struktur weiter. Es gibt keinen zusätzlichen Navigationsmodus, keinen Chat und keine neue Dashboard-Ebene.

Eine Sichtung ist keine Bestätigung. Eine Navigation verändert keine Freigabe. Eine Korrektur behält ihren Shot und ihren Anlass. Ein Werkzeug zeigt ausschließlich passende Einstellungen. Ein Generierungsauftrag bindet Modell, Eingaben, Dauer und Kosten. Diese Regeln gelten auch bei Abbruch, Revision und Hintergrundarbeit.

## Befund → Änderung → Prüfung gegen Verschlimmbesserung

| Befund | Umsetzung | Geprüfter Gegenfall |
| --- | --- | --- |
| 1. Blocking bestätigt schon beim „Sichten“. | „Vorlagen prüfen“ startet die Sichtung bei der ersten offenen Vorlage. Erst die ausdrückliche Bestätigung übernimmt genau diese Vorlage und führt weiter. | Das Öffnen bestätigt nichts. Die zweite Vorlage bleibt offen. Änderungen an Geometrie entwerten weiterhin die betroffene Sichtung. Die Phasenfreigabe bleibt gesperrt, solange eine Bestätigung fehlt. |
| 2. Continuity-Korrektur verliert ihren Zusammenhang. | Betroffener Shot, Vorher/Nachher und nächster erforderlicher Schritt bleiben über Planung, Blocking, References und erneuten Review sichtbar. Die korrigierten Zustände stehen direkt oben im Inspector. Nur betroffene Anker werden erneuert. | Andere Ankersichtungen bleiben erhalten. Unverändertes Blocking wird erklärt, aber nicht still freigegeben. Bereits übersprungenes Blocking bleibt übersprungen. Eine unabhängige Revision beendet den alten Korrekturkontext. |
| 3. Farbwerkzeug zeigt Titel-Einstellungen. | Inspector und Werkzeug folgen einer gemeinsamen Auswahl. Bei ausgewähltem Titel fordert Farbe ausdrücklich zur Auswahl eines Videoclips auf. | Der Werkzeugwechsel wählt keinen anderen Clip heimlich aus und verändert keinen Titel. Titelbearbeitung bleibt erreichbar. Sequenzbezogene Untertitel benötigen keine Videoauswahl. |
| 4. Auftragsergebnis benennt den nächsten Schritt nicht. | Nach Identitäten folgt direkt „Shot-Anker vorbereiten“. Danach führt die Oberfläche zu ausstehenden Sichtungen bzw. zur Freigabe. Veraltete Abschlussmeldungen werden entfernt. | Eine sichtbare nächste Handlung ersetzt keine strukturelle Freigabe. Fehlende Bilder, veraltete Eingaben oder unbestätigte Ergebnisse blockieren weiterhin die passende Aktion. |
| 5. Take-Sichtung besteht aus wiederholten Dialogen. | Dauerhafter Viewer in der Arbeitsfläche mit Varianten, Shot-Filmstreifen, Befund und Entscheidung. Nach Auswahl oder Ablehnung folgt bei Bedarf der nächste noch nicht ausgewählte Shot. Pfeiltasten unterstützen Shot- und Variantenwechsel. | Navigation akzeptiert keinen Take. Eine bewusste Abweichung braucht weiterhin eine Begründung und bleibt am Take sichtbar. Übersicht, Reparaturmöglichkeiten und weitere Varianten bleiben erreichbar. Texteingaben werden nicht von den Pfeiltasten abgefangen. |
| 6. Videoauftrag bietet keine konkrete Modellentscheidung. | Modellwahl im Hauptauftrag, aufklappbare Eingaben und Renderdauer je Shot, daran gebundene Beispielkosten. Zusätzliche Takes nutzen denselben Ablauf. Die simulierten fal-Routen für Seedance 2.0 und 2.5 orientieren sich am vorhandenen Code. | Text-only kann bestätigte Bildanker nicht still ignorieren. Deaktivierte Anbieter und geänderte Modelle entwerten eine frühere Kostenfreigabe. Ein längerer Modelloutput ändert nicht das geplante Shot-Timing. Retakes erhalten vorhandene Varianten und die bewusste Schnittauswahl. |
| 7. Kreative Alternative ist ungerichtet. | Kurze Änderungsziele „Klarer“, „Knapper“, „Mehr Spannung“, optional ein begrenztes Textfeld, anschließend Vorher/Nachher und ausdrückliche Übernahme. | Vorschau und Abbruch verändern den Text nicht. Übernahme betrifft nur den ausgewählten Abschnitt und lässt sich rückgängig machen. Die Simulation behauptet keine KI-Auswertung einer freien Notiz. |
| 8. Hintergrundarbeit sperrt die Orientierung. | Freigegebene Phasen lassen sich während eines Auftrags lesend öffnen. Sichtung und Panel-Bedienung bleiben möglich. | Bearbeitung, Revision, Freigabe und zweiter Auftrag bleiben gesperrt. Der laufende Auftrag endet auch beim Lesen einer anderen Phase. Größenänderungs-Controls sind anschließend wieder bedienbar. |
| 9. Medienaktionen gelten für unsichtbare Auswahl. | Ordner-, Filter- und Suchwechsel entfernen die nicht mehr sichtbare Auswahl samt unpassendem Inspector. | Ein leerer Ordner zeigt keine ausgewählten Medien aus anderen Ordnern. Reiner Ansichts- oder Sortierwechsel erhält eine weiterhin sichtbare Auswahl. Medienzuordnungen werden nicht gelöscht. |
| 10. Technische Hilfsfunktionen sind unverständlich. | Inhaltssuche erklärt zunächst Verfügbarkeit und Nutzen. Wartung bleibt sekundär erreichbar. Modellprüfung nennt Modell, belegte Demo-Eingaben, Grenzen und offene Fähigkeiten anstelle beliebiger Bestätigungs-Checkboxen. | Keine manuelle Bestätigung erfindet Modellfähigkeiten. Unbekannte Fähigkeiten bleiben unbekannt. Speicher- und Modellfunktionen verschwinden nicht aus der Oberfläche. |
| 11. Gestaltung, Sprache und Metadaten wirken unfertig. | Gestaltungsparameter in der Hauptfläche mit gemeinsamen Ausrichtungsachsen; kompakter Inspector. Singular/Plural korrigiert, Mediennamen statt interner IDs, verständliche Cover-Beschreibung statt internem Prompt. | Keine vorzeitigen Szenenbilder im Briefing. Technische Promptdaten bleiben intern erhalten. Die feste Beispielsequenz wird bei abweichender Briefinglänge ausdrücklich als Ausschnitt bezeichnet. |

## Vollständiger Bedienungsdurchlauf

Der neue Durchlauf bedient die sichtbare Oberfläche über DOM-/Browserinteraktionen; er springt nicht mit Fixture- oder State-Funktionen durch die Phasen. Zustandswerte werden nur für Assertions gelesen.

Neues Music-Video-Projekt → Track und Lyrics → Audioanalyse mit Abhören → Einstieg ohne Vorarbeit → eigenes Briefing → Gestaltung → Treatment mit gezielter Alternativvorschau und Abbruch → Skript → Storyboard/Animatic → Shotplanung → optionales Blocking und zwei ausdrückliche Sichtungen → Identitäten → sechs Anker mit Sichtung → Render-Review → gezielte Continuity-Korrektur an 1E → erneute Planung und unverändertes Blocking → nur den betroffenen Anker erneuern → Review freigeben → modellgebundener Videoauftrag → währenddessen Storyboard lesen → sechs Takes im dauerhaften Viewer auswählen → Rohschnitt → Titel → Farbe mit passender Auswahl → Endkontrolle mit bewusster gestalterischer Ausnahme und fünf geprüften Übergängen → vollständige Beispielsequenz abspielen → simulierter Export → leerer Medienordner ohne versteckte Auswahl.

Screenshots zeigen unter anderem die [Korrektur in der Planung](walkthrough/02-correction-plan.png), den [betroffenen Anker](walkthrough/03-correction-anchor.png), den [Videoauftrag](walkthrough/04-video-order.png), die [Take-Auswahl](walkthrough/05-selected-takes.png) und den [abgeschlossenen Export](walkthrough/06-export.png). Zusätzlich wurden Viewer, Gestaltung und Änderungsdialog visuell geprüft.

## Verifikation

**312 automatisierte Prüfpunkte bestanden; keine unbehandelten Browserfehler in den dafür instrumentierten Durchläufen.** Die Zahl umfasst sich teilweise überschneidende Gegenproben und ist kein Ersatz für einen Test mit realen Erstnutzern.

| Prüfgruppe | Bestanden | Nachweis |
| --- | ---: | --- |
| Neue Interaktions- und Gegenproben einschließlich echter Inline-Vorschau | 47 | [checks.json](checks.json) |
| Bestehende Workflow-/Blocking-/Revisionsregressionen | 88 | [regression/checks.json](regression/checks.json) |
| Durchgehende Bedienung vom neuen Projekt bis Export | 12 | [walkthrough/checks.json](walkthrough/checks.json) |
| Freigaben und Schutzbedingungen | 32 | [legacy-studio-guard-checks.json](legacy-studio-guard-checks.json) |
| Schnitt und Arbeitsräume | 35 | [legacy-studio-workspace-checks.json](legacy-studio-workspace-checks.json) |
| Bestehende Polish-Prüfungen | 32 | [legacy-polish.log](legacy-polish.log) |
| Hintergrundaufträge | 25 | [legacy-background-checks.json](legacy-background-checks.json) |
| Vorschaubild und Album-Cover | 41 | [legacy-artwork-checks.json](legacy-artwork-checks.json) |

Vorhandene Tests wurden nur dort an die bewusst ersetzte Bedienung angepasst: einzelne Clay-Bestätigungen statt Sammelbestätigung, Take-Viewer statt Dialog, gezielte Ankeraktion und gerichtete Alternative statt ungerichtetem Vorschlag. Die fachlichen Schutzbedingungen bleiben geprüft. Die mit „Fable“ bezeichneten Fälle sind Wiederholungen früher festgehaltener Befunde; in diesem Durchgang fand kein neuer externer Agent-Review statt.

Die Inline-Auslieferung wurde zusätzlich selbst geladen und bedient; der Take-Viewer bleibt auch bei 768 Pixeln Vorschau-Breite innerhalb des Fensters. Die bisherigen Layoutprüfungen bleiben erfolgreich. Artifact-Hashes und Zähler stehen in [verification.json](verification.json).

Anfängliche Browserläufe scheiterten an gemeinsam genutzten Chrome-Profilen bzw. dem temporären Speicherlimit. Die erfolgreichen Läufe verwenden getrennte Profile und Shared Memory. Frühere Annahmen des Ablaufskripts über nicht mehr vorhandene Footer-Buttons und die aktuelle Schnittposition wurden korrigiert; daraus wurden keine Produktbefunde abgeleitet. Temporäre Browserprofile wurden entfernt.

## Kompatibilität und Grenzen

- Storyboard, Shotplanung, References und optionales Blocking behalten ihre getrennten Aufgaben. Gemeinsame Clay-Locations, shotbezogene Inszenierung und 2D-Vorlagen bleiben erhalten. Die Akzentfarbe des Format-Packs bleibt Bestandteil der bestehenden Desktop-Oberfläche.
- Die Seedance-Demo orientiert sich an `FalModelRegistry.swift` und dem vorhandenen Musicvideo-Fähigkeitenkatalog. Sie ist keine neu implementierte Provider-Anbindung und keine Live-Verfügbarkeitsprüfung. Kosten sind ausdrücklich Beispielkosten.
- Audio und Videowiedergabe bleiben Simulationen; der Take-Viewer verwendet Standbilder. Die Beispielgeschichte hat 20 Sekunden. Eine längere Briefingvorgabe wird sichtbar davon unterschieden, aber nicht generativ umgesetzt.
- Keine realen Modellaufrufe, Dateiexporte oder native macOS-Tests. PR #548, Epic #540 und die parallele Higgsfield-Arbeit wurden nicht verändert. Der Browsernachweis betrifft das UI-Konzept, nicht die native Implementierung.
- Das Ergebnis verbessert die beobachteten Brüche im durchgehenden Ablauf. Ob Orientierung und Premium-Eindruck für reale Erstnutzer überzeugen, muss anschließend in einer beobachteten Nutzung geprüft werden; daraus folgt keine pauschale Abnahmebehauptung.

## Geänderte Mockup-Bausteine

Die Interaktionsverbesserungen liegen überwiegend in `desktop-production-workbench.interaction.js` und `.interaction.css`. Die bestehenden Module für Clay, Workflow, Studio, Medien, Generierung und Cover wurden gezielt angepasst. Der Packager integriert die neue Interaktionsschicht in dieselbe Standalone-Datei und dieselbe eingebettete Vorschau. Tests: `check-desktop-production-first-use.mjs`, `check-desktop-production-first-use-path.mjs` und `check-desktop-production-regression.py`.
