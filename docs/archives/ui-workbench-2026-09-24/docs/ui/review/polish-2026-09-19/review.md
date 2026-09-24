# Desktop-Polishing · 19.09.2026

Scope: bestehender Clickdummy und native Umsetzungsplanung. Keine Swift-Änderung, kein nativer Build, keine Veröffentlichung.

## Unabhängiges Review

Claude über das nachgeprüfte High5-Profil, Modellalias `fable`, Effort `high`; tatsächlich gemeldetes Modell **claude-fable-5-1**. Nur Read/Glob/Grep, Plan-Permissions, keine Delegation/Schreibtools. Erster erfolgreicher Lauf: 412.7 s, 49 Turns, Exit 0, parsebares Schema, keine Permission-Denials. [Originalbefunde](fable-review.json). Fable hat Quellen und Screenshots geprüft, nicht selbst interaktiv geklickt.

Die automatische Freigabeprüfung lehnte zunächst den Alias-Aufruf ab, weil die erlaubte CLI nicht erkennbar war. Nach Verifikation, dass `claude-high5` nur `CLAUDE_CONFIG_DIR` setzt, wurde der direkte `claude -p`-Aufruf mit genau diesem High5-Profil freigegeben. Es wurden keine Schutzmechanismen deaktiviert.

## Verifizierte Befunde und Behandlung

| Fable-Befund | Entscheidung / Ergebnis |
|---|---|
| Falsches Phasenziel in der Revisionsleiste | Bestätigt, behoben: Überschrift und Revisionsaktion benennen die betrachtete Phase; der Dialog bestätigt genau dieses Ziel. |
| Shotplanung überschreibt freigegebenes Timing | Bestätigt, behoben: Dauer/Handlung lesend; expliziter Storyboard-Rewind. Der Handler verweigert auch direkte Timing-Mutationen aus der Planung. Native Dauer-Eigentümerschaft bleibt eigene Vertragsentscheidung. |
| Deaktivierte Trim-Griffe verdecken Clipnamen | Bestätigt, behoben: Griffe ausschließlich im Schnitt und auf ungesperrten Spuren. |
| Uneinheitliche Panel-Kopfkanten | Bestätigt, behoben: ein 40-px-Token für Sidebar, Arbeitsfläche und Inspector. Zwei knappe Inspector-Zeilen bleiben erhalten, damit Objekttyp/Quelle sichtbar sind; volle Texte per Tooltip. |
| Inspector verliert Kontext beim Scrollen | Bestätigt, behoben: Kopf und Icon-Reiter außerhalb des scrollenden Inhalts; stabil reservierter Scrollbalkenraum im Dummy. Native Overlay-Scroller sind Umsetzungssache. |
| Produktionsfelder versehentlich gestapelt | Bestätigt, behoben: gemeinsames Label-/Wert-Raster, rechtsbündige Zahlen, volle Feldbedienung. |
| Doppelte Shotwahl / unechter Transport | Bestätigt, behoben: keine zweite Shotleiste in der Liste; Blocking/References/Takes nur Shotwahl und Gesamtdauer, kein Playhead/Transport. |
| Exportstart in globaler Statusleiste | Bestätigt, behoben: Start im kontextbezogenen Ausgabedock; Status und zwei Aktivitätsanzeigen bleiben getrennt. Im Verlauf wird kein unbeteiligter neuer Export gestartet. |
| Postproduction mischt Modus und Clipnavigation | Bestätigt, behoben: Clipliste nur in der Endkontrolle, neutral ausgewählt; dort mit dem Review-Playhead verbunden. Sonst bleibt die Timeline die Objektauswahl. |
| Inspector-Reiter brechen um | Bestätigt, behoben: einzeilige, zugänglich benannte Icon-Reiter. Gruppenüberschrift benennt das aktuelle Werkzeug. |
| Vier permanente Medien-Kopfzeilen | Bestätigt, behoben: Kopf und Filterzeile; Suchbereich im Suchfeld, vollständiger Ordnerpfad im Tooltip. Auf schmalen Vorschauflächen umbrechende Filter statt abgeschnittener Controls. |
| Ausgewählter Storyboard-Shot außerhalb der Sicht | Bestätigt, behoben: Phase-/Auswahlwechsel holt das Objekt in die lokale Arbeitsfläche. Kein Scrollen des äußeren Hosts; kein laufendes Zurückspringen bei manueller Sichtung. |
| Umgebrochene Export-Clipnamen | Bestätigt, behoben: Clipname und Timecode in zwei definierten Zeilen, 112-px-Miniaturen. |
| Unvollständige Modellprofile im Dummy | Richtiger Erhaltungsbefund. Kein neues fiktives Demomodell ergänzt. GEN-03/04 bleiben `partial`; nativ vollständigen vorhandenen GenerationView-Eingabeteil samt Validatoren wiederverwenden. Kein Copy-Paste des vereinfachten Dummy-Slots. |
| Veraltete normative Spec | Behoben: 121 Gruppen, tatsächliche Sidebar-Regeln, Shotwahl/Transport, Timing-Eigentümerschaft und Exportdock aktualisiert. |

Zusätzliche eigene Korrekturen: References zeigt standardmäßig ein vollständiges Rendering; Sketchvergleich ist bewusst wählbar. Audioabschnitte verwenden dieselbe zeitproportionale Breite wie die Beat-Achse. Verdeckte 5-px-Offsets im Schnitt-Sidebarkopf entfernt; keine automatische Panelbreitenänderung durch die Basis-Freigabe. Offline-Reviewkopie verwendet nun dieselben vom Inline-Host gelieferten Lucide-Symbole statt Text-Ersatzsymbolen.

## Prüfung und Grenzen

- 18 Ansichten vor und nach Polishing aufgenommen; nachher 54 Layoutzustände bei 1440/1048/768 px vermessen. Kein horizontaler Überlauf, keine abgeschnittenen Button-Inhalte. Alle drei Panel-Kopfkanten werden zusätzlich explizit geprüft.
- 32 bestandene gezielte Interaktionsprüfungen für Freigabe, Rewind, Timing, Vergleich, Tab-Reihen, Scrolling, Exportziel und Suchbereich: [polish-checks.json](polish-checks.json).
- Bestehende Prüfungen für NLE/Workspaces, Schutzregeln, Fable-Regressionsfälle, UX, Hintergrundaktivität und Exportbilder ausgeführt. Eine alte UX-Abfrage erwartete den ersetzten Such-Tab-Button; sie wurde auf die tatsächlich gewählte Suchfeld-Option angepasst, bei identischer fachlicher Behauptung.
- Echte Inline-Vorschau geprüft ([Aufnahme](after-inline.png)); statische Aufnahmen aller Arbeitswege visuell geprüft. Diese Evidenz beweist keine Videodekodierung, Audioausgabe, macOS-Accessibility oder native Engine-Parität.
- Funktionsinventar weiterhin 121 Gruppen: 114 simuliert, 2 teilweise, 5 Vorschläge. Native Quellenstand unverändert. Kein Modell-/Provider-Aufruf und kein Videoexport im Dummy.

Die [Umsetzungsplanung](../../implementation-plan-2026-09-19.md) ordnet alle Arbeitswege den drei Benchmarks zu und trennt UI-Wiederverwendung von notwendigen neuen Verträgen. Besonders: Sanity vor Frames ersetzt keinen abschließenden Review der erst danach generierten Ankerbilder.

## Zweiter Fable-Durchgang

[Abschlussbefunde](fable-followup-review.json): erneut `claude-fable-5-1`, high, 204.0 s, 39 Turns, Exit 0, keine Permission-Denials. Fable bestätigt die beiden hohen Korrekturen, Kopfkanten, Medienverdichtung, Icon-Reiter, Shotwahl und den Exportstart. Vier Restbefunde wurden nachgeprüft und anschließend behoben:

1. Getrennte Szenen-/Abschnittsauswahl statt Verwendung der Shot-ID. Fable sah während des laufenden Nachchecks dieselben zwei gerade neu reproduzierten Fehlfälle (27/29), die auch im eigenen visuellen Review aufgefallen waren. Jetzt besitzt jedes Textdokument seinen eigenen geklemmten Auswahlindex; die Shotauswahl wird nicht überschrieben. Leere Alternativvorschläge sind zusätzlich gegen Übernahme geschützt.
2. Der temporäre rote Prüfstand wird hier ausdrücklich dokumentiert; final bestehen alle 32 gezielten Fälle einschließlich Szenenrevision und Textfokus. Das Skript liefert bei einem Fehlschlag Exit 1.
3. Postproduction nennt im Timeline-Hinweis nur Auswahl/Inspector, keine dort entfernten Trim-/Quellenaktionen.
4. Etappe 3 des Plans benennt getrennte Sidebar-Einträge in nativer Reihenfolge: Referenzstudien → Shotliste → Plausibilitätsprüfung → Shot-Anker → Video-Takes. Der vollständige Render-Review folgt erst mit dem eigenen Vertrag. Keine irreführende gemeinsame References-Freigabe.

Diese letzten Korrekturen wurden von Codex umgesetzt und gezielt geprüft; es wird keine dritte externe Freigabe behauptet.

Finale Evidenz: 209 bestandene Interaktionsprüfungen über sieben Prüfläufe (35 + 31 + 29 + 16 + 25 + 41 + 32), dazu 54 übereinstimmende Dreifach-Kopfkanten ohne horizontalen Überlauf. Die Aufnahme-/Mockprüfungen sind keine native Laufzeitprüfung.
