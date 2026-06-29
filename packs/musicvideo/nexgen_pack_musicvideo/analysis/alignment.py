"""Forced Alignment: bereitgestellte Lyrics gegen Vocals-Stem matchen.

Nutzt WhisperX (Whisper-Transkription + Wav2Vec2 forced alignment) auf dem
demucs/LALAL-Vocals-Stem. Bereitgestellte Lyrics mit `[Section]`-Markern
und `(Regie-Anweisungen)` werden aus der Lyric-Sequence herausgefiltert,
die verbleibenden Zeilen werden via Sequence-Alignment zwischen User- und
Whisper-Tokens robust auf Zeitmarken gemapped.
"""

from __future__ import annotations

import difflib
import re
from dataclasses import dataclass
from pathlib import Path

from nexgen_pack_musicvideo.analysis_schema import AlignmentLine

SECTION_MARKER_RE = re.compile(r"^\s*\[([^\]]+)\]\s*$")
STAGE_DIRECTION_RE = re.compile(r"^\s*\(.*?\)\s*$")


def available() -> bool:
    try:
        import whisperx  # noqa: F401
        return True
    except Exception:
        return False


def _pick_device() -> str:
    import torch

    if torch.backends.mps.is_available() and torch.backends.mps.is_built():
        return "mps"
    if torch.cuda.is_available():
        return "cuda"
    return "cpu"


@dataclass
class ParsedLyrics:
    """Gereinigte, zeilenweise Lyrics mit optionalem Section-Marker pro Zeile."""

    lines: list[tuple[str, str | None]]  # (text, section_marker)


def parse_lyrics(lyrics_text: str) -> ParsedLyrics:
    """Teile Lyrics in Zeilen, extrahiere `[Section]`-Marker als Labels.
    Regie-Anweisungen in `(...)` werden ignoriert (nicht als Lyrics gezählt).

    Unterstützt: `[Verse 1]`, `[Pre-Chorus]`, `[Chorus - Final]` → `chorus-final`.
    Wiederkehrende identische Marker werden automatisch nummeriert
    (`chorus` → `chorus1`, dann `chorus2`), wenn sie nicht schon explizit
    nummeriert oder qualifiziert sind (z.B. `chorus-final` bleibt).
    Whitespace-Trailing (Markdown-Hard-Breaks `  `) wird gestrippt.
    """
    lines: list[tuple[str, str | None]] = []
    pending_marker: str | None = None
    marker_counts: dict[str, int] = {}
    last_assigned: dict[str, str] = {}  # roh_marker → finaler_marker (stabil über Zeilen)

    for raw in lyrics_text.splitlines():
        line = raw.strip()
        if not line:
            continue
        m = SECTION_MARKER_RE.match(raw)
        if m:
            raw_marker = _normalize_marker(m.group(1))
            # Wenn der Marker keine eigene Zahl/Qualifier trägt und er wiederkommt,
            # hänge eine Laufnummer an.
            has_digit = bool(re.search(r"\d", raw_marker))
            has_qualifier = "-" in raw_marker  # z.B. "chorus-final"
            if has_digit or has_qualifier:
                pending_marker = raw_marker
            else:
                count = marker_counts.get(raw_marker, 0)
                # Erst nummerieren ab dem zweiten Auftreten (chorus, chorus2, chorus3…)
                marker_counts[raw_marker] = count + 1
                pending_marker = raw_marker if count == 0 else f"{raw_marker}{count + 1}"
            last_assigned[raw_marker] = pending_marker
            continue
        if STAGE_DIRECTION_RE.match(raw):
            continue
        lines.append((line, pending_marker))
        pending_marker = None

    return ParsedLyrics(lines=lines)


def _normalize_marker(label: str) -> str:
    """[Verse 1] → verse1; [Chorus - Final] → chorus-final; [Pre-Chorus] → pre-chorus."""
    s = label.strip().lower()
    # Normalize dashes
    s = s.replace("–", "-").replace("—", "-")
    # Pre-chorus und Chorus-final als Hyphen-Kette halten
    # Strip leading/trailing spaces around hyphens
    s = re.sub(r"\s*-\s*", "-", s)
    # Remove remaining whitespace in tokens that aren't separated by hyphens
    s = re.sub(r"\s+", "", s)
    return s


_TOKEN_RE = re.compile(r"[a-z0-9']+")


def _tokens_from_text(text: str) -> list[str]:
    return _TOKEN_RE.findall(text.lower().replace("'", "'"))


def _normalize_token(t: str) -> str:
    """Apostrophe raus, lowercase — für Matching."""
    return re.sub(r"[^a-z0-9]", "", t.lower())


def align(
    vocals_wav: Path,
    lyrics_text: str,
    whisper_model_name: str = "large-v3",
    compute_type: str = "float32",
    language: str = "en",
) -> list[AlignmentLine]:
    """Forced-Align bereitgestellte Lyrics gegen Vocals-Stem.

    `language` wird hart an Whisper übergeben, damit Language-Detection nicht
    auf Single-Singer-Vocals daneben liegt (Default 'en').
    """
    import whisperx

    parsed = parse_lyrics(lyrics_text)
    if not parsed.lines:
        return []

    device = _pick_device()
    # WhisperX/Whisper hat auf MPS noch schwache Unterstützung → CPU fällt stabiler
    whisper_device = "cpu" if device == "mps" else device

    audio = whisperx.load_audio(str(vocals_wav))
    model = whisperx.load_model(
        whisper_model_name, device=whisper_device, compute_type=compute_type, language=language
    )
    transcription = model.transcribe(audio, batch_size=4, language=language)

    align_model, metadata = whisperx.load_align_model(language_code=language, device=whisper_device)
    aligned = whisperx.align(
        transcription["segments"],
        align_model,
        metadata,
        audio,
        whisper_device,
        return_char_alignments=False,
    )
    word_segments = aligned.get("word_segments", [])

    return _map_lyrics_via_sequence_alignment(parsed, word_segments)


def _map_lyrics_via_sequence_alignment(
    parsed: ParsedLyrics,
    word_segments: list[dict],
) -> list[AlignmentLine]:
    """Robustes Line-to-Word-Mapping mittels Sequence-Alignment.

    Ablauf:
    1. Flatten User-Lyrics in Token-Liste mit (token, line_idx).
    2. Flatten Whisper-Words in Token-Liste mit (token, word_idx, start, end).
    3. difflib.SequenceMatcher findet matching blocks zwischen beiden
       Token-Listen (fuzzy-tolerant).
    4. Für jede User-Zeile: finde min/max Whisper-Word-Index aus
       gemappten Tokens. Daraus Start/Ende-Zeit.
    """
    if not word_segments or not parsed.lines:
        return []

    # 1. User-Tokens mit Zeilenindex
    user_tokens: list[str] = []
    user_line_for_token: list[int] = []
    for i, (text, _marker) in enumerate(parsed.lines):
        for tok in _tokens_from_text(text):
            n = _normalize_token(tok)
            if n:
                user_tokens.append(n)
                user_line_for_token.append(i)

    # 2. Whisper-Tokens mit Word-Index
    whisper_tokens: list[str] = []
    whisper_word_idx: list[int] = []  # parallel zu whisper_tokens
    valid_words: list[dict] = []
    for w_idx, w in enumerate(word_segments):
        raw = w.get("word", "")
        n = _normalize_token(raw)
        if not n:
            continue
        whisper_tokens.append(n)
        whisper_word_idx.append(w_idx)
        valid_words.append(w)

    if not whisper_tokens:
        return []

    # 3. Sequence-Alignment
    matcher = difflib.SequenceMatcher(a=user_tokens, b=whisper_tokens, autojunk=False)
    blocks = matcher.get_matching_blocks()

    # Mapping user_token_idx → whisper_token_idx (sparse)
    user_to_whisper: dict[int, int] = {}
    for block in blocks:
        for offset in range(block.size):
            user_to_whisper[block.a + offset] = block.b + offset

    # 4. Für jede Zeile: Zeitmarken aus gemappten Tokens
    out: list[AlignmentLine] = []
    for line_idx, (text, marker) in enumerate(parsed.lines):
        # User-Token-Indices dieser Zeile
        user_idxs = [i for i, ln in enumerate(user_line_for_token) if ln == line_idx]
        if not user_idxs:
            continue
        # Die gemappten
        mapped_whisper_idxs = [
            user_to_whisper[i] for i in user_idxs if i in user_to_whisper
        ]
        if not mapped_whisper_idxs:
            # Zeile konnte nicht gemappt werden (Whisper hat sie nicht transkribiert)
            continue
        lo = min(mapped_whisper_idxs)
        hi = max(mapped_whisper_idxs)
        # Expand ranges to include ALL valid_words from lo to hi (damit Zwischenpausen drin sind)
        line_words = valid_words[lo : hi + 1]
        start = float(line_words[0].get("start", 0.0))
        end = float(line_words[-1].get("end", start + 1.0))
        out.append(
            AlignmentLine(
                start=round(start, 3),
                end=round(end, 3),
                text=text,
                section_marker=marker,
                words=[
                    {
                        "text": w.get("word", ""),
                        "start": float(w.get("start", 0.0)),
                        "end": float(w.get("end", 0.0)),
                        "score": float(w.get("score", 0.0)),
                    }
                    for w in line_words
                ],
            )
        )
    return out
