# Konzept: Diagnose-Build für den UI-Hänger

Status: Vorschlag, keine Implementierung und keine Build-/Release-Freigabe.

## 1. Ziel und Nachweis

Beim nächsten UI-Stillstand entsteht automatisch ein lokal gesichertes Diagnosepaket.
Es verbindet symbolisierbare Thread-Stacks mit der tatsächlichen Ereignisfolge, dem
letzten bekannten UI-Zustand und den für einen Offline-Replay benötigten Eingaben.
Während des Hängers muss der Nutzer weder ein Menü öffnen noch einen Sample erzeugen.

Ein einzelner Vorfall kann einen finalen Fix nicht garantieren. Das Abnahmeziel ist
konkret: den blockierenden Codepfad und die vorausgehenden Zustandsänderungen ermitteln,
den Fall möglichst reproduzieren und einen daraus abgeleiteten Fix unabhängig prüfen.
Ein grüner Test ohne reproduzierenden Kontrollfall bleibt kein Fix-Nachweis.

## 2. Vorhandenes und nachgewiesene Lücken

- `Sources/NexGenVideo/Utilities/MainThreadHangWatchdog.swift` sendet Main-Queue-Pings
  im Sekundentakt, erkennt einen ausstehenden Ping nach acht Sekunden und sammelt
  einmalig einen dreisekündigen `/usr/bin/sample`. Bis zu 32 grobe Kontextwechsel
  werden mit App-Version, Build und Betriebssystem als JSON gespeichert.
- `AppDelegate` startet ihn erst bei `applicationDidFinishLaunching`; der Diagnose-
  Replay startet vorher und durchläuft diesen normalen Startpfad bislang nicht.
- `AgentPanelView` meldet Phase, Streaming und offene Entscheidungskarten. Es fehlen
  Ereignisreihenfolge, genaue Nachrichtenrevision, Geometrie und Beginn/Ende einzelner
  Render-, Bild- und Layoutoperationen.
- `Log` verwendet Unified Logging und stderr, `Telemetry` bindet Sentry ein. Beides
  ist keine garantierte, konsistente lokale Replay-Aufzeichnung. Bestehende Logtexte
  sind nicht automatisch für einen datenschutzarmen Export geeignet.
- Die bisherigen Replays sind Debug-Builds mit rekonstruierten Zeitabläufen. Auch mit
  Originalchats, Timeline, Manifest, Pipeline-Zustand und gepinntem Pack wurde der
  gemeldete Hänger nicht reproduziert. Medien und weitere Phasenartefakte fehlen teilweise.

Folgerung: nicht noch ein allgemeiner Crashlogger, sondern eine zusammenhängende
Aufzeichnung des realen Vorgangs im normalen, optimierten App-Lebenszyklus.

## 3. Architektur

### A. Begrenzter Ereignisrekorder in der App

Kleine, typisierte Ereignisse mit monotonem Zeitstempel, Sequenznummer, Start-/Fenster-
ID, Korrelations-ID und relevanter Revision. UTC dient nur der Zuordnung zum Vorfall.
Erfasst werden sowohl der Eingang eines Ereignisses als auch seine Übernahme durch
den Main Actor; damit bleiben Queue-Verzögerung und Ausführungsdauer unterscheidbar.

Der UI-Pfad schreibt nur kleine Datensätze in vorreservierte, begrenzte Puffer.
Kein synchrones Dateischreiben, Komprimieren, Hashen großer Bilder oder Warten auf IPC.
Bei Überlast werden Ereignisse verworfen und die Lücke gezählt, nicht die UI blockiert.
Eine eigene Schreibstrecke persistiert fortlaufend atomar abgeschlossene Segmente;
Teilsegmente bleiben anhand von Längen/Prüfsummen lesbar bis zum letzten gültigen Record.

Zusätzlich `OSSignposter`-Intervalle mit denselben IDs für die spätere Analyse in
Instruments. Signposts ergänzen das eigene Journal, ersetzen es nicht: Ein nachträglich
gestartetes Instruments kann die Vergangenheit nicht vollständig rekonstruieren.

### B. Separater, mitgelieferter Diagnose-Helfer

Ein signierter Swift-Helfer im App-Bundle wird früh beim normalen App-Start gestartet.
Kein zusätzlich zu installierendes Werkzeug, kein Login-Item, kein Root-Dienst.
Er überwacht einen bestätigten Main-Thread-Heartbeat unabhängig von SwiftUI und dem
Threadpool der App. PID allein reicht nicht: PID, Prozessstart und Start-ID werden
gebunden, um nach einem Neustart keinen fremden Prozess zu untersuchen.

Der vorhandene In-Process-Watchdog wird integriert, nicht als zweiter konkurrierender
Sampler weiterbetrieben. Ein Incident-Koordinator verhindert doppelte Erfassungen.
Sentry kann ergänzen, ist aber weder für die lokale Erkennung noch den Export nötig.

Der Helfer darf ausschließlich den zugehörigen NGV-Prozess untersuchen. Er arbeitet
mit bereits publizierten Zustandsdaten und Journal-Segmenten, fragt bei einem Hänger
keine SwiftUI-Hierarchie ab und wartet nicht auf eine Antwort des Main Actors.
Nach normalem Beenden beendet er sich; nach Prozessverlust schließt er das Paket
innerhalb eines begrenzten Zeitfensters ab und beendet sich ebenfalls.

### C. Kohärente Replay-Daten

Im ausdrücklich aktivierten Modus mit Projektinhalten wird ein Ausgangszustand mit
anschließenden Render-Eingaben und Zustandsänderungen aufgezeichnet. Es werden keine
Provider-Aufrufe wiederholt. Beide Agent-Backends liefern dasselbe Diagnoseformat.

Erfasst wird an der Grenze vom geparsten Backend-Ereignis zum App-Zustand, einschließlich
Teiltexten, partiellen Tool-Argumenten und Bildbereitstellung. Keine HTTP-Header,
CLI-Umgebung oder Authentifizierungsnachrichten. Ein zusätzlicher Marker nach der
Übernahme dokumentiert, welche Revision tatsächlich in der UI angekommen ist.

Nachrichten, Bildbytes und referenzierte lokale Artefakte erhalten immutable
Diagnose-Blob-IDs. Große Bytes werden einmalig außerhalb des UI-Pfads gesichert.
Ausgangszustand und Deltas teilen eine explizite Revision; Dateistände werden beim
Commit erfasst, nicht beim Hänger durch unkoordiniertes Kopieren einer lebenden
Recovery-Struktur. Ein Ringpuffer darf keine Deltas verwerfen, ohne vorher einen neuen
vollständigen Ausgangszustand zu sichern. Fehlende Bytes, Versionskonflikte und verlorene
Ereignisse stehen ausdrücklich im Manifest: keine behauptete Vollständigkeit.

## 4. Was aufgezeichnet wird

| Bereich | Erforderliche Daten |
| --- | --- |
| Build und Umgebung | Version, Buildnummer, Commit, Release-Konfiguration, SDK/Compiler, macOS-Build, Architektur, aktive Pack-Version/Vertrag/Hash, geladene Binary-UUIDs und Ladeadressen, Display-Skalierung und Fenstergrößen |
| UI-Zustand | Aktives Fenster/Panel, Split-Breiten, Scroll-Offset und Inhalts-/Viewport-Höhe, Pin-to-bottom, Scrollphase, Fokusziel als interner Typ/ID, offene Karte/Sheet, sichtbare Turn-IDs, letzter abgeschlossener Layoutschritt; Snapshot-Alter |
| Agent und Pipeline | Stream-/Turn-/Tool-Korrelation, Empfang und Main-Actor-Übernahme, Blocktypen und Größen, Dialog öffnen/schließen, Freigabe-/Generation-Zustand, Phase/Stage, Engine-Refresh angefordert/begonnen/beendet |
| Renderstrecke | Transcript-Projektion, Markdown-Verarbeitung, Bilddekodierung und Bildübergabe an die UI, bekannte AppKit-/SwiftUI-Layoutgrenzen: Start, Ende, Dauer, vorgeschlagene und resultierende Maße, nicht-finite Werte |
| Systemzustand | Thread-Samples, CPU-Zeitdifferenzen, Speicherverbrauch und Druck, Threadzahl, App aktiv/inaktiv, Sleep/Wake, Live-Resize und modale Zustände; ausdrücklich keine Liste fremder Apps |
| Optionaler Replay-Inhalt | Gezeigte Texte/Tool-UI-Payloads, benötigte Bilder, Timeline/Manifest und beteiligte Pipeline-Artefakte mit Versionen und Integritätsprüfung; keine ungefilterte Projektkopie |

UI-Zustände werden beim normalen Zustandswechsel oder an bestehenden Layoutgrenzen
als Werte publiziert. Keine zusätzlichen Layoutdurchläufe, keine `@State`-Änderungen
aus Geometriemessungen und keine Traversierung sekundärer SwiftUI-Layer für Diagnostik.
Freitext, Tastendrücke und Feldinhalte gehören nicht in die strukturelle Ereignisspur.
Erfasste Maße sind Beobachtungen, keine Behauptung über interne SwiftUI-Ursachen.

## 5. Ablauf bei einem Stillstand

Vorgeschlagene, vor Versand zu validierende Schwellen:

1. Main-Thread-Ping alle 500 ms, maximal ein ausstehender Ping. Heartbeat und
   Run-Loop-Fortschritt werden getrennt von Hintergrundaktivität protokolliert.
2. Nach zwei Sekunden ohne Antwort: Verdacht markieren und vorhandene Journal-
   Segmente gegen Überschreiben sichern. Noch keine Nutzerunterbrechung.
3. Nach fünf Sekunden: lokales Incident-Verzeichnis und Manifest sofort anlegen;
   alle Threads drei Sekunden lang sampeln. CPU-Verlauf und letzte publizierte
   Zustandsrevision mitsichern.
4. Bei anhaltendem Stillstand um Sekunde 15: zweites, zeitlich getrenntes Sample.
   So lässt sich ein stabiler Wartepfad von einer wechselnden Layout-/CPU-Schleife
   unterscheiden. Weitere Erfassung pro Vorfall bleibt begrenzt.
5. Bei Erholung: Ende/Dauer und erste neue UI-Revision ergänzen. Bei Force-Quit:
   vorhandene Daten finalisieren, fehlendes Ende und unvollständige Segmente markieren.

Sleep/Wake und eine pausierte Überwachung setzen die Messbasis zurück. Modale Dialoge
und Live-Resize werden korrekt berücksichtigt, aber nicht pauschal als Blindstellen
ausgenommen. Ein lange laufender Provider bei weiterhin bedienbarer UI ist kein UI-Hang.
Der Helfer beendet oder startet NGV niemals automatisch neu und verändert weder
Projekt, Gate-Zustand noch laufende kostenpflichtige Jobs.

## 6. Sampling und Symbolisierung: harte Versandvoraussetzung

Der bestehende `/usr/bin/sample`-Pfad ist der erste Kandidat. Dass er in einem
Debug-/Ad-hoc-Build funktioniert, beweist keine Berechtigung beim Developer-ID-
signierten Hardened-Runtime-Build. Auch eine gleiche Team-ID ist kein solcher Beweis.

Deshalb zuerst ein Machbarkeits- und Abnahmetest am tatsächlich signierten/notarisierten
Paket unter macOS 26, als normaler Benutzer, ohne Debugger, sudo oder Entwickler-Setup.
Der Report muss verwertbare Main-Thread- und weitere Thread-Stacks enthalten.
Bei Sperre wird der genaue Fehler gespeichert; ein leerer Report zählt nicht als Erfolg.
Dann ist vor Versand ein geprüfter In-Process-Sampling-Pfad für eigene Threads nötig,
integriert mit dem vorhandenen Crash-SDK, ohne zweiten konkurrierenden Signalhandler.
Ein verfügbarer geeigneter SDK-Pfad ist noch zu verifizieren, nicht vorausgesetzt.

Kein stilles Hinzufügen von `get-task-allow`, kein Abschalten der Hardened Runtime und
keine privaten SwiftUI-Hooks. Ohne nachgewiesen funktionierenden Stack-Capture wird
dieser Build nicht als einsatzbereiter Diagnose-Build ausgeliefert.

CI archiviert passende dSYMs für Host, Engine, Helfer und das tatsächlich geladene Pack
versionsgebunden über die gesamte Diagnose hinaus. Binary-UUID und dSYM-UUID müssen
übereinstimmen. Die heutige optionale Sentry-Symbolübertragung und siebentägige
DMG-Artefaktaufbewahrung reichen dafür nicht als Nachweis.

## 7. Datenschutz, Grenzen und Export

- Lokaler Diagnosemodus mit einmaliger klarer Einwilligung vor der Arbeit. Strukturdaten
  und zusätzliche Projektinhalte sind getrennt wählbar; ohne Inhalte ist der Replay
  entsprechend eingeschränkt. Diese Konzeptanfrage allein aktiviert keine Aufzeichnung.
- Kein automatischer Upload, auch nicht über Sentry. Diagnoseereignisse erhalten einen
  eigenen strikt gefilterten Kanal; bestehendes stderr wird nicht ungeprüft übernommen.
- Niemals API-Keys, Tokens, Keychain-Daten, Umgebungsvariablen, Autorisierungsheader,
  signierte Download-URLs oder fremde Dateien. Pfade und IDs werden minimiert; rohe
  Stack-Samples können lokale Pfade enthalten und bleiben deshalb ebenfalls geschützt.
- App-private Ablage mit Verzeichnisrechten 0700 und Dateirechten 0600; Projektinhalte
  werden bereits auf dem Datenträger authentifiziert verschlüsselt, nicht erst beim Export.
  Der Helfer braucht während eines Hängers keine interaktive Keychain-Freigabe.
- Vorschlag für harte Grenzen: 120 Sekunden Ereignisfenster, 32 MiB Strukturjournal,
  256 MiB Inhaltspuffer, maximal drei Vorfälle und insgesamt 1 GiB Diagnoseablage.
  Bei Grenzen bleiben Manifest/Stacks/Strukturdaten vorrangig erhalten; verlorene oder
  ausgelassene Inhalte werden ausgewiesen. Keine unbemerkte Vollplatten-Aufzeichnung.
- Unexportierte Daten verfallen nach sieben Tagen; pausiert die App, erfolgt Bereinigung
  beim nächsten Start. Nach Abschluss der Analyse werden Entwicklerkopien, CI-Artefakte,
  verschlüsselte Fixtures und zugehörige Schlüssel entfernt. Kein dauerhaftes privates
  Regressionstestmaterial: stattdessen einen synthetischen Minimalfall ableiten.

Nach Erholung oder nächstem Start erscheint: „Diagnose eines UI-Stillstands gespeichert“
mit „Diagnose exportieren“ und „Löschen“. Export erzeugt genau ein Paket mit Inhaltsliste,
Größe und Vollständigkeitsstatus. Während des Hängers ist keine Interaktion erforderlich.
Der Export ist eine Kopie; lokale Daten werden nicht allein aufgrund eines erfolgreichen
Exports gelöscht. Die schon vorhandene Aktion zum Öffnen des Diagnoseordners bleibt.

## 8. Inhalt und Auswertung des Diagnosepakets

`manifest.json` beschreibt Schema, Build, Vorfall, Prüfungen, Datenschutzmodus und Lücken.
Dazu kommen Ereignisjournal, letzte UI-Snapshots, Thread-Samples, CPU-/Speicherverlauf,
Binary-/Symbolzuordnung und optional verschlüsselte Replay-Blobs. Jedes Teilstück erhält
Integritätsprüfung; ein abgebrochener Capture bleibt als unvollständiges Paket nutzbar.

Ein Auswerter liefert: zuletzt begonnene, nicht beendete Operation; letzte erhaltene
und letzte angewandte Stream-Revision; zeitliche Reihenfolge der UI-Änderungen; dominante
symbolisierte Stacks; konsistente oder fehlende Replay-Eingaben. Keine automatische
Behauptung „Root Cause“, nur belegte Befunde und explizite Hypothesen.

Replay erfolgt vollständig offline: echte Ereignisreihenfolge und Zeitabstände,
gesicherter Ausgangszustand, identische Pack-Bindung und Geometrie. Kein Agentenstart,
keine Generierung und kein Gate-Schreiben. Zusätzlich kontrollierte Zeitvariationen,
weil eine Aufzeichnung das Thread-Scheduling nicht vollständig reproduziert.

## 9. Abnahme vor Übergabe an den Nutzer

| Test | Erforderlicher Nachweis |
| --- | --- |
| Main-Thread-Endlosschleife | Helfer erkennt Stillstand, zwei lesbare Samples zeigen die Schleife, Journal enthält den auslösenden Marker |
| Main-Thread-Warten auf Semaphore | Thread-Stacks unterscheiden Wartepfad vom CPU-Spin; Helfer bleibt funktionsfähig |
| Erholung nach kurzem/langem Stillstand | Richtige Schwellen, genau ein Vorfall, Erholungsmarker und Dauer stimmen |
| Force-Quit während Capture | Nach erneutem Start ist mindestens das früh gesicherte Teilpaket exportierbar; kein Main-Thread-Handshake nötig |
| Sleep/Wake, Modal, Live-Resize, langsamer Provider | Keine unbegründeten Hang-Meldungen; echte UI-Blockade bleibt erkennbar |
| Platte voll, verweigerte Rechte, Helfer-Ausfall, Puffer voll | Sichtbarer Capture-Fehler bzw. Lückenstatus, keine zusätzliche UI-Blockade, begrenzter Ressourcenverbrauch |
| Datenschutz | Markierte Test-Secrets fehlen in allen Exporten und Telemetriepfaden; Löschung/Fristen und Dateirechte werden geprüft |
| Release-Parität | Normaler AppDelegate-/Fenster-/Projektstart, Release-Optimierung, signiertes Paket, macOS 26; kein bloßer Harness-Sonderpfad |
| Replay | Aufzeichnung eines bekannten injizierten Fehlers reproduziert diesen offline; reparierte Variante besteht, fehlerhafte Kontrolle schlägt fehl |

Zielbudget im Vergleich zur identischen App ohne Rekorder: weniger als ein Prozentpunkt
zusätzliche Idle-CPU, höchstens fünf Prozent zusätzliche p95-Interaktionslatenz und
höchstens 64 MiB zusätzliche App-RAM-Nutzung; Helfer separat messen und auf 64 MiB
begrenzen. Dies sind Abnahmekriterien, keine bereits gemessenen Zusagen. Der Test muss
viele Bilder, lange Streams, Kartenwechsel, Scrollen und Fenstergrößenänderungen umfassen.

## 10. Umsetzung und Build-Entscheidung

1. Signierten Capture-Pfad und Symbolisierung nachweisen; Sicherheits-/Berechtigungsrisiko zuerst.
2. Rekorder, konsistente Snapshots und Helfer mit begrenzten Puffern implementieren.
3. Gezielte Instrumentierung der Chat-/Layout-/Bild-/Pipeline-Grenzen und Offline-Replay.
4. Datenschutz, Export, Löschung sowie die komplette Fehlersimulation abnehmen.
5. Einen Diagnose-Build als zusammenhängendes Paket vorbereiten, nicht mehrere Teil-Releases.

Vorgeschlagene Versionsbezeichnung: nächste freie Patch-Version, beispielsweise 1.5.3,
mit neuer monotoner Buildnummer und klarer Kennzeichnung als Diagnose-Build. Version und
Changelog gemeinsam aktualisieren. Keine unbewiesenen Layoutänderungen oder fremden
UI-Issues in diesen Build mischen; Basis ist der tatsächlich betroffene Produktionspfad.
Pack-Pins und Pack-ABI bleiben unverändert; Diagnosezustand gehört nicht in öffentliche
Pack-Grenztypen oder in Projektdateien.

Builds/Tests/Bundles ausschließlich GitHub Actions (`xcode-27`); Laufzeitprüfung auf
macOS-26-Runnern. Bestehende Signierung/Notarisierung wiederverwenden. Kein Build auf dem
MacBook. Ein echter, durch CI nicht erfüllbarer Berechtigungsnachweis wäre eine konkret
zu benennende Abnahmehürde, keine stillschweigende Verlagerung der Tests auf den Nutzer.
Merge und Release erst nach ausdrücklichem „build now“; dieses Konzept startet nichts.

## Quellen

Apple beschreibt Hänger als Problem des Main Threads bzw. Main Run Loops:
[Understanding hangs in your app](https://developer.apple.com/documentation/xcode/understanding-hangs-in-your-app).
Zeitlich korrelierte Intervalle werden durch
[Recording Performance Data](https://developer.apple.com/documentation/os/recording-performance-data)
unterstützt. Die Berechtigungsgrenzen bei Prozesszugriffen stehen in
[Debugging tool entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.debugger)
und [Hardened Runtime](https://developer.apple.com/documentation/security/hardened-runtime).
Diese Quellen ersetzen nicht den geforderten Test des konkreten signierten Artefakts.
