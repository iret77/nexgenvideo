# Future Format Packs — Knowledge & Behavior Spec v0.1

**Status: ausgearbeiteter Draft für spätere Pack-Entscheidungen; keine Implementierungs-/Release-Freigabe.** Diese Spec ist selbst die vorbereitete Wissensbasis, kein Ticket, erst noch eine Spec zu schreiben. Parent #433; Wissensmigration #482. Die Kandidaten sind fachliche Scopes, keine bereits beschlossenen Pack-IDs.

Quelle: [ai-film-production v3.1.1-en, Commit 0333751](https://github.com/iret77/ai-film-production/tree/0333751214c7af17977dd33f0ba88ba9c352421e), unveränderter HEAD am 2026-09-08. Referenzkürzel unten beziehen sich ausschließlich auf diesen Snapshot. Frühere v2.4-Auslegungen sind abgelöst.

## 1. Wie diese Spec zu lesen ist

- **S** = konkret aus dem Skill extrahiertes Wissen; **N** = daraus abgeleiteter NexGenVideo-Produkt-/Vertragsentwurf. Beide sind Vorschläge für die zukünftigen Packs; keine der genannten Zahlen ist ein live verifiziertes Modelllimit.
- **SS** = `references/story-structures.md`; **GB** = `genre-baselines.md`; **PP** = `production-pipeline.md`; **PB** = `production-bible.md`; **PA** = `post-audio-legal.md`; **FC** = `film-craft.md`; **SC** = `style-control.md`; **PX** = `pixar-look.md`; **W** = `workflows.md`.
- Genre (Action/Horror/Comedy usw.), Look (Anime/stylized 3D), Storycontainer (Dreiakt/Kishōtenketsu/Mosaik) und Director-/DoP-Rezept sind zunächst Libraries. Ein eigener Pack braucht zusätzliche Intake-, Artefakt-, Phasen- oder Delivery-Policy. Animation/Vertical können deshalb auch Compose-Module statt eigenständiger Packs werden.
- Alle Phasenfolgen unten sind **logische Draft-Flows**. Ein später genehmigter Pack deklariert genau einen eigenen geordneten Harness-Vertrag nach #441. Es wird keine globale zusätzliche Phasenliste eingeführt und Musicvideos gesperrter Graph wird nicht verändert.
- Pflichtfragen nur für fehlende formatentscheidende Angaben; vorhandenen Canon verwenden. Ein Pack kann kreative DRAFT-Vorschläge liefern, darf aber fehlende Tatsachen, Quellen, Kundenzusagen oder Freigaben nicht erfinden. Generierung verlangt den tatsächlichen Approval-/Spend-Pfad.

## 2. Gemeinsame technische Verträge (N)

Jeder Pack liefert seine eigenen versionierten Context-/Policy-Extensions und Runtime-Instructions; Core konsumiert nur Referenzen und generische Ausführungsanforderungen. Jede Extension benennt `schema`, `pack_id`, `project_id`, stabile fachliche IDs, genaue Source-Artefakt-/Media-Hashes und getrennte Approval-/Decision-Referenzen. Kein zweiter Canontext als Copy im Core.

- #440: formatneutrale Execution/Creative-Context-Projektion; #483: Camera-/State-/Take/Cut-/Blockout-Plan; #484: kausale Vorschläge, nur wenn narrativ passend.
- #438/#437/#439: Assets, Requirements, tatsächliche Route und Modell-/Mode-Dialekt. Keine Providerlisten, Preiszahlen oder Requestsyntax im Pack. Ein datierter Skillclaim ist keine ausführbare Capability.
- #442/#443: echte Medienreview-/Take-/Sequence-Proofs. Harte Integritäts-/Identity-/Qualitätsausschlüsse vor Emotion-Ranking; keine behauptete Sichtung ungesehener Medien.
- #444/#445: Assembly und Finish/Delivery. Pack liefert Pacing-/Audio-/Readiness-Policy, Core schreibt/prüft die tatsächlichen Quellen, Zeiten und Exporte.
- Pure imported, generated und ai_enhanced werden pro Shot respektiert. Reales Material wird nicht für eine abstrakte „Stills-first“-Pflicht neu generiert. AI-enhanced verwendet ausschließlich die deklarierte Projektquelle.
- Ein Pack-interner neuer Fact/Asset-State erfordert eigene Freigabe und den passenden Rewind. Public ABI bleibt unverändert; neue Artefaktversionen, reale separate `.ngvpack`-Loads und exakte Projektpins.

## 3. Fiction / Shortmovie

**S — Kernwissen:** SS 23a–c/23d/23g: Formatlänge und Geschichte bestimmen den Container; kurzer Film = eine Situation/ein wesentlicher Turn, spät hinein/früh hinaus, nicht automatisch verkürzter Spielfilm. Nichtlinearität braucht getrennte Story-/Präsentationsreihenfolge und Continuity pro Zeitebene. PP 7: Dialog als bewusste wiederkehrende Coverage mit Achs-/Eyeline-Bindung; W10 für komplexe Räume.

**N — Intake:** vorhandenes Script oder Greenfield; Zielumfang, POV, Premise/Want/Tension/Turn/Endrichtung, Dialogsprache und beabsichtigter Container. Fehlende Storyteile sind Vorschläge. Ein stiller Kurzfilm verlangt keinen Dialog.

**N — Draft-Flow:** Premise/Container → Treatment/Script → Szenen-/Beatreview → Setup/Storyboard/Stateplan → Assets/ggf. Blockout → Execution/Generation → Take-/Sequenzreview → Schnitt/Delivery. Lookfreie Planung kann vor fertigen Assets existieren; keine vorgetäuschten Assetfreigaben.

**N — Packartefakte:** `FictionStoryContext` mit Scene-/Beat-IDs, Storyzeit und Präsentationsreihenfolge, POV, Szenenziel/Wertwechsel, Dialogreferenzen und narrativem Stategraph. `DialogueCoveragePolicy` bindet Sprecher, Reaktion, Listening Coverage, Achse und bewusste Ausnahmen. Filmlook bleibt Core-Library.

**Abnahme:** Eine nichtlineare Dreiszene erhält in chronologischer wie präsentierter Reihenfolge korrekte Propzustände. Löschen eines Plants markiert späteren Payoff. Ein kurzer Film ohne Dialog funktioniert vollständig; ein fehlender genehmigter Dialog wird nicht in den Prompt erfunden. #448 bleibt der kleine technische Fixture-Beweis, kein vollständiger Fiction-Pack.

## 4. Series / Episodic

**S — Kernwissen:** SS 23d/PB 22a.6 trennen episodisch (stabile Welt, lokale Auflösung/Reset), serialisiert (Staffel als durchgehender Film), hybrid (episodische A-Handlung plus B-Staffelbogen), Anthologie (Thema/Ton/Frame statt gleicher Figuren) und Limited Series (fixes Ende). Sitcom: Cold Open, Premise-Pivot, A/B-Handlung, Eskalation, Status-quo-Reset. Sketch: ein absurdes Prinzip, Steigerung, bewusster Abbruch am Höhepunkt; kein erzwungenes klassisches Ende.

**N — Intake:** Serienpol, Zielanzahl/Umfang, bekannte Welt/Cast, Staffelabschluss oder offene Serie, Einstiegsvoraussetzungen und Episoden-/Staffelbogen. Sketch/Sitcom sind Varianten, nicht neue Packs auf Verdacht.

**N — Draft-Flow:** World/Season contract → Season-/Episode map → freigegebene Episode → Fiction-/Sketch-Unterworkflow → Episode Review → Season Consistency/Delivery. Ein Projekt besitzt kanonische Welt-/Staffelartefakte und schlanke Episodenindizes; Episoden sind in V1 keine fremden externen Projekte mit ungesicherten Querpfaden.

**N — Artefakte:** `SeriesContext` (Pol, unveränderliche Weltversion, gemeinsamer Assetindex), `SeasonArc` (B-Arc/Reveal-/Payoff-IDs, Boundary Changes), `EpisodePlan` (Hook, lokaler Bogen, In/Out-State, Reset-/Cliffhanger-Entscheidung). Serialized Continuity gilt über Episodengrenzen; Anthologie darf Cast/Look pro Episode wechseln. Änderungen an der Welt erfolgen nur als explizite neue Version mit betroffenen Episoden, nicht als stiller Chat-Edit.

**Abnahme:** Episodische Verletzung setzt sich nur bei genehmigtem Carryover fort; serialisierte Verletzung verschwindet nicht in Episode 2. Anthologie erbt keine fremde Figur. Staffeländerung benennt genau die abhängigen Episoden. Innerhalb eines Projekts läuft weiterhin nur ein aktiver Phase-Job.

## 5. Documentary / Interview / Biographical

**S — Kernwissen:** SS 23d: eine Argumentationsform wählen — These/Essay, Chronologie, investigative Reveal-Leiter, Beobachtung oder Porträtmosaik. Interview: Paper Edit vor Bildproduktion, Soundbites an Filmpositionen, Stimmen als Witness/Expert/Counterposition/Emotional Center, eigenständige Aussagen, Held Silence am emotionalen Peak. PP 7b: Audio zuerst, konsistente Blickseite, geplante B-Roll, J-/L-Cuts; PA 18/20: Stimme/Provenienz und Freigaben.

**N — wichtige Adaption:** Echte Dokumentation benutzt echte Interviews/Transkripte/Quellen. Der Skill beschreibt auch erfundene dokumentarische Szenen; deren „geschriebene Antworten“ dürfen in NGV niemals als authentische Zeugenaussagen gelten. Generierte B-Roll ist Illustration/Rekonstruktion, kein Beleg eines realen Ereignisses. Eine Biografie unterscheidet belegte Fakten und ausdrücklich fiktionalisierte Szenen.

**N — Intake/Flow:** dokumentarische Wahrheitsklasse und Fragestellung → Quellen/Interviews/Consent-Metadaten → Transcript/Paper Edit → Narration-/Audio-Lock → Bild-/Rekonstruktionsplan → Assets/Execution → Claim-/Context-/Sequence-Review → Schnitt/Disclosure-Delivery. Beobachtungsfilm darf ohne Interview/VO starten.

**N — Artefakte:** `DocumentaryEvidenceMap` (Claim → reale Quelle/Zeitbereich, Status), `PaperEdit` (verbatim Bite, Source-In/Out, Argumentfunktion, Zielposition), `ReconstructionPlan` (was inszeniert/generiert ist und wie gekennzeichnet), `InterviewCoveragePolicy`. Sprecherfunktionen sind Dramaturgie, keine Erlaubnis, Aussagen umzuformulieren oder Kontext zu verfälschen.

**Abnahme:** Generierter Clip kann keinen Claim als belegt markieren; ein gekürzter Bite behält Originalquelle/Range. Disclosure/Source fehlt → kein behaupteter faktischer Beweis. Held-silence-Beat wird nicht automatisch mit B-Roll zugedeckt. Audio-only-Porträt und imported-only Observational funktionieren. Rechtsstatus bleibt dokumentierte Nutzerangabe; keine automatische juristische Freigabe aus dem Skill.

## 6. Commercial / Product / UGC Ad

**S — Kernwissen:** GB Commercial/Ad und SS 23d: eine erinnerbare Botschaft, Produkt als Protagonist/Payoff, Dramaturgie nach Länge; kurzer Bumper ein Bild/Gag, längerer Spot Setup/Payoff oder Mini-Arc. Eine dominante Politur (glossy oder bewusst UGC), Produktgeometrie/Packshot konsistent, genaue Logos/Claims/Endcards im Postpfad. Makro/Liquid/Food braucht konkrete Risiko-/Rescueplanung.

**N — Intake/Flow:** Zielgruppe, Kernbotschaft, tatsächlicher Produkt-/Brandkanon, belegte Claims, CTA, genehmigte Varianten/Seitenverhältnisse → Message/Concept → Script/Packshot-/Endcard-Plan → Assets/Execution → Brand-/Claim-/Sequence-Review → Varianten/Delivery. Keine automatische Shop-, Veröffentlichungs- oder Werbebuchung.

**N — Artefakte:** `CampaignBrief` (eine Message, Claims mit Quelle/Approval, Brand-/Produktversion), `AdVariantPlan` (Länge, Hook, Payoff, CTA, Pflichtbestandteile, Safe Areas), `ProductTruthConstraints` (referenzierte Form/Farbe/Verpackung/Skala). 6/15/30/60 Sekunden sind Skill-Beispiele, keine fest verdrahteten Plattformlimits.

**Abnahme:** Kürzere Variante verliert Pflichtclaim/CTA nicht still. Falsches Logo oder Produktverformung wird als Finding sichtbar; exakter Endcardtext kommt aus dem freigegebenen Text-/Grafikpfad. Synthetischer UGC-Sprecher wird nicht als echter Kunde mit erlebtem Ergebnis ausgegeben. Regionale Disclosures werden als konkrete Delivery-Anforderung mit geklärter Quelle geführt, nicht aus pauschalem Rechtswissen behauptet.

## 7. Vertical / Social / Microdrama

**S — Kernwissen:** SS 23d: Hook → Promise → Teilpayoffs/Rehooks → Promise-Payoff/Loop; Faceless VO, wiederkehrende Skitfigur, Part-Series und serialisiertes Microdrama sind unterschiedliche Formen. 9:16 bevorzugt lesbare Singles/vertikale Geografie; Titel-/Thumbnailversprechen wird im Script eingelöst. Skill-Zeitspannen sind Startheuristiken, keine universellen Retention-Gates.

**N — Intake/Flow:** Inhaltsform, Zielplattform/-format, Hookversprechen, Länge, Caption-/Audioabsicht, Einzelstück versus Reihe → Micro-Outline/ggf. Season-/Parts map → Vertical Setup-/Safe-Area-Plan → Execution → Promise-/Loop-/Lesbarkeitsreview → Varianten/Delivery. Plattformvorgaben kommen aus datierter aktueller Delivery-Spec.

**N — Artefakte:** `RetentionPlan` mit Hook-/offene-Frage-/Payoff-IDs und begründeten Rehooks; `VerticalFramingPolicy`; `PartBoundaryPlan` für Cliffhanger, Wiedereinstieg und endgültige Auflösung. Microdrama konsumiert Series-Canon; Faceless konsumiert Explainer/Documentary-Voiceover; dieselben Fakten nicht doppelt speichern.

**Abnahme:** Jeder gesetzte Promise hat einen Payoff oder bewusst genehmigten Cliffhanger; letzter Part schließt die Serie nicht versehentlich offen. 16:9→9:16-Reframe prüft Gesichter, Hände/Produkt und Captionflächen im tatsächlichen Export. Loop wird an realen End-/Anfangsbytes gesichtet. Keine Garantie von Reichweite/Retention und keine automatische Monetarisierung aus dem Skill.

## 8. Explainer / Educational / Faceless VO

**S — Kernwissen:** SS 23d/23e: VO-Spine, Hook/Promise, segmentierte Payoffs, VO soll dem Bild zusätzliche Information geben; PP 7b liefert B-Roll-/Audio-first-Mechanik. Der Skill enthält keine vollständige Pädagogik-Spec.

**N — deshalb expliziter NGV-Entwurf:** Intake klärt Lernziel, Publikum/Vorwissen, Ausgangsmaterial, belegte Aussagen, Ziellänge und Sprache. Plan: Learning brief → Claim-/Concept map → VO/Erklärstruktur → Visual explanation plan → Audio/Assets/Execution → Verständnis-/Faktenreview → Delivery.

**N — Artefakte:** `LearningObjectiveMap` (Ziel → erforderliche Begriffe/Schritte → Nachweis im Inhalt), `ExplanationScript` (VO mit Quellen-/Beispielbindung), `VisualExplanationPlan` (Diagramm/Demo/Analogie/B-Roll und jeweilige Aussage). Notwendige Begriffe werden vor ihrer Verwendung eingeführt; Analogie ist als Analogie markiert, nicht als Mechanismusbeweis. Exakte Formeln, UItexte und Diagrammlabels gehören in den deterministischen Grafik-/Postpfad, nicht in eine frei generierte Aufnahme.

**Abnahme:** Tutorial ohne Gesicht benötigt keine Figur/Voiceclone/Lipsync. Unbelegte Zahl bleibt offen statt vom Agenten vervollständigt. Ein definiertes Lernziel ohne erklärenden Schritt wird gemeldet; ein automatisch gesetztes Bool behauptet nicht tatsächliches menschliches Verständnis. Importierter Screencast und generierte Illustration sind pro Shot unterscheidbar. Pädagogische Evaluation und konkrete Zielgruppenpolicies müssen vor Produktfreigabe noch ausgearbeitet werden — diese Lücke ist nicht durch den Skill belegt.

## 9. Animation / Family / Anime Production

**S — Kernwissen:** GB Family Animation trennt Dramaturgie vom Look: Want/Need, verdiente emotionale Wendung, komische und emotionale Beats; Anime kann gehaltene Posen, sichtbare Emotionsbeats und selektiv aufwendige Bewegung benutzen. PP 1/3/8, PX 8–10 und W10: Figuren-/Proportionen vor Blockout/Plates, State-/Expression-Sheets, klare Trennung von Blocking und Look, Motion Ladder zur Stilprüfung.

**N — Packgrenze:** Ein Cartoon-Look allein aktiviert nur Libraries/Profile. Ein separater Animation-Pack ist erst gerechtfertigt, wenn Character-development, Rig-/Expression-/Motion-Approval und Animatic-Freigabe seinen eigenen Arbeitsablauf tragen. Sonst bleibt Animation ein Compose-Modul auf Fiction/Series/Musicvideo.

**N — Intake/Flow:** Geschichte/Format plus Animationstechnik/-grammatik → Character-/Expression-/Proportion-Design → Storyboard/Animatic → Blockout/Layout → Style-/Location-Anker → Motion-Test/Execution → Performance-/Continuity-Review → Picture Lock/Audio/Delivery. Der logische Flow muss mit W10 und bestehendem Canon konsistent deklariert werden; er erfindet keine zugleich aktiven Phasen.

**N — Artefakte:** `AnimationPerformancePolicy` (Pose/Timing/Holds/Smears/Weight pro genehmigter Technik), `CharacterPerformanceModel` (Expression-/State-Assetrefs), `AnimaticApproval` (Schnitt-/Timingplan, Rohquelle versus finaler Pixelpfad). Family-Psychologie ist optional nach Storycontainer; Anime ist kein Pflichtturnierplot.

**Abnahme:** Figurengestützter Plate nutzt Figur als Style-/Scale-Referenz ohne Doppelcharakter; leerer derivierter Plate behält korrekte Herkunft. Fast-action oder Squash/Stretch wird als erklärte Animationsabsicht reviewed, nicht als genereller Physikfehler verworfen. Kein notwendiger Stil-/Motion-Test wird durch Dateiexistenz als bestanden erklärt.

## 10. Trailer / Teaser

**S — verwertbare Basis:** SS 23d (Hook/Reveal-Leiter), FC §4/7 (Schnittrhythmus, Spannung, Motive), PP 10 (saubere Coverage-Ranges) und GB Thriller/Commercial liefern Bausteine. Der Skill liefert keinen vollständigen dedizierten Trailer-Workflow.

**N — Produktentwurf:** Intake legt verfügbares Ausgangswerk, Teaser versus Storytrailer, Zielversprechen, Spoilergrenze, Zielvarianten und verpflichtende Titel/Releaseinfos fest. Flow: Source map → Promise-/Reveal-/Spoiler plan → ausgewählte Media-Ranges/ggf. genehmigte Zusatzproduktion → Trailer assembly → Promise-/Spoiler-/Audio-Review → Endcards/Delivery.

**N — Artefakte:** `TrailerDisclosurePlan` (sichtbare Information pro Beat, verbotene Reveals, Freigabeversion), `TrailerSelectionPlan` (Originalsource/range, Zweck, Reihenfolge), `CampaignVariant`. Dieselbe Source aus einem anderen Projekt wird explizit ins aktuelle Projekt übernommen und lokal gehasht; kein ungeprüfter Cross-project-Link. Zusatzshots sind neue genehmigte Produktion, keine als vorhandene Filmszene getarnte Behauptung.

**Abnahme:** Plot-Twist außerhalb freigegebener Spoilergrenze blockiert die Auswahlentscheidung. Umordnung verwendet richtige Quellranges, verändert keine Originaltakes. Teaser darf abstrakt bleiben; Storytrailer verspricht keine Handlung, die das Ausgangswerk nicht besitzt. Genaue Länge/Endcarddaten werden gegen die wirkliche Delivery geprüft. Trailer-spezifische Varianten-/Spoilerpolicy ist vor Implementierung gesondert produktseitig zu bestätigen.

## 11. Vacation / Travel / Personal Documentary

**S — verwertbare Basis:** SS 23c (Mosaik/Bookend/Vignette), SS 23d/GB Documentary (Chronologie/Beobachtung), FC (Schnitt/Ortsorientierung) und PP 9 (hybrides Material). Der Skill ist für generatives Filmen geschrieben und liefert keine vollständige Footage-first-Urlaubseditorik.

**N — Produktentwurf:** Default vorhandenes Material; Intake fragt Reise/Zeitraum, Personen/Orte nur soweit nötig, gewünschte Erzählform/Privatheit, Musik und Zielumfang. Flow: Import/Kuration → belegte Orts-/Zeitgruppen → Chronologie oder genehmigter Erinnerungsschnitt → Coverage-/Lückenplan → Schnitt → Review/Delivery. Generative Ergänzung ist optional und ausdrücklich als solche gekennzeichnet.

**N — Artefakte:** `TravelMemoryIndex` (Medien-IDs, bekannte Zeit-/Ortsmetadaten mit Herkunft/Unsicherheit), `JourneyEditPlan` (Ortswechsel, Begegnungen, Details, Geräusche, wiederkehrende Motive), `GapDecision` (bewusst auslassen, Titelkarte, bestehendes Material oder genehmigte generative Illustration). EXIF und Dateinamen sind Hinweise, keine Freigabe zum Erfinden von Personen/Orten/Ereignissen.

**Abnahme:** Imported-only vom Intake bis Export ohne Provider/Bible-Neugeneration. Unbekannter Ort bleibt unbekannt; fehlender Reiseabschnitt wird nicht automatisch synthetisch „rekonstruiert“. Bewusster Mosaikschnitt ist keine defekte Chronologie. Originalton und Musik können getrennt reviewed werden; vorgeschlagene private Personen-/Ortstitel werden vor Verwendung bestätigt, sofern nicht bereits Canon.

## 12. Aktivierung, Lücken und spätere Umsetzung

| Kandidat | Kategorie-Verantwortung | Gemeinsame Libraries / Profiles | Evidenzbreite |
|---|---|---|---|
| Fiction | Script/Szene/Dialog/Storyzeit | Narrative, Genre, Setup/Coverage | direkt, reichhaltig |
| Series | Welt/Staffel/Episode/Reset | Fiction/Comedy/Retention | direkt, reichhaltig |
| Documentary | Quellen/Claims/Paper Edit/Rekonstruktion | Interview/VO/Look | direkt, mit Wahrheitsklassen-Adaption |
| Commercial | Brand/Produkt/Message/CTA/Varianten | Genre/Produkt-Coverage | direkt |
| Vertical | Hook/Payoff/Loop/Parts/Framing | Series/VO/Narrative je Form | direkt; Packagingentscheidung offen |
| Explainer | Lernziel/Erklärung/Claim | VO/Diagramm/Source-QA | teilweise; Pädagogik ist N |
| Animation | Character/Motion/Animatic | Look/Family/Anime/Narrative | direkt; eigener Pack nur bei eigenem Workflow |
| Trailer | Spoiler/Reveal/Source-selection | Schnitt/Spannung/Campaign | abgeleitet; dedizierte Policy ist N |
| Vacation | Footage/Orts-/Zeitkuration/Erinnerung | Mosaik/Documentary/Assembly | abgeleitet; Footage-first ist N |

Vor einer Pack-Implementierung werden Kandidaten-ID und tatsächlicher Produktscope, geordnete PhaseContracts, konkrete geschlossene Schemas/Writer, UI-Intake und unabhängige Acceptance-Traces bestätigt. Diese Spec gibt dafür bereits Inhalt und Beispiele vor. Weder neue Packs noch Anbieter-/Modellfakten werden allein durch das Inventar veröffentlicht. Bestehendes #448 bleibt bewusst klein.

## 13. Vollständigkeits- und Reviewkriterien der Spec

- [x] Neun künftige Kandidaten enthalten konkrete Intake-/Flow-/Artefakt-/Abnahmeentwürfe und Quellstellen.
- [x] Formatwissen ist von Genre/Look/Providerwissen und gemeinsamem Core getrennt.
- [x] Direkte Skill-Extraktion und zusätzliche NGV-Entwürfe sind unterscheidbar; dünn belegte Bereiche sind ausdrücklich benannt.
- [x] Sitcom/Sketch, episodisch/serialisiert/Anthologie, faceless/part-series und Animation-as-look sind als Varianten eingeordnet.
- [x] Reale Dokumentation, importiertes Material und individuelle kreative Ausnahmen werden nicht durch generative Defaultregeln verfälscht.
- [ ] Produktentscheidungen und tatsächliche ausführbare Schemas/CI-Verträge erfolgen erst beim jeweiligen genehmigten Pack-Auftrag.

Keine bestehenden locked Specs werden mit diesem Draft geändert. Diese Spec und die Musicvideo-Child-Issues sind dauerhaft in #433/#447/#482 verlinkt; kurzlebige Sitzungsnotizen sind keine Voraussetzung, sie zu verstehen.
