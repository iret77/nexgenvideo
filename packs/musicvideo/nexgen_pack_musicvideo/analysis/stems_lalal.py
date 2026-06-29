"""LALAL.AI REST-Adapter für Premium-Stem-Separation (optional, kostenpflichtig).

Pay-per-Song (Credits). Splitter "phoenix" = beste Qualität. Wir separieren
im Default Vocals + Instrumental (1 API-Call = ein Credit-Paket).

API-Key: `.lalal.env` im Repo-Root mit `LALAL_API_KEY=...`, chmod 600,
via .gitignore geschützt. Niemals committen.

Workflow:
  1. POST /api/upload/   → file_id
  2. POST /api/split/    → startet Split-Job
  3. GET  /api/check/?id=<file_id>  polling bis "success"|"error"
  4. GET  <stem_url>     → download
"""

from __future__ import annotations

import os
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Literal

from nexgen_pack_musicvideo.analysis_schema import Stems

LALAL_BASE = "https://www.lalal.ai"
LALAL_ENV_FILE = "lalal.env"

Splitter = Literal["phoenix", "orion"]
Stem = Literal["vocals", "drum", "bass", "piano", "electric_guitar", "acoustic_guitar", "synthesizer", "strings"]


def available() -> bool:
    try:
        import requests  # noqa: F401
        return True
    except Exception:
        return False


def _load_api_key() -> str:
    from nexgen_engine.core.paths import repo_root

    key = os.environ.get("LALAL_API_KEY")
    if key:
        return key
    candidates = [
        repo_root() / ".lalal.env",
        Path.home() / ".config" / "nexgen" / "lalal.env",
    ]
    for path in candidates:
        if path.exists():
            for line in path.read_text(encoding="utf-8").splitlines():
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, _, v = line.partition("=")
                if k.strip() == "LALAL_API_KEY":
                    return v.strip().strip('"').strip("'")
    raise FileNotFoundError(
        "LALAL_API_KEY fehlt. Lege `.lalal.env` im Repo-Root an mit `LALAL_API_KEY=...`."
    )


@dataclass
class LalalJob:
    file_id: str
    original_name: str


def _headers(api_key: str) -> dict[str, str]:
    return {"Authorization": f"license {api_key}"}


def _upload(audio_path: Path, api_key: str) -> LalalJob:
    import requests

    with audio_path.open("rb") as fp:
        resp = requests.post(
            f"{LALAL_BASE}/api/upload/",
            headers={
                **_headers(api_key),
                "Content-Disposition": f'attachment; filename="{audio_path.name}"',
            },
            data=fp.read(),
            timeout=600,
        )
    resp.raise_for_status()
    data = resp.json()
    if data.get("status") != "success":
        raise RuntimeError(f"LALAL upload failed: {data}")
    return LalalJob(file_id=data["id"], original_name=data.get("name", audio_path.name))


def _start_split(
    file_id: str,
    api_key: str,
    stem: Stem = "vocals",
    splitter: Splitter = "phoenix",
    enhanced: bool = True,
) -> None:
    import requests

    params = [{
        "id": file_id,
        "stem": stem,
        "splitter": splitter,
        "enhanced_processing_enabled": enhanced,
        "dereverb_enabled": False,
    }]
    resp = requests.post(
        f"{LALAL_BASE}/api/split/",
        headers=_headers(api_key),
        data={"params": __import__("json").dumps(params)},
        timeout=60,
    )
    resp.raise_for_status()
    data = resp.json()
    if data.get("status") != "success":
        raise RuntimeError(f"LALAL split failed: {data}")


def _poll(file_id: str, api_key: str, interval_s: int = 10, timeout_s: int = 1200) -> dict:
    import requests

    deadline = time.monotonic() + timeout_s
    while True:
        resp = requests.get(
            f"{LALAL_BASE}/api/check/",
            headers=_headers(api_key),
            params={"id": file_id},
            timeout=60,
        )
        resp.raise_for_status()
        payload = resp.json()
        if payload.get("status") != "success":
            raise RuntimeError(f"LALAL check failed: {payload}")
        result = payload["result"].get(file_id, {})
        task = result.get("task") or {}
        state = task.get("state")
        if state == "success":
            return result
        if state == "error":
            raise RuntimeError(f"LALAL task error: {task.get('error')}")
        if time.monotonic() > deadline:
            raise TimeoutError(f"LALAL timeout after {timeout_s}s")
        time.sleep(interval_s)


def _download(url: str, dest: Path) -> Path:
    import requests

    dest.parent.mkdir(parents=True, exist_ok=True)
    with requests.get(url, stream=True, timeout=600) as r:
        r.raise_for_status()
        with dest.open("wb") as f:
            for chunk in r.iter_content(1 << 16):
                if chunk:
                    f.write(chunk)
    return dest


def separate(
    audio_path: Path,
    out_dir: Path,
    stem: Stem = "vocals",
    splitter: Splitter = "phoenix",
) -> Stems:
    """Separiere Audio via LALAL.AI. Gibt Stems-Objekt mit vocals + 'other'
    (dem entgegengesetzten Stem) zurück. drums/bass bleiben None im
    Default-Modus.
    """
    api_key = _load_api_key()
    out_dir.mkdir(parents=True, exist_ok=True)

    job = _upload(audio_path, api_key)
    _start_split(job.file_id, api_key, stem=stem, splitter=splitter)
    result = _poll(job.file_id, api_key)

    split = result.get("split") or {}
    stem_url = split.get("stem_track")
    back_url = split.get("back_track")
    if not stem_url or not back_url:
        raise RuntimeError(f"LALAL result missing URLs: {result}")

    vocals_path = _download(stem_url, out_dir / f"{stem}.wav")
    other_path = _download(back_url, out_dir / "instrumental.wav")

    stems = Stems()
    if stem == "vocals":
        stems.vocals = str(vocals_path)
        stems.other = str(other_path)
    else:
        stems.other = str(vocals_path)  # conservative
    return stems
