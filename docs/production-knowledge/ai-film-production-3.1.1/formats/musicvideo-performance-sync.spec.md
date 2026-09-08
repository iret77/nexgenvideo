# [Musicvideo] Originalsong als Performancequelle mit exakten Segmenten und Mouth-Ownership binden

Tracking: https://github.com/iret77/nexgenvideo/issues/488

Parent: #447; Skill-Auswertung: #433.

Quelle: **ai-film-production v3.1.1-en @ `0333751`**; am 2026-09-08 unverändert als GitHub-HEAD bestätigt. Produktbasis für diese statische Ableitung: NexGenVideo `main` @ `5adddf7`. Anbieterfähigkeiten werden durch diese Auswertung nicht live bestätigt.

## Problem

„Die Figur singt/rappt“ oder ein unspezifischer Audiohinweis bindet weder den tatsächlich ausgewählten Songabschnitt noch den richtigen Mund. Gleichzeitig darf Provider-Audio nicht den Originaltrack im fertigen Musikvideo ersetzen oder verdoppeln. Bestehender Songanker und Default `addLinkedAudio: false` bleiben Grundlage.

## Pack-eigener Vertrag

Eine versionierte `MusicPerformanceBinding` verbindet:

- Originaltrack-Hash, sample-/framebezogene Source-Offsets mit Timebase, tatsächlich exportierte Segmentbytes/Hash und Zielposition auf der Songtimeline;
- Zweck `timing_only`, `performed_song` oder genehmigter eigenständiger Dialog-/diegetischer Layer. Gesang verwendet das Segment als **die tatsächlich performte Musik**, nicht nur als unverbindliche Stimmung;
- Sänger-/Performer-IDs, hörbare Stimmen und sichtbare Mouth-Ownership pro Zeitbereich; andere Figuren erhalten keinen unbestellten Gesang. Duett/Chor sind explizite Mehrsprecherfälle, kein globales Ein-Sänger-Limit;
- genehmigte Lyrics/Alignment, wo vorhanden; ohne Lyrics kann der Track selbst die Performancequelle sein, niemals vom Agenten erfundener Gesangstext;
- Segmentgrenzen entlang vorhandener musikalischer Phrasen/Atempausen, soweit tatsächlich belegt; ansonsten Vorschlag mit Review. Keine universelle 12-Sekunden-Dauer oder behauptete Samplegenauigkeit eines Generators.

Der Core plant/kompiliert die notwendige Audio-/Video-Inputrolle entsprechend dem belegten Providerangebot. Unterstützt die aktive Route die Performancequelle nicht, entsteht eine sichtbare Alternativentscheidung: andere ausführbare Route, importierte Performance oder genehmigte nicht-lippensynchrone Coverage. Kein stummes Mouth-Moving als erfolgreicher Sync-Nachweis.

## Final-Mix-Policy

Der Originalsong bleibt unveränderte musikalische Quelle an der genehmigten Timelineposition. Provider-Audio wird im Songmaster standardmäßig stumm geschaltet. Explizit genehmigte Zusatzlayer sind getrennt und dürfen weder Songersatz noch Doppelmusik erzeugen. Die Pack-Delivery-Projektion nennt Song-/Segmentherkunft und bestätigte Credit-/Nutzungsmetadaten; sie entscheidet keine Rechtsfragen und erfindet keine Freigaben. Generic Mix/Export/QC implementiert #445.

## Abnahme

- [ ] Zwei Segmente desselben Tracks binden verschiedene genaue Offsets/Hashes; Vertauschen von Segment, Sänger oder Zielzeit stoppt vor Generation/Approval.
- [ ] Solo-Fixture hält Mouth-Ownership; Duett mit überlappenden genehmigten Stimmen bleibt darstellbar. Visueller/akustischer Sync wird tatsächlich gesichtet und attribuiert, nicht aus gleichen Hashes abgeleitet.
- [ ] Audioinhalt/Mode-/Referenzlimits kommen aus der Route; falscher Inputslot oder eine Route ohne Audio-Conditioning wird vor Spend abgelehnt.
- [ ] Final-Mix-Fixture enthält den Originalsong einmal, kein versehentlich verlinktes Provider-Musikbett; erlaubte diegetische Layer bleiben sichtbar und getrennt.
- [ ] Ohne Lyrics, ohne Contentprovider und mit importierter Performance sind gültige Pfade vorhanden. Bereits vorhandene originale Medien müssen nicht generiert werden.
- [ ] Reconnect/Retry dupliziert keinen Spend oder Timelineclip; #480 genehmigt die tatsächliche Anzahl geplanter Performance-Generationen, nicht zukünftige unbestimmte Retakes.

## Quellen und Zuständigkeiten

[Performed music / Voice / Audio finishing, ch. 18](https://github.com/iret77/ai-film-production/blob/0333751214c7af17977dd33f0ba88ba9c352421e/references/post-audio-legal.md), [Music Film](https://github.com/iret77/ai-film-production/blob/0333751214c7af17977dd33f0ba88ba9c352421e/references/genre-baselines.md), [Music track as timing input / voice channel, ch. 14b](https://github.com/iret77/ai-film-production/blob/0333751214c7af17977dd33f0ba88ba9c352421e/references/video-prompting.md).

#438 besitzt generische multimodale Referenzbindungen, #439 deren Syntax, #442/#443 Review/Repair, #444 Assembly und #445 generische Delivery. Hier liegen Songsemantik, Performance-/Mouth-Ownership und die Pack-Projektion. #447 wird darauf reduziert, diese Policy zu integrieren; kein doppelter Writer.

## Gemeinsame Umsetzungsgrenze

Pack-eigene Policy und Ressourcen konsumieren Core-Writer, AssetGraph, Execution/ReferencePlan, Compiler, Review und Assembly. Neue versionierte Extension-Artefakte statt Stored Fields in ABI-gepinnten Typen; geschlossenes Tool-Schema, ein kanonischer Writer, unabhängiges Gate und exakte Quellen-Lineage. Alte gepinnte Projekte werden nicht beim Öffnen migriert. Gesperrter Start/Phasenvertrag bleibt erhalten; notwendige Abweichungen vor Implementierung separat entscheiden. Verifikation ausschließlich GitHub Actions, keine bezahlten Generationstests. Dieses Issue ist Backlog, keine Build-/Merge-/Release-Freigabe.
