"""Markdown-Formatter für Projekt-Artefakte.

Jede Funktion nimmt ein geladenes Pydantic-Modell oder einen Pfad und liefert
einen Markdown-String zurück, der direkt im Chat angezeigt werden kann.

Zweck: der Orchestrator kann ein Artefakt konsistent ins Chat packen, BEVOR er
um Freigabe bittet. Damit muss der Sub-Agent nichts mehr selbst "anzeigen" (was
ohnehin nicht im Chat landet).
"""

from __future__ import annotations

import re
from pathlib import Path

import yaml

from nexgen_engine.core.paths import display_name

# Regex-Konsistenz mit dem Dispatcher und dem sanity-Check
# still_only_discipline. Substring-Match wuerde `xstill_only_approved`
# faelschlich als still-only anzeigen, obwohl der Dispatcher es korrekt
# ablehnt.
_STILL_ONLY_RE = re.compile(r"\bstill_only_approved\s*:", re.IGNORECASE)

from nexgen_engine.bible.schema import Bible
from nexgen_engine.bible.schema import load as load_bible
from nexgen_engine.brief.schema import Brief
from nexgen_engine.brief.schema import load as load_brief
from nexgen_engine.shotlist.schema import Shotlist
from nexgen_engine.storyboard.schema import Storyboard
from nexgen_engine.storyboard.schema import load as load_storyboard
from nexgen_engine.treatment.schema import Treatment
from nexgen_engine.treatment.schema import load as load_treatment


def _shorten(text: str, length: int = 80) -> str:
    t = text.strip().replace("\n", " ")
    return t if len(t) <= length else t[: length - 1] + "…"


def _mm_ss(seconds: float) -> str:
    m = int(seconds // 60)
    s = int(seconds % 60)
    return f"{m}:{s:02d}"


def show_brief(project_dir: Path) -> str:
    b: Brief = load_brief(project_dir)
    lines: list[str] = []
    lines.append(f"## Brief · {b.project}")
    lines.append("")
    lines.append("| Feld | Wert |")
    lines.append("|---|---|")
    lines.append(f"| Mission | `{b.mission.value}`{' · ' + b.mission_other if b.mission_other else ''} → {b.target_platform} |")
    if b.target_audience:
        lines.append(f"| Zielpublikum | {b.target_audience} |")
    lines.append(f"| Format | {b.aspect_ratio.value} · {b.length_mode} |")
    lines.append(f"| Modus | `{b.project_mode}` |")
    model = b.model_preference.value + (f" · {b.model_preference_other}" if b.model_preference_other else "")
    lines.append(f"| Runway-Modell | {model} |")
    lines.append(f"| Frame-Image-Modell | `{b.frame_image_model.value}`{' · ' + b.frame_image_model_other if b.frame_image_model_other else ''} |")
    lines.append(f"| Stems-Provider | `{b.stems_provider.value}` |")
    lines.append(f"| Chord-Analyse | {'an' if b.enable_chord_analysis else 'aus'} |")
    lines.append(f"| Budget | {b.budget_eur:.2f} € |")
    lines.append(f"| Konzept-Typ | `{b.concept_type.value}`{' · ' + b.concept_type_other if b.concept_type_other else ''} |")
    medium = f"`{b.visual_medium.value}`"
    if b.visual_medium_other:
        medium += f" · {b.visual_medium_other}"
    if b.visual_medium_notes:
        medium += f" — {b.visual_medium_notes}"
    lines.append(f"| Medium | {medium} |")
    tone = ", ".join(t.value for t in b.tone) if b.tone else "—"
    lines.append(f"| Ton | {tone}{' · ' + b.tone_other if b.tone_other else ''} |")
    if b.style_references:
        refs = " · ".join(b.style_references)
        lines.append(f"| Stil-Referenzen | {refs} |")
    figures = b.figures.value + (f" · {b.figures_other}" if b.figures_other else "")
    if b.figure_count_hint:
        figures += f" ({b.figure_count_hint})"
    lines.append(f"| Figuren | {figures} |")
    lyrics_int = b.lyrics_integration.value
    if b.lyrics_integration_other:
        lyrics_int += f" · {b.lyrics_integration_other}"
    lines.append(f"| Lyrics-Integration | {lyrics_int} |")
    # Cut-Handles-Mode — Schnitt-Workflow-Anker.
    lines.append(f"| Cut-Handles | `{b.cut_handles_mode.value}` |")
    # Director-Pattern — sichtbar im Brief-Review vor Gate.
    pattern_id = (b.director_pattern or "").strip()
    if pattern_id:
        lines.append(f"| Director-Pattern | `{pattern_id}` |")
    if b.notes:
        lines.append("")
        lines.append("**Notes:**")
        lines.append(b.notes.strip())
    return "\n".join(lines)


def show_treatment(project_dir: Path, version: int | None = None) -> str:
    t: Treatment = load_treatment(project_dir, version=version)
    lines: list[str] = []
    lines.append(f"## Treatment · {t.meta.project} · v{t.meta.version}")
    if t.meta.title:
        lines.append(f"### {t.meta.title}")
    lines.append("")
    lines.append(f"**Origin:** `{t.meta.origin}` · **Generator:** {t.meta.generator} · **Generated:** {t.meta.generated}")
    lines.append("")
    lines.append(f"> {t.meta.summary_oneline}")
    lines.append("")
    lines.append("---")
    lines.append("")
    lines.append(t.body_markdown.strip())
    if t.meta.notes:
        lines.append("")
        lines.append("---")
        lines.append("")
        lines.append(f"_Notes: {t.meta.notes}_")
    return "\n".join(lines)


def show_bible(project_dir: Path) -> str:
    bible: Bible | None = load_bible(project_dir)
    if bible is None:
        return "_Keine bible.yaml vorhanden._"
    lines: list[str] = []
    lines.append(f"## Bible · {bible.project}")
    lines.append("")
    # Look
    look = bible.look
    any_look = any([look.style, look.palette, look.lighting, look.lens, look.film_stock, look.grain, look.motion_style, look.additional])
    if any_look:
        lines.append("### Look-Guide")
        lines.append("")
        lines.append("| Feld | Wert |")
        lines.append("|---|---|")
        if look.style:
            lines.append(f"| **Style** | {look.style} |")
        if look.palette:
            lines.append(f"| Palette | {look.palette} |")
        if look.lighting:
            lines.append(f"| Lighting | {look.lighting} |")
        if look.lens:
            lines.append(f"| Lens | {look.lens} |")
        if look.film_stock:
            lines.append(f"| Film-Stock | {look.film_stock} |")
        if look.grain:
            lines.append(f"| Grain | {look.grain} |")
        if look.motion_style:
            lines.append(f"| Motion-Style | {look.motion_style} |")
        if look.additional:
            lines.append(f"| Additional | {look.additional} |")
        lines.append("")

    def _coverage_cell(it) -> str:
        """Coverage-Anker als kompakte Anzeige: refs + sheets."""
        refs = len(getattr(it, "reference_images", []) or [])
        sheets = getattr(it, "sheets", {}) or {}
        parts = []
        if refs:
            parts.append(f"{refs} ref")
        if sheets:
            keys = sorted(sheets.keys())
            parts.append(f"sheets: {', '.join(keys)}")
        if not parts:
            return "⚠️ KEINE"
        return " · ".join(parts)

    def _people_section(header: str, items: list, with_count: bool = False) -> None:
        if not items:
            return
        lines.append(f"### {header}")
        lines.append("")
        if with_count:
            lines.append("| id | name | n | prompt (gekürzt) | attributes | Coverage |")
            lines.append("|---|---|---:|---|---|---|")
        else:
            lines.append("| id | name | prompt (gekürzt) | attributes | Coverage |")
            lines.append("|---|---|---|---|---|")
        for it in items:
            attrs = ", ".join(f"{k}={v}" for k, v in it.attributes.items()) if it.attributes else "—"
            cov = _coverage_cell(it)
            if with_count:
                lines.append(f"| `{it.id}` | {it.name} | {it.member_count} | {_shorten(it.visual_prompt, 60)} | {attrs} | {cov} |")
            else:
                lines.append(f"| `{it.id}` | {it.name} | {_shorten(it.visual_prompt, 60)} | {attrs} | {cov} |")
        lines.append("")

    _people_section("Characters", bible.characters)
    _people_section("Ensembles", bible.ensembles, with_count=True)
    _people_section("Props", bible.props)
    _people_section("Locations", bible.locations)
    if bible.notes:
        lines.append("**Notes:**")
        lines.append(bible.notes.strip())
    return "\n".join(lines)


def show_shotlist(project_dir: Path, version: str = "current") -> str:
    """Formatte shotlist/<version>.yaml für den Chat.

    Hierarchische Markdown-Struktur statt einer großen Tabelle — die
    Desktop-App rendert H4-Header + Bullet-Items + Inline-Markdown deutlich
    übersichtlicher als eine 7-spaltige Tabelle mit 30-50 Zeilen.

    Pro Shot eine kompakte Header-Zeile (ID, Zeit, Dauer, Typ, Keyframe,
    Flags) plus eine zweite Zeile mit Refs (👤/📍/🎒-Emojis als visuelle
    Marker) und Beschreibungs-Excerpt.
    """
    path = project_dir / "shotlist" / f"{version}.yaml"
    if not path.exists():
        return f"_Keine shotlist/{version}.yaml vorhanden._"
    data = yaml.safe_load(path.read_text(encoding="utf-8"))
    sl = Shotlist.model_validate(data)

    lines: list[str] = []
    lines.append(f"## Shotlist · {sl.project} · {version} · mode={sl.mode.value}")
    lines.append("")

    # Header-Zeile mit kompakten Kennzahlen
    durations = [s.duration_s for s in sl.shots]
    asl = (sum(durations) / len(durations)) if durations else 0.0
    perceived = sl.song.perceived_bpm if hasattr(sl.song, "perceived_bpm") else sl.song.bpm
    bpm_str = f"{sl.song.bpm:.1f} BPM"
    if abs(perceived - sl.song.bpm) > 0.1:
        mult = getattr(sl.song, "tempo_multiplier", 1.0)
        bpm_str = f"{perceived:.1f} BPM (×{mult:g} aus {sl.song.bpm:.1f})"
    lines.append(
        f"**{len(sl.shots)} Shots** · ASL {asl:.1f}s · Budget {sl.budget_eur:.2f} € "
        f"· {bpm_str} · Dauer {_mm_ss(sl.song.duration_s)}"
    )
    lines.append("")

    # Section-Übersicht (kompakte Tabelle — ist kurz, lohnt sich)
    by_section: dict[str, list] = {}
    for shot in sl.shots:
        by_section.setdefault(shot.section or "(none)", []).append(shot)

    lines.append("### Section-Übersicht")
    lines.append("")
    lines.append("| Section | Zeit | Shots | ASL | KF-Mix |")
    lines.append("|---|---|---|---|---|")
    for sec, shots in by_section.items():
        start = _mm_ss(shots[0].time_start)
        end = _mm_ss(shots[-1].time_end)
        sec_asl = sum(s.duration_s for s in shots) / len(shots)
        from collections import Counter
        kf_counter = Counter(s.keyframe_strategy.value for s in shots)
        # kompakt: 'start×4 none×2'
        kf_mix = " ".join(f"{k}×{v}" for k, v in kf_counter.most_common())
        lines.append(f"| `{sec}` | {start}–{end} | {len(shots)} | {sec_asl:.1f}s | {kf_mix} |")
    lines.append("")

    # Sanity-Snapshot wenn vorhanden — gibt dem User direkt einen Blick
    # auf bekannte Findings, ohne dass er den sanity-Check separat fahren muss.
    sanity_path = project_dir / "sanity-report.yaml"
    if sanity_path.exists():
        try:
            srep = yaml.safe_load(sanity_path.read_text(encoding="utf-8")) or {}
            n_err = len(srep.get("errors") or [])
            n_warn = len(srep.get("warnings") or [])
            badge = "✓" if n_err == 0 else "✗"
            lines.append(
                f"**Sanity-Snapshot:** {badge} {n_err} Errors · ⚠ {n_warn} Warns "
                f"(siehe sanity-report.yaml)"
            )
            lines.append("")
        except Exception:
            pass

    # Shots pro Section als kompakte Bullet-Items
    lines.append("### Shots")
    lines.append("")
    for sec, shots in by_section.items():
        lines.append(f"#### `{sec}` · {_mm_ss(shots[0].time_start)}–{_mm_ss(shots[-1].time_end)} · {len(shots)} Shots")
        lines.append("")
        for shot in shots:
            # Header-Zeile: ID + Zeit + Dauer + Typ + Keyframe + Flags
            kf = shot.keyframe_strategy.value
            kf_badge = {"none": "–", "start": "▶︎", "start_end": "▶︎▶︎"}.get(kf, kf)
            flags: list[str] = []
            if shot.redo:
                flags.append("⟳ redo")
            if getattr(shot, "chain_with_previous_end", False):
                flags.append("⛓ chain")
            # still-only-Marker im notes-Feld → Pipeline-Sichtbarkeit.
            # Regex-Konsistenz mit Dispatcher/sanity-Check.
            notes_str = getattr(shot, "notes", None) or ""
            if _STILL_ONLY_RE.search(notes_str):
                flags.append("🖼 still-only (NLE)")
            flag_str = " · " + " · ".join(flags) if flags else ""
            lines.append(
                f"- **`{shot.id}`** · {_mm_ss(shot.time_start)} · {shot.duration_s:.1f}s "
                f"· {shot.type.value} · KF {kf_badge}{flag_str}"
            )

            # Refs-Zeile: 👤 Characters · 📍 Location/View · 🎒 Props
            ref_parts: list[str] = []
            if shot.character_refs:
                ref_parts.append("👤 " + ", ".join(shot.character_refs))
            if shot.location_ref:
                loc = shot.location_ref
                if shot.location_view:
                    loc = f"{loc}/{shot.location_view}"
                ref_parts.append(f"📍 {loc}")
            if shot.prop_refs:
                ref_parts.append("🎒 " + ", ".join(shot.prop_refs))
            mood = (shot.mood or "").strip()
            if mood:
                ref_parts.append(f"_{mood}_")
            if ref_parts:
                lines.append("  " + " · ".join(ref_parts))

            # Beschreibungs-Excerpt
            desc = (shot.description or "").strip()
            if desc:
                lines.append(f"  > {_shorten(desc, 140)}")
            lines.append("")  # Leerzeile zwischen Shots

    if sl.notes:
        lines.append("### Notes")
        lines.append("")
        lines.append(sl.notes.strip())
    return "\n".join(lines).rstrip() + "\n"


def show_analysis(project_dir: Path) -> str:
    """Audio-Analyse-Ergebnis als kompakte Übersicht.

    Liest die erste analysis/*.json und zeigt: BPM/Key/Dauer,
    Downbeats + Quelle, Stems-Status, Alignment-Zeilen, Section-Liste
    mit Zeitstempeln, gruppierte Anomalien aus `interpretation`.

    Schema-Referenz: bpm/key/duration_s liegen TOP-LEVEL, Sections
    haben `start/end/label`, Anomalien haben `kind/time/note`.
    """
    ana_dir = project_dir / "analysis"
    if not ana_dir.exists():
        return "_Kein analysis/-Ordner vorhanden — Phase A noch nicht durch._"
    candidates = sorted(p for p in ana_dir.glob("*.json") if not p.name.startswith("_"))
    if not candidates:
        return "_Keine analysis/<song>.json vorhanden — Analyse-Lauf ausführen._"
    import json as _json
    data = _json.loads(candidates[0].read_text(encoding="utf-8"))

    lines: list[str] = []
    project = data.get("project") or display_name(project_dir)
    lines.append(f"## Analyse · {project}")
    lines.append("")

    bpm = data.get("bpm")
    key = data.get("key")
    duration = data.get("duration_s")
    lines.append("| Feld | Wert |")
    lines.append("|---|---|")
    if bpm is not None:
        lines.append(f"| BPM | {float(bpm):.1f} |")
    if key:
        lines.append(f"| Tonart | {key} |")
    if duration is not None:
        lines.append(f"| Dauer | {_mm_ss(float(duration))} ({float(duration):.1f}s) |")
    downbeats = data.get("downbeats") or []
    db_source = data.get("downbeat_source")
    if downbeats:
        src = f" ({db_source})" if db_source else ""
        lines.append(f"| Downbeats | {len(downbeats)}{src} |")
    elif db_source:
        lines.append(f"| Downbeat-Quelle | `{db_source}` |")
    stems = data.get("stems")
    if isinstance(stems, dict) and stems:
        present = [k for k in ("vocals", "drums", "bass", "other") if k in stems]
        if present:
            lines.append(f"| Stems | {', '.join(present)} |")
    elif isinstance(stems, dict) and stems.get("provider"):
        lines.append(f"| Stems | `{stems['provider']}` |")
    alignment = data.get("alignment") or []
    if alignment:
        lines.append(f"| Alignment-Zeilen | {len(alignment)} |")
    lines.append("")

    # Sections — bevorzugt top-level (mit echten Zeitstempeln + label),
    # sonst Fallback auf interpretation.section_labels (nur Labels).
    sections = data.get("sections") or []
    interpretation = data.get("interpretation") or {}
    section_labels = interpretation.get("section_labels") or []

    if sections and isinstance(sections, list) and sections and "start" in sections[0]:
        lines.append("### Sections")
        lines.append("")
        lines.append("| # | Label | Start | Dauer |")
        lines.append("|---|---|---|---|")
        for s in sections:
            idx = s.get("index", "")
            label = s.get("label") or "—"
            start = float(s.get("start") or 0.0)
            end = float(s.get("end") or start)
            dur = max(0.0, end - start)
            lines.append(f"| {idx} | {label} | {_mm_ss(start)} | {dur:.0f}s |")
        lines.append("")
    elif section_labels:
        lines.append("### Sections")
        lines.append("")
        lines.append("| # | Label | Confidence |")
        lines.append("|---|---|---|")
        for s in section_labels:
            idx = s.get("index", "")
            label = s.get("label") or "—"
            conf = s.get("confidence")
            conf_s = f"{float(conf):.2f}" if conf is not None else "—"
            lines.append(f"| {idx} | {label} | {conf_s} |")
        lines.append("")

    # Anomalien gruppiert nach kind
    anomalies = interpretation.get("anomalies") or []
    if anomalies:
        from collections import Counter
        kinds = Counter(a.get("kind", "unknown") for a in anomalies if isinstance(a, dict))
        lines.append(f"### Anomalien ({len(anomalies)})")
        lines.append("")
        for kind, count in kinds.most_common():
            # Hole bis zu zwei Beispiel-Notes für Kontext
            samples = [a.get("note", "") for a in anomalies if isinstance(a, dict) and a.get("kind") == kind][:2]
            sample_s = " · ".join(_shorten(n, 90) for n in samples if n)
            lines.append(f"- **{count}× {kind}** — {sample_s}" if sample_s else f"- **{count}× {kind}**")
        lines.append("")

    overall = interpretation.get("overall_character")
    if overall:
        lines.append("### Charakter")
        lines.append("")
        lines.append(_shorten(str(overall), 400) if len(str(overall)) > 400 else str(overall))
        lines.append("")

    structure_cands = data.get("structure_candidates") or []
    if structure_cands:
        lines.append(f"_Structure-Detector-Kandidaten: {len(structure_cands)}_")
        lines.append("")

    return "\n".join(lines)


def show_production_design(project_dir: Path) -> str:
    """production_design/production_design.yaml als kompakte Übersicht.

    Liest die Style-Refs (relative Pfade), den Visual-Medium-Tag,
    die ggf. präzisierten Notes und das optionale Color-Script.
    """
    pd_path = project_dir / "production_design" / "production_design.yaml"
    if not pd_path.exists():
        return "_Keine production_design.yaml vorhanden — Phase K2 noch nicht durch._"
    data = yaml.safe_load(pd_path.read_text(encoding="utf-8")) or {}
    lines: list[str] = []
    project = data.get("project") or display_name(project_dir)
    lines.append(f"## Production Design · {project}")
    lines.append("")
    lines.append("| Feld | Wert |")
    lines.append("|---|---|")
    if data.get("visual_medium"):
        lines.append(f"| Visual Medium | `{data['visual_medium']}` |")
    if data.get("visual_medium_notes"):
        lines.append(f"| Notes | {_shorten(str(data['visual_medium_notes']), 200)} |")
    if data.get("generator"):
        lines.append(f"| Generator | {data['generator']} |")
    lines.append("")

    refs = data.get("refs") or []
    if refs:
        lines.append("### Style-Refs")
        lines.append("")
        lines.append("| # | Pfad | Notiz |")
        lines.append("|---:|---|---|")
        for i, ref in enumerate(refs, 1):
            if isinstance(ref, dict):
                path = ref.get("path", "")
                note = ref.get("note", "")
            else:
                path = str(ref)
                note = ""
            lines.append(f"| {i} | `{path}` | {note} |")
        lines.append("")

    color_script = data.get("color_script") or {}
    if color_script:
        lines.append("### Color Script")
        lines.append("")
        lines.append("| Section | Stimmung |")
        lines.append("|---|---|")
        for section, mood in color_script.items():
            lines.append(f"| {section} | {mood} |")
        lines.append("")

    if data.get("notes"):
        lines.append("**Notes:**")
        lines.append("")
        lines.append(str(data["notes"]).strip())
    return "\n".join(lines)


def show_storyboard(project_dir: Path, version: str = "current") -> str:
    """Storyboard als Section-Tabelle + Step-Liste pro Section + Bedarfs-Aggregat."""
    if version == "current":
        sb = load_storyboard(project_dir, version="current")
    else:
        try:
            sb = load_storyboard(project_dir, version=int(version[1:]) if version.startswith("v") else version)
        except (ValueError, AttributeError):
            sb = load_storyboard(project_dir, version=version)
    if sb is None:
        return f"_Kein Storyboard `{version}` vorhanden — Phase K4 noch nicht durch._"
    lines: list[str] = []
    lines.append(f"## Storyboard · {sb.meta.project} · v{sb.meta.version} · {sb.meta.origin}")
    lines.append("")
    if sb.meta.summary_oneline:
        lines.append(f"> {sb.meta.summary_oneline}")
        lines.append("")
    lines.append(f"**{len(sb.sections)} Sektionen · {sum(len(s.steps) for s in sb.sections)} Steps**")
    lines.append("")

    # Sections-Tabelle
    lines.append("### Sektionen")
    lines.append("")
    lines.append("| ID | Label | Energy | Funktion | Steps | Zeit |")
    lines.append("|---|---|---|---|---:|---|")
    for s in sb.sections:
        zeit = ""
        if s.time_start or s.time_end:
            zeit = f"{_mm_ss(s.time_start)}-{_mm_ss(s.time_end)}"
        lines.append(f"| `{s.id}` | {s.label or '—'} | {s.energy or '—'} | {s.function or '—'} | {len(s.steps)} | {zeit} |")
    lines.append("")

    # Steps pro Section
    for sec in sb.sections:
        if not sec.steps:
            continue
        lines.append(f"### Steps · {sec.id}")
        lines.append("")
        lines.append("| Step | Funktion | Subject | Camera | Location-View |")
        lines.append("|---|---|---|---|---|")
        for st in sec.steps:
            subj = _shorten(st.subject, 60)
            cam = _shorten(st.camera, 50)
            view = st.location_view_request or "—"
            lines.append(f"| `{st.id}` | {st.function.value} | {subj} | {cam} | {view} |")
        lines.append("")

    # Bedarfs-Aggregat (Locations × Views)
    demand = sb.location_view_demand()
    if demand:
        lines.append("### Bible-Bedarf (Location-Views)")
        lines.append("")
        lines.append("| Location-Hint | benötigte Views |")
        lines.append("|---|---|")
        for loc in sorted(demand):
            views = ", ".join(sorted(demand[loc]))
            lines.append(f"| `{loc}` | {views} |")
        lines.append("")

    if sb.meta.notes:
        lines.append("**Notes:**")
        lines.append(sb.meta.notes.strip())
    return "\n".join(lines)


def show_renders(project_dir: Path, phase: str = "preview") -> str:
    """Renders-Manifest als Markdown — Pfade, Kosten, Status.

    Liefert den `## Renders ·`-Marker, den der display_before_ask-Hook
    bei Video-Approval-Gates erwartet. Bilder/Videos selbst gehen via
    Read inline.
    """
    import yaml
    lines: list[str] = []
    project_name = display_name(project_dir)
    lines.append(f"## Renders · {project_name} · {phase}")
    lines.append("")
    manifest_path = project_dir / "renders" / f"manifest-{phase}.json"
    if not manifest_path.exists():
        # Probe das alternative YAML-Format
        manifest_path = project_dir / "renders" / f"manifest-{phase}.yaml"
    if not manifest_path.exists():
        lines.append(f"_Kein Manifest unter `renders/manifest-{phase}.*` —_ "
                     f"Render-Phase R{'1' if phase == 'preview' else '2'} "
                     "noch nicht gelaufen.")
        return "\n".join(lines)
    try:
        if manifest_path.suffix == ".json":
            import json as _json
            data = _json.loads(manifest_path.read_text(encoding="utf-8"))
        else:
            data = yaml.safe_load(manifest_path.read_text(encoding="utf-8")) or {}
    except (ValueError, OSError) as exc:
        lines.append(f"_Manifest defekt: {type(exc).__name__}_")
        return "\n".join(lines)
    results = data.get("results") if isinstance(data, dict) else None
    if not isinstance(results, list) or not results:
        lines.append("_Manifest leer._")
        return "\n".join(lines)
    lines.append("| Shot | Status | Modell | EUR | Pfad |")
    lines.append("|---|---|---|---|---|")
    total_eur = 0.0
    for r in results:
        if not isinstance(r, dict):
            continue
        shot_id = r.get("shot_id", "?")
        status = r.get("status", "?")
        model = r.get("runway_model", "")
        eur = r.get("eur_spent", 0.0)
        out_path = r.get("out_path") or "—"
        try:
            total_eur += float(eur or 0.0)
        except (TypeError, ValueError):
            pass
        lines.append(f"| `{shot_id}` | {status} | {model} | "
                     f"{float(eur or 0):.3f} | `{out_path}` |")
    lines.append("")
    lines.append(f"**Gesamt:** {total_eur:.2f} EUR · {len(results)} Shots")
    return "\n".join(lines)
