from nexgen_engine.pack import discover_packs


def test_discovers_installed_musicvideo_pack():
    reg = discover_packs()
    assert "musicvideo" in [p.name for p in reg.packs]
    # the pack's contract registrations are picked up:
    assert "analysis" in reg.engine.phases
    assert reg.engine.duration_policy is not None
    assert "tempo" in reg.engine.sanity_checks


def test_mcp_list_phases_includes_core_and_pack():
    from nexgen_engine import mcp_server
    ph = mcp_server.phases()
    assert "bible" in ph       # engine core phase
    assert "analysis" in ph    # pack-contributed phase
