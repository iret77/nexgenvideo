from __future__ import annotations

import re
from enum import Enum
from pathlib import Path
from typing import Annotated

import yaml
from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

from nexgen_engine.core.modes import Mode

SCHEMA_VERSION = "shotlist/v3"
SHOTLIST_SUBDIR = "shotlist"
SHOTLIST_VERSION_RE = re.compile(r"^v(\d+)$")
SHOT_ID_RE = re.compile(r"^s\d{3}$")
CAMERA_ID_RE = re.compile(r"^cam\d{2}$")
DURATION_EPSILON = 1e-3


class ShotType(str, Enum):
    CLOSE_UP = "close-up"
    ESTABLISHING = "establishing"
    HIGH_MOTION = "high-motion"
    PERFORMANCE = "performance"
    B_ROLL = "b-roll"


class ModelSuggestion(str, Enum):
    GEN_4_5 = "gen-4.5"
    SEEDANCE_2_0 = "seedance-2.0"
    VEO3 = "veo3"
    VEO3_1_FAST = "veo3.1_fast"
    GEN_4_TURBO = "gen-4-turbo"


class KeyframeStrategy(str, Enum):
    """Wie viele Standbilder werden pro Shot gerendert und an den Video-Provider übergeben."""
    NONE = "none"  # pure text-to-video
    START = "start"  # image-to-video mit Start-Frame
    START_END = "start_end"  # Interpolation (nur bestimmte Modelle)


class SceneVideoProvider(str, Enum):
    """Pro Shot wählbarer Video-Provider (v0.11).

    Default in neuen Projekten ist FAL — voller Seedance-2-Feature-Set
    (Multi-Reference-Mode + 1080p + Audio-Lip-Sync).

    RUNWAY bleibt als Legacy-Wert erhalten — Altprojekte können weiter
    auf Runway rendern, neue setzen auf FAL.
    """
    FAL = "fal"
    RUNWAY = "runway"


class SeedanceInputMode(str, Enum):
    """Wie Seedance-Anker uebergeben werden — KEYFRAME schliesst
    REFERENCE aus, das ist eine Seedance-2-Modell-Eigenschaft (von
    ByteDance dokumentiert: 'Keep those modes separate').

    KEYFRAME: 1 Start-Frame (+ optional End-Frame) als first_frame_url
        / last_frame_url. Identitaet/Welt kommt aus dem Frame.

    REFERENCE: bis zu 9 Image-Refs (Char-Sheets + Location-Wide etc.)
        per @image1-Mention im Prompt. Komposition wird Modell-Wahl,
        aber Identitaet ist stark verankert.
    """
    KEYFRAME = "keyframe"
    REFERENCE = "reference"


class Framing(str, Enum):
    """Bildausschnitt pro Shot.

    Steuert dramaturgische Bildvielfalt UND BG-Konsistenz-Risiko. Pro
    Framing definiert die format-spezifische Framing-Risk-Tabelle
    (welche Welt-Bereiche der Shot zeigt, welche Zone-Anforderungen
    daraus folgen).

    Optional bei v1/v2-Shotlists, empfohlen ab v3 — Sanity warnt bei
    fehlendem Framing.
    """
    WIDE = "wide"          # Establishing, ganzer BG sichtbar
    FULL = "full"          # Vollkörper, BG vollständig sichtbar
    MS = "ms"              # Medium Shot, Knie aufwärts, BG-Oberkante sichtbar
    MCU = "mcu"            # Medium Close-Up, Brust aufwärts, minimaler BG (oft nur SKY)
    CU = "cu"              # Close-Up, Gesicht, BG nicht wesentlich
    ECU = "ecu"            # Extreme Close-Up, Detail am Subject
    OTS = "ots"            # Over-the-Shoulder, Ziel-Zone wichtig
    POV = "pov"            # Subjektive Kamera, Blick-Richtung wichtig
    INSERT = "insert"      # Detail auf Objekt, kein architektonischer BG
    AERIAL = "aerial"      # Vogelperspektive, eigener BG-Typ (oft GROUND)


class CameraHeight(str, Enum):
    """Kamerahoehe — was Modelle zuverlaessig parsen.

    Keine mm-Brennweiten, keine Gradzahlen — der Wortschatz ist bewusst
    kurz, weil Bild-/Video-Modelle alles darueber hinaus ignorieren oder
    unzuverlaessig interpretieren.
    """
    EYE_LEVEL = "eye_level"      # Augenhoehe der Figur
    LOW = "low"                  # Huefte, leicht nach oben blickend
    HIGH = "high"                # ueber Kopfhoehe, leicht herab
    OVERHEAD = "overhead"        # senkrecht von oben (top-down)
    KNEE = "knee"                # Kniehoehe (Kind-Perspektive)
    WORM = "worm"                # Bodenhoehe, stark hochblickend


class CameraAngle(str, Enum):
    """Achse der Kamera zum Subject."""
    FRONTAL = "frontal"                         # direkt von vorn
    THREE_QUARTER_LEFT = "three_quarter_left"   # 45 deg, Subject von Kameralinks
    THREE_QUARTER_RIGHT = "three_quarter_right" # 45 deg, Subject von Kamerarechts
    PROFILE_LEFT = "profile_left"               # 90 deg, Subject im Profil nach links
    PROFILE_RIGHT = "profile_right"             # 90 deg, Subject im Profil nach rechts
    BACK = "back"                               # hinter dem Subject (OTS-Variante)


class LensHint(str, Enum):
    """Lens-Charakter — wirkt auf Kompression, nicht auf Brennweite."""
    WIDE = "wide"        # weitwinklig, mehr Kontext, leichte Verzerrung am Rand
    NORMAL = "normal"    # ~50mm-Anmutung
    LONG = "long"        # leichte Kompression, Hintergrund nah


class CameraSetup(BaseModel):
    """Kamera-Triplet pro Shot.

    Modell-tauglich: drei Enums plus optionaler kurzer Freitext-Hinweis.
    Bewusst keine Compound-Bewegungen, Gradzahlen, Brennweiten.
    Die format-spezifische Default-Tabelle liefert pro Framing das
    empfohlene Default-Triplet.
    """
    model_config = ConfigDict(extra="forbid")

    height: CameraHeight
    angle: CameraAngle
    lens_hint: LensHint = LensHint.NORMAL
    note: str = ""
    """Optionaler kurzer Komposition-Zusatz, z.B. 'slight handheld',
    'window light from left'. Kein Ort fuer technische Details."""


class CharacterBlocking(BaseModel):
    """Strukturierte Pose+Position+Blick pro Figur pro Shot.

    Hintergrund: Bild-Modelle haben starke Defaults — Figuren frontal
    zur Kamera, mittig, Moebel werden re-arrangiert um zu passen. Ohne
    explizite Blocking-Anweisungen passiert das jedes Mal. Pflicht bei
    Multi-Charakter-Shots (>=2 character_refs); Solo-Shots koennen das
    Blocking weglassen, weil dort der NO_BLOCKING_AT_T0-Check (Pose+
    Vektor) reicht.
    """
    model_config = ConfigDict(extra="forbid")

    character_ref: str
    """Muss in Shot.character_refs sein."""

    position: Annotated[str, Field(min_length=1)]
    """Freitext: 'left third, foreground', 'right edge, behind desk',
    'center, sitting on floor'. Modell-tauglich heisst hier:
    raumbezogene Kompositions-Sprache, keine Pixel-Koordinaten."""

    pose: Annotated[str, Field(min_length=1)]
    """Freitext: 'sitting at desk', 'standing in doorway', 'kneeling
    next to bench'. Pose enthaelt Aktion-Hinweis fuer t=0."""

    gaze: Annotated[str, Field(min_length=1)]
    """Freitext: 'at notebook', 'toward Mark', 'into camera', 'down at
    floor'. WICHTIG: leer lassen verfaellt zum Modell-Default
    (frontal in die Kamera). Schema laesst Leerwert hart durchfallen;
    wenn 'unspezifiziert' gemeint, explizit 'unspecified' setzen — dann
    warnt Sanity (GAZE_UNSPECIFIED) statt das Modell schweigend frontal
    rendern zu lassen."""

    relation_to_set: str = ""
    """Optional: Bezug zur Kulisse, idealerweise mit Zone-ID.
    'next to zone left_window', 'behind zone bar_counter'. Macht den
    Set-Bezug fuer das Modell explizit und blockt Re-Arrangement."""


class Song(BaseModel):
    model_config = ConfigDict(extra="forbid")

    title: str
    artist: str | None = None
    audio_path: str
    lyrics_path: str | None = None
    analysis_path: str
    bpm: Annotated[float, Field(gt=0)]
    """Technische BPM aus analysis.json. Konsumenten sollen `perceived_bpm`
    bevorzugen — das ist das in A2 vom User bestätigte wahrgenommene Tempo."""
    tempo_multiplier: float = 1.0
    """Aus analysis.tempo_multiplier durchgereicht."""
    duration_s: Annotated[float, Field(gt=0)]

    @property
    def perceived_bpm(self) -> float:
        return self.bpm * self.tempo_multiplier


class Shot(BaseModel):
    model_config = ConfigDict(extra="forbid")

    id: str
    section: str | None = None  # leer im multicam-Modus
    time_start: Annotated[float, Field(ge=0)]
    time_end: float
    duration_s: float
    type: ShotType
    description: str
    visual_prompt: str
    motion: str | None = None
    mood: str
    lyrics_excerpt: str | None = None
    character_refs: list[str] = Field(default_factory=list)
    character_views: dict[str, str] = Field(default_factory=dict)
    """Optional: pro character_ref der bevorzugte Sheet-View-Key, z.B.
    ``{"alex": "side"}``. Frame-Builder picks `bible.<id>.sheets[<view>]`
    als primären Anker, gefolgt von den restlichen Sheets/Refs nach
    Capability-Limit."""
    location_ref: str | None = None
    location_view: str | None = None
    """Optional: Schlüssel in ``Location.sheets``, der als primärer
    Anker für diesen Shot dient. Z.B. ``"entrance"`` für einen
    Shot, der das Schultor von außen zeigt. Wenn None: der Frame-
    Builder nimmt `wide` (oder den ersten verfügbaren Sheet) plus
    Bible-Reference-Images bis zum Capability-Limit."""
    model_suggestion: ModelSuggestion | None = None
    keyframe_strategy: KeyframeStrategy = KeyframeStrategy.START
    """Default ab v0.10.4: START. Pure text_to_video (NONE) ist die
    Ausnahme — sobald ein Shot Bible-Refs (character/location/prop)
    traegt, MUSS er einen Anker-Frame haben, sonst erfindet das Video-
    Modell die Welt neu und bricht die Konsistenz zu image_to_video-
    Shots derselben Location. Sanity-Check `MISSING_BIBLE_ANCHOR_FOR_T2V`
    blockt diese Inkonsistenz. Escape via `text_to_video_ok:`-Marker in
    Shot.notes nur fuer wirklich abstrakte / welt-freie Visuals."""
    framing: Framing | None = None
    """Bildausschnitt (siehe `Framing`-Enum). Optional bei v1/v2-Shotlists,
    empfohlen ab v3 — Sanity warnt bei None. Steuert sowohl Bildvielfalt
    (Sanity `FRAMING_MONOKULTUR`) als auch BG-Konsistenz-Risiko (Sanity
    `FRAMING_RISK_MISMATCH` vs. `Shot.visible_zones`)."""

    visible_zones: list[str] = Field(default_factory=list)
    """Welche `Location.zones[].id` zeigt dieser Shot. Pflicht für
    framings mit Architektur-BG (WIDE, FULL, MS, OTS, POV, AERIAL),
    optional für BG-arme (MCU, CU, ECU, INSERT). Sanity prüft
    `DIRTY_ZONE_VISIBLE` (error), `ZONE_UNCOVERED` (warn) und
    `FRAMING_RISK_MISMATCH` (error)."""

    zone_introduces: list[str] = Field(default_factory=list)
    """Optional: Zonen-IDs, die dieser Shot erstmals etabliert. Beim
    Frame-Approve werden die Zonen in `Location.zones` als `dirty` mit
    `established_by_shot=<id>` markiert — wenn der Approver-Workflow das
    Update durchführt. Nur sinnvoll, wenn die Zone vorher `undefined` war
    oder neu hinzukommt."""

    camera_setup: CameraSetup | None = None
    """Strukturiertes Kamera-Triplet (Hoehe, Achse, Lens-Charakter).
    Empfohlen ab v3 — Sanity warnt bei None. Siehe `CameraSetup` und die
    format-spezifische Default-Tabelle fuer das empfohlene Default pro
    Framing."""

    character_blocking: list[CharacterBlocking] = Field(default_factory=list)
    """Strukturierte Pose+Position+Blick pro Figur. Pflicht bei Shots
    mit >=2 character_refs (Sanity `MISSING_CHARACTER_BLOCKING`).
    Solo-Shots koennen das weglassen — dort reicht der NO_BLOCKING_AT_T0-
    Check auf den visual_prompt."""
    # Bible-Referenzen: Props zusätzlich zu character_refs/location_ref.
    prop_refs: list[str] = Field(default_factory=list)
    prop_views: dict[str, str] = Field(default_factory=dict)
    """Optional: Pro prop_ref der gewünschte Sheet-View, falls der
    Prop in mehreren Zuständen / Varianten vorliegt
    (z.B. ``{"notebook": "open"}``)."""
    # Multicam-spezifisch
    camera_id: str | None = None
    camera_label: str | None = None
    # Partial-Rerender-Flag: wird vom User nach Final-Abnahme gesetzt,
    # wenn ein Shot nochmal gerendert werden soll.
    redo: bool = False
    scene_video_provider: SceneVideoProvider = SceneVideoProvider.FAL
    """Video-Render-Provider (v0.11). Default FAL fuer neue Projekte;
    RUNWAY bleibt fuer Altbestand verfuegbar. Pro Shot ueberschreibbar."""

    seedance_input_mode: SeedanceInputMode = SeedanceInputMode.KEYFRAME
    """KEYFRAME (Default): klassischer Anker via Start/End-Frame —
    funktioniert auf beiden Providern. REFERENCE: Multi-Image-Refs aus
    der Bible per @image1-Syntax — NUR FAL exposed das, Runway weist
    den Modus zur Run-Zeit ab. Sanity-Check
    `REFERENCE_MODE_REQUIRES_FAL` (error) blockt diese Inkonsistenz
    pre-render."""

    reference_image_refs: list[str] = Field(default_factory=list)
    """Optionale Bible-Asset-Pfade fuer Reference-Mode. Default leer —
    Builder leitet im Reference-Mode automatisch aus Bible-Refs
    (`character_refs.<id>.sheets[<view>]` + `location_ref.sheets[...]`)
    ab. Explizite Liste hier ueberschreibt das fuer Sonderfaelle.
    Schemaerweiterung v0.11.0."""

    # Continuity-Pattern „Anchor-and-Extend": letzter Frame des vorherigen
    # Shots wird als Start-Frame dieses Shots verwendet. Nur sinnvoll wenn
    # Location + Charaktere zwischen den Shots übereinstimmen und der Cut
    # eine Kamera/Action-Variation, KEIN Schnitt sein soll. Frame-Phase liest
    # das Flag und überspringt die eigene Start-Frame-Generation; statt-
    # dessen wird `renders/finals/<prev_shot>.last_frame.png` extrahiert.
    chain_with_previous_end: bool = False
    notes: str | None = None

    @field_validator("id")
    @classmethod
    def _shot_id_pattern(cls, v: str) -> str:
        if not SHOT_ID_RE.match(v):
            raise ValueError(f"shot id {v!r} muss dem Muster 's\\d{{3}}' entsprechen")
        return v

    @field_validator("camera_id")
    @classmethod
    def _camera_id_pattern(cls, v: str | None) -> str | None:
        if v is None:
            return v
        if not CAMERA_ID_RE.match(v):
            raise ValueError(f"camera_id {v!r} muss dem Muster 'cam\\d{{2}}' entsprechen")
        return v

    @model_validator(mode="after")
    def _check_times(self) -> "Shot":
        if self.time_end <= self.time_start:
            raise ValueError(
                f"shot {self.id}: time_end ({self.time_end}) muss > time_start ({self.time_start}) sein"
            )
        implied = self.time_end - self.time_start
        if abs(implied - self.duration_s) > DURATION_EPSILON:
            raise ValueError(
                f"shot {self.id}: duration_s ({self.duration_s}) passt nicht zu "
                f"time_end - time_start ({implied:.3f})"
            )
        return self

    @model_validator(mode="after")
    def _blocking_refs_valid(self) -> "Shot":
        """Jedes character_blocking[i].character_ref MUSS in character_refs sein."""
        if not self.character_blocking:
            return self
        ref_set = set(self.character_refs)
        for cb in self.character_blocking:
            if cb.character_ref not in ref_set:
                raise ValueError(
                    f"shot {self.id}: character_blocking referenziert "
                    f"{cb.character_ref!r}, das nicht in character_refs={self.character_refs!r} ist"
                )
        return self


class Shotlist(BaseModel):
    model_config = ConfigDict(extra="forbid")

    schema_: str = Field(alias="schema")
    mode: Mode
    project: str
    song: Song
    generated: str
    generator: str
    budget_eur: Annotated[float, Field(gt=0)] = 50.0
    shots: Annotated[list[Shot], Field(min_length=1)]
    notes: str | None = None

    @field_validator("schema_")
    @classmethod
    def _schema_const(cls, v: str) -> str:
        # v1 und v2 werden tolerant gelesen — neu hinzugekommene Felder
        # (framing, visible_zones, zone_introduces in v3) sind optional.
        # Alte Shotlists laden also weiter; beim nächsten Save schreibt
        # der Validator die aktuelle Version hin.
        if v not in {SCHEMA_VERSION, "shotlist/v2", "shotlist/v1"}:
            raise ValueError(
                f"schema {v!r} unbekannt. Erlaubt: {SCHEMA_VERSION}, "
                "shotlist/v2 (legacy), shotlist/v1 (legacy)"
            )
        return v

    @model_validator(mode="after")
    def _shot_ids_sequential(self) -> "Shotlist":
        ids = [s.id for s in self.shots]
        if len(set(ids)) != len(ids):
            raise ValueError(f"shot-IDs müssen eindeutig sein: {ids}")
        expected = [f"s{i:03d}" for i in range(1, len(ids) + 1)]
        if ids != expected:
            raise ValueError(
                f"shot-IDs müssen lückenlos sequentiell sein, erwartet {expected}, war {ids}"
            )
        return self

    @model_validator(mode="after")
    def _mode_specific_rules(self) -> "Shotlist":
        if self.mode == Mode.MULTICAM:
            # Jeder "Shot" ist eine Kamera, spannt den ganzen Song.
            cam_ids: list[str] = []
            for shot in self.shots:
                if shot.camera_id is None:
                    raise ValueError(
                        f"mode=multicam: shot {shot.id} braucht camera_id (z.B. 'cam01')"
                    )
                cam_ids.append(shot.camera_id)
                if abs(shot.time_start) > DURATION_EPSILON:
                    raise ValueError(
                        f"mode=multicam: shot {shot.id} time_start muss 0 sein (war {shot.time_start})"
                    )
                if abs(shot.time_end - self.song.duration_s) > 0.5:
                    raise ValueError(
                        f"mode=multicam: shot {shot.id} time_end muss ≈ song.duration_s "
                        f"({self.song.duration_s}) sein (war {shot.time_end})"
                    )
            if len(set(cam_ids)) != len(cam_ids):
                raise ValueError(f"mode=multicam: camera_id muss eindeutig sein, war {cam_ids}")
        else:
            for shot in self.shots:
                if shot.camera_id is not None or shot.camera_label is not None:
                    raise ValueError(
                        f"mode={self.mode.value}: shot {shot.id} darf keine camera_id/label haben"
                    )
                # Im PHRASE-Modus ist `section` optional (nicht jede Phrase gehört zu
                # einem offiziellen Section-Label — instrumentale Phrasen z.B. nicht).
                if self.mode != Mode.PHRASE and shot.section is None:
                    raise ValueError(
                        f"mode={self.mode.value}: shot {shot.id} braucht ein section-Label"
                    )
        return self


def latest_version(project_dir: Path) -> int | None:
    """Highest N among `<data_root>/shotlist/vN.yaml`, or None if none exist."""
    versions = [
        int(m.group(1))
        for p in (project_dir / SHOTLIST_SUBDIR).glob("v*.yaml")
        if (m := SHOTLIST_VERSION_RE.match(p.stem)) is not None
    ]
    return max(versions) if versions else None


def shotlist_path(project_dir: Path, version: int) -> Path:
    return project_dir / SHOTLIST_SUBDIR / f"v{version}.yaml"


def load(project_dir: Path) -> Shotlist | None:
    """Load the latest versioned shotlist (`shotlist/vN.yaml`, highest N), or
    None if the project has none yet. `project_dir` is the data root."""
    version = latest_version(project_dir)
    if version is None:
        return None
    data = yaml.safe_load(shotlist_path(project_dir, version).read_text(encoding="utf-8"))
    return Shotlist.model_validate(data)


def save(project_dir: Path, shotlist: Shotlist, version: int | None = None) -> Path:
    """Write a shotlist to `shotlist/vN.yaml`. With no `version`, the next free N
    (one past the current latest, starting at 1). Returns the written path."""
    if version is None:
        latest = latest_version(project_dir)
        version = 1 if latest is None else latest + 1
    path = shotlist_path(project_dir, version)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        yaml.safe_dump(
            shotlist.model_dump(by_alias=True, mode="json"),
            sort_keys=False,
            allow_unicode=True,
        ),
        encoding="utf-8",
    )
    return path
