# NexGenVideo — Konzept (autoritativ)

> **Diese Datei ist die maßgebliche Produkt- und Architektur-Quelle.** Sie vereint das
> ursprüngliche Integrationskonzept aus `musicvideo/docs/v1-studio-plan.md` (Abschnitt
> „Palmier-Integration", Rev. 3) mit der erweiterten Zielvision (2026-06-28) und **löst die
> dortige Palmier-Integrations-Sektion ab**. Bei Widerspruch gilt dieses Dokument.
> Für die Produktions-Disziplin im Detail (Bible/Anker, Reference-Mode, Sanity-Gates, Render,
> 3D/Pano) bleibt `musicvideo/docs/v1-studio-plan.md` die Referenz des **Pakets** — nicht der Plattform.

## 1. Was NexGenVideo ist

NexGenVideo ist ein **KI-nativer macOS-Videoeditor**, technischer Fork von
`palmier-io/palmier-pro` (Swift 6.2, SwiftUI + AppKit, AVFoundation, macOS 26, arm64,
non-sandboxed Developer-ID-App), aber **in sich vollständig autonom**: nutzbar **ohne jede
Verbindung, Referenz oder Abhängigkeit zum Upstream-Projekt oder dessen Diensten**.

Kernidee: **Du arbeitest in NexGen mit Claude bidirektional zusammen.** Claude bedient alle
Tools, generiert und orchestriert die Projektarbeit; du schaust über die NexGen-UI zu und
greifst jederzeit ein — previewen, freigeben, kommentieren, Clips schieben/kürzen, korrigieren.
Keine Claude-Desktop-App nötig — dein gewohnter Claude bleibt an deiner Seite, **innerhalb** von
NexGen.

## 2. Leitprinzipien

- **Konsistenz ist das Produkt.** Der Unterschied zwischen AI-Slop und Premium-Video ist *nicht* die
  Roh-Generierungsqualität (die ist oft schon gut), sondern **Konsistenz & Logik über Shots hinweg** —
  Figuren, Details und Szene müssen einen *neuen Kamerawinkel* überstehen, ohne zu halluzinieren.
  NexGen schöpft dafür **alle technischen Hebel** aus: maximale Anker-Bilder, top-optimierte Prompts,
  und Hilfs-Pipelines (3D-Clay/Marble-Kamera), deren *einziger* Zweck konsistente Vorlagen/Anker für
  die Generierung ist. Diese Maschinerie ist **CORE** (siehe §4.1), kein Plugin-Detail.
- **Cockpit + Quality-Engine getrennt.** NexGen ist Cockpit, Schnitt-/Render-Surface und
  Orchestrierungs-Host. Die wiederverwendbare Produktions-Substanz (Konsistenz-Disziplin,
  Prompt-Compile, Render-Manifest, Cost-Guard, Frame-Audit) lebt in der **Generic Production Engine**
  (`NexGenEngine`, Swift-Library, in den App-Binary kompiliert).
- **MCP = Transport, Pack = Spezialisierung.** Deterministische Engine-Operationen → `nexgen`-MCP-
  `tools`; Disziplin/Wissen → gebündelte Ressourcen der Engine. Ein **nativer Format-Pack** (Swift-
  Modul, konform zum `Pack`-Protokoll) ist die aktivierbare Einheit **pro Videoformat**.
- **Claude besitzt den Agent-Loop.** Egal ob über API-Key (in-app) oder `claude -p` (CLI):
  Claude führt seine Tool-Calls selbst aus und treibt die Timeline über NexGens **lokalen
  MCP-Server**. NexGen baut keinen eigenen Agent-Loop für die eingebettete Runtime nach.
- **BYO-Keys, lokal, kein Login.** Keine Accounts, keine serverseitige Generierung, keine
  Telemetrie-Pflicht. Du bringst deine eigenen Provider- und Claude-Keys mit.
- **Hybride Produktion ist erstklassig.** NexGenVideo ist ein vollwertiges NLE. Der generische
  Workflow **und jeder Pack** (musicvideo, später weitere) sind ohne KI-Generierung, mit ihr, oder
  gemischt nutzbar — **kein Workflow setzt Generierung voraus.** Jeder Shot trägt einen `source_mode`
  aus drei Werten: `generated` (Provider rendert), `live_action` (der User dreht selbst) und
  `ai_enhanced` (importiertes Realmaterial läuft durch einen Video-to-Video-Pass, der bestehende
  „AI-Edit"-Pfad). Für `live_action`-Shots liefert der Assistent klare Regie-Specs (Framing, Kamera,
  Licht, Blocking, Stil-Referenzen), die der User dreht und professionell schneidet; die Render-Phase
  überspringt sie und sie kosten 0. `ai_enhanced`-Shots werden wie generierte abgerechnet und über
  den Edit-Pfad geführt.

## 3. Abgrenzung zum Upstream (Autonomie)

NexGen entfernt **alles**, was an `palmier-io` oder dessen Backend hängt. Wer Palmiers
gehostete Generierung will, nutzt das Original-Produkt — nicht diesen Fork.

**Raus (zu entfernen / abgelöst):**
- Palmiers eingebaute Generierung (`generate_video`, `canGenerate`, serverseitige Modell-Calls).
- Das **Convex**-Backend (Modell-Katalog `models:list`, Generation, Credits, Samples).
- Die **Clerk**-Login-/Account-Schicht (kein Sign-in).
- Die Models-Pane in ihrer heutigen (Convex-gespeisten) Form.
- Verbleibende Upstream-Verweise: interner Target-/Modulname `PalmierPro`, Bundle-Reste
  `io.palmier.*`, MCP-Servername `palmier`, README-/Doku-Verweise auf palmier-io, deren
  Social/Mail/Lizenz-Attribution. (Das Datei-Format-UTI `io.palmier.project` der `.palmier`-Datei
  kann aus Kompatibilität bleiben oder migriert werden — eigene Entscheidung.)

> Eine **eigene** Account-/Billing-Schicht ist ausdrücklich **kein** Teil dieser Autonomie. Falls
> jemals gewünscht, ist das ein separates, eigenes Backend-Projekt — nicht dieser Fork.

## 4. Architektur — drei Schichten

1. **NexGen Host (Swift)** — Editor, Timeline, UI, **lokaler MCP-Server**, eingebettete
   `claude -p`-Runtime *und/oder* In-App-Agent (Anthropic-Key). Verwaltet **Provider-API-Keys**
   (macOS-Keychain). Führt die Provider-Calls aus. Lädt **immer** den Generic Core + **optional
   aktivierte** Format-Packs. Liefert die **bidirektionale Review-UI**.
2. **Generic Production Engine (`NexGenEngine`, Swift-Library)** — die wiederverwendbare Substanz:
   Asset-Graph-Bible, Konsistenz/Reference-Engine, Sanity/Linter-Framework, Prompt-Compile-Pipeline,
   **Render-Manifest + Cost-Guard**, State-Aggregator, Projekt-Layout/Paths, Frame-Compliance. In den
   App-Binary **hineinkompiliert** — kein Python, kein venv, kein Subprozess. Die Engine **komponiert
   Prompts + erzwingt die Disziplin**; der Host führt die Provider-Calls aus (mit den Keychain-Keys).
   Ihre Tools sind erstklassige `nexgen`-MCP-Tools (M7).
3. **Format-Packs (dünn, nativ)** — die **einzige** Daseinsberechtigung eines Packs ist
   **kategoriespezifisches Wissen**, das *nicht* jedes Videoformat braucht. Ein Pack ist ein
   **Swift-Modul** in `NexGenEngine` (konform zum `Pack`-Protokoll), das seine Checks/Duration-Policy/
   UI-Contract/Projekt-Dirs in die Engine **registriert** und sein Wissen (Pattern-Libraries,
   Phasen-Dokus) als gebündelte Ressourcen mitbringt. Für Konsistenz/Bible/Kamera/Render/Effekte nutzt
   es **den Core**. Erstes Pack: `musicvideo`; geplant: `explainer`, `fiction`/`shortmovie`, `trailer`,
   `vacation`, …

**Ein Repo, ein Produkt, eine Sprache (Monorepo).** Alle drei Schichten leben in `nexgenvideo` als
Swift — *kein* eigenes Core-Repo, *kein* Submodul, **kein Python mehr**:

```
nexgenvideo/
  Sources/NexGenVideo/            ← Swift-Host (App)
  Sources/NexGenEngine/           ← Generic Production Engine (Swift-Library)
  Sources/NexGenEngine/Packs/     ← native Format-Packs (musicvideo; weitere daneben)
```

Der ehemalige `engine/`+`plugins/`-Python-Baum ist in `NexGenEngine` (+ `Packs/`) portiert und in M9
(Issue #119) entfernt. Begründung: ein autonomes Produkt = ein Repo, eine Sprache, eine Versionierung,
keine Runtime-Bootstrap-Reibung. Ein eigenes `nexgen-core`-Repo bräuchte es nur, wenn die Engine von
*Fremd-Hosts* mitgenutzt würde — bei „NexGen ist *der* Host" trifft das nicht zu.

### 4.1 Core ↔ Plugin — die verbindliche Grenze

> **Verbindliche Bindungsentscheidung (Owner):** Packs sind **echte, ladbare `.ngvpack`-Bundles** —
> signierter Swift-Dynlib + Ressourcen + Info.plist-Metadaten (Pack-ID, Version, `NGVMinAppVersion`,
> Entry-Class), außerhalb des DMG ausgeliefert und auf Anfrage geladen. Der frühere Zustand „Pack =
> in den App-Binary hineinkompiliertes Swift-Modul" war ein nicht freigegebenes Interim: `NexGenEngine`
> ist jetzt eine **geteilte dynamische Bibliothek**, die Host und Pack gemeinsam linken; ein
> `catalog.json` auf dem stabilen `plugins`-Kanal speist den In-App-Picker (Install/Update/Activate,
> mit hartem Lade-Gate: Version → Signatur → Load). Maßgeblich für das ladbare Format ist
> **[PLUGIN_STANDARD.md](PLUGIN_STANDARD.md)**; die „Swift-Modul in NexGenEngine"-Formulierungen unten
> und in §3 beschreiben weiterhin korrekt die *inhaltliche* Grenze (welches Wissen Core vs. Pack ist),
> nur die *Auslieferungsform* ist nun das `.ngvpack`.

**Faustregel:** *Braucht es jedes Videoformat? → Core. Nur diese Kategorie? → Plugin.* Früher war
`musicvideo` ein All-in-One-Tool **nur** für Musikvideos. Künftig ist die All-in-One-**Konsistenz-/
Produktions-Maschinerie der Core**, und ein Pack ist eine **dünne Kategorie-Schicht** darauf.

**CORE (nexgen + Generic Engine) — die Konsistenz-Maschinerie, von allen Packs genutzt:**
Asset-Graph-**Bible** (`bible`), **Anker-Maximierung** (`render/identity_anchor`), **3D-Clay/Marble-
Kamera-Pipeline** (`bible/scene3d`: marble/pov/restyle/preprocess → deterministische Vorlagen + Anker
für die Generierung), **Prompt-Optimierung** (`render/prompt`: builder/linter/compliance),
**Konsistenz-/Sanity-Gates** (`gates`, generische `sanity/*`), **Frame-Engine** (`frames`:
Generierung/Audit/deterministische Crops/last-frame-Continuity), **Render-Dispatch + Cost-Guard +
Provider-Driver** (`render/dispatcher`, …), **Effekt-/Postproduktion/Finishing** (siehe §5.4), State,
MCP-Spine, Projekt-Layout.

**PLUGIN (dünn, kategoriespezifisch) — nur das Format-Wissen:**
- **`musicvideo`:** Musik-/Beat-/Tempo-Analyse + eingebundene Audio-Tools Dritter (`analysis`,
  `common/tempo`), Lyrics, **Modi, wie sich Story/Storyboard/Schnitt zu Musik & Takt verhalten**
  (Mode.phrase/section, lyrics_anchor, refrain-anchor), **Genre/Mood + Blueprints berühmter
  Musikvideo-Regisseure** (`patterns/library/*.yaml`), Cover.
- **`explainer` (geplant):** Aufmerksamkeitspsychologie, Pädagogik/Didaktik, Wissensstrukturierung,
  Pacing für Verständnis, Skript-/Voiceover-Logik.
- **`fiction`/`trailer`/`vacation`/… (geplant):** je eigene Narrativ-, Schnitt- und Struktur-Doktrin.

**MIXED (heute im `musicvideo`-Monolith verwoben; beim Extrahieren hinter ein Engine-Interface):**
`brief/schema`, `shotlist/schema`, `storyboard/schema`, `render/dispatcher` + `frames/generate`
(Shot-Interface entkoppeln), `show/formatters`. Riskanteste Naht: Music-Annahmen in generischem Code
(`Shot.duration_s` ↔ `perceived_bpm`, `lyrics_anchor`, `Mode.phrase/section`). Lösung: das Pack
registriert seine Builder/Checks/Bands über eine **Engine-Schnittstelle** — der Core kennt keine Musik.

## 5. Provider- & Modell-Einbindung

NexGen bindet **Generator-Plattformen direkt ein** — der User bringt die Zugänge mit. Modalitäten:
**Video, Bild, Musik, SFX, Stimme/Vertonung, Effekt/Postproduktion.** Zwei Integrationsklassen:

**(a) REST/API-Provider** — z. B. **Runway, fal.ai, OpenArt, Higgsfield, ElevenLabs**.
- **API-Keys** pro Provider in den Settings (Sektion „Providers"), in der **Keychain** gespeichert,
  nie im Repo/Klartext. Der Host reicht sie an die Engine.
- **Modell-Katalog** kommt aus der **Provider-Registry des Hosts** (nicht aus Convex), in der UI
  pro Modalität auswählbar/aktivierbar.
- Der **Host** ruft die Provider (`FalModelRegistry`/`MarbleClient` etc., Cost-Guard) und exponiert
  Generate-/Render-Ops als **`nexgen`-MCP-Tools** → sowohl `claude -p` als auch der In-App-Agent rufen
  sie auf. Die Engine komponiert dazu die Prompts und erzwingt die Sanity-/Cost-Disziplin.

**(b) MCP-native Tools** — Apps, die selbst einen MCP-Server mitbringen. Hier braucht es **keinen
Key/Driver**: NexGens eingebettete Claude-Runtime hängt sie als **zusätzlichen MCP-Server** in die
`mcpServers`-Config (neben NexGens Timeline-MCP), Claude orchestriert sie direkt.

Fertige Clips/Audio landen in beiden Fällen per `import_media` (referenziert in place, kostenlos) +
`add_clips` frame-/beat-genau auf der NexGen-Timeline.

### 5.1 ACE Studio 2 (MCP-native Vertonung — Stimme, Instrumente, SFX, Video-Scoring)

**ACE Studio 2** (Timedomain, seit Dez 2025) ist ein All-in-One-KI-Musikstudio: 140+ KI-Stimmen in
8 Sprachen (Verse25-Vocal-Synth), KI-Instrumente, Generative Kits, **Video Composer** (analysiert
Video szenen-/frame-genau und generiert passende Musik + SFX als editierbare Timeline-Clips, bis
~45 min / 2 GB), DAW-Integration (ACE Bridge 2). Es deckt die **Vertonungs-Modalität** ab —
KI-Gesang, Instrumental, SFX, Score-to-Picture — und ergänzt/ersetzt teils den ElevenLabs-Pfad.

**Anbindung (MCP-nativ, Klasse b):** ACE Studio läuft als lokale App mit eigenem **MCP-Server** —
Transport **HTTP `http://localhost:21572/mcp`** oder **stdio** (Befehl aus ACE Preferences → General
→ MCP Server), **kein Auth** (lokal). Der Server exponiert Projekt-Info, Track-Erstellung/-Edit und
MIDI. NexGens eingebettete Claude-Runtime trägt ihn als zusätzlichen `mcpServers`-Eintrag → Claude
erzeugt/editiert dort Vokals/Instrumente/SFX und legt die exportierten Audio-Clips per NexGen-MCP auf
die Timeline.

**Caveats (Stand Web-Recherche 2026-06):** der ACE-MCP-Server ist **experimentell**; **Video
Composer ist derzeit GUI-only** (noch nicht über MCP fernsteuerbar). Heißt: Vokal-/Track-/MIDI-Arbeit
ist schon MCP-automatisierbar, die One-Click-Video-Vertonung (Video Composer) bleibt bis auf Weiteres
ein manueller ACE-Schritt — bei MCP-Erweiterung von ACE automatisierbar. Quellen: `docs.acestudio.ai`
(MCP-Server, Video Composer), `acestudio.ai/blog` (2.0 / 2.0.7-Release).

### 5.2 MCP-native Orchestrierung (größter Architektur-Hebel)

Tools, die selbst MCP sprechen, sind die effizienteste Provider-Anbindung (Klasse b) — Claude hängt
sich direkt dran, kein Driver pro Provider:
- **Comfy Partner MCP** (offiziell): *ein* lokaler MCP-Server → vereinte Generate-Tools über **30+
  Provider** (Flux/BFL, Ideogram, Kling, Runway, Veo, Meshy [3D-Assets], ElevenLabs, …). Kann große
  Teile des Provider-Layers ersetzen.
- **ComfyUI MCP** (z. B. `artokun/comfyui-mcp`): das gesamte Open-Source-Generierungs-Ökosystem +
  eigene Graphen/Modelle, Live-Graph-Editing aus der Claude-Session. Maximale Pipeline-Tiefe.
- **Blender MCP**: Claude steuert Blender direkt — **veredelt genau die 3D-Clay/Kamera-Core-Pipeline**
  (`bible/scene3d`, Splat/SPZ): deterministische Kamera-Renders agentengetrieben statt CLI-Glue.

### 5.3 Modalitäten & aktueller Katalog (volatil — bei Integration verifizieren)

> Die Modell-Landschaft ändert sich wöchentlich. Dies ist eine **Momentaufnahme (2026-06)**, kein
> Festschreiben — die **Provider-Registry der Engine** ist die Laufzeit-Wahrheit.
- **Lip-Sync / Avatare / Dialog** — eigene Modalität, die `musicvideo` nicht braucht, aber z. B.
  `explainer`/`fiction`: **Hedra** (Character-3, phonem-genauer Lip-Sync aus 1 Bild, 140+ Sprachen),
  **Runway Act-Two** (Performance-Capture Körper/Gesicht/Hände → beliebiger Charakter).
- **Video (SOTA):** Veo 3.1 (4K + natives Audio + Lip-Sync), Kling 3.0 (**Multi-Shot-Storyboard** —
  passt 1:1 auf unser Shotlist-Modell), Seedance 2.0 (Multi-Ref: 9 Bilder + 3 Clips + 3 Audios).
  **Sora 2 NICHT** integrieren (OpenAI schaltet Sora ab, API-Ende ~09/2026).
- **Musik:** Udio + **Suno**. **Transkription/Untertitel:** Whisper (→ „Edit-by-Transcript").

### 5.4 Effekt- & Postproduktions-Modelle (Core-Finishing-Stage)

Spezialisierte **Nachbearbeitung** ist eine **Core**-Stufe (von allen Packs genutzt) — sie hebt Clips
auf Auslieferungsqualität *und* schließt Konsistenzlücken:
- **Relight / Matte / Kompositing:** **Beeble** — Video → relightbare 2.5D-Szene mit PBR-Passes
  (Normals/Albedo/Depth/Specular/Roughness/Alpha) + Auto-Roto. Die Depth/Normal-Passes speisen
  zusätzlich die 3D-/Anker-Disziplin.
- **Inpainting / Object-Removal:** **VOID** (mask-guided, SAM-3-Masken), temporal stabil/flickerfrei.
- **Roto / Matte:** DaVinci Magic Mask, BiRefNet, SAM-3. **Layer-Zerlegung:** Generative Omnimatte.
- **Upscale / Denoise / Frame-Interpolation:** **Topaz Video AI** (OSS-Fallback: Real-ESRGAN/Video2X).
- **Restyle / Style-Transfer:** Video-to-Video (z. B. Runway).

Anbindung wie §5 (REST oder MCP-native); vieles kommt gebündelt über Comfy Partner / ComfyUI MCP.

## 6. Claude-Anbindung (zwei austauschbare Backends)

Claude steuert die eingebundenen Modelle und orchestriert das Projekt — **nach Wahl** über:
- **(a) In-App Anthropic-API-Key** (BYO-Key, Pay-per-Token), oder
- **(b) eingebettetes `claude -p` CLI** (Claude-Abo, keine API-Metering).

Die beiden sind **sich gegenseitig ausschließende** Backends desselben In-App-Agenten (ist die
Runtime an, wird der API-Key-Pfad übersprungen). **Keine Claude-Desktop-App nötig.** Die
eingebettete Runtime liegt unter `Sources/NexGenVideo/Agent/Runtime/` (Process, Event-Mapper,
Locator, Launch). Sie **lädt kein Python** — Engine + Format-Packs sind nativ in den App-Binary
kompiliert und über die `nexgen`-MCP-Tools erreichbar. Sie spricht NexGens MCP
(`127.0.0.1:19789/mcp`) hermetisch (`--strict-mcp-config`), Auth über Abo (`--setting-sources
project,local`, `--permission-mode bypassPermissions` headless). `--plugin-dir` bleibt nur für
**externe** Claude-Code-Plugins (Dev-Override); erstklassige Format-Packs brauchen es nicht.
Verifizierter CLI-Vertrag: `claude` v2.1.191.

## 7. Zusammenarbeitsmodell (bidirektional, Human-in-the-loop)

Claude arbeitet, **du** behältst die Kontrolle über die NexGen-UI: live mitlesen (Stream im
Agent-Panel), **previewen, freigeben, kommentieren, Clips schieben/kürzen, korrigieren**.
Review-Gates (z. B. Frame-Freigaben aus der Pipeline) erscheinen in der UI; headless laufen sie
als geführter/auto-approve-Modus. Claude = mit dir, nicht statt dir.

## 8. Produktions-Disziplin (Substanz der Engine — nicht verwässern)

Aus dem Quality-Motor zu bewahren (Detail in `musicvideo/docs/v1-studio-plan.md`): Bible-Anker
(Identitäten anchor-first), Reference-Mode/Konsistenz, **Sanity/Linter-Gates** (hart im
Render-Dispatcher erzwungen, kein „weicher" Bypass), **Cost-Guard** (Provider-Calls nur nach
Approve/innerhalb Limits, Provider-Limits gegen aktuelle Doku verifiziert), **Frame-Audit**
zwischen Provider-Call und Freigabe, anchor-getriebene 3D/Pano-Kamera (Splat-Renders als i2v-Anker).
Provider-Prompts sind Englisch (bindend). Diese Disziplin ist der Grund, warum nicht „irgendein
Modell-Call" reicht — sie macht die Konsistenz über Shots und Re-Renders reproduzierbar.

## 9. Offene Entscheidungen

- ✅ **Entschieden 2026-06-28 — Monorepo:** Generic Core + erste Packs leben in `nexgenvideo`,
  *kein* eigenes Repo, *kein* Submodul. Die alte „eigenes `nexgen-core`-Repo"-Tendenz war
  Über-Strukturierung und ist verworfen (ein autonomes Produkt = ein Repo).
- ✅ **Umgesetzt (M0–M9) — nativ statt Python:** die Engine + Packs sind Swift (`Sources/NexGenEngine/`,
  `…/Packs/`) statt Python (`engine/`+`plugins/`). Ein Produkt = eine Sprache; kein Runtime-Bootstrap.
- Mapping `.palmier`-Projektort ↔ Engine-Projektordner (Layout v2 `_studio/`) — Detaildesign.
- `io.palmier.project`-UTI behalten oder migrieren.

## 10. Bauphasen (Sequenz)

1. **De-Palmier-isierung / Autonomie:** Clerk, Convex, Palmiers Generierung, die Convex-Models-Pane
   raus; kein Sign-in; Upstream-Referenzen entfernen (README, MCP-Name, interne `PalmierPro`/
   `io.palmier.*`-Reste schrittweise).
2. **Provider-Layer:** API-Key-Verwaltung (Keychain) für REST-Provider **+ Anbindung MCP-nativer
   Tools (z. B. ACE Studio 2)** + Generate-Tools über MCP + provider-gespeister Modell-Katalog in der UI.
3. **Generic-Core als native Swift-Library** (`NexGenEngine`): die Substanz aus `musicvideo` erst nach
   Python `engine/`+`plugins/` extrahiert, dann (M0–M8) 1:1 nach Swift portiert und in M9 vom Python
   befreit; Multi-Pack-Wiring (Core immer + aktiviertes Pack) über die native Pack-Registry + Packs-UI.
4. **`musicvideo` als In-App-Workflow-Pack** (Konzept → final geschnittenes Video).
5. **Bidirektionale Review-UX** (Preview/Approve/Comment/Trim, Frame-Gates).

## 11. Build-/CI-Realität (verbindlich)

**Kein lokaler Build — niemals.** Verifikation ausschließlich über **GitHub Actions**
(`ci.yml`, `macos-26`, `swift build` + `swift test`). Signiert + notarisiert über **unsere eigene
high5 Developer ID** (`release.yml`, App-Store-Connect-API-Key, EdDSA-Sparkle-Key). `dev-latest` =
rollendes signiertes Prerelease als öffentlicher Direktlink **für die App (DMG)**; die Format-Packs
laufen über den davon entkoppelten, append-only `plugins`-Kanal. PRs immer `--repo iret77/nexgenvideo`.

## 12. Status (Stand 2026-06-28)

**Auf `main` (erledigt):**
- Eigenes Developer-ID-Signing/Notarisierung; Bundle-ID `de.h5ventures.nexgenvideo`; Sparkle-Feed auf unser Repo.
- Rebrand: Wortmarke **„NexGenVideo"** (ein Wort) überall sichtbar; Icon + Splash; Projekt-Extension `.ngv` + UTI `de.h5ventures.nexgenvideo.project`.
- Eigenes Hosting des Such-CoreML-Modells (weg von Palmiers HF).
- Eingebettete `claude -p`-Runtime (`Agent/Runtime/*`) + AgentPane-„Runtime"-Section.
- **Phase-1-De-Palmier-isierung abgeschlossen:** Clerk-Login, Convex-Backend und die Convex-Models-Pane entfernt; MCP-Servername `nexgen`; Changelog-Feed auf unser Repo.
- **Generation autonom über fal.ai (BYO-Key):** kuratierter Katalog — Bild (FLUX-Familie, Recraft,
  Ideogram, Imagen 4, Qwen, SD 3.5; Edit: Kontext, Gemini), Video (Kling, Seedance, Veo 3, Hailuo;
  + Kling/Seedance image-to-video), Audio (ElevenLabs TTS/SFX, Stable Audio), Upscale (Clarity, Topaz).
  fal-Storage-Upload für Referenzen verdrahtet; Provider-Keys-Pane. Architektur: `FalModelRegistry`
  (per-Modell-Dialekt) + `FalInputBuilder`/`FalOutput` + generischer `runFalJob`.
- **Marble (World Labs) World-Model (BYO-Key):** zweiter Provider neben fal, gleiche Katalog-Mechanik.
  `MarbleClient` (eigener Lifecycle: `WLT-Api-Key`-Header, `worlds:generate` → `operations/{id}`-Long-Poll)
  + `MarbleModelRegistry` + `MarbleInputBuilder`/`MarbleOutput`; `GenerationService` routet `marble/`-Modelle
  über `runMarbleJob`. Referenz-Bild + Geometrie-Text-Prompt → 3D-Welt; **nutzbarer Output = das
  equirektanguläre Panorama (PNG)**, gemappt auf den `.image`-Asset-Typ. Mesh (GLB), Splats (SPZ) und die
  POV/Restyle-Pipeline (numpy/py360convert aus dem alten `scene3d`-Modul) bewusst **out of scope**.

- **Native Generic Engine (`NexGenEngine`, Swift):** die Python-Engine ist vollständig nach Swift
  portiert (M0–M8) und in den App-Binary kompiliert — alle 12 Cockpit-Reads nativ, 20 Workflow-Tools
  als erstklassige `nexgen`-MCP-Tools, `musicvideo` als natives `Pack`-Modul (Checks/Duration-Policy/
  UI-Contract + gebündelte Pattern-/Phasen-Ressourcen). **M9 (Issue #119): der gesamte Python-Baum
  (`engine/`, `plugins/`), venv/uv-Bootstrap und das On-Disk-Plugin-Laden sind entfernt** — die App
  ist einsprachig, mit nativer Pack-Registry. Golden-Parität gegen die eingefrorenen Python-Oracle-
  Fixtures (Tests/NexGenEngineTests/Goldens).

**Offen / nächste Schritte:**
- **Laufzeit gegen die echte fal-API noch ungetestet** — bisher nur CI-Compile. Erst-Test nötig (txt2img → txt2video → TTS → i2v).
- **Marble blind implementiert** (kein Test-Key) — Erst-Test nötig.
- Mesh-/Splat-Import + POV-Extraction/Restyle für Marble (3D-Konsistenz-Workflow) als Folge-Arbeit.
- Weitere Provider (Runway, OpenArt, Higgsfield, ElevenLabs-direkt) als eigene Clients.
- Weitere native Format-Packs (`explainer`, `fiction`, …) auf der `Pack`-Schnittstelle.

---

### Quellen / Lineage
- `musicvideo/docs/v1-studio-plan.md` — „Palmier-Integration (Rev. 3)" + Ökosystem-/Säulen-Konzept
  (von diesem Dokument für die Plattform **abgelöst**; bleibt Referenz für das `musicvideo`-Pack).
- Stufen-Modell: **Stufe A** = Light (kein Fork, MCP-Client + Bridge) — *nicht* unser Weg;
  **Stufe B** = Vollausbau (Fork bettet `claude -p` ein) — **das bauen wir**, erweitert um volle
  Autonomie + eigene Provider-Einbindung (dieses Dokument).
