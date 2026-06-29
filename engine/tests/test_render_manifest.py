"""Generic per-shot render manifest — schema, ordering, aggregation, persistence.

The manifest is format-neutral: it only ever sees shot IDs, outputs, costs, phases.
The shotlist fixture here exists solely to produce ordered shot IDs; the manifest
module never reads it.
"""

from pathlib import Path

from nexgen_engine import mcp_server
from nexgen_engine.core import layout as layout_mod
from nexgen_engine.core.modes import Mode
from nexgen_engine.render import manifest as manifest_mod
from nexgen_engine.shotlist import schema as shotlist_schema

PHASE = "preview"


def _shot(idx: int) -> shotlist_schema.Shot:
    return shotlist_schema.Shot(
        id=f"s{idx:03d}",
        section="verse",
        time_start=float(idx - 1) * 4.0,
        time_end=float(idx) * 4.0,
        duration_s=4.0,
        type=shotlist_schema.ShotType.PERFORMANCE,
        description=f"d{idx}",
        visual_prompt=f"prompt {idx}",
        mood="m",
        framing=shotlist_schema.Framing.WIDE,
    )


def _shotlist(n: int = 3) -> shotlist_schema.Shotlist:
    song = shotlist_schema.Song(
        title="t", audio_path="a.wav", analysis_path="an.json",
        bpm=120.0, duration_s=float(n) * 4.0,
    )
    return shotlist_schema.Shotlist(
        schema=shotlist_schema.SCHEMA_VERSION,
        mode=Mode.SECTION,
        project="demo",
        song=song,
        generated="2026-01-01",
        generator="test",
        shots=[_shot(i) for i in range(1, n + 1)],
    )


def _scaffold(tmp_path: Path, n: int = 3) -> Path:
    data_root = layout_mod.init_project(tmp_path / "p", "demo", mode=Mode.SECTION)
    shotlist_schema.save(data_root, _shotlist(n))
    return data_root


def _ordered(data_root: Path) -> list[str]:
    sl = shotlist_schema.load(data_root)
    assert sl is not None
    return [s.id for s in sl.shots]


def test_empty_manifest_when_none_on_disk(tmp_path: Path):
    data_root = _scaffold(tmp_path)
    man = manifest_mod.load(data_root, PHASE)
    assert man.entries == {}
    assert man.phase == PHASE
    assert manifest_mod.spent(man) == 0.0


def test_next_unrendered_respects_shotlist_order_and_skips_rendered(tmp_path: Path):
    data_root = _scaffold(tmp_path)
    ordered = _ordered(data_root)
    man = manifest_mod.load(data_root, PHASE)

    # nothing recorded → first shot in order
    assert manifest_mod.next_unrendered(ordered, man) == "s001"

    # render the FIRST shot → next is s002
    manifest_mod.record(man, "s001", output="a.png", cost_eur=1.0, phase=PHASE,
                        updated_at="2026-01-01T00:00:00+00:00")
    assert manifest_mod.next_unrendered(ordered, man) == "s002"

    # a failed s002 is NOT rendered → it is still the next unrendered
    manifest_mod.record(man, "s002", output=None, cost_eur=0.0, status="failed",
                        phase=PHASE, updated_at="2026-01-01T00:00:00+00:00")
    assert manifest_mod.next_unrendered(ordered, man) == "s002"

    # render s002 + s003 → all done → None
    manifest_mod.record(man, "s002", output="b.png", cost_eur=2.0, phase=PHASE,
                        updated_at="2026-01-01T00:00:00+00:00")
    manifest_mod.record(man, "s003", output="c.png", cost_eur=3.0, phase=PHASE,
                        updated_at="2026-01-01T00:00:00+00:00")
    assert manifest_mod.next_unrendered(ordered, man) is None


def test_spent_and_summary_aggregate(tmp_path: Path):
    data_root = _scaffold(tmp_path)
    ordered = _ordered(data_root)
    man = manifest_mod.load(data_root, PHASE)
    manifest_mod.record(man, "s001", output="a.png", cost_eur=1.50, phase=PHASE,
                        updated_at="t")
    manifest_mod.record(man, "s002", output=None, cost_eur=0.0, status="failed",
                        phase=PHASE, updated_at="t")

    assert manifest_mod.spent(man) == 1.5
    summ = manifest_mod.summary(ordered, man)
    assert summ == {"total": 3, "rendered": 1, "pending": 1, "failed": 1, "spent_eur": 1.5}


def test_record_stamps_updated_at_when_not_passed(tmp_path: Path):
    man = manifest_mod.RenderManifest(project="demo", phase=PHASE)
    manifest_mod.record(man, "s001", output="x.png", cost_eur=1.0, phase=PHASE)
    assert man.entries["s001"].updated_at is not None


def test_round_trip_through_save_load(tmp_path: Path):
    data_root = _scaffold(tmp_path)
    man = manifest_mod.load(data_root, PHASE)
    manifest_mod.record(man, "s001", output="renders/s001.mp4", cost_eur=2.25,
                        phase=PHASE, updated_at="2026-01-01T00:00:00+00:00")
    manifest_mod.record(man, "s002", output=None, cost_eur=0.0, status="failed",
                        phase=PHASE, updated_at="2026-01-01T00:00:00+00:00")
    manifest_mod.save(data_root, man)

    reloaded = manifest_mod.load(data_root, PHASE)
    assert set(reloaded.entries) == {"s001", "s002"}
    e1 = reloaded.entries["s001"]
    assert e1.status == "rendered"
    assert e1.output == "renders/s001.mp4"
    assert e1.cost_eur == 2.25
    assert e1.updated_at == "2026-01-01T00:00:00+00:00"
    assert reloaded.entries["s002"].status == "failed"
    assert manifest_mod.spent(reloaded) == 2.25


def test_manifest_phase_json_is_the_file_written(tmp_path: Path):
    data_root = _scaffold(tmp_path)
    man = manifest_mod.load(data_root, PHASE)
    manifest_mod.record(man, "s001", output="a.png", cost_eur=1.0, phase=PHASE,
                        updated_at="t")
    written = manifest_mod.save(data_root, man)

    assert written == data_root / "renders" / f"manifest-{PHASE}.json"
    assert written.exists()


def test_legacy_keys_readable_by_already_spent_in_project(tmp_path: Path):
    # Continuity: render.costs.already_spent_in_project reads `shots[].eur_spent`.
    from nexgen_engine.render import costs as costs_mod

    data_root = _scaffold(tmp_path)
    man = manifest_mod.load(data_root, PHASE)
    manifest_mod.record(man, "s001", output="a.png", cost_eur=4.0, phase=PHASE,
                        updated_at="t")
    manifest_mod.save(data_root, man)
    assert costs_mod.already_spent_in_project(data_root) == 4.0


# ----- MCP tool surface -------------------------------------------------

def test_next_render_shot_tool_returns_prompt_and_then_done(tmp_path: Path):
    data_root = _scaffold(tmp_path)
    out = mcp_server.next_render_shot(str(data_root), PHASE)
    assert out["shot_id"] == "s001"
    assert out["done"] is False
    assert out["visual_prompt"] == "prompt 1"
    assert out["framing"] == "wide"

    for sid in ("s001", "s002", "s003"):
        mcp_server.record_render(str(data_root), PHASE, sid, output=f"{sid}.png", cost_eur=1.0)

    done = mcp_server.next_render_shot(str(data_root), PHASE)
    assert done["shot_id"] is None
    assert done["done"] is True


def test_record_render_tool_persists_and_reports_spend(tmp_path: Path):
    data_root = _scaffold(tmp_path)
    res = mcp_server.record_render(str(data_root), PHASE, "s001", output="a.mp4", cost_eur=3.5)
    assert res["status"] == "rendered"
    assert res["output"] == "a.mp4"
    assert res["spent_eur"] == 3.5

    reloaded = manifest_mod.load(data_root, PHASE)
    assert reloaded.entries["s001"].cost_eur == 3.5


def test_get_render_manifest_tool_entries_and_summary(tmp_path: Path):
    data_root = _scaffold(tmp_path)
    mcp_server.record_render(str(data_root), PHASE, "s001", output="a.png", cost_eur=2.0)
    out = mcp_server.get_render_manifest(str(data_root), PHASE)
    assert set(out["entries"]) == {"s001"}
    assert out["summary"] == {
        "total": 3, "rendered": 1, "pending": 2, "failed": 0, "spent_eur": 2.0
    }
