# Produktionsartefakte und Zielworkflow — Entscheidungsentwurf v2

Status: **zur Entscheidung, nicht freigegeben**. Bezug: [#559](https://github.com/iret77/nexgenvideo/issues/559), [Epic #550](https://github.com/iret77/nexgenvideo/issues/550), [Render-Review #533](https://github.com/iret77/nexgenvideo/issues/533), [Clickdummy PR #575](https://github.com/iret77/nexgenvideo/pull/575) und [unabhängiges Review](https://github.com/iret77/nexgenvideo/pull/577#issuecomment-5761872301). Dieses Dokument ändert weder Runtime-Code noch einen gesperrten Vertrag. Alle neuen Namen, Pfade, Schemas und Toleranzen sind Entscheidungsvorschläge.

## Ergebnis und noch offene Owner-Entscheidungen

Der neue Workflow darf nicht als Erweiterung des heutigen globalen Musicvideo-Vertrags implementiert werden. Er benötigt einen **eigenen, exakt versionierten Projekt-/Pack-/Host-Vertrag** und neue Artefakttypen. Bestehende Projekte behalten `storyboard/v1`, `shotlist/v4`, ihre Phasenordnung und ihr exakt gepinntes Pack. Der neue Vertrag wird ausschließlich für neu angelegte Projekte mit dem neuen Projektschema oder durch eine ausdrücklich bestätigte Recovery-copy-Migration aktiv.

Folgende Punkte sind noch echte Produktentscheidungen und werden nicht durch diesen Entwurf vorweggenommen:

1. **Shot-Identität nach der ersten Promotion.** Empfohlen ist Option A: ein neues `shotlist/v5` mit dauerhaftem, nicht wiederverwendbarem `sNNN`, separater Schnittreihenfolge und erlaubten Nummernlücken. Option B behält `shotlist/v4`, friert dafür Struktur und Reihenfolge nach der ersten Promotion vollständig ein. Eine spätere andere Struktur wäre ein separat dupliziertes Projekt mit neuer Projekt- und Identitätsdomäne, nicht eine Recovery-Migration desselben Projekts. Ein „Umnummerieren und alte Takes weiterverwenden“ ist in beiden Optionen verboten.
   Für Option A ist zusätzlich zu entscheiden, ob unveränderte bezahlte Outputs anhand eines per-Shot-Fingerprints weiterverwendet werden dürfen (empfohlen) oder ob jede Shot-List-Änderung alle Outputs stale macht. Abhängige Kettennachfolger werden in beiden Fällen transitiv stale.
2. **Phrase-Modus.** Empfohlen ist, `phrase` im neuen Vertrag zunächst fail-closed abzulehnen. Eine Freigabe benötigt vorher ein kanonisches, analyseseitig gemessenes Phrase-Artefakt und genaue Abdeckungsregeln. Eine stille Behandlung als `section` ist verboten.
3. **Storyboard-Skizzen.** Empfohlen ist import-only über eine host-eigene Zuweisungskarte; der Agent darf Bilder vorschlagen, aber nicht als „usergewählt“ ausgeben. Auch diese Variante ändert die gesperrte Staging-/Capability-Grenze. Bezahltes `generate_image` in `storyboard` wäre die weitergehende Alternative und benötigt zusätzlich Kosten-, Provenienz- und Retry-Regeln.
4. **Dauerregel für `generative_film` — zwingende Vorbedingung.** Der Neuvertrag ist nur freigabefähig, wenn redaktionelle Timing-Dauer und technische Provider-Ausführbarkeit wie unten getrennt werden. Ohne diese ausdrückliche Änderung des gesperrten Profilvertrags ist die versprochene exakte Timing-Projektion widersprüchlich; der Neuvertrag bleibt dann insgesamt gesperrt.
5. **Coverage-Schweregrade.** Empfohlen ist, die heutigen `info`-/`warning`-Schweregrade für Lücken, Tail und Overlap beizubehalten, sie aber schon im Storyboard-Timing deterministisch zu erfassen und bytegebunden weiterzureichen. Ein Hochstufen zu Approval-Blockern samt Ausnahmeformat wäre eine eigene Produkt- und Sanity-Vertragsentscheidung.

`render_review` ist keine weitere freie Wahl in diesem PR: Die Phase darf erst Bestandteil des neuen Vertrags werden, wenn #533 ihren eigenen Artefakt-, Writer- und Gate-Vertrag festgelegt hat. Ohne diese Entscheidung lautet die neue Reihenfolge ohne `render_review`.

## Review-Evidenz am Bestand

| Review-Komplex | Tatsächlicher Bestand | Konsequenz für den Zielvertrag |
|---|---|---|
| 1. Host-/Pack-Koexistenz | [`PipelineAgentContract.musicvideoPhases`](../../Sources/NexGenVideo/Agent/Pipeline/PipelineAgentContract.swift) enthält genau eine globale Reihenfolge. [`validateLockedMusicvideoIfNeeded`](../../Sources/NexGenVideo/Agent/Pipeline/PhaseContractResolver.swift) vergleicht auch aufgelöste Packverträge damit. Writer-Selektoren und Capabilities sind ebenfalls global registriert. | Host-Auflösung und Validierung müssen nach einer exakten Vertragsidentität dispatchen. Ein neues Pack darf den Altvertrag nicht umdeuten. |
| 2. Kausalitäts-/Step-Eigentum | [`treatment/causality.json`](../../Engine/Sources/NexGenEngine/Production/StoryCausalityPlanV1.swift) besitzt die Story-Kausalität. [`storyboard/causality.json`](../../Engine/Sources/NexGenEngine/Production/StoryboardCausalityV1.swift) besitzt Step→Treatment-Beat. `execution_shots.storyboard_step_ids` wird im [`PipelineExecutionPlanComposer`](../../Sources/NexGenVideo/Agent/Pipeline/PipelineExecutionPlanComposer.swift) auf Vollständigkeit geprüft. | Script, Timing und Shot List dürfen keine parallelen Kausalitäts- oder Step-Zuordnungen besitzen. Storyboard, Kausalität und Timing werden eine atomare Revision; Shot List erhält nur eine exakt geprüfte Projektion. |
| 3. Shot-Identität | `shotlist/v4` verlangt positionsbezogene, lückenlose `sNNN`. Frames, Reference-Pläne, Render-Proofs und Takes verwenden diese ID bereits als technische Identität. | Reorder darf keine bezahlten oder genehmigten Ergebnisse neu zuordnen. Der Zielvertrag benötigt entweder neue stabile/sparse IDs oder ein hartes Struktur-Freeze nach Promotion. |
| 4. Timing, Multicam, Phrase | [`Shotlist.swift`](../../Engine/Sources/NexGenEngine/Artifacts/Shotlist.swift) prüft Dauer auf `0.001 s`; Multicam startet bei `0` und endet innerhalb `0.5 s` der Songdauer. Coverage nutzt zusätzlich `0.01 s` Overlap- und `0.5 s` Gap-Grenzen. `phrase` ist noch kein durchgehend ausführbarer Briefing-/Timing-Vertrag. | Dieselben modusspezifischen Regeln müssen schon das genehmigte Storyboard-Timing deterministisch klassifizieren. Keine spätere freie Neuinterpretation. |
| 5. Draft-/Bible-Grenze | `Storyboard.Step` v1 trägt heute bereits Source-Mode, Kamera, Framing, Blocking und Reference-Requests; der aktuelle Shot-List-Writer erwartet später vollständige ausführbare Werte. | Diese Felder dürfen nicht erneut frei im Draft und in der Shot List entstehen. Der Neuvertrag verwendet einen neuen Storyboard-Typ und legt Feldbesitz ausdrücklich fest. Bible-Auflösung schließt Draft-Verpflichtungen, ohne den genehmigten Draft zurückzuschreiben. |
| 6. Render-Review-Ketten | Der Vorgänger-Video-Hash einer generierten Kette existiert bei einem statischen Pre-Render-Review noch nicht. Tatsächliche Ergebnisse haben bereits Take- und Sequence-Review-Oberflächen. | Statischer Plan-Review und spend-unmittelbare Byte-Bindung sind zwei verschiedene Belege. Der erste genehmigt die Kettenregel, der zweite bindet die wirklich erzeugten Vorgängerbytes. |
| 7. Capabilities/Profile | `storyboard` hat heute weder `generate_image` noch allgemeines Import-/Staging-Recht. Der Profilvertrag leitet ausführbare Dauer aus der ausgewählten Route ab. | Jede Erweiterung ist eine explizite Vertragsentscheidung. Der Entwurf empfiehlt engen Sketch-Import und trennt redaktionelle Dauer von technischer Route. |
| 8. Migration/Gates | Gates und kumulative Lineage kennen Script, Timing und Draft heute nicht. Pack-Bindung enthält zwar Projekt-Schema, die Pipeline-Auflösung dispatcht aber nicht vollständig danach. | Neue Phasenfreigaben dürfen nicht aus alten Approvals erfunden werden. Die Upgrade-Pflicht folgt allein aus der exakten Pack-/Projektbindung, nie aus zufällig vorhandenen Dateien. |
| 9. Bestehendes Story-Intake | Der gesperrte Startvertrag platziert optionales bestehendes Story-/Identity-/Style-Material nach genehmigter Analyse und vor Storyentwicklung; bestehendes Storymaterial landet unter `import/script.md`. | Das Intake bleibt an dieser Stelle. Die neue Phase heißt in der UI „Script development“; das Intake heißt „Existing story material“. Der Script-Writer bindet Import oder ausdrückliches Greenfield. |

## Exakte Host-/Pack-Vertragsidentität

Projekt-Pin und Host-Vertragsdispatch sind zwei getrennte, gemeinsam zu prüfende Identitäten:

`project_binding = (pack_id, pack_version, project_schema)`

`host_contract_key = (pack_id, project_schema, pipeline_contract_schema, contract_id, engine_contract)`

Für den Altvertrag bleibt das heutige Bindungs-/Contract-Key-Paar unverändert. Der Neuvertrag erhält ein neues `project_schema`, ein neues Pipeline-Manifest-Schema und eine neue `contract_id`. Die konkreten Versionsnummern werden erst bei Freigabe festgelegt; dieses Dokument vergibt keine scheinbar schon veröffentlichte Version.

Der Host muss für jeden unterstützten `host_contract_key` separat registrieren und prüfen:

- exakte Phasenordnung und Abhängigkeiten;
- Artefakt-, Writer-, Gate- und Lineage-Selektoren;
- phase-bound und supporting Capabilities;
- Phasendokumente, Hardsteps und Intake-Schritte;
- Projekt-Schema und Pack-Ressourcen aus derselben vertrauenswürdigen Bindung.

`PhaseContractRuntime` muss nach dem `host_contract_key` auflösen und cachen, nicht nach Pack-ID. Unabhängig davon muss die tatsächlich geladene Packversion exakt dem `project_binding` entsprechen. Dadurch bleiben Pack-Releases append-only und unabhängig vom App-Release, solange sie denselben vom Host unterstützten Vertrag erfüllen. Beide Identitäten werden gegen die vertrauenswürdige In-Session-Deklaration und separat gegen die Arbeitskopie von `ngv.json` geprüft. Ein unbekannter Contract-Key, ein falscher Versions-Pin oder eine teilweise Übereinstimmung stoppt Öffnen, Speichern, Gate-Mutation und Phasenausführung fail-closed. Es gibt weder Fallback auf die globale Altphasenliste noch „latest wins“.

Der Neuvertrag ergänzt Host-Funktionen additiv. Er fügt keine gespeicherten Felder in bestehende öffentliche Pack-Grenztypen ein und verschiebt keine Properties in `EngineRegistry`. Neue Artefakte verwenden neue Typen oder ABI-sichere bestehende Carrier. Das konkrete Kompatibilitätstupel des alten Packs bleibt weiterhin loadbar und durch seinen bisherigen Validator geschützt.

## Zielreihenfolge und Intake

Ohne #533:

`project_init → analysis → brief → production_design → treatment → script → storyboard → shot_planning → bible → shotlist → sanity → frames → render`

Nach einer separaten Freigabe von #533:

`… → sanity → frames → render_review → render`

Track, optionale Lyrics, Project Init und genehmigte Audioanalyse bleiben in der Reihenfolge des [Startvertrags](../MUSICVIDEO_START_CONTRACT.md). Danach bleibt das vorhandene optionale Intake für Story-/Identity-/Style-Material. Der sichtbare Intake-Name ist **Existing story material (optional)**; er importiert ausschließlich nach `import/script.md` oder zeichnet **No existing story material** im Intake-Ledger auf. Erst die spätere Phase **Script development** erzeugt das kanonische Script-Artefakt. Medienbibliotheksimport erfüllt das Intake nicht automatisch.

Eine Änderung an `import/script.md` ist nach Brief-Approval nur über Rewind zur Phase `brief` zulässig. Sie invalidiert `brief`, `production_design`, `treatment`, `script` und alle Nachfolger, weil `import/` ab Brief zur kumulativen Lineage gehört. Einen isolierten Rewind auf einen Intake-Eintrag gibt es nicht. Greenfield bleibt eine vollständige Antwort und benötigt keine künstliche Quelldatei.

## Artefakte, ein Owner je Aussage

Der Neuvertrag verwendet `storyboard/v2` und `storyboard-causality/v2`; deren v1-Schemas bleiben dem Altvertrag vorbehalten. `shotlist/v4` bleibt ebenfalls Altvertrag, außer der Owner wählt ausdrücklich Identitätsoption B mit dem beschriebenen Struktur-Freeze.

| Aussage | Einziger kanonischer Owner im Neuvertrag | Erlaubte spätere Darstellung |
|---|---|---|
| Story-Kausalität, Beat-Chronologie, Ursachen und Payoffs | bestehender Treatment-Kausalitätsplan | Script/Storyboard referenzieren Beat-IDs; sie ändern den Graphen nicht. |
| Importiertes Storymaterial und erlaubte Abweichungen | exakte Bytes von `import/script.md` plus `story-source/v1` aus Brief | Treatment und Script zitieren Quellbereiche; nur eine vor Treatment userbestätigte Source-Decision darf Faktenabweichungen erlauben. |
| Genehmigter Wiedergabebereich | `playback-range/v1` aus Brief, gebunden an die Audioanalyse | Beat/Section/Phrase planen in diesem Bereich; Multicam-Quellen bleiben vollständige Songaufnahmen und nutzen ihn erst für die Timeline-Ausgabe. |
| Szenenkomposition, Dialog/Performance und Treatment-Adaption | `script/v1.scenes` | Storyboard referenziert Szenen; es besitzt keine zweite Szene. |
| Sichtbare atomare Handlung und narrative Funktion eines Steps | `storyboard/v2.step` | Draft und Shot List referenzieren Step-IDs, ohne Handlungstext frei zu überschreiben. |
| Step→Treatment-Beat | `storyboard-causality/v2` | Timing und Execution Plan lesen die Zuordnung. |
| `plan_shot_id`, Step-Abdeckung, Schnittzeit und Sketch-Momente | `storyboard-timing/v1` | Draft referenziert `plan_shot_id`; `execution_shots.storyboard_step_ids` ist eine exakte Projektion. |
| Shot-Source-Mode | `shot-planning-draft/v1` | Shot List muss exakt projizieren; Render darf nicht umwählen. |
| Shot-Kamera, Framing, Bewegung und Blocking-Bedarf | `shot-planning-draft/v1` | Shot List löst technische Parameter auf, ändert aber nicht die genehmigte Absicht. |
| Semantischer Reference-Bedarf | `shot-planning-draft/v1` | Bible erfüllt Bedarf; Shot List bindet die exakten erfüllenden Assetpfade/-hashes. |
| Provider-Route, exakte Projektpfade und ausführbarer Produktionsplan | Shot List und bestehende Execution-Sidecars | Render konsumiert ausschließlich diese Werte. |
| Tatsächlicher Render-Input und Outputbytes | bestehender Render-Proof/Take-Provenienz | Take- und Sequence-Review bewerten die tatsächlich erzeugten Ergebnisse. |

### Story-Quelle und Wiedergabebereich in Brief

Der Neuvertrag ergänzt die Brief-Transaktion um zwei neue Sidecars, ohne bestehende öffentliche Brief-Typen zu erweitern:

- `brief/story-source.v1.json` bindet entweder `import/script.md` mit Pfad und SHA-256 oder den vorhandenen `brief.script`-Decline aus dem Intake-Ledger. Bei Import enthält es keine nachträglich vom Script erfundene Fact-Liste. Sein Feld `source_decisions` enthält ausschließlich host-eigene, vor Treatment userbestätigte Einträge mit stabiler ID, exaktem Bytebereich, Disposition `preserve`, `non_factual` oder `owner_superseded`, verpflichtender Begründung für jede Nicht-Preserve-Disposition und einem Confirmation-Receipt. Nur `owner_superseded` darf eine Faktenabweichung autorisieren.
- `brief/playback-range.v1.json` bindet die genehmigten Analysebytes und enthält entweder `full_song` mit `start=0` und `end=analysis.duration_s` oder `excerpt` mit userbestätigtem In-/Out-Punkt innerhalb dieser Dauer. Der Bereich besitzt die redaktionelle Ausgabe; er verkürzt keine Multicam-Quelldatei.

Beide Sidecars sind ab Brief Bestandteil der kumulativen Lineage. Treatment und Script können exakte Quellbereiche zitieren, aber keine neue Faktenwahrheit und keine spätere Ausnahme erzeugen. Wird erst in Treatment oder Script eine unzulässige Abweichung erkannt, ist `brief` das Rewind-Ziel; die Source-Decision muss vor einer neuen Treatment-Freigabe entstehen.

### Script

Vorschlag: `script/vN.v1.json` und `script/current.v1.json`, Schema `script/v1`.

Das Artefakt bindet die exakten aktuellen Treatment-, Treatment-Kausalitäts- und `story-source/v1`-Bytes. `source_binding` ist eine unveränderliche Projektion mit genau einer Variante:

- `imported`: Projektpfad `import/script.md` und dessen SHA-256;
- `greenfield`: den ausdrücklichen Decline-Eintrag des Intakes.

Bei Import nennt jede Szene verwendete Treatment-Beat-IDs und exakte Quellbereiche aus `import/script.md`. Der strukturelle Gate prüft, dass alle Referenzen existieren, jede Szene eine konkrete Adaption besitzt und keine Quelle still ersetzt wurde. Ob Prosa eine Tatsache inhaltlich korrekt bewahrt, bleibt ein sichtbarer Reviewpunkt; der Gate darf semantische Wahrheit nicht vortäuschen. Script darf eine Abweichung nur auf eine bereits in `story-source/v1` genehmigte Source-Decision projizieren. Jede andere Abweichung erfordert Brief-Rewind und anschließend neue Treatment-/Script-Revisionen.

Script-Szenen besitzen keinen eigenen Kausalitätsgraphen. Wenn eine Szene eine neue Ursache, einen neuen Payoff oder eine geänderte Chronologie benötigt, wird Treatment ausdrücklich zurückgespult und dessen bestehender Kausalitätsplan revidiert.

### Atomare Storyboard-Revision

Vorschlag: Eine Revisionsnummer schreibt in **einer** `ArtifactTransaction`:

- `storyboard/vN.v2.yaml` und `storyboard/current.v2.yaml`, Schema `storyboard/v2`;
- `storyboard/causality/vN.v2.json` und `storyboard/causality-current.v2.json`, Schema `storyboard-causality/v2`;
- `storyboard/timing-vN.v1.json` und `storyboard/timing-current.v1.json`, Schema `storyboard-timing/v1`.

`storyboard/v2` ist ein neuer Typ, kein Feld-Append an `Storyboard` v1. Sein Step besitzt ID, genau einen Script-Szenenbezug, narrative Funktion und atomare sichtbare Handlung, aber keine zweite ausführbare Source-, Kamera-, Blocking- oder Reference-Entscheidung. `storyboard-causality/v2` bindet Treatment-Kausalität und Storyboard-Bytes. Sein Gate verlangt, dass jeder dem Step zugeordnete Treatment-Beat zu den Beat-Referenzen der verknüpften Script-Szene gehört; eine neue Step-Ursache kann so nicht am Script vorbei entstehen. `storyboard-timing/v1` bindet Script-, Storyboard- und Causality-Bytes und enthält je geplantem Shot:

- stabile `plan_shot_id`;
- genau eine `primary_step_id` und null bis mehrere eindeutige `additional_step_ids`;
- `time_start`, `time_end`, `duration_s` und Schnittreihenfolge; Szene und Abschnitt werden ausschließlich über `primary_step_id` abgeleitet;
- null bis mehrere Sketch-Momente mit Offset innerhalb des Shots, Rolle und optionalem host-bestätigten Sketch-Receipt samt Bild-Hash.

Die Menge aller primären und zusätzlichen Step-IDs muss genau alle Storyboard-Steps abdecken. Ein Step darf mehrere geplante Shots begründen; ein geplanter Shot kann mehrere Steps realisieren. Diese Zuordnung wird nirgendwo unabhängig editiert. Eine veröffentlichte `plan_shot_id` darf nie für eine andere `primary_step_id` oder eine materiell andere atomare Handlung wiederverwendet werden; entfernte IDs werden im Identitätsledger retired. Der Timing-Gate prüft dies auch nach Rewind.

Der Shot-List-Writer projiziert die Step-IDs nach `execution_shots.storyboard_step_ids`; sein unabhängiger Gate vergleicht Menge und Reihenfolge exakt mit der genehmigten Timing-Revision. Der heutige Execution-Plan-Check ist fest an `storyboard-causality/v1` gebunden und kann nicht unverändert weiterlaufen. Im Neuvertrag dispatchen Composer, kanonische Extension-Referenzen und Gate nach `host_contract_key` und prüfen gemeinsam `storyboard-causality/v2` und `storyboard-timing/v1`; der Altvertrag behält den v1-Check.

Eine fehlende Revisionskomponente, abweichende Current-/Archivbytes oder ein stale Hash blockiert Storyboard-Approval. Jede Änderung an Storyboard, Kausalität, Timing oder gebundenen Sketchbytes erzeugt gemeinsam eine neue Revision und setzt `shot_planning` sowie alle Nachfolger pending.

### Shot-Planning-Draft und Bible-Auflösung

Vorschlag: `shot-planning/vN.v1.json` und `shot-planning/current.v1.json`, Schema `shot-planning-draft/v1`.

Der Draft deckt jede `plan_shot_id` genau einmal ab und bindet die genehmigten Script-/Storyboard-/Causality-/Timing-Bytes. Pro Shot besitzt er ausschließlich:

- Source-Mode;
- genehmigte Kamera-/Framing-/Bewegungsabsicht;
- Blocking-Bedarf;
- typisierte semantische Reference-Anforderungen;
- typisierte, vor Bible noch ungelöste **Auflösungsverpflichtungen** mit `required` oder einer konkreten, vorab erlaubten optionalen Skip-Variante.

Eine offene Auflösungsverpflichtung ist kein fehlender Pflichtwert und kein Platzhalter, den die Bible in den genehmigten Draft zurückschreibt. Draft-Approval schließt die oben genannten kreativen Entscheidungen. Die Bible erzeugt oder bestätigt anschließend ihre eigenen kanonischen Entitäten, Ansichten und Bildbelege. Ihr Gate prüft vor Bible-Approval, dass jede erforderliche Draft-Pflicht erfüllbar und durch einen aktuellen Bible-Beleg gedeckt ist.

Der bestehende `PipelineShotlistWriter` bleibt einziger Writer der ausführbaren Shot List. Im Neuvertrag schreibt er in derselben Transaktion zusätzlich `execution/shot-planning-promotion.v1.json`. Dieser Beleg bindet Timing-, Draft-, Bible-, Shot-List- und Execution-Sidecar-Hashes und löst jede Draft-Verpflichtung auf eine exakte Bible-/Medien-ID oder einen projektlokalen Pfad auf. Nichtanwendbarkeit ist nur zulässig, wenn der genehmigte Draft genau diese optionale Variante vorsieht und der User sie über die host-eigene Skip-Aktion bestätigt hat; der Agent oder Shot-List-Writer darf sie nicht neu entscheiden.

Fehlt lediglich ein geforderter Bible-Beleg, ist `bible` das Rewind-Ziel. Ist die genehmigte Pflicht selbst falsch oder nicht erfüllbar, ist `shot_planning` das Rewind-Ziel und Bible wird als Nachfolger invalidiert. Der Promotion-Beleg ändert in keinem Fall Draftwerte.

Source-Mode, Timing, Step-Abdeckung und kreative Kameraabsicht sind in der Shot List reine, exakt geprüfte Projektionen. Eine native Source-Mode-Änderung im Neuvertrag führt deshalb zu einem Rewind auf `shot_planning`, schreibt eine neue Draft-Revision und durchläuft Bible und Promotion erneut; sie mutiert nicht direkt die Shot List. Provider-Route, native technische Parameter, vollständige Projektpfade und `production_plan` gehören dagegen erst der Shot List. Ein unvollständiger Draft wird nie als Shot List geladen oder angezeigt.

## Verbindliche Timing-Regeln vor Promotion

Alle Zahlen sind endlich, und `duration_s = time_end - time_start` mit höchstens `0.001 s` Abweichung. Songdauer und Struktur stammen aus den exakt gebundenen genehmigten Analysebytes. Für Beat/Section und einen später freigegebenen Phrase-Modus gilt `time_start ≥ playback_range.start` und `time_end ≤ playback_range.end`. Multicam besitzt dagegen vollständige Kameraquellen über die analysierte Songdauer; ein Excerpt begrenzt erst die spätere Timeline-Ausgabe.

- **beat/section:** Die Timing-Einträge bilden eine Schnittspur. Der Gate führt denselben Coverage-Classifier schon hier aus: Lücken oder ein ungedecktes Ende über `0.5 s` sind `info`, Overlap über `0.01 s` ist `warning`; diese Befunde blockieren nach der empfohlenen Entscheidung nicht. Befundcode, Bereich und Timing-Hash werden gebunden und bei Shot-List-Promotion sowie Sanity exakt reproduziert. Nur eine ausdrückliche Owner-Entscheidung darf daraus Blocker mit einem typisierten Ausnahmeformat machen.
- **multicam:** Jeder geplante Shot ist eine vollständige Kameraquelle, nicht ein Teilstück derselben Schnittspur. `time_start` ist innerhalb `0.001 s` gleich `0`; `time_end` ist innerhalb `0.5 s` gleich `analysis.duration_s`; jede Kamera-ID ist eindeutig. Globale Nichtüberlappung ist hier ausdrücklich falsch. `playback_range` schränkt nur die Timeline-/Exportauswahl ein und ändert nicht die Quelldauer.
- **phrase:** Bis zur Owner-Entscheidung blockiert der neue Timing-Writer diesen Modus. Bei späterer Freigabe muss jeder Schnitt eine gemessene Phrase-ID aus einem kanonischen Analyseartefakt referenzieren; Instrumentalbereiche, Grenztoleranzen und Mehrphrasen-Shots müssen vor Implementierung festgelegt sein. Es gibt keinen Fallback auf Section-Grenzen.

Sketch-Momente sind Binnenzustände. Ihr Offset liegt zwischen `0` und `duration_s`; mehrere Momente erzeugen weder zusätzliche Shots noch Schnitte. Ein optionaler Bildbeleg muss projektlokal, regulär, rollenrichtig und mit seinen exakten Bytes sowie dem host-eigenen Auswahl-Receipt gebunden sein.

Für `generative_film` ist folgende Änderung eine **Freigabevoraussetzung des Neuvertrags**: Storyboard-Timing besitzt die redaktionelle Nettodauer; der gewählte Provider-Pfad besitzt die technische Ausführbarkeit. Die Shot List darf Timing nicht an ein Modell anpassen. Sie muss stattdessen eine Route wählen, die die Dauer nativ erfüllt, oder einen im neuen Profil ausdrücklich erlaubten Segment-/Long-take-/Rescue-Plan schreiben. Ist das nicht möglich, wird Route oder Timing durch den zuständigen Rewind geändert. Solange [`PRODUCTION_PROFILES.md`](../PRODUCTION_PROFILES.md) weiterhin Dauer aus der Route ableitet, kann der Neuvertrag nicht freigegeben oder für ein Projekt aktiviert werden.

## Shot-Identität und Reorder

Vor der ersten Shot-List-Promotion ist `plan_shot_id` innerhalb der genehmigten Revisionskette stabil. Storyboard-Reorder ändert Schnittreihenfolge und Zeiten, nie die ID. Bei der ersten Promotion entsteht ein persistenter Identity-Ledger mit `plan_shot_id ↔ sNNN`, primärem Step und Fingerprint der atomaren Handlung. Dieser Ledger bleibt auch nach Rewind erhalten. Eine beibehaltene ID muss Step und Handlung behalten; eine materielle Änderung erhält eine neue `plan_shot_id`, die alte wird retired und nie wiederverwendet.

**Option A, empfohlen:** Ein neues `shotlist/v5` trennt technische ID von Schnittreihenfolge. `sNNN` wird monoton aus einem persistierten High-water mark vergeben, nie wiederverwendet und nie neu nummeriert. Entfernte Shots werden im Identitätsledger als retired geführt; neue Shots erhalten die nächste freie Nummer, auch wenn sie zeitlich früher liegen. Die sichtbare Reihenfolge folgt Timing bzw. einem eigenen `cut_order`, nicht der Nummer. Bei der empfohlenen Wiederverwendungsentscheidung bindet jeder Frames-/Reference-/Render-/Take-Beleg den Hash seines unveränderlichen Ledger-Eintrags und einen per-Shot-Fingerprint der tatsächlich relevanten Planbytes, nicht pauschal den Gesamt-Hash der Shot List. Eine Änderung macht den betroffenen Shot und alle Kettennachfolger stale, aber nicht automatisch unabhängige unveränderte bezahlte Takes. Die alternative Gesamtbindung würde jede Änderung vollständig invalidieren und muss wegen ihrer Kostenfolge ausdrücklich gewählt werden. Option A erfordert einen neuen Typ und neue Validatoren; `shotlist/v4` bleibt unverändert.

**Option B:** Der Neuvertrag bleibt auf `shotlist/v4`. Dann sind Reorder, Einfügen, Löschen und Splitten ab der ersten Promotion im Projekt gesperrt. Eine andere Struktur entsteht nur durch ein ausdrücklich dupliziertes neues Projekt mit neuer `projectId`; das Ursprungsprojekt und seine Frames, References, Render-Proofs und Takes bleiben unverändert. Sie werden nicht in die Identitätsdomäne des Duplikats übernommen. Das ist keine Recovery-copy-Migration.

Unter beiden Optionen darf ein bezahlter oder genehmigter Output niemals durch Neuordnung einem anderen Shot zugeschrieben werden. Rewind macht Outputs höchstens stale; er ändert ihre ursprüngliche Identität und Provenienz nicht. Redaktionelles Umstellen bereits erzeugter Clips auf der Timeline bleibt erlaubt, erzeugt aber keine neue Pipeline-Zuordnung.

## Render-Review und generierte Ketten

Der optionale statische `render_review` nach Frames kann nur Bytes binden, die bereits existieren: Script, Storyboard-Bundle, Draft, Bible, Shot List, Execution Plan, Frame-/Reference-Bilder, kompilierte Prompts und deklarierte Kettenregeln. Für eine geplante Fortsetzung prüft er Vorgänger-ID, Strategie, topologische Reihenfolge, Zyklenfreiheit und die vorgesehene Input-Rolle. Er behauptet **nicht**, den noch nicht erzeugten Vorgänger-Video-Hash geprüft zu haben.

Unmittelbar vor jedem kostenpflichtigen Render kompiliert der Host den Prompt mit derselben Prompt-Engine erneut und vergleicht dessen exakte Bytes beziehungsweise den kanonischen Hash mit dem in `render_review` gebundenen Preflight. Eine Abweichung macht den Review stale und blockiert Spend. Die genaue Receipt-Form gehört #533; der Neuvertrag darf bloße „ähnliche“ Prompts nicht als genehmigt behandeln.

Unmittelbar vor jedem kostenpflichtigen Folge-Render erzeugt der Host außerdem aus dem aktuellen, bereits abgeschlossenen Vorgänger einen einmalig konsumierbaren Generation-Request:

- `frame_continuation` bindet den exakten Vorgänger-Video-Hash und den daraus deterministisch extrahierten letzten Frame samt Byte-Hash;
- `native_extension` bindet den exakten genehmigten Vorgänger-Video-Hash und den ausführbaren nativen Extension-Modus.

Fehlt der Vorgänger oder ändern sich seine Bytes, wird der Request nicht abgesendet und jeder bereits vorbereitete Nachfolger-Request stale. Weder Sketch noch Bible-Bild noch ein anderes Take darf substituiert werden. Der bestehende Render-Proof bindet anschließend den wirklich abgesendeten Request und Output; [`TakeReview`](../../Sources/NexGenVideo/Inspector/Cockpit/TakeReview.swift) und [`SequenceReviewV1`](../../Engine/Sources/NexGenEngine/Artifacts/SequenceReviewV1.swift) bewerten reale Ergebnisse. Plan-Review, spend-unmittelbare Byte-Bindung, Take-Review und Sequence-Review sind vier verschiedene Belege.

## Capability- und Kostenentscheidungen

| Phase | Phase-bound | Supporting im empfohlenen Vertrag | Ausdrücklich nicht erlaubt |
|---|---|---|---|
| `script` | `write_script` | nur lesende Treatment-/Import-Tools | Mediengenerierung, Staging, fremde Writer |
| `storyboard` | atomarer `write_storyboard_bundle` | nur lesende Bibliothek; der Agent kann eine Zuweisung anfragen | `generate_image`, `copy_project_file`, `run_provider_tool`, freie Pfade, agentisches Attach |
| `shot_planning` | `write_shot_planning_draft` | lesende Bible-Bedarfs-/Medienvorschau | Frames-/Render-Generierung, phasenfremder Blockout-Proof |
| `render_review`, nur nach #533 | `write_render_review` | lesende aktuelle Inputs und deterministisches Prompt-Preflight | Bild-/Videogenerierung und sonstiger Spend |

`attach_storyboard_sketch` ist im empfohlenen Vertrag **kein Agent-Tool**, sondern eine host-eigene Aktion an einer sichtbaren Sketch-Karte. Nur der User wählt den konkreten Bibliothekskandidaten; der Host schreibt ein Receipt mit Medien-ID, Originalname, Zielrolle und Byte-Hash und übernimmt ausschließlich reguläre Bildbytes in deklarierte Storyboard-Sketchpfade. Die Aktion schreibt keine kanonische Phase-Lineage; der atomare Storyboard-Writer versiegelt Receipt und Bildbytes später in seiner Revision. Auch dieses enge native Staging benötigt eine ausdrückliche Änderung des gesperrten Harness, der Staging heute auf Production Design und Bible begrenzt.

Falls der Owner stattdessen bezahlte Storyboard-Generierung wählt, müssen `generate_image`, Prompt-Compilation, Kostenfreigabe, Provider-Request, Retry-/Join-Identität und Prompt-/Modell-/Byte-Provenienz ausdrücklich im neuen Manifest, Phasendokument und Gate stehen. Die aktuelle Storyboard-Capability darf nicht still erweitert werden.

`source_mode=imported` bleibt ohne Frames- oder Provider-Renderpflicht ausführbar. `ai_enhanced` bindet wie im gesperrten Harness seinen exakten projektlokalen `source_path`; der Agent wählt oder ersetzt ihn nicht in Render. Optionales Blocking darf als Bedarf im Draft stehen, aber nur ein späterer kanonischer räumlicher Proof mit echter Quellen-, Kamera-, Export- und Byte-Provenienz erfüllt ihn. Die sichtbare host-eigene Skip-Aktion ist nur verfügbar, wenn der Draft diese Pflicht als optional markiert; ihr Receipt erfüllt genau die vorab erlaubte Nichtanwendbarkeitsvariante und erzeugt keinen Schein-Proof.

## Migration ohne erfundene Freigaben

Der Upgrade-Trigger ist ausschließlich die bestätigte Änderung der exakten Pack-/Projektbindung. Das Vorhandensein von `script/`, `shot-planning/` oder einer gleichnamigen Fremddatei löst weder Promotion noch Migration aus. Der unveränderte Altvalidator ignoriert Pfade, die sein Vertrag nicht kennt; er erhält keine neue Ablehnungssemantik.

Die deklarierte Pack-Migration arbeitet transaktional in einer Recovery-Kopie:

1. Sie prüft Quell-Pack, Quell-Projektschema, Ziel-Pack, Ziel-Projektschema und beide Pipeline-Vertragsidentitäten.
2. Sie erhält alle bisherigen Projekt- und Medienbytes. In der Recovery-Kopie werden alte kanonische Pipeline-Artefakte samt Current-Mirrors physisch nach `pipeline/migration-history/<source-contract-fingerprint>/…` verschoben und in einem Hash-Manifest erfasst. Erst nach verifizierter Bytegleichheit werden die alten aktiven Pfade in der Recovery-Kopie entfernt. Dadurch können v1-Loader keine Legacy-Datei als aktuellen Neuvertrag lesen. Die ursprüngliche Arbeitskopie bleibt bis zum erfolgreichen Save unverändert.
3. Nur `project_init` und `analysis` dürfen als genehmigt übernommen werden, wenn ihre heutigen Current-/Archivbytes, Gates und kumulative Lineage exakt und der Zielvertrag dafür eine explizite Migrationsabbildung besitzt.
4. `brief` und alle Nachfolger werden pending. Die neuen `story-source/v1`- und `playback-range/v1`-Bytes dürfen nicht aus einem alten freien Brief-/Intake-Zustand erfunden werden; der User bestätigt sie in der neuen Brief-Phase. Damit werden auch `production_design`, `treatment`, `script`, `storyboard`, `shot_planning`, `bible`, `shotlist`, `sanity`, `frames`, optional `render_review` und `render` zurückgesetzt. Ebenso werden kein Script, kein Timing, keine Step→Shot-Zuordnung, kein Draft und kein Promotion-Beleg aus alten Dateien erfunden.
5. Die neue aktuelle Phase ist `brief`, sofern `project_init` und `analysis` gültig übernommen wurden; andernfalls die früheste invalidierte Phase.
6. Vor Bestätigung zeigt die UI exakt, welche Approvals verloren gehen, welche historischen Render/Takes erhalten bleiben und dass alte Outputs nicht automatisch dem neuen Shot-Identitätsraum angehören. Abbrechen lässt die Quellkopie unverändert.
7. Erst der erfolgreiche Abschluss schreibt die neue `ngv.json`-Bindung und aktiviert die disjunkten Neuvertragspfade. Jeder Fehler verwirft die Recovery-Kopie vollständig.

Bestehende Projekte öffnen weiterhin ausschließlich ihre exakt gepinnte Packversion. Es gibt keine globale Migration, keine stille Wiederverwendung eines neuesten Packs und keinen Altprojekt-Fallback auf den neuen Workflow.

## Nach Freigabe notwendige Änderungen an gesperrten Verträgen

Diese Änderungen sind **nicht** Teil dieses PRs:

| Gesperrtes Dokument | Erforderliche ausdrückliche Änderung |
|---|---|
| [`PIPELINE_AGENT_HARNESS.md`](../PIPELINE_AGENT_HARNESS.md) | Versionierter Dispatch statt einer einzigen Musicvideo-Reihenfolge; neue Phasen, atomare Storyboard-Dreierrevision, vertragsspezifischer Execution-Plan-Check, Owner-Tabelle, Promotion, native Sketch-Zuweisung, Source-Mode-Rewind, Capabilities, Job-/Gate-/Rewind-Regeln und unabhängige Negativ-Evidenz. |
| [`PROJECT_STORAGE.md`](../PROJECT_STORAGE.md) | Neue Brief-/Script-/Storyboard-/Draft-Familien, Current-/Archiv-Bytegleichheit, Identity-Ledger/Promotion, physisch disjunkte Migration-History und fail-closed Bindung an Project-Pin plus Host-Contract-Key. |
| [`PLUGIN_STANDARD.md`](../PLUGIN_STANDARD.md) | Manifest-Projekt-Schema, `contract_id`, vom Pack-Versionspin getrennter Host-Support-Dispatch, side-by-side Packversionen und deklarierte Recovery-Migration ohne ABI-Verletzung. |
| [`PRODUCTION_PROFILES.md`](../PRODUCTION_PROFILES.md) | Zwingende Trennung redaktioneller Nettodauer von Route-Ausführbarkeit; gegebenenfalls `shotlist/v5`; Phrase bleibt gesperrt oder erhält einen separaten messbaren Vertrag. |
| [`MUSICVIDEO_START_CONTRACT.md`](../MUSICVIDEO_START_CONTRACT.md) | Bestehendes Story-Intake bleibt nach Analyse; eindeutige UI-Namen sowie Brief-eigene Bindung von Import/Greenfield und Playback-Range. Die Startreihenfolge selbst bleibt unverändert. |
| [`PATTERN_FIT_CONTRACT.md`](../PATTERN_FIT_CONTRACT.md) | Derselbe frühe Coverage-Classifier mit unveränderten Schweregraden; nur nach separater Owner-Entscheidung neue Blocker/Ausnahmen. Keine zweite Coverage-Wahrheit. |

Die Implementierung benötigt außerdem ein neues Host-Registry-Modell, neue Artefakttypen statt gespeicherter Felder in öffentlichen Altwerttypen und einen versionierten Shot-List-Pfad entsprechend der Owner-Entscheidung. Der neue Draft-Writer ist für Agent und native Source-Mode-Edits der einzige Owner des Drafts; der vorhandene `PipelineShotlistWriter` bleibt alleiniger Writer der ausführbaren Shot List und ihrer Promotion.

## Verbindliche Review- und Negativ-Evidenz für Folge-PRs

Release-Evidenz muss die Owner-sichtbare Reihenfolge unabhängig von Packdocs und `hardsteps.json` behaupten. Mindestens zu prüfen sind:

- Altprojekt und Neuvertrag gleichzeitig: jeweils richtige Reihenfolge, Tools, Writer und Gates; unbekanntes oder gekreuztes Tupel fail-closed;
- Brief bindet Import oder Greenfield samt Playback-Range; Script zitiert exakte Quellbereiche; neue Kausalität oder ungenehmigte Faktenabweichung ohne Brief-/Treatment-Rewind wird abgelehnt;
- atomarer Commit/Rollback von Storyboard v2, Causality v2 und Timing v1; Current-/Archiv- und Bildbyte-Manipulation blockiert;
- 1 Step→mehrere Shots, 1 Shot→mehrere Steps, exakte Gesamt-Coverage und Shot-List-Projektion ohne zweite editierbare Zuordnung;
- beat/section mit reproduzierten `info`-/`warning`-Befunden, multicam stets über die volle analysierte Songdauer mit separater Excerpt-Ausgabe und die gewählte Phrase-Entscheidung, jeweils direkt unter, auf und über jeder Toleranz;
- Draft-Approval vor Bible, spätere Auflösung ohne Draft-Revision und Ablehnung einer Shot List mit offenem Bedarf;
- Reorder/Add/Delete gemäß gewählter Identitätsoption; Wiederverwendung gemäß gewählter Fingerprint-Granularität; retired `plan_shot_id` und `sNNN` bleiben gesperrt; historischer Frame/Render/Take bleibt an seiner ursprünglichen Identität;
- statischer Kettenreview ohne erfundenen Vorgängerhash, danach spend-unmittelbare Gleichheit des kompilierten Prompts und Bindung der echten Vorgängerbytes; geänderter Vorgänger blockiert den Nachfolger;
- Capability-Negativfälle für bezahlte Generierung, freie Pfade, fremde Phase, Staging aus/in kanonische Artefakte und Retry/Transport-Reconnect;
- Migration mit vollständiger Reset-Liste, physisch disjunkter Legacy-History, frühem Upstream-Fehler, Abbruch/Rollback und historischen Outputs; bloße Draft-Dateipräsenz bewirkt nichts;
- UI-Abnahme mit getrenntem „Existing story material“-Intake und „Script development“-Gate sowie sichtbaren Rollen für Sketch, Bible-Reference, Frame-Anchor, Take und Sequence Review.

Verantwortung: #560 kann Script erst nach Vertragsfreigabe implementieren; #561 übernimmt atomare Storyboard-/Causality-/Timing-Eigentümerschaft; #563 implementiert Draft, Bible-Auflösung, Identität und Promotion; #562 liefert die native Ansicht. #533 bleibt alleiniger Vertrag für die optionale Pre-Render-Review-Phase. #572/#573 betreffen nur optionalen externen Snapshot-Import. Dieser Entwurf autorisiert keine Implementierung, keinen lokalen Build, keinen Release und keine kostenpflichtige Generierung.
