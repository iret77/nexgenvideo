"""Registry-driven sanity audit: register core checks, run, assert report."""

from __future__ import annotations

import pytest

from nexgen_engine.brief.schema import Brief
from nexgen_engine.core.modes import Mode
from nexgen_engine.pack import EngineRegistry
from nexgen_engine.sanity.audit import AuditContext, Finding, SanityReport, audit
from nexgen_engine.sanity.checks import register_core_checks
from nexgen_engine.shotlist import schema


def _shot(idx: int, start: float, end: float, prompt: str, section: str = "verse"):
    return schema.Shot(
        id=f"s{idx:03d}",
        section=section,
        time_start=start,
        time_end=end,
        duration_s=end - start,
        type=schema.ShotType.PERFORMANCE,
        description="d",
        visual_prompt=prompt,
        mood="m",
    )


def _shotlist(shots, *, mode=Mode.SECTION, duration_s=8.0):
    song = schema.Song(
        title="t",
        audio_path="a.wav",
        analysis_path="an.json",
        bpm=120.0,
        duration_s=duration_s,
    )
    return schema.Shotlist(
        schema=schema.SCHEMA_VERSION,
        mode=mode,
        project="proj",
        song=song,
        generated="2026-01-01",
        generator="test",
        shots=shots,
    )


_GOOD_PROMPT = (
    "Alex stands center frame at the bar, pouring a drink, warm tungsten light "
    "from the left, medium shot, calm reflective mood at dusk."
)


def _registry_with_core() -> EngineRegistry:
    reg = EngineRegistry()
    register_core_checks(reg)
    return reg


def test_register_core_checks_populates_registry():
    reg = _registry_with_core()
    assert {"coverage", "mode_match", "prompt_quality"} <= set(reg.sanity_checks)


def test_audit_returns_report_clean_for_a_well_formed_project():
    # Two back-to-back shots tiling [0,8], good prompts, no brief mismatch.
    shotlist = _shotlist(
        [_shot(1, 0.0, 4.0, _GOOD_PROMPT), _shot(2, 4.0, 8.0, _GOOD_PROMPT)]
    )
    reg = _registry_with_core()
    report = audit(AuditContext(shotlist=shotlist), reg.sanity_checks)

    assert isinstance(report, SanityReport)
    assert report.project == "proj"
    assert report.is_clean is True
    assert report.errors == []


def test_audit_flags_short_prompt_and_uncovered_tail():
    # One short prompt (-> PROMPT_TOO_SHORT error) and a tail gap (shot ends at
    # 4s but timeline runs to 8s -> UNCOVERED_TAIL info).
    shotlist = _shotlist([_shot(1, 0.0, 4.0, "too short")], duration_s=8.0)
    reg = _registry_with_core()
    report = audit(AuditContext(shotlist=shotlist), reg.sanity_checks)

    codes = {f.code for f in report.findings}
    assert "PROMPT_TOO_SHORT" in codes
    assert "UNCOVERED_TAIL" in codes
    assert report.is_clean is False  # the short-prompt finding is an error


def test_audit_flags_mode_mismatch_against_brief():
    shotlist = _shotlist(
        [_shot(1, 0.0, 4.0, _GOOD_PROMPT), _shot(2, 4.0, 8.0, _GOOD_PROMPT)],
        mode=Mode.SECTION,
    )
    brief = Brief.model_construct(project_mode="beat")
    reg = _registry_with_core()
    report = audit(AuditContext(shotlist=shotlist, brief=brief), reg.sanity_checks)

    assert any(f.code == "MODE_MISMATCH" for f in report.errors)


def test_audit_isolates_a_raising_check():
    def _boom(ctx: AuditContext) -> list[Finding]:
        raise RuntimeError("kaboom")

    reg = _registry_with_core()
    reg.register_sanity_check("boom", _boom)
    shotlist = _shotlist([_shot(1, 0.0, 8.0, _GOOD_PROMPT)])
    report = audit(AuditContext(shotlist=shotlist), reg.sanity_checks)

    failed = [f for f in report.errors if f.code == "AUDIT_CHECK_FAILED"]
    assert len(failed) == 1
    assert "boom" in failed[0].message


def test_audit_runs_on_empty_registry():
    shotlist = _shotlist([_shot(1, 0.0, 8.0, _GOOD_PROMPT)])
    report = audit(AuditContext(shotlist=shotlist), {})
    assert isinstance(report, SanityReport)
    assert report.findings == []
    assert report.is_clean is True


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(pytest.main([__file__, "-q"]))
