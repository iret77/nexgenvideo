# [Musicvideo] Visuelles Konzept als songgebundene Wiederholungs- und Steigerungskurve planen

Tracking: https://github.com/iret77/nexgenvideo/issues/489

Parent: #447; Skill-Auswertung: #433.

Quelle: **ai-film-production v3.1.1-en @ `0333751`**; am 2026-09-08 unverändert als GitHub-HEAD bestätigt. Produktbasis für diese statische Ableitung: NexGenVideo `main` @ `5adddf7`. Anbieterfähigkeiten werden durch diese Auswertung nicht live bestätigt.

## Problem und vorhandene Basis

Brief kennt bereits `narrative | performance | abstract | hybrid`; Storyboard hat Section-Funktionen wie Aufbau/Refrain/Kontrast/Auflösung und einen Refrain-Anker. Diese vorhandenen Begriffe sollen nicht nochmals eingeführt werden. Was die Skill-Auswertung zusätzlich fordert, ist eine nachvollziehbare Verbindung zwischen **einem tragenden visuellen Konzept**, dessen gezielter Wiederkehr/Variation und dem tatsächlich gemessenen Songverlauf.

## Pack-eigene Funktion

Ein versionierter `MusicVisualArc` verknüpft genehmigtes Treatment, Track-/Analysis-Fingerprint und vorhandene Section-/Motif-/Shot-IDs:

- pro Section: musikalische Funktion aus genehmigter Analyse, visuelle Funktion, Motiv-/Setup-Bezug, was gleich bleibt, was variiert und warum; Variation kann Framing, Performance, Farbe/Licht, Raum oder State betreffen;
- wiederkehrender Refrain: bewusstes Wiedererkennen plus geplante Veränderung; bloßes Wiederholen ist ebenso zulässig wie Steigerung, wenn es künstlerisch entschieden ist. Nicht jeder nächste Refrain muss automatisch größer/heller/schneller werden;
- Bridge/Breakdown/Outro: Kontrast, Rücknahme, Umdeutung oder Closure ausdrücklich planen; keine automatische zusätzliche Storywendung für abstrakte/performancegetriebene Videos;
- narrative/hybrid: kausaler Storygraph #484 plus Song-Arc, voneinander unterscheidbar. Nichtnarrativ: Motiv-/Energie-/Performancebogen ohne erfundenen Protagonistenkonflikt;
- Lyrics: genehmigte Wahl zwischen wörtlicher, metaphorischer, kontrapunktischer oder nicht verwendeter Bildbeziehung. Das sind semantische Zuordnungen; sie erfinden keine Zeitmarken und ändern nicht die Originallyrics.

Der Agent erzeugt den Arc aus bereits vorhandener Analyse und kreativen Entscheidungen; kein zusätzliches Pflichtinterview. Er zeigt verständlich: „Das Motiv kehrt im zweiten Refrain wieder; diesmal verändert sich …“. Bestehende Treatment-/Storyboard-Writer besitzen ihre jeweilige Extension. Ein späterer Änderungswunsch benennt betroffene Sections, Assets und Freigaben vor dem erforderlichen Rewind.

## Consumer und Abnahme

- [ ] Treatment → Storyboard → Shot List konsumieren dieselben Section-/Motif-Bindungen. Jede genehmigte Variation erreicht einen wirksamen Kamera-/State-/Lighting-/Performance-Parameter oder ist ausdrücklich nur Guidance; keine wirkungslosen Pflichtfelder.
- [ ] Fixture Verse–Chorus–Verse–Chorus–Bridge–Chorus–Outro zeigt Wiederkehr, bewusst konstante Elemente, Variation und Auflösung in allen drei Artefakten.
- [ ] Abstract-/Performance-Fixture funktioniert ohne Plot; narrative/hybrid nutzt den genehmigten kausalen Bogen, ohne das Songtiming zu erfinden.
- [ ] Andere Audio-/Analysis-Bytes oder nicht existierende Section-/Motif-IDs blockieren Currency/Approval. Kreative Überzeugungskraft bleibt ein attribuiertes Review, kein vorgetäuschter deterministischer Score.
- [ ] Bereits gemessene musikalische Phrasen dürfen Bewegungsintents informieren; dieses Issue schaltet den ausdrücklich noch nicht implementierten `project_mode: phrase` nicht heimlich frei.
- [ ] Lyrics fehlen: vollständiger Ablauf ohne Uploadzwang, erfundenen Text oder erzwungene Kausalgeschichte.

## Quellen und Zuständigkeiten

[Music Film / Musical](https://github.com/iret77/ai-film-production/blob/0333751214c7af17977dd33f0ba88ba9c352421e/references/genre-baselines.md), [23d Music video / commercial und 23f](https://github.com/iret77/ai-film-production/blob/0333751214c7af17977dd33f0ba88ba9c352421e/references/story-structures.md), [Schnitt/Rhythmus und Motive](https://github.com/iret77/ai-film-production/blob/0333751214c7af17977dd33f0ba88ba9c352421e/references/film-craft.md). Die konkreten Datentypen sind NGV-Entwurf aus dieser Doktrin.

#187/#188 bleiben Owner von Pattern-Schema, Messwerten und Regierezept-Content; hier werden ausgewählte Rezepte/`craft_signature`s konsumiert, keine neue Pattern-Library angelegt. #483 liefert wiederverwendbare Setups/State Ladder, #440 Execution-Projektion. #447 besitzt Integration und Migration.

## Gemeinsame Umsetzungsgrenze

Pack-eigene Policy und Ressourcen konsumieren Core-Writer, AssetGraph, Execution/ReferencePlan, Compiler, Review und Assembly. Neue versionierte Extension-Artefakte statt Stored Fields in ABI-gepinnten Typen; geschlossenes Tool-Schema, ein kanonischer Writer, unabhängiges Gate und exakte Quellen-Lineage. Alte gepinnte Projekte werden nicht beim Öffnen migriert. Gesperrter Start/Phasenvertrag bleibt erhalten; notwendige Abweichungen vor Implementierung separat entscheiden. Verifikation ausschließlich GitHub Actions, keine bezahlten Generationstests. Dieses Issue ist Backlog, keine Build-/Merge-/Release-Freigabe.
