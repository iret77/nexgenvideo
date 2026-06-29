"""Render cost model — load + construction sanity (engine-side)."""

from __future__ import annotations

import textwrap
from pathlib import Path

from nexgen_engine.render.costs import (
    CostGuard,
    CostsConfig,
    ModelPricing,
    already_spent_in_project,
    load_costs,
)


def test_module_has_no_musicvideo_refs() -> None:
    src = Path(__file__).parent.parent / "nexgen_engine" / "render" / "costs.py"
    assert "musicvideo" not in src.read_text(encoding="utf-8")


def test_dataclasses_construct_directly() -> None:
    pricing = ModelPricing(
        eur_per_second=0.10,
        max_duration_s=10.0,
        default_ratio="16:9",
    )
    assert pricing.eur_per_second_for(None) == 0.10
    assert pricing.eur_per_second_for("1080p") == 0.10  # no per-resolution table

    pro = ModelPricing(
        eur_per_second=0.68,
        max_duration_s=10.0,
        default_ratio="16:9",
        min_duration_s=5.0,
        eur_per_second_by_resolution={"720p": 0.30, "1080p": 0.68},
    )
    assert pro.eur_per_second_for("720p") == 0.30
    assert pro.eur_per_second_for("1080p") == 0.68
    assert pro.eur_per_second_for("4k") == 0.68  # unknown → fallback

    cfg = CostsConfig(
        pricing={"seedance2": pricing},
        model_map={"SEEDANCE_2_0": "seedance2"},
        defaults={"preview": "seedance2", "final": "seedance2"},
        overlap_pre_s=1.5,
        overlap_post_s=1.5,
        polling_interval_s=5,
        polling_timeout_s=600,
    )
    assert cfg.price("seedance2") is pricing
    assert isinstance(cfg.cost_guard, CostGuard)


def test_load_costs_from_yaml(tmp_path: Path) -> None:
    yaml_text = textwrap.dedent(
        """
        pricing:
          seedance2:
            eur_per_second: 0.10
            max_duration_s: 10.0
            default_ratio: "16:9"
          "fal:bytedance/seedance-2.0/pro":
            eur_per_second: 0.68
            max_duration_s: 10.0
            default_ratio: "16:9"
            min_duration_s: 5.0
            eur_per_second_by_resolution:
              720p: 0.30
              1080p: 0.68
        model_map:
          SEEDANCE_2_0: seedance2
        defaults:
          preview: seedance2
          final: "fal:bytedance/seedance-2.0/pro"
        overlap:
          pre_s: 1.5
          post_s: 1.5
        polling:
          interval_s: 5
          timeout_s: 600
        cost_guard:
          confirm_threshold_eur: 12.0
          project_wide_budget: true
        """
    )
    costs_yaml = tmp_path / "costs.yaml"
    costs_yaml.write_text(yaml_text, encoding="utf-8")

    cfg = load_costs(costs_yaml)

    assert isinstance(cfg, CostsConfig)
    assert set(cfg.pricing) == {"seedance2", "fal:bytedance/seedance-2.0/pro"}
    assert cfg.pricing["seedance2"].eur_per_second == 0.10
    pro = cfg.pricing["fal:bytedance/seedance-2.0/pro"]
    assert pro.min_duration_s == 5.0
    assert pro.eur_per_second_by_resolution == {"720p": 0.30, "1080p": 0.68}
    assert cfg.model_map == {"SEEDANCE_2_0": "seedance2"}
    assert cfg.defaults["final"] == "fal:bytedance/seedance-2.0/pro"
    assert cfg.overlap_pre_s == 1.5
    assert cfg.polling_timeout_s == 600
    assert cfg.cost_guard.confirm_threshold_eur == 12.0
    assert cfg.cost_guard.project_wide_budget is True


def test_already_spent_in_project(tmp_path: Path) -> None:
    import json

    renders = tmp_path / "renders"
    renders.mkdir()
    (renders / "manifest-preview.json").write_text(
        json.dumps({"shots": [{"eur_spent": 1.5}, {"eur_spent": 2.0}]}),
        encoding="utf-8",
    )
    (renders / "manifest-final.json").write_text(
        json.dumps({"shots": [{"eur_spent": 10.0}]}),
        encoding="utf-8",
    )

    assert already_spent_in_project(tmp_path) == 13.5
    # exclude the final phase → only preview counts
    assert already_spent_in_project(tmp_path, exclude_phase="final") == 3.5
    # empty project dir → 0.0
    assert already_spent_in_project(tmp_path / "nope") == 0.0
