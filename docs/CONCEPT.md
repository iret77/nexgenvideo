# NexGen Video — Konzept (autoritativ)

> **Diese Datei ist die maßgebliche Produkt- und Architektur-Quelle.** Sie vereint das
> ursprüngliche Integrationskonzept aus `musicvideo/docs/v1-studio-plan.md` (Abschnitt
> „Palmier-Integration", Rev. 3) mit der erweiterten Zielvision (2026-06-28) und **löst die
> dortige Palmier-Integrations-Sektion ab**. Bei Widerspruch gilt dieses Dokument.
> Für die Produktions-Disziplin im Detail (Bible/Anker, Reference-Mode, Sanity-Gates, Render,
> 3D/Pano) bleibt `musicvideo/docs/v1-studio-plan.md` die Referenz des **Pakets** — nicht der Plattform.

## 1. Was NexGen Video ist

NexGen Video ist ein **KI-nativer macOS-Videoeditor**, technischer Fork von
`palmier-io/palmier-pro` (Swift 6.2, SwiftUI + AppKit, AVFoundation, macOS 26, arm64,
non-sandboxed Developer-ID-App), aber **in sich vollständig autonom**: nutzbar **ohne jede
Verbindung, Referenz oder Abhängigkeit zum Upstream-Projekt oder dessen Diensten**.

Kernidee: **Du arbeitest in NexGen mit Claude bidirektional zusammen.** Claude bedient alle
Tools, generiert und orchestriert die Projektarbeit; du schaust über die NexGen-UI zu und
greifst jederzeit ein — previewen, freigeben, kommentieren, Clips schieben/kürzen, korrigieren.
Keine Claude-Desktop-App nötig — dein gewohnter Claude bleibt an deiner Seite, **innerhalb** von
NexGen.

## 2. Leitprinzipien

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
   verwalteten Keys). Wird mit der App gebündelt, vom eingebetteten Claude per `--plugin-dir` geladen.
3. **Format-Packs (dünn)** — z. B. `musicvideo`: nur format-spezifische Skills/Scripte
   (Song-/Audio-/Beat-Analyse, Lyrics, Treatment/Storyboard/Shotlist-Semantik, Cover,
   Genre-/Mood-Pattern). Ein Pack begleitet den User **in NexGen** durch den gesamten Prozess —
   vom Konzept bis zum final geschnittenen Video. Pro Videoformat ein Pack auf gemeinsamer Basis.

**Generic vs. format-spezifisch (First-Cut-Grenze):** GENERIC → Engine: `common/{gates,paths,
schema,models,project,aspect}`, `render/*` (dispatcher, costs, provider-driver, prompt-builder/
linter/compliance), `frames/*`, `bible/*` (inkl. scene3d), `storyboard/{framing_risk,camera}`,
`sanity/*` (generisch), `state/*`, `mcp_server/*`. MUSIC-SPECIFIC → Pack: `analysis/*` (Audio-DSP),
`patterns/*`, `cover/*`, `common/tempo`, `sanity/checks/{tempo,pacing,pattern_drift}`. MIXED →
hinter Interface entkoppeln: `brief/schema`, `shotlist/schema` (Mode.phrase/section, lyrics_anchor),
`storyboard/schema`, `render/dispatcher` + `frames/generate` (Shot-Interface), `show/formatters`.
Riskanteste Naht: Music-Annahmen in generischem Code (`Shot.duration_s` ↔ `perceived_bpm`,
`lyrics_anchor`, `Mode.phrase/section`) — das Pack registriert music-spezifische Builder/Checks/Bands.

## 5. Provider- & Modell-Einbindung

NexGen bindet die **Generator-Plattformen direkt ein** — der User bringt API-Keys mit:
**Runway, fal.ai, OpenArt, Higgsfield, ElevenLabs, …**, über alle Modalitäten: **Video, Bild,
Musik, SFX**.

- **API-Keys** pro Provider in den Settings (Sektion „Providers"), in der **Keychain** gespeichert,
  nie im Repo/Klartext. Der Host reicht sie an die Engine.
- **Modell-Katalog** kommt aus der **Provider-Registry der Engine** (nicht aus Convex). In der UI
  pro Modalität auswählbar/aktivierbar.
- **Generierung als MCP-Tools.** Die Engine exponiert Generate-/Render-Operationen über den
  MCP-Server → sowohl `claude -p` als auch der In-App-Agent rufen sie auf. Der Host legt fertige
  Clips per `import_media` (referenziert in place, kostenlos) + `add_clips` frame-genau auf die
  Timeline.

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

- **Wo lebt der Generic Core physisch?** Eigenes Repo `iret77/nexgen-core` (von der App
  gebündelt/submoduled) **vs.** Unterordner im nexgen-video-Repo. *Plan-Tendenz: eigenes Repo*
  (sauberer Schnitt, eigene Versionierung, mehrere Packs). **Noch zu entscheiden.**
- Mapping `.palmier`-Projektort ↔ Engine-Projektordner (Layout v2 `_studio/`) — Detaildesign.
- `io.palmier.project`-UTI behalten oder migrieren.

## 10. Bauphasen (Sequenz)

1. **De-Palmier-isierung / Autonomie:** Clerk, Convex, Palmiers Generierung, die Convex-Models-Pane
   raus; kein Sign-in; Upstream-Referenzen entfernen (README, MCP-Name, interne `PalmierPro`/
   `io.palmier.*`-Reste schrittweise).
2. **Provider-Layer:** API-Key-Verwaltung (Keychain) + Generate-Tools über MCP + provider-gespeister
   Modell-Katalog in der UI.
3. **Generic-Core-Extraktion** aus `musicvideo` (MOVE-Tier 1:1 verschieben, dann MIXED hinter
   Interfaces; bestehende Tests als Regressionsnetz) → `nexgen-core`; Multi-Pack-Wiring (Core immer
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
„NexGen Video"; Icon + Splash; eigenes Hosting des Such-CoreML-Modells (weg von Palmiers HF);
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
