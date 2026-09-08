# [Musicvideo] Performance-, Dance- und Concert-Coverage als ausführbare Pack-Policy

Tracking: https://github.com/iret77/nexgenvideo/issues/490

Parent: #447; Skill-Auswertung: #433.

Quelle: **ai-film-production v3.1.1-en @ `0333751`**; am 2026-09-08 unverändert als GitHub-HEAD bestätigt. Produktbasis für diese statische Ableitung: NexGenVideo `main` @ `5adddf7`. Anbieterfähigkeiten werden durch diese Auswertung nicht live bestätigt.

## Problem

Ein Step mit Funktion `performance` beschreibt noch nicht, welche Ansichten die Performance lesbar machen. Der Skill unterscheidet Dance, Concert und Instrumentalperformance und verlangt dafür jeweils andere Bildbeweise, Referenzen und Schnittentscheidungen.

## Pack-eigene Coverage-Policy

Neue versionierte `MusicPerformanceCoverage`-Extension je zusammenhängendem Songsegment, mit explizitem Typ und genehmigten Ausnahmen:

- **Dance:** Choreografie in benannten, an gemessene Segmente gebundenen Bewegungsbeats; Ganzkörper und Boden-/Kontaktbezug in den Ansichten, die Bewegung beweisen müssen; genügend ununterbrochene Coverage, bevor Akzent-Inserts schneiden. Ein reiner Gesichts-CU erfüllt keinen Ganzkörpernachweis.
- **Concert/Band:** geplanter Master, bewegliche Performanceansicht, Publikumsreaktion und Detail-/Akzent-Coverage; Zuordnung zu Sänger/Musiker/Publikum und Set-Achsen. Keine Pflicht, vier neue Clips zu generieren, wenn vorhandenes genehmigtes Material oder ein Take mehrere Rollen erfüllt. Publikum kann entfallen, wenn das Konzept kein Konzert behauptet.
- **Instrument:** Instrumenttyp, Spieler, Hände/Orientierung, sichtbare Aktion und Performancequelle verbinden. Feinmotorik als Review-Risiko mit konkretem Rescue, z. B. auf Gesamtbewegung oder Reaktion schneiden; keinen falschen Griff als automatisch physikalisch geprüft deklarieren.
- **Szenische Gesangsnummer:** eigene visuelle Identität pro Nummer/Section zulässig, während Sänger-/Instrument-/Songkanon erhalten bleibt. Zwischen Performance und Story wird die Coverage bewusst übergeben.

Pack erzeugt Coverage-Demands; #483 liefert Setups/Blockout, #438 required Assetrollen, #437 ausführbare Route, #439 Promptprojektion, #442/#443 echte Sichtung und #444 Schnitt. „Cut on beat, move with phrase“ wird an tatsächliche Analyse/Audio gebunden, nicht an pauschale Sekunden-/BPMtabellen. Ein Crop darf vorgeschriebene Füße, Boden oder Instrument nicht unbemerkt entfernen.

## Abnahme

- [ ] Dance-Fixture verlangt einen echten Full-body-/Floor-Nachweis; Close-up-only-Candidates bleiben als Inserts nutzbar, erfüllen aber nicht das Master-Requirement.
- [ ] Band-Fixture weist Master, Performer, Reaktion und Detail nach oder hält eine bewusst genehmigte Ausnahme fest; Role-Coverage wird im tatsächlichen Assembly-Plan verwendet.
- [ ] Fehlende Körper-/Instrument-/Motion-Referenz wird vor Spend sichtbar und nicht durch zusätzliche Promptadjektive ersetzt. Kein globales Figurenlimit, Route-Capabilities bestimmen technische Grenzen.
- [ ] Instrument-Finding nennt Zeitbereich, sichtbaren Fehler und umsetzbaren Rescue. Userfreigabe von Risiko übergeht keinen fehlenden Quellen-/Lineage-Proof.
- [ ] Rein importiertes Concert-Fixture erzeugt keine Bilder/Videos; es kann vorhandene Ranges nach demselben Coverage-Vertrag auswählen.
- [ ] Song-/Section-/Choreografieänderung invalidiert die betroffenen Pläne; spätere tatsächliche Cut-Zeiten werden geprüft statt aus Prompt-Zeitmarken behauptet.

## Quellen und Nachbarscopes

[Music Film / Musical: dance, concert, instrument](https://github.com/iret77/ai-film-production/blob/0333751214c7af17977dd33f0ba88ba9c352421e/references/genre-baselines.md), [Renderability/Rescue](https://github.com/iret77/ai-film-production/blob/0333751214c7af17977dd33f0ba88ba9c352421e/references/renderability.md), [Production Pipeline ch. 6/9/10/16](https://github.com/iret77/ai-film-production/blob/0333751214c7af17977dd33f0ba88ba9c352421e/references/production-pipeline.md), [Beat-/Performance-Timing 14b](https://github.com/iret77/ai-film-production/blob/0333751214c7af17977dd33f0ba88ba9c352421e/references/video-prompting.md).

Die generische Camera-/Asset-/Review-Maschinerie bleibt in bestehenden Core-Issues. #187/#188 bleiben Pattern-Content; dieses Issue liefert dessen musikspezifische ausführbare Coverage-Policy. Die Song-/Mouth-Ownership-Schiene liegt im Geschwister-Issue #488.

## Gemeinsame Umsetzungsgrenze

Pack-eigene Policy und Ressourcen konsumieren Core-Writer, AssetGraph, Execution/ReferencePlan, Compiler, Review und Assembly. Neue versionierte Extension-Artefakte statt Stored Fields in ABI-gepinnten Typen; geschlossenes Tool-Schema, ein kanonischer Writer, unabhängiges Gate und exakte Quellen-Lineage. Alte gepinnte Projekte werden nicht beim Öffnen migriert. Gesperrter Start/Phasenvertrag bleibt erhalten; notwendige Abweichungen vor Implementierung separat entscheiden. Verifikation ausschließlich GitHub Actions, keine bezahlten Generationstests. Dieses Issue ist Backlog, keine Build-/Merge-/Release-Freigabe.
