"""Kosten-Modell + Pre-Flight-Check."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Literal

import yaml

from nexgen_engine.core.paths import repo_root
from nexgen_engine.shotlist.schema import Mode, Shot, Shotlist

Phase = Literal["preview", "final"]


@dataclass(frozen=True)
class ModelPricing:
    eur_per_second: float
    """Fallback-Preis (Worst-Case-Resolution), wenn das Modell
    `eur_per_second_by_resolution` nicht setzt. Wird auch genutzt, wenn
    die im Call uebergebene Resolution unbekannt ist."""
    max_duration_s: float
    default_ratio: str
    min_duration_s: float = 0.0
    """Provider-Minimum pro Render-Call. Shots unter dieser Schwelle werden
    vom Provider auf min_duration_s aufgerundet (zusaetzliche Sekunden
    werden mitberechnet). Default 0 = kein Minimum dokumentiert."""
    eur_per_second_by_resolution: dict[str, float] | None = None
    """Resolution-spezifische Preise (v0.11.5). Wenn gesetzt, ueberschreibt
    es eur_per_second fuer bekannte Resolutionen. Beispiel: fal Seedance
    Pro hat 720p $0.30/s, 1080p $0.68/s — Faktor >2 zwischen den
    Aufloesungen. Vor v0.11.5 war das nicht differenziert → Estimate
    fuer Final-Renders war systematisch zu niedrig (Bug 22)."""

    def eur_per_second_for(self, resolution: str | None) -> float:
        """Resolution-spezifischer Preis mit Fallback.

        - Bekannte Resolution → exakter Preis.
        - Unbekannte Resolution oder None → eur_per_second
          (Worst-Case-Fallback).
        """
        if resolution and self.eur_per_second_by_resolution:
            price = self.eur_per_second_by_resolution.get(resolution)
            if price is not None:
                return price
        return self.eur_per_second


@dataclass(frozen=True)
class CostGuard:
    """Cost-Guard-Schwellen (v0.11.5)."""
    confirm_threshold_eur: float = 10.0
    project_wide_budget: bool = True


@dataclass
class CostsConfig:
    pricing: dict[str, ModelPricing]
    model_map: dict[str, str]
    defaults: dict[str, str]
    overlap_pre_s: float
    overlap_post_s: float
    polling_interval_s: int
    polling_timeout_s: int
    cost_guard: CostGuard = CostGuard()

    def runway_model_for(self, shot: Shot, phase: Phase) -> str:
        """Aufloesung des Render-Modells pro Shot — provider-aware.

        Bug 24 (v0.11.6): vorher zog `model_suggestion → model_map`
        ueber den Provider-Branch hinweg → ein fal-Shot mit
        `model_suggestion=SEEDANCE_2_0` bekam `"seedance2"` (Runway-
        Legacy-Preis 0.10 EUR/s) zugewiesen, obwohl der Dispatcher in
        Wirklichkeit ueber den fal-Endpoint rendert (0.25–0.68 EUR/s).
        Estimate war um Faktor 2.5–6 zu niedrig.

        Neue Logik:
        - `scene_video_provider == FAL`: nimm `defaults[phase]`, wenn
          es ein fal-Modell ist; sonst Fallback auf
          `fal:bytedance/seedance-2.0/fast`. `model_suggestion` wird
          IGNORIERT, weil model_map nur Runway-Modelle kennt.
        - `scene_video_provider == RUNWAY` (Legacy): wie vorher —
          `model_suggestion → model_map`, sonst defaults[phase].
        """
        # Lokaler Import um Schema-Zirkularitaet zu vermeiden.
        from nexgen_engine.shotlist.schema import SceneVideoProvider

        if shot.scene_video_provider == SceneVideoProvider.FAL:
            default = self.defaults.get(phase, "")
            if default.startswith("fal:"):
                return default
            # defaults zeigt auf Runway-Modell (alte Config) →
            # sicheres fal-Fallback.
            return "fal:bytedance/seedance-2.0/fast"

        # Runway-Pfad (Legacy)
        suggestion = shot.model_suggestion.value if shot.model_suggestion else None
        if suggestion and suggestion in self.model_map:
            return self.model_map[suggestion]
        # Bei Runway-Provider darf defaults nicht auf ein fal-Modell
        # zeigen — wenn doch, fallback auf einen bekannten Runway-Slug.
        runway_default = self.defaults.get(phase, "")
        if runway_default.startswith("fal:"):
            return "seedance2"  # bewaehrter Runway-Legacy-Default
        return runway_default

    def price(self, runway_model: str) -> ModelPricing:
        if runway_model not in self.pricing:
            raise KeyError(
                f"Kein Pricing für Runway-Modell {runway_model!r} in costs.yaml"
            )
        return self.pricing[runway_model]


def load_costs(path: Path | None = None) -> CostsConfig:
    path = path or (repo_root() / "costs.yaml")
    data = yaml.safe_load(path.read_text(encoding="utf-8"))
    pricing = {
        name: ModelPricing(
            eur_per_second=float(p["eur_per_second"]),
            max_duration_s=float(p["max_duration_s"]),
            default_ratio=str(p["default_ratio"]),
            min_duration_s=float(p.get("min_duration_s", 0)),
            eur_per_second_by_resolution=(
                {k: float(v) for k, v in p["eur_per_second_by_resolution"].items()}
                if "eur_per_second_by_resolution" in p else None
            ),
        )
        for name, p in data["pricing"].items()
    }
    cost_guard_data = data.get("cost_guard", {})
    cost_guard = CostGuard(
        confirm_threshold_eur=float(
            cost_guard_data.get("confirm_threshold_eur", 10.0)
        ),
        project_wide_budget=bool(
            cost_guard_data.get("project_wide_budget", True)
        ),
    )
    return CostsConfig(
        pricing=pricing,
        model_map={k: str(v) for k, v in data["model_map"].items()},
        defaults={k: str(v) for k, v in data["defaults"].items()},
        overlap_pre_s=float(data["overlap"]["pre_s"]),
        overlap_post_s=float(data["overlap"]["post_s"]),
        polling_interval_s=int(data["polling"]["interval_s"]),
        polling_timeout_s=int(data["polling"]["timeout_s"]),
        cost_guard=cost_guard,
    )


@dataclass
class ShotEstimate:
    shot_id: str
    runway_model: str
    duration_s: float  # effektive Render-Dauer (Bug 28: Kern, OHNE Overlap)
    eur: float
    truncated: bool  # True, wenn wegen Model-Limit gekürzt wurde
    notes: str = ""


@dataclass
class ProjectEstimate:
    phase: Phase
    mode: Mode
    shot_estimates: list[ShotEstimate]
    total_eur: float
    budget_eur: float
    over_budget: bool


def _seedance_render_duration(shot: Shot, costs: CostsConfig, mode: Mode) -> float:
    """Effektive Render-Dauer, die an Seedance/Runway geschickt wird.

    Bug 28 (v0.11.11): vorher addierten wir hier `overlap_pre_s +
    overlap_post_s` (Default 3s) aufs Shot-Duration drauf — die
    gepaddete Dauer ging 1:1 als Render-Dauer an Seedance. Folgen:
    (1) Seedance kennt das Handle-Konzept nicht und streckt die Aktion
        ueber die gepaddete Dauer → Slow-Motion (Befund claude_mouse
        s016: 4.83s Kern + 3s Handles → 7.83s gerendert, Aktion auf
        7.83s gedehnt).
    (2) Pacing-Heuristik (Feature 26) rechnete mit der Kern-Dauer,
        Seedance bekam aber die gepaddete — inkonsistent.

    Fix: Seedance bekommt die Kern-Dauer. Pre-/Post-Handles werden
    deterministisch in Post per `mv-render handles` (ffmpeg tpad)
    angehaengt — saubere Freeze-Frame-Handles, kein Provider-Call,
    kein Slow-Motion-Risiko.

    `costs.overlap_pre_s` / `_post_s` bleiben im Schema, werden aber
    fuer die Seedance-Dauer nicht mehr addiert — sie dokumentieren
    noch das Default-Padding fuer `mv-render handles`.
    """
    return shot.duration_s


def _stitched_segments(total_s: float, model_limit_s: float) -> int:
    import math

    return max(1, math.ceil(total_s / model_limit_s))


def _resolution_for_phase(
    model_id: str,
    phase: Phase,
    *,
    final_resolution: str = "1080p",
) -> str | None:
    """Resolution-Wahl pro Modell + Phase (v0.11.7).

    - Final-Phase: nimm `final_resolution` aus dem Brief. Wenn das
      Modell die Resolution nicht unterstuetzt (z.B. Fast hat kein
      1080p), Fallback auf das Modell-Max.
    - Preview-Phase: kleinste verfuegbare Resolution (720p — 480p ist
      auf fal nicht gepreist, siehe costs.yaml Header).

    Runway-Modelle haben kein semantisches Resolution-Konzept (Ratios
    enthalten die Aufloesung) → None → eur_per_second-Fallback.
    """
    if not model_id.startswith("fal:"):
        return None
    is_fast = "/fast" in model_id
    if phase == "final":
        # Brief-Default 1080p, aber Fast hat kein 1080p
        if is_fast and final_resolution == "1080p":
            return "720p"  # Fast-Max
        return final_resolution
    # Preview: kleinste verfuegbare = 720p (480p nicht angeboten,
    # siehe costs.yaml Header).
    return "720p"


def estimate(
    shotlist: Shotlist,
    costs: CostsConfig,
    phase: Phase,
    *,
    final_resolution: str = "1080p",
) -> ProjectEstimate:
    """Pre-Flight-Estimate.

    `final_resolution` wird aus dem Brief (`brief.final_resolution`)
    durchgereicht — der Dispatcher uebergibt es. Pro 720p ($0.30/s)
    vs Pro 1080p ($0.68/s) ist Faktor 2.3x, die Schaetzung muss das
    abbilden.
    """
    estimates: list[ShotEstimate] = []
    for shot in shotlist.shots:
        runway_model = costs.runway_model_for(shot, phase)
        pricing = costs.price(runway_model)
        resolution = _resolution_for_phase(
            runway_model, phase, final_resolution=final_resolution,
        )
        eur_per_second = pricing.eur_per_second_for(resolution)

        raw_duration = _seedance_render_duration(shot, costs, shotlist.mode)
        truncated = False
        padded = False
        if shotlist.mode in {Mode.BEAT, Mode.PHRASE}:
            if raw_duration > pricing.max_duration_s:
                billable_s = pricing.max_duration_s
                truncated = True
            elif raw_duration < pricing.min_duration_s:
                billable_s = pricing.min_duration_s
                padded = True
            else:
                billable_s = raw_duration
            eur = billable_s * eur_per_second
            notes_parts: list[str] = []
            if truncated:
                notes_parts.append(f"truncated to {pricing.max_duration_s}s")
            if padded:
                notes_parts.append(
                    f"padded to provider-min {pricing.min_duration_s}s "
                    f"(actual shot {raw_duration:.1f}s)"
                )
            if resolution:
                notes_parts.append(f"@{resolution}")
            note = "; ".join(notes_parts)
        else:
            segments = _stitched_segments(raw_duration, pricing.max_duration_s)
            billable_s = raw_duration
            eur = billable_s * eur_per_second
            note = f"stitch={segments}" if segments > 1 else ""
            if resolution:
                note = f"{note}; @{resolution}" if note else f"@{resolution}"

        estimates.append(
            ShotEstimate(
                shot_id=shot.id,
                runway_model=runway_model,
                duration_s=round(billable_s, 3),
                eur=round(eur, 3),
                truncated=truncated,
                notes=note,
            )
        )

    total = round(sum(e.eur for e in estimates), 2)
    return ProjectEstimate(
        phase=phase,
        mode=shotlist.mode,
        shot_estimates=estimates,
        total_eur=total,
        budget_eur=shotlist.budget_eur,
        over_budget=total > shotlist.budget_eur,
    )


# ----- Project-weiter Spend-Tracking (Bug 22 / v0.11.5) -------------

def already_spent_in_project(
    project_dir: Path, *, exclude_phase: Phase | None = None
) -> float:
    """Summiert bereits ausgegebenes EUR aus allen vorhandenen
    `renders/manifest-<phase>.json`.

    Args:
        exclude_phase: optionale Phase ueberspringen (z.B. den
            aktuellen Run, der gerade neu kalkuliert wird).

    Returns:
        Summe `eur_spent` ueber alle Manifest-Shots, gerundet auf
        2 Nachkommastellen.
    """
    import json

    total = 0.0
    renders_dir = project_dir / "renders"
    if not renders_dir.is_dir():
        return 0.0
    for manifest_path in renders_dir.glob("manifest-*.json"):
        # Phase aus Dateiname: manifest-preview.json → preview
        stem_parts = manifest_path.stem.split("-", 1)
        if len(stem_parts) == 2 and exclude_phase and stem_parts[1] == exclude_phase:
            continue
        try:
            data = json.loads(manifest_path.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            continue
        for shot in data.get("shots", []):
            try:
                total += float(shot.get("eur_spent") or 0.0)
            except (TypeError, ValueError):
                continue
    return round(total, 2)


@dataclass
class CostGuardVerdict:
    """Pre-Flight-Befund — der Caller entscheidet, wie er reagiert."""
    new_run_eur: float
    already_spent_eur: float
    project_total_eur: float
    """new_run + already_spent (project-wide)."""
    budget_eur: float
    over_budget: bool
    """project_total > budget."""
    needs_confirmation: bool
    """new_run >= confirm_threshold_eur."""
    confirm_threshold_eur: float

    def message(self) -> str:
        """Pretty-Print fuer CLI-Ausgabe.

        Wechselkurs konsistent mit costs.yaml-Header (v0.11.9, Codex-
        Review): die fal-Preise sind dort 1:1 EUR=USD notiert
        ("konservativ leicht hoeher als der echte USD-Wert"). Anzeige
        damit konsistent: USD ≈ EUR (keine kuenstliche 0.95-Aufblaehung
        mehr).
        """
        new_usd = self.new_run_eur
        proj_usd = self.project_total_eur
        lines = [
            f"Geschaetzte Kosten dieses Runs: {self.new_run_eur:.2f} EUR "
            f"(~${new_usd:.2f})",
        ]
        if self.already_spent_eur > 0:
            lines.append(
                f"Bereits ausgegeben in vorherigen Renders: "
                f"{self.already_spent_eur:.2f} EUR"
            )
            lines.append(
                f"Projekt-Total nach diesem Run: "
                f"{self.project_total_eur:.2f} EUR (~${proj_usd:.2f}), "
                f"Budget: {self.budget_eur:.2f} EUR"
            )
        return "\n".join(lines)


def cost_guard_check(
    project_dir: Path,
    *,
    estimate_eur: float,
    phase: Phase,
    budget_eur: float,
    guard: CostGuard,
) -> CostGuardVerdict:
    """Pre-Flight Cost-Guard.

    - Liest project-weite Bereits-Ausgaben aus den Manifesten
      (exclude_phase=phase, da der aktuelle Run noch nicht im Manifest
      ist — sonst wuerde der vorherige Lauf gleicher Phase mitzaehlen).
    - Vergleicht (new + spent) gegen budget.
    - Setzt needs_confirmation, wenn new_run >= confirm_threshold.

    Hard-Stop trifft der Caller (mv-render preview) — wir liefern
    nur die Daten + Diagnose.

    NICHT in v0.11.7: Variance-Detection (Estimate-Rate vs historisch
    beobachtete Real-Rate). Der Mechanismus war in v0.11.5/.6 toter
    Code, weil `duration_s` nicht im Manifest persistiert ist
    (`RenderResult`-Schema fehlt das Feld). Wird zurueckgebaut, bis
    das Schema erweitert ist UND eine echte Use-Case fuer Variance-
    Warnung formuliert ist.
    """
    already = (
        already_spent_in_project(project_dir, exclude_phase=phase)
        if guard.project_wide_budget else 0.0
    )
    total = round(estimate_eur + already, 2)
    return CostGuardVerdict(
        new_run_eur=estimate_eur,
        already_spent_eur=already,
        project_total_eur=total,
        budget_eur=budget_eur,
        over_budget=total > budget_eur,
        needs_confirmation=estimate_eur >= guard.confirm_threshold_eur,
        confirm_threshold_eur=guard.confirm_threshold_eur,
    )
