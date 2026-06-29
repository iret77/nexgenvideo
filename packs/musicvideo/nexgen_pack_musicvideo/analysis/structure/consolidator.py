"""Consolidator: mehrere Structure-Candidate-Listen + optional Alignment
→ eine finale `sections`-Liste mit priorisiertem Vertrauen.

Regel (in Abstimmung mit dem User):
1. Wenn Forced-Alignment mit [Section]-Markern vorliegt: Marker sind
   die Wahrheit für Section-Starts. Andere Detectoren als Zusatzhinweis.
2. Sonst: für jede Grenzen-Gruppe, die aus den Detectoren konvergiert
   (Cluster innerhalb 2 s Toleranz), Mittelwert bilden.
3. Bei > 2 s Divergenz zwischen Detectoren: `anomaly`-Flag,
   konservativere (frühere) Grenze nehmen — Overlap-Render deckt die Lücke.
4. Alle Grenzen am Ende auf den nächsten Downbeat snappen (±0.5 s).
"""

from __future__ import annotations

from dataclasses import dataclass

from nexgen_pack_musicvideo.analysis_schema import AlignmentLine, Section


TOLERANCE_S = 2.0
DOWNBEAT_SNAP_S = 0.5


@dataclass
class ConsolidationResult:
    sections: list[Section]
    anomalies: list[dict]  # {kind, time, detail}


def _cluster_boundaries(boundaries: list[tuple[float, str]], tolerance: float) -> list[tuple[float, list[str]]]:
    """Gruppe Boundaries aus verschiedenen Quellen, die innerhalb tolerance zueinander liegen.
    Rückgabe: Liste von (repräsentative_zeit, beteiligte_quellen).
    """
    if not boundaries:
        return []
    boundaries = sorted(boundaries, key=lambda x: x[0])
    groups: list[list[tuple[float, str]]] = [[boundaries[0]]]
    for t, src in boundaries[1:]:
        if t - groups[-1][-1][0] <= tolerance:
            groups[-1].append((t, src))
        else:
            groups.append([(t, src)])
    out = []
    for g in groups:
        mean = sum(t for t, _ in g) / len(g)
        out.append((mean, [src for _, src in g]))
    return out


def _snap(t: float, downbeats: list[float]) -> float:
    if not downbeats:
        return t
    closest = min(downbeats, key=lambda d: abs(d - t))
    return closest if abs(closest - t) <= DOWNBEAT_SNAP_S else t


def consolidate(
    candidates: list[list[Section]],
    alignment: list[AlignmentLine] | None,
    downbeats: list[float],
    duration_s: float,
) -> ConsolidationResult:
    anomalies: list[dict] = []

    # Pfad A: Alignment mit [Section]-Markern
    if alignment:
        marker_lines = [ln for ln in alignment if ln.section_marker]
        if marker_lines:
            sections: list[Section] = []
            sorted_markers = sorted(marker_lines, key=lambda ln: ln.start)
            for i, ln in enumerate(sorted_markers):
                end = sorted_markers[i + 1].start if i + 1 < len(sorted_markers) else duration_s
                sections.append(
                    Section(
                        index=i,
                        start=round(_snap(ln.start, downbeats), 3),
                        end=round(_snap(end, downbeats), 3),
                        cluster=i,
                        label=ln.section_marker,
                        source="alignment",
                        confidence=0.9,
                    )
                )
            # Sicherstellen: erste Section beginnt bei 0
            if sections and sections[0].start > 0.5:
                sections.insert(
                    0,
                    Section(
                        index=0,
                        start=0.0,
                        end=sections[0].start,
                        cluster=-1,
                        label="intro",
                        source="alignment",
                        confidence=0.8,
                    ),
                )
                for i, s in enumerate(sections):
                    sections[i] = Section(**{**s.model_dump(), "index": i})
            return ConsolidationResult(sections=sections, anomalies=anomalies)

    # Pfad B: Mehrheits-/Mittelwert-Konsolidierung aus Detectoren
    boundaries: list[tuple[float, str]] = []
    for cand in candidates:
        for sec in cand:
            src = sec.source or "unknown"
            boundaries.append((float(sec.start), src))
        if cand:
            # letzten End-Marker aufnehmen
            boundaries.append((float(cand[-1].end), cand[-1].source or "unknown"))

    clusters = _cluster_boundaries(boundaries, TOLERANCE_S)
    # Dedupe auf sinnvolle Grenzen
    times: list[float] = []
    for t, srcs in clusters:
        snapped = _snap(t, downbeats)
        if not times or snapped - times[-1] > 2.0:
            times.append(round(snapped, 3))
        # Single-Source-Boundary ohne Konvergenz: info
        if len(set(srcs)) == 1:
            anomalies.append(
                {"kind": "single_source_boundary", "time": round(snapped, 3), "detail": srcs[0]}
            )

    # Divergenz-Flag: wenn innerhalb eines Clusters die Spanne > tolerance
    for t, srcs in clusters:
        cluster_times = [b[0] for b in boundaries if abs(b[0] - t) <= TOLERANCE_S]
        if max(cluster_times) - min(cluster_times) > TOLERANCE_S - 0.01:
            anomalies.append(
                {
                    "kind": "boundary_divergence",
                    "time": round(t, 3),
                    "detail": f"spread={max(cluster_times) - min(cluster_times):.2f}s, sources={srcs}",
                }
            )

    if not times or times[0] > 0.5:
        times = [0.0] + times
    if times[-1] < duration_s - 0.5:
        times.append(duration_s)

    sections = [
        Section(
            index=i,
            start=a,
            end=b,
            cluster=i,
            source="consolidated",
            confidence=0.6,
        )
        for i, (a, b) in enumerate(zip(times, times[1:], strict=False))
    ]
    return ConsolidationResult(sections=sections, anomalies=anomalies)
