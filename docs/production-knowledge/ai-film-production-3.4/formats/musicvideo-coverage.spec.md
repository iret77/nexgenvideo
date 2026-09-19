> Revision 3.4: Quelle ist das bereitgestellte Archiv, kein behaupteter GitHub-Commit. Historische Issues #488–#490 sind umgesetzt/geschlossen; die neue Runtime-Adaption ist ein eigener Delta-Scope. Vollständige Regeln und Ausnahmen: [Migrationsvertrag](../migration-3.4.spec.md), [Handbuch](../README.md). Diese Spec ändert keine gesperrte Phasenfolge.

### Gemeinsames 3.4-Delta

Eine projektweit dokumentierte Technik A (Caption Spine), B (Blocks) oder C (Master Style Block + Story) trägt die Prompts; kein universeller Default und keine stillen Wechsel. Der Agent liefert Canon, Ereignisfolge/Endzustände, Acting und Referenzjobs, ergänzt Look-/Kamerakontrollen nur begründet und hält Lint sowie Crew choices getrennt vom Modellprompt. Drafts prüfen die geplante Take-Länge; zehn Sekunden sind nur ein Fallback. W10 ergänzt ein Animatic als Planungsartefakt. Explizite `[edit]`-Blueprintprüfungen laufen in Assembly und erzwingen keinen Reroll. Kontext wird abschnitts- und technikbezogen geladen.

Ergänzend werden Performance-Capture und daraus abgeleitete Neuinszenierung als source_mode-gebundene Route geplant; Bewegungsclip, Figurenidentität und Look erhalten getrennte Referenzjobs. Eine Unterweisung jeder Körpermechanik ist kein Pflichtfeld. Musik-/Choreografieereignisse bleiben die verbindlichen Beats; Modell-Timecodes budgetieren Ereignisse und beweisen keine tatsächlichen Schnittzeitpunkte. Loop- und Kameraübergänge werden im Blockout/Animatic geprüft, anschließend am Ergebnis.

# [Musicvideo] Performance-, Dance- und Concert-Coverage als ausführbare Pack-Policy

Tracking: https://github.com/iret77/nexgenvideo/issues/490

Parent: #447; Skill-Auswertung: #433.

Quelle: **ai-film-production v3.4 aus dem bereitgestellten Archiv**; dessen Identität steht in `../inventory.json`. Produktbasis dieser Fortschreibung: NexGenVideo `main` @ `8bd8fbde`. Anbieterfähigkeiten werden durch diese Auswertung nicht live bestätigt.

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

[Music Film / Musical: dance, concert, instrument](../handbook/genre-baselines.md), [Renderability/Rescue](../handbook/renderability.md), [Production Pipeline ch. 6/9/10/16](../handbook/production-pipeline.md), [Beat-/Performance-Timing 14b](../handbook/video-prompting.md).

Die generische Camera-/Asset-/Review-Maschinerie bleibt in bestehenden Core-Issues. #187/#188 bleiben Pattern-Content; dieses Issue liefert dessen musikspezifische ausführbare Coverage-Policy. Die Song-/Mouth-Ownership-Schiene liegt im Geschwister-Issue #488.

## Gemeinsame Umsetzungsgrenze

Pack-eigene Policy und Ressourcen konsumieren Core-Writer, AssetGraph, Execution/ReferencePlan, Compiler, Review und Assembly. Neue versionierte Extension-Artefakte statt Stored Fields in ABI-gepinnten Typen; geschlossenes Tool-Schema, ein kanonischer Writer, unabhängiges Gate und exakte Quellen-Lineage. Alte gepinnte Projekte werden nicht beim Öffnen migriert. Gesperrter Start/Phasenvertrag bleibt erhalten; notwendige Abweichungen vor Implementierung separat entscheiden. Verifikation ausschließlich GitHub Actions, keine bezahlten Generationstests. Die 3.4-Fortschreibung ist in #547 erfasst; keine Build-/Merge-/Release-Freigabe.
