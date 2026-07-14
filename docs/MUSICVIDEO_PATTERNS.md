# Musicvideo Patterns — Konzept (Regisseur-/Stil-Vorlagen)

> **Status:** Konzept, owner-gated. Der inhaltliche Umbau (Re-Grounding, Ergänzen)
> wird gesondert freigegeben. Diese Datei ist die maßgebliche Quelle für die
> Pattern-Schicht des musicvideo-Packs; die referenzierenden Issues zeigen hierher,
> damit das Konzept nicht verwaist.
>
> **Begriff:** Wir nennen das Feature **„Pattern"** (Code nutzt `pattern` bereits;
> kein Rename). CONCEPT.md spricht synonym von „Blueprints berühmter Regisseure".
>
> **⚠️ Auswahl-Mechanismus abgelöst:** Die Pattern-**Auswahl/Empfehlung** folgt jetzt
> normativ [docs/PATTERN_FIT_CONTRACT.md](PATTERN_FIT_CONTRACT.md) (`pattern-fit/1.0`):
> deterministischer Fit-Scorer über eine eingefrorene Policy, `fit_profile`-Pflichtblock
> je Pattern-YAML, harter Cutover ohne Trigger-Scorer/Fallback, fail-closed bis alle 23
> Profile existieren. Die unten beschriebenen Trigger-/`scorePatterns`-Abschnitte sind
> historisch — sie beschreiben den entfernten Integer-Scorer, nicht mehr das Verhalten.

## 1. Zweck & Einordnung

NexGenVideo ist generische, AI-assistierte Videoerstellung. Ein **Plugin** (z. B.
`musicvideo`) macht die Produktions-Pipeline spezifisch für eine Video-Art. Ein
**Pattern** verfeinert das optional weiter: der User kann sich an Klassikern der
Musikvideo-Geschichte orientieren. Schicht-Logik:

```
NGV (generisch)  →  Plugin: musicvideo (Pipeline)  →  Pattern (optionale Stil-Vorlage)
```

Ein Pattern ist eine **faktenbasierte Stil-Schablone**, abgeleitet aus realen
Vorlagen — bekannte Regisseure/DOPs (Romanek, Wong Kar-wai/Doyle, Corbijn, Gavras,
Hype Williams …) oder archetypische Genre-Stile (Tiny-Desk, Vaporwave, Punk-DIY …).
Sie ist **optional**: wer eine klare eigene Vorstellung hat, braucht kein Pattern.
Mit gezielten User-Anpassungen entsteht am Ende dennoch etwas Eigenes.

Zwei eiserne Regeln verhindern strukturell ein „Fassaden-Feature":

- **(R1) Jede Pattern-Angabe bindet an einen realen Pipeline-Hebel** — kein Feld ohne
  Konsument (analog zu „no dead provider key fields").
- **(R2) Jede operative Angabe trägt eine Quellen-Provenienz** — Faktum oder als
  Inferenz gelabelt. Keine erfundenen Werte.

## 2. Ist-Zustand (Regression — siehe Issue #185)

Die 23 Pattern-YAMLs + das Schema wurden aus dem Vorgängerrepo `iret77/musicvideo`
**byte-identisch/schema-treu** übernommen. Der **Wirkmechanismus** wurde beim
Pack-Split jedoch nicht mit portiert → im laufenden App-Flow ist das Feature eine
Fassade:

- Scorer (`scorePatterns`/`suggestPatterns`) ist toter Code (kein MCP-Tool).
- `PATTERN_DRIFT` ist nicht als Pack-Sanity registriert (ENGINE_MIGRATION.md verlangt es).
- Der Agent hat keinen sanktionierten Pfad zu den YAMLs.
- `brief.md` §18 / `storyboard.md` §4 verweisen auf Tools/Checks, die es nicht gibt.

Vollständige Belege und Fix-Richtung: **Issue #185**.

Inhaltliche Prüfung: Referenzen sind **real und recherchiert** (14 Regisseur-, 5
Archetyp-, 4 Hybrid-Stile; 148 Quellen, ~90 Domains). Schwäche: `framing_mix`/
`asl_range` sind **geschätzt, nicht gemessen** (runde 5er-Schritte, `ms_pct` in ~19/23
dominant); einzelne Patterns dünn zitiert (cartoon-adult-swim, punk-diy,
lyric-typography, tiny-desk). Nit: „Khalil" statt korrekt „Kahlil" Joseph.

## 3. Ziel-Architektur

### 3.1 Schema (feste Struktur, erweitert das heutige Pattern)

- **Per-Value-Provenienz** statt eines pauschalen `approximation_basis`: jeder
  operative Block (`framing_mix`, `asl_range`, `camera`, `lighting`, `color`) trägt
  `basis: measured | documented | inferred` + Quelle + (bei `measured`) das vermessene
  Referenzvideo. Damit ist „Faktum vs. Schätzung" auf Feldebene sichtbar.
- **`craft_signature[]`** — die verifizierbaren, zitierbaren Techniken (z. B.
  Step-Printing, anamorph 2.40:1, single hard key/deep shadows, practical neon als
  key). Das ist der faktenbasierte Kern, der direkt in `visual_prompt`/Bible/Lighting
  übersetzt.
- **Nur hebel-gebundene Direktiven** im Schema (R1). Rückwärtskompatibel: bestehende
  Felder bleiben; die neuen sind additiv.

### 3.2 Mechanismus (echte Wirkung — behebt die Regression, Issue #185)

- **Auswahl:** MCP-Tool `suggest_patterns(brief_context)` → Swift-Scorer → Top-N +
  Begründung + Quellen → brief-Agent zeigt via `show_dialog`.
- **Laden:** MCP-Tool `get_pattern(id)` → storyboard/shotlist/bible konsumieren die
  Direktiven.
- **Injektion (stärkster Hebel):** `craft_signature`/Style-Tokens fließen in das
  **mandatorische `compile_prompt`-Gate** (merged bereits gelockte Attribute) → jeder
  gerenderte Frame erbt den Stil, nicht nur das Storyboard.
- **Spiegel:** `PATTERN_DRIFT` (framing/ASL) als Pack-Sanity registrieren + optional
  Style-Token-Presence im Linter. Der Spiegel macht aus „gewählt" ein „ausgeführt".

## 4. Grounding-Methodik (recherchebasiert, nicht geraten)

Evidenz-Tiers, per Wert im `basis`-Label festgehalten:

1. **`documented`** — Primär-Craft-Quellen (Regie/DOP-Interviews, ASC/BFI/Criterion,
   Shot-Breakdowns). Die zitierbaren Techniken in `craft_signature`.
2. **`measured`** — gemessene Shot-Statistik gegen ein kanonisches Referenzvideo
   (siehe §5). Liefert reale `asl_range` (Median = `typical_s`, Perzentile = min/max)
   und `framing_mix` (ausgezählte Verteilung).
3. **`inferred`** — bewusster Stil-Zielwert, aus zitierter Craft abgeleitet, explizit
   als nicht-gemessen gelabelt.

**Archetyp-Sonderfall:** Für die 14 Regisseur- + 4 Hybrid-Patterns existiert ein
kanonisches Video zum Vermessen. Für die 5 reinen Genre-Archetypen (Punk, Vaporwave,
Lyric-Typo, Tiny-Desk, K-Pop) gibt es das nicht → repräsentative Stichprobe (3–5
Exemplare aggregieren) **oder** ehrlich `documented`/`inferred`.

**Bar:** Ein Filmemacher liest das Pattern und erkennt es als korrekt; jede operative
Aussage → Quelle oder als Inferenz markiert.

## 5. Messwerkzeug (privat, einmalig, nicht für Public Release)

Die gemessenen Werte entstehen in einem **einmaligen, offline Authoring-Schritt** —
**nicht** in der App zur Laufzeit. Die App konsumiert nur das fertige YAML.

- **Ort:** eigenes **privates Repo** (empfohlen) oder Sub-Tool außerhalb des
  Release-Trees. Nie im ausgelieferten App-Bundle. Wird ausschließlich vom Owner
  betrieben. (Details/Entscheidung: eigenes Issue.)
- **ASL/Schnittrate:** [PySceneDetect](https://www.scenedetect.com/) → Shot-Grenzen →
  Dauer je Einstellung → `asl_range` (min/median/max, gemessen).
- **framing_mix:** Shot-Scale-Klassifikation in der
  [CineScale](https://cinescale.github.io/shotscale/)-Taxonomie (9 Klassen ≈ unsere
  FramingMix-Felder) über einen repräsentativen Frame je erkanntem Shot; **Mensch
  spot-checkt** eine Stichprobe.
- **Output:** je Video ein Stats-Artefakt (JSON/YAML) — Videotitel + URL + Dauer, Tool
  + Version, Messdatum, Ergebnis-Stats. Fließt als `basis: measured`-Werte in die
  Pattern-YAMLs. Wir speichern nur abgeleitete Statistik + Zitat, nicht das Video.

## 6. Arbeitspakete (jeweils eigenes Issue, verweist hierher)

1. **Mechanismus-Fix** — `suggest_patterns`/`get_pattern`-Tools, `compile_prompt`-
   Injektion, `PATTERN_DRIFT` registrieren. → **Issue #185**.
2. **Messwerkzeug** — privates Repo/Sub-Tool (§5). Voraussetzung für Paket 4. → **Issue #186**.
3. **Schema-Evolution** — Per-Value-Provenienz + `craft_signature` + Anti-Fassade (§3.1). → **Issue #187**.
4. **Content-Re-Grounding** — 18 kanonische Patterns vermessen, Werte + Provenienz
   füllen, schwach zitierte Patterns nachziehen, „Kahlil"-Fix (§4). Hängt an Paket 2+3. → **Issue #188**.

## 7. Offene Owner-Entscheidungen

- **Grounding-Bar:** Blend (gemessen wo kanonisches Video existiert, sonst gelabelte
  Inferenz) — empfohlen. Alternativen: nur `documented` (Zahlen raus) / volle
  Mehr-Video-Cinemetrics.
- **Messwerkzeug:** eigenes privates Repo vs. gitignoriertes Sub-Tool.
- Reihenfolge: Mechanismus-Fix (#185) zuerst und separat vom inhaltlichen Umbau.
