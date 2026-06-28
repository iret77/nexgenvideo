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
  Render-Dispatch, Cost-Guard, Frame-Audit) lebt in der **Generic Production Engine** (Python).
- **MCP = Transport, Plugin = Distribution.** Deterministische CLIs → MCP-`tools`; Disziplin →
  MCP-`resources`; Phasen/Commands → MCP-`prompts`. Ein Plugin (`plugin.json` + Skills + MCP) ist
  die installier-/aktivierbare Einheit **pro Videoformat**.
- **Claude besitzt den Agent-Loop.** Egal ob über API-Key (in-app) oder `claude -p` (CLI):
  Claude führt seine Tool-Calls selbst aus und treibt die Timeline über NexGens **lokalen
  MCP-Server**. NexGen baut keinen eigenen Agent-Loop für die eingebettete Runtime nach.
- **BYO-Keys, lokal, kein Login.** Keine Accounts, keine serverseitige Generierung, keine
  Telemetrie-Pflicht. Du bringst deine eigenen Provider- und Claude-Keys mit.

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
   (macOS-Keychain). Lädt **immer** den Generic Core + **optional aktivierte** Format-Packs.
   Liefert die **bidirektionale Review-UI**.
2. **Generic Production Engine (Python, ex-`musicvideo`)** — die wiederverwendbare Substanz:
   Asset-Graph-Bible, Konsistenz/Reference-Engine, Sanity/Linter-Framework,
   **Render-Dispatch + Cost-Guard + Provider-Driver**, State-Aggregator, MCP-Spine,
   Projekt-Layout/Paths, scene3d/Pano, Frame-Compliance. **Ruft die Provider** (mit den vom Host
   verwalteten Keys). Lebt im **Monorepo** (Unterordner `engine/`), wird mit der App gebündelt und vom
   eingebetteten Claude per `--plugin-dir` geladen.
3. **Format-Packs (dünn)** — die **einzige** Daseinsberechtigung eines Packs ist
   **kategoriespezifisches Wissen**, das *nicht* jedes Videoformat braucht. Ein Pack begleitet den
   User in NexGen durch den Prozess seiner Kategorie (Konzept → final geschnittenes Video), nutzt für
   Konsistenz/Bible/Kamera/Render/Effekte aber **den Core**. Erstes Pack: `musicvideo`; geplant:
   `explainer`, `fiction`/`shortmovie`, `trailer`, `vacation`, …

**Ein Repo, ein Produkt (Monorepo).** Alle drei Schichten leben in `nexgen-video` — *kein* eigenes
Core-Repo, *kein* Submodul:

```
nexgen-video/
  Sources/PalmierPro/   ← Swift-Host (App)
  engine/               ← Generic Production Engine (Python, generisch)
  packs/musicvideo/     ← erstes Format-Pack (dünn); weitere Packs daneben
```

Das heutige separate `musicvideo`-Repo „geht auf" in `engine/` (generische Teile) + `packs/musicvideo/`
(Musik-Spezifika). Begründung: ein autonomes Produkt = ein Repo, eine Versionierung, kein
Submodul-Schmerz. Ein eigenes `nexgen-core`-Repo bräuchte es nur, wenn die Engine von *Fremd-Hosts*
mitgenutzt würde — bei „NexGen ist *der* Host" trifft das nicht zu.

### 4.1 Core ↔ Plugin — die verbindliche Grenze

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
- **Modell-Katalog** kommt aus der **Provider-Registry der Engine** (nicht aus Convex), in der UI
  pro Modalität auswählbar/aktivierbar.
- Die Engine ruft die Provider (Render-Dispatch, Cost-Guard) und exponiert Generate-/Render-Ops als
  **MCP-Tools** → sowohl `claude -p` als auch der In-App-Agent rufen sie auf.

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
eingebettete Runtime liegt unter `Sources/PalmierPro/Agent/Runtime/` (Process, Event-Mapper,
Locator, Launch); sie lädt Generic Core + aktiviertes Pack via `--plugin-dir`, spricht NexGens
MCP (`127.0.0.1:19789/mcp`) hermetisch (`--strict-mcp-config`), Auth über Abo (`--setting-sources
project,local`, `--permission-mode bypassPermissions` headless). Verifizierter CLI-Vertrag:
`claude` v2.1.191.

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

- ✅ **Entschieden 2026-06-28 — Monorepo:** Generic Core + erste Packs leben in `nexgen-video`
  (`engine/`, `packs/<pack>/`), *kein* eigenes Repo, *kein* Submodul. Die alte „eigenes
  `nexgen-core`-Repo"-Tendenz war Über-Strukturierung und ist verworfen (ein autonomes Produkt = ein Repo).
- Mapping `.palmier`-Projektort ↔ Engine-Projektordner (Layout v2 `_studio/`) — Detaildesign.
- `io.palmier.project`-UTI behalten oder migrieren.

## 10. Bauphasen (Sequenz)

1. **De-Palmier-isierung / Autonomie:** Clerk, Convex, Palmiers Generierung, die Convex-Models-Pane
   raus; kein Sign-in; Upstream-Referenzen entfernen (README, MCP-Name, interne `PalmierPro`/
   `io.palmier.*`-Reste schrittweise).
2. **Provider-Layer:** API-Key-Verwaltung (Keychain) für REST-Provider **+ Anbindung MCP-nativer
   Tools (z. B. ACE Studio 2)** + Generate-Tools über MCP + provider-gespeister Modell-Katalog in der UI.
3. **Generic-Core-Extraktion** aus `musicvideo` (MOVE-Tier 1:1 verschieben, dann MIXED hinter
   Interfaces; bestehende Tests als Regressionsnetz) → `engine/` im Monorepo; Multi-Pack-Wiring (Core immer
   + aktiviertes Pack) + Packs-UI.
4. **`musicvideo` als In-App-Workflow-Pack** (Konzept → final geschnittenes Video).
5. **Bidirektionale Review-UX** (Preview/Approve/Comment/Trim, Frame-Gates).

Disziplin: erst die Stufe-B-Runtime an einem echten Projekt beweisen, dann die große
Python-Extraktion — nicht umgekehrt.

## 11. Build-/CI-Realität (verbindlich)

**Kein lokaler Build — niemals.** Verifikation ausschließlich über **GitHub Actions**
(`ci.yml`, `macos-26`, `swift build` + `swift test`). Signiert + notarisiert über **unsere eigene
high5 Developer ID** (`release.yml`, App-Store-Connect-API-Key, EdDSA-Sparkle-Key). `dev-latest` =
rollendes signiertes Prerelease als öffentlicher Direktlink. PRs immer `--repo iret77/nexgen-video`.

## 12. Status (Stand 2026-06-28)

**Auf `main` (erledigt):** eigenes Developer-ID-Signing/Notarisierung; Rebrand Display-Name →
„NexGenVideo"; Icon + Splash; eigenes Hosting des Such-CoreML-Modells (weg von Palmiers HF);
eingebettete `claude -p`-Runtime (`Agent/Runtime/*`) + AgentPane-„Runtime"-Section; Bundle-ID
`de.h5ventures.nexgenvideo`; Sparkle-Feed auf unser Repo.

**Noch Palmier-gekoppelt (= Phase 1, zu entfernen):** Clerk-Login, Convex-Backend, die
Convex-gespeiste Models-Pane, Palmiers `generate_video`-Pfad, interner Name `PalmierPro` /
`io.palmier.*`-Reste, MCP-Servername `palmier`, README-Upstream-Verweise.

---

### Quellen / Lineage
- `musicvideo/docs/v1-studio-plan.md` — „Palmier-Integration (Rev. 3)" + Ökosystem-/Säulen-Konzept
  (von diesem Dokument für die Plattform **abgelöst**; bleibt Referenz für das `musicvideo`-Pack).
- Stufen-Modell: **Stufe A** = Light (kein Fork, MCP-Client + Bridge) — *nicht* unser Weg;
  **Stufe B** = Vollausbau (Fork bettet `claude -p` ein) — **das bauen wir**, erweitert um volle
  Autonomie + eigene Provider-Einbindung (dieses Dokument).
