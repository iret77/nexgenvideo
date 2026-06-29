"""Demucs-Stems (vocals/drums/bass/other)."""

from __future__ import annotations

from pathlib import Path

import numpy as np

from nexgen_pack_musicvideo.analysis_schema import Stems


def available() -> bool:
    try:
        import demucs.pretrained  # noqa: F401
        import torch  # noqa: F401
        import torchaudio  # noqa: F401
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


def separate(audio_path: Path, out_dir: Path, model_name: str = "htdemucs_ft") -> Stems:
    """Separiere Audio in 4 Stems (htdemucs_ft), speichere als WAV in out_dir.

    Gibt ein Stems-Objekt mit den relativen Dateipfaden zurück.
    """
    import torch
    import torchaudio
    from demucs.apply import apply_model
    from demucs.pretrained import get_model

    out_dir.mkdir(parents=True, exist_ok=True)
    device = _pick_device()
    model = get_model(name=model_name).to(device)
    model.eval()

    wav, sr = torchaudio.load(str(audio_path))
    if sr != model.samplerate:
        wav = torchaudio.functional.resample(wav, sr, model.samplerate)
        sr = model.samplerate
    if wav.shape[0] == 1:
        wav = wav.repeat(2, 1)  # mono→stereo

    ref = wav.mean(0)
    wav = (wav - ref.mean()) / (wav.std() + 1e-8)

    with torch.no_grad():
        sources = apply_model(model, wav.unsqueeze(0).to(device), split=True, progress=False)[0]
    sources = sources * wav.std() + ref.mean()

    out_paths: dict[str, str] = {}
    for source_tensor, name in zip(sources, model.sources, strict=False):
        path = out_dir / f"{name}.wav"
        torchaudio.save(str(path), source_tensor.cpu(), sr)
        out_paths[name] = str(path)

    return Stems(
        vocals=out_paths.get("vocals"),
        drums=out_paths.get("drums"),
        bass=out_paths.get("bass"),
        other=out_paths.get("other"),
    )


def peak_check(audio_path: Path) -> float:
    """Schnell-Check ob die Datei überhaupt Audio enthält (RMS)."""
    import torchaudio

    wav, _ = torchaudio.load(str(audio_path))
    return float(np.sqrt(np.mean(wav.numpy() ** 2)))
