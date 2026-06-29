"""Analysis-Pipeline v0.4.

Orchestriert die einzelnen Analyzer. Jede Stage ist optional — wenn die
dafür nötige Library nicht installiert ist, wird sie übersprungen, und
das Ergebnis in `pipeline_stages` markiert. Downstream-Agents verlassen
sich auf dieses Feld, um zu wissen, was verfügbar ist.

Stages in Reihenfolge:
 1. load_audio       — librosa (immer)
 2. rhythm           — beats + downbeats + global BPM
 3. stems            — demucs (optional)
 4. alignment        — whisperx auf vocals (optional, braucht Lyrics + stems)
 5. structure        — essentia + librosa, konsolidiert
 6. features         — energy + tempo curve, key, (optional) chord
 7. persist          — analysis/<song>.json
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

import librosa

from nexgen_pack_musicvideo.analysis import alignment as alignment_mod
from nexgen_pack_musicvideo.analysis import downbeats as downbeats_mod
from nexgen_pack_musicvideo.analysis import features as features_mod
from nexgen_pack_musicvideo.analysis import stems as stems_mod
from nexgen_pack_musicvideo.analysis import stems_lalal as lalal_mod
from nexgen_pack_musicvideo.analysis.audio import LoadedAudio, load
from nexgen_pack_musicvideo.analysis.structure import to_candidate
from nexgen_pack_musicvideo.analysis.structure.consolidator import consolidate
from nexgen_pack_musicvideo.analysis.structure.essentia_detector import EssentiaDetector
from nexgen_pack_musicvideo.analysis.structure.essentia_detector import available as essentia_available
from nexgen_pack_musicvideo.analysis.structure.librosa_detector import LibrosaDetector
from nexgen_pack_musicvideo.analysis_schema import (
    Analysis,
    Section,
    Stems,
    StructureCandidate,
)

AUDIO_EXTS = {".wav", ".mp3", ".flac", ".m4a", ".aiff"}


@dataclass
class PipelineOptions:
    stems_provider: str = "demucs"   # "none" | "demucs" | "lalal"
    enable_alignment: bool = True
    enable_chord: bool = False
    whisper_model: str = "large-v3"


@dataclass
class PipelineProgress:
    stages_done: list[str] = field(default_factory=list)
    stages_skipped: list[tuple[str, str]] = field(default_factory=list)  # (stage, reason)


def run(
    project: str,
    project_dir: Path,
    audio_path: Path,
    lyrics_text: str | None,
    opts: PipelineOptions,
    on_progress: callable | None = None,  # type: ignore[type-arg]
) -> tuple[Analysis, PipelineProgress]:
    """Führe komplette Pipeline aus, gib Analysis + Progress zurück."""
    progress = PipelineProgress()

    def note(stage: str, text: str = "") -> None:
        progress.stages_done.append(stage)
        if on_progress:
            on_progress(stage, text)

    def skip(stage: str, reason: str) -> None:
        progress.stages_skipped.append((stage, reason))
        if on_progress:
            on_progress(stage, f"SKIPPED: {reason}")

    # 1. Load audio
    loaded: LoadedAudio = load(audio_path)
    note("load_audio", f"{loaded.duration_s:.1f}s @ {loaded.sr} Hz")

    # 2. Rhythm: beats + downbeats
    import numpy as np
    _, beat_frames = librosa.beat.beat_track(y=loaded.y, sr=loaded.sr, units="frames")
    beats = librosa.frames_to_time(beat_frames, sr=loaded.sr).tolist()
    db_times, db_source = downbeats_mod.detect(loaded, audio_path, beats)
    # BPM: robuster aus Downbeats, fallback auf librosa
    bpm = features_mod.global_bpm_from_downbeats(db_times)
    if bpm <= 0 and len(beats) >= 2:
        bpm = float(60.0 / np.median(np.diff(beats)))
    note("rhythm", f"bpm={bpm:.2f}, {len(beats)} beats, {len(db_times)} downbeats ({db_source})")

    # 3. Stems (optional, provider-abhängig)
    stems_obj: Stems | None = None
    vocals_wav: Path | None = None
    stems_dir = project_dir / "analysis" / "stems"
    if opts.stems_provider == "demucs":
        if stems_mod.available():
            try:
                stems_obj = stems_mod.separate(audio_path, stems_dir)
                if stems_obj.vocals:
                    vocals_wav = Path(stems_obj.vocals)
                note("stems/demucs", f"written to {stems_dir.relative_to(project_dir)}")
            except Exception as e:
                skip("stems/demucs", f"error: {e}")
        else:
            skip("stems/demucs", "demucs not installed (pip install -e .[audio])")
    elif opts.stems_provider == "lalal":
        if lalal_mod.available():
            try:
                stems_obj = lalal_mod.separate(audio_path, stems_dir, stem="vocals", splitter="phoenix")
                if stems_obj.vocals:
                    vocals_wav = Path(stems_obj.vocals)
                note("stems/lalal", f"written to {stems_dir.relative_to(project_dir)}")
            except Exception as e:
                skip("stems/lalal", f"error: {e}")
        else:
            skip("stems/lalal", "requests not installed")
    else:
        skip("stems", "provider=none")

    # 4. Alignment (optional, braucht vocals + lyrics)
    alignment_result = []
    if opts.enable_alignment:
        if not alignment_mod.available():
            skip("alignment", "whisperx not installed (pip install -e .[audio])")
        elif not lyrics_text:
            skip("alignment", "no lyrics provided (instrumental track)")
        elif not vocals_wav:
            skip("alignment", "no vocals stem (demucs skipped or failed)")
        else:
            try:
                alignment_result = alignment_mod.align(
                    vocals_wav=vocals_wav,
                    lyrics_text=lyrics_text,
                    whisper_model_name=opts.whisper_model,
                )
                note("alignment", f"{len(alignment_result)} lines aligned")
            except Exception as e:
                skip("alignment", f"error: {e}")

    # 5. Structure: Essentia + Librosa → Candidates → Consolidate
    candidates: list[StructureCandidate] = []
    candidate_sections: list[list[Section]] = []

    if essentia_available():
        try:
            ed = EssentiaDetector()
            secs = ed.detect(audio_path, loaded.duration_s)
            candidates.append(to_candidate(ed, secs))
            candidate_sections.append(secs)
            note("structure/essentia", f"{len(secs)} sections")
        except Exception as e:
            skip("structure/essentia", f"error: {e}")
    else:
        skip("structure/essentia", "essentia not installed")

    ld = LibrosaDetector()
    try:
        secs = ld.detect(audio_path, loaded.duration_s)
        candidates.append(to_candidate(ld, secs))
        candidate_sections.append(secs)
        note("structure/librosa", f"{len(secs)} sections")
    except Exception as e:
        skip("structure/librosa", f"error: {e}")

    consolidation = consolidate(
        candidates=candidate_sections,
        alignment=alignment_result,
        downbeats=db_times,
        duration_s=loaded.duration_s,
    )
    note("structure/consolidate", f"{len(consolidation.sections)} consolidated sections, {len(consolidation.anomalies)} anomalies")

    # 6. Features
    energy = features_mod.energy_curve(audio_path)
    note("features/energy", f"{len(energy)} points")

    tempo = features_mod.tempo_curve(audio_path)
    note("features/tempo", f"{len(tempo)} points")

    key = features_mod.key_essentia(audio_path)
    if key:
        note("features/key", key)
    else:
        skip("features/key", "essentia not available")

    chords = []
    if opts.enable_chord:
        chords = features_mod.chord_progression(audio_path)
        if chords:
            note("features/chord", f"{len(chords)} chord segments")
        else:
            skip("features/chord", "madmom chord processor unavailable or failed")

    # Merge consolidation-anomalies in Interpretation.anomalies (für analysis-agent)
    pre_anomalies = [
        {"kind": a["kind"], "time": a.get("time"), "note": a.get("detail", "")}
        for a in consolidation.anomalies
    ]

    # 7. Persist
    analysis = Analysis(
        schema=Analysis.model_fields["schema_"].default,
        project=project,
        song_path=str(audio_path.relative_to(project_dir)),
        sample_rate=loaded.sr,
        duration_s=round(loaded.duration_s, 3),
        bpm=round(bpm, 3),
        beats=[round(t, 3) for t in beats],
        downbeats=[round(t, 3) for t in db_times],
        downbeat_source=db_source,
        sections=consolidation.sections,
        stems=stems_obj,
        alignment=alignment_result,
        structure_candidates=candidates,
        energy_curve=energy,
        tempo_curve=tempo,
        key=key,
        chord_progression=chords,
        pipeline_stages=progress.stages_done,
    )
    if pre_anomalies:
        from nexgen_pack_musicvideo.analysis_schema import Interpretation

        analysis.interpretation = Interpretation(anomalies=pre_anomalies)

    return analysis, progress


def _find_audio_file(project_dir: Path) -> Path:
    audio_dir = project_dir / "audio"
    candidates = sorted(
        p
        for p in (audio_dir.iterdir() if audio_dir.is_dir() else [])
        if p.is_file() and p.suffix.lower() in AUDIO_EXTS
    )
    if not candidates:
        raise FileNotFoundError(f"Keine Audio-Datei in {audio_dir}")
    return candidates[0]


def _read_lyrics(project_dir: Path) -> str | None:
    p = project_dir / "lyrics" / "lyrics.txt"
    if p.exists() and p.stat().st_size > 0:
        return p.read_text(encoding="utf-8")
    return None


def run_phase(project_dir: Path, opts: PipelineOptions | None = None) -> Analysis:
    """Single-argument entrypoint for the engine's `analysis` phase.

    Resolves audio + lyrics from the project layout, runs the full pipeline,
    persists analysis/<song>.json and returns the Analysis.
    """
    import json

    from nexgen_engine.core.paths import display_name

    project_dir = Path(project_dir)
    audio_path = _find_audio_file(project_dir)
    lyrics_text = _read_lyrics(project_dir)

    analysis, _progress = run(
        project=display_name(project_dir),
        project_dir=project_dir,
        audio_path=audio_path,
        lyrics_text=lyrics_text,
        opts=opts or PipelineOptions(),
    )

    out_dir = project_dir / "analysis"
    out_dir.mkdir(exist_ok=True)
    out_path = out_dir / f"{audio_path.stem}.json"
    payload = analysis.model_dump(by_alias=True, exclude_none=True)
    out_path.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return analysis
