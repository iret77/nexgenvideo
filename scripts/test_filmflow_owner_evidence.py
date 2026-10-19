"""Synthetic oracle shapes only; these fixtures make no native, OAuth or producer claim."""
import copy
import json
from pathlib import Path
import tempfile
import unittest
import uuid

from filmflow_owner_evidence import CAPTURES, MISSING, RESOURCE, SHOT, digest, portable_dtos, validate
from test_production_cover_owner_evidence import png


def data(value): return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def fixture(output):
    folder = output / "filmflow-owner-100"; folder.mkdir()
    def write(name, value):
        target = folder / name; target.parent.mkdir(parents=True, exist_ok=True)
        raw = value if isinstance(value, bytes) else data(value); target.write_bytes(raw); return digest(raw)
    sid = "f0000000-0000-4000-8000-000000000001"
    summary = dict(projectId="fixture", title="Fixture", phase="STORYBOARD", state="DRAFT", role="OWNER", updatedAt="2026-01-01")
    version = dict(versionNumber=1, label="Draft", state="DRAFT")
    project = dict(summary, aspectRatio="16:9", sketchStyle="PENCIL", shotNumberingScheme="EU", counts=dict(scenes=1, shots=1, entities=2), activeScriptVersion=version)
    project.pop("updatedAt")
    shot = dict(shotLabel="1A.1", shotType="WS", description="A lantern crosses the empty doorway.", camera=dict(move="PAN", moveNotes="Track the harbour light"), lighting={}, staging={}, durationSeconds=400, charactersInFrame=[])
    dtos = {"get_project": project, "list_scenes": [dict(sceneNumber="1A", heading="Harbour", shotCount=1)],
        "get_shotlist": dict(project=dict(title="Fixture", shotNumberingScheme="EU", aspectRatio="16:9", sketchStyle="PENCIL"), scriptVersion=version,
            scenes=[dict(sceneNumber="1A", heading="Harbour", shots=[shot])]),
        "list_entities": [dict(name="Keeper", type="CHARACTER", aliases=[], isConfirmed=True), dict(name="Keeper", type="PROP", aliases=[], isConfirmed=False)]}
    image = png(320, 180); image_sha = write("source.png", image); image_path = "images/" + image_sha + ".png"; write("snapshot/" + image_path, image)
    responses, calls = [], [{"tool": "get_project", "stage": "held-before-response"}, {"tool": "get_project", "stage": "transport-cancelled"}]
    for tool, dto in dtos.items():
        pointers = {"get_shotlist": [SHOT + "/storyboardImageUrl"], "list_entities": ["list_entities#/0/referenceImageUrl", MISSING]}.get(tool, [])
        raw = data(dto); path = "dto/" + tool + ".json"; write("snapshot/" + path, raw)
        schema_sha = write("snapshot/schemas/" + tool + ".json", {"type": "object"})
        response = dict(tool=tool, argumentsSHA256=digest(data({"projectId": "fixture"})), toolSchemaSHA256=schema_sha,
            sourceObservationUTF8SHA256=digest(b"original-observation-" + raw), sourceObservationUTF8Count=len(raw)+21,
            sourceObservationEncoding="sdk-decoded-text-utf8",
            portablePath=path, portableDTOSHA256=digest(raw), omissions=["/unknownSecretURL"] if tool == "get_project" else [], imagePointers=pointers)
        responses.append(response)
        calls += [{"tool": tool, "sdkTextUTF8SHA256": response["sourceObservationUTF8SHA256"]}] * (2 if tool == "get_project" else 1)
    snapshot = dict(schema="ngv.filmflow-snapshot.v1", id=sid, resource=RESOURCE, startedAt="2026-01-01T00:00:00Z", finishedAt="2026-01-01T00:00:01Z",
        project=summary, noActiveScript=False, responses=responses, images=[dict(id=image_sha, sha256=image_sha, path=image_path, byteCount=len(image), width=320, height=180,
        contentType="public.png", pointers=[SHOT + "/storyboardImageUrl", "list_entities#/0/referenceImageUrl"])], missingImages=[dict(pointer=MISSING, reason="Unavailable image")])
    snapshot_sha = write("snapshot/snapshot.v1.json", snapshot)
    write("adoptions/" + sid + "/accepted.json", dict(snapshotSHA256=snapshot_sha, omittedImagePointers=[MISSING], acceptedAt="2026-01-01T00:00:02Z"))
    write("gates-before.yaml", b"brief: pending\n"); write("gates-after.yaml", b"brief: pending\n")
    write("lineage-before.json", {"unchanged": "actual-lineage-fixture"}); write("lineage-after.json", {"unchanged": "actual-lineage-fixture"})
    notes_before, notes_after = dict(id="original"), dict(id="imported", source={"path": "import/script.md"})
    for label in ("before", "undo", "restored"): write("notes-" + label + ".json", notes_before)
    for label in ("applied", "redo"):
        write("notes-" + label + ".json", notes_after); write("notes-" + label + ".md", b"Planning notes\nA lantern crosses the empty doorway.")
    identity = dict(schema="confirmed-identity-assets/v1", project="project", entries={"keeper": dict(identity_name="Prepared Harbour Keeper", role="character", sha256=image_sha)})
    write("identity-before.absent", b"absent"); write("identity-undo.json", dict(entries={}))
    for label in ("applied", "redo"): write("identity-" + label + ".json", identity)
    script_before = dict(schema="script/v1", scenes=[dict(id="scene-native", events=[dict(id="event-native", action="Original action", treatmentBeatIDs=["beat-native"])])])
    script_after = copy.deepcopy(script_before); script_after["scenes"][0]["events"][0]["action"] = shot["description"]
    for label in ("before", "undo"): write("script-" + label + ".json", script_before)
    for label in ("applied", "redo"): write("script-" + label + ".json", script_after)
    def ref(path, raw, role="test", identifier="native"):
        sha = write("adoption-outputs/" + path, raw); return dict(id=identifier, path=path, sha256=sha, role=role)
    original_image = ref("storyboard/sketches/original.png", image)
    proof = dict(schema="storyboard-sketch-proof/v1", projectID="project", shotID="shot-native", momentID="moment-native", image=original_image,
        source={"uploaded": dict(original=original_image, selectionReceiptID="native-confirmation")})
    proof_ref = ref("storyboard/sketches/proof.json", proof)
    timing_before = dict(schema="storyboard-timing/v1", timebase=dict(ticksPerSecond=30), mode="sequential", rangeStartTicks=0, rangeDurationTicks=240,
        shots=[dict(id="shot-native", moments=[dict(id="moment-native", intent="Doorway", offsetTicks=0)])])
    timing_after = copy.deepcopy(timing_before); timing_after["shots"][0]["moments"][0]["asset"] = dict(image=original_image, proof=proof_ref)
    for label in ("before", "undo"): write("timing-" + label + ".json", timing_before)
    for label in ("applied", "redo"): write("timing-" + label + ".json", timing_after)
    plan_before = dict(schema="shot-planning-draft/v1", shots=[dict(shotID="shot-native", sourceMode="generated", camera=dict(movement="static", framing={}), obligations=[])])
    plan_after = copy.deepcopy(plan_before); plan_after["shots"][0]["camera"].update(movement="pan", movementDetail="Track the harbour light")
    for label in ("before", "undo"): write("planning-" + label + ".json", plan_before)
    for label in ("applied", "redo"): write("planning-" + label + ".json", plan_after)
    receipt_kinds = [("brief", "planning-notes", [SHOT], "brief.story-source", [ref("brief/source-selections/a.v1.json", notes_after), ref("brief/source-selections/a.source.md", b"notes")]),
        ("brief", "list_entities#/0", ["image", "native-identity-confirmation"], "character:keeper", [ref("import/filmflow-adoptions/" + sid + "/identity-fixture.v1.json", identity), original_image]),
        ("script", SHOT, ["action"], "event-native", [ref("script/v2.v1.json", script_after)]),
        ("storyboard", SHOT, ["image"], "moment-native", [ref("storyboard/timing-v2.v1.json", timing_after)]),
        ("shot_planning", SHOT, ["camera.movementDetail"], "shot-native", [ref("shot-planning/v2.v1.json", plan_after)])]
    for index, (phase, source, selected, target, outputs) in enumerate(receipt_kinds):
        identifier = str(uuid.UUID(int=index + 1))
        write("adoptions/" + sid + "/" + identifier + ".json", dict(schema="ngv.filmflow-adoption.v1", id=identifier, projectID="project", phase=phase,
            mapping=dict(snapshotID=sid, snapshotSHA256=snapshot_sha, sourceObjectID=source, targetID=target, fields=selected), outputs=outputs))
    closure = {str(p.relative_to(folder / "adoption-outputs")): digest(p.read_bytes()) for p in (folder / "adoption-outputs").rglob("*") if p.is_file()}
    persisted = {}
    for source, prefix in (("snapshot", "import/filmflow/" + sid), ("adoptions", "import/filmflow-adoptions"), ("adoption-outputs", "")):
        for path in (folder / source).rglob("*"):
            if not path.is_file(): continue
            target = ((prefix + "/") if prefix else "") + str(path.relative_to(folder / source))
            for when in ("saved", "reopened"): persisted[target] = write(when + "/" + target, path.read_bytes())
    for when in ("saved", "reopened"): persisted["shot-planning/current.v1.json"] = write(when + "/shot-planning/current.v1.json", plan_after)
    changed = write("stale-source.json", b"{}")
    native = dict(interactions=[], screenshots=[], progress="filmflow-owner-100.json")
    rows = native["interactions"]
    def state(label, evidence): rows.append(dict(kind="verified-state", label=label, evidence=evidence))
    required = {"filmflow.connect": 1, "filmflow.cancel-operation": 1, "filmflow.download": 2, "filmflow.accept": 1, "filmflow.omit." + MISSING: 1,
        "filmflow.notes.apply": 1, "filmflow.identity.confirm": 1, "filmflow.identity.apply": 1, "filmflow.script.apply": 1,
        "filmflow.duration.apply": 1, "filmflow.sketch.apply": 1, "filmflow.camera.apply": 2}
    for name, count in required.items(): rows.extend(dict(kind="pointer", id=name) for _ in range(count))
    for _ in range(6): state("application-menu", dict(path=["File", "Import from FilmFlow…"], closed=True))
    state("application-menu", dict(path=["File", "Save"], closed=True))
    rows.extend(dict(kind="keyboard", code=6, characters="z", modifiers=1048576) for _ in range(8))
    rows.extend(dict(kind="keyboard", code=6, characters="Z", modifiers=1179648) for _ in range(5))
    rows.append(dict(kind="text", field=dict(id="filmflow.identity.name", actual="Prepared Harbour Keeper", expected="Prepared Harbour Keeper")))
    state("FilmFlow transport cancellation", dict(heldReads=1, cancelledReads=1, retainedCount=0))
    state("FilmFlow stale source refused", dict(message="Changed source", originalSHA256=digest(data(dtos["get_shotlist"])), changedSHA256=changed))
    for label in sorted(CAPTURES):
        name = "filmflow-owner-100-" + label + ".png"; (output / name).write_bytes(image); native["screenshots"].append(name)
    value = dict(schema="ngv.filmflow-owner.v1", scale=1, effectiveScale=1, viewport=dict(width=960, height=640), backingScale=2,
        snapshotSHA256=snapshot_sha, snapshotID=sid, liveOAuth=False, isolatedSDKTransport=True, calls=calls, native=native,
        reopenedSnapshotSHA256=snapshot_sha, offlineReadCallCountBefore=len(calls), offlineReadCallCountAfter=len(calls), adoptionOutputs=closure, persistedFiles=persisted)
    checkpoint(output, value)
    return value


def checkpoint(root, value):
    folder = root / "filmflow-owner-100"
    value["files"] = {str(p.relative_to(folder)): digest(p.read_bytes()) for p in folder.rglob("*") if p.is_file() and p.name != "result.json"}
    (folder / "result.json").write_bytes(data(value))
    (root / value["native"]["progress"]).write_bytes(data(dict(value["native"], failure=None)))


class FilmFlowEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name); self.value = fixture(self.root); self.folder = self.root / "filmflow-owner-100"
    def check(self): return validate(self.value, self.root, 1)
    def sync(self): checkpoint(self.root, self.value)
    def edit(self, name, update):
        path = self.folder / name; value = json.loads(path.read_bytes()); update(value); path.write_bytes(data(value)); self.sync()
    def write_persisted(self, name, value):
        raw = data(value)
        (self.folder / name).write_bytes(raw)
        if name.startswith("snapshot/"):
            relative = "import/filmflow/" + self.value["snapshotID"] + "/" + name.removeprefix("snapshot/")
        elif name.startswith("adoptions/"):
            relative = "import/filmflow-adoptions/" + name.removeprefix("adoptions/")
        else:
            self.assertTrue(name.startswith("adoption-outputs/"))
            relative = name.removeprefix("adoption-outputs/")
        self.assertIn(relative, self.value["persistedFiles"])
        for when in ("saved", "reopened"): (self.folder / when / relative).write_bytes(raw)
        self.value["persistedFiles"][relative] = digest(raw)
        return digest(raw)

    def detached_adoption(self, phase, update):
        self.assertTrue(self.check())
        path = next(p for p in (self.folder / "adoptions").rglob("*.json")
                    if json.loads(p.read_bytes()).get("phase") == phase)
        receipt = json.loads(path.read_bytes())
        reference = receipt["outputs"][0]
        name = "adoption-outputs/" + reference["path"]
        archive = json.loads((self.folder / name).read_bytes())
        update(archive)
        reference["sha256"] = self.write_persisted(name, archive)
        self.value["adoptionOutputs"][reference["path"]] = reference["sha256"]
        self.write_persisted(str(path.relative_to(self.folder)), receipt)
        self.sync()
        self.assertFalse(self.check())

    def test_complete_synthetic_shape(self): self.assertTrue(self.check())
    def test_real_oauth_cannot_be_claimed(self): self.value["liveOAuth"] = True; self.sync(); self.assertFalse(self.check())
    def test_snapshot_bytes_are_bound(self): (self.folder / "snapshot/dto/get_project.json").write_bytes(b"{}"); self.sync(); self.assertFalse(self.check())
    def test_unknown_signed_url_cannot_be_portable(self):
        self.assertTrue(self.check())
        dto = json.loads((self.folder / "snapshot/dto/get_project.json").read_bytes())
        dto["unknownSecretURL"] = "https://external.invalid/?token=x"
        dto_sha = self.write_persisted("snapshot/dto/get_project.json", dto)
        snapshot = json.loads((self.folder / "snapshot/snapshot.v1.json").read_bytes())
        next(row for row in snapshot["responses"] if row["tool"] == "get_project")["portableDTOSHA256"] = dto_sha
        snapshot_sha = self.write_persisted("snapshot/snapshot.v1.json", snapshot)
        for path in (self.folder / "adoptions").rglob("*.json"):
            receipt = json.loads(path.read_bytes())
            target = receipt["mapping"] if receipt.get("schema") == "ngv.filmflow-adoption.v1" else receipt
            target["snapshotSHA256"] = snapshot_sha
            self.write_persisted(str(path.relative_to(self.folder)), receipt)
        self.value["snapshotSHA256"] = self.value["reopenedSnapshotSHA256"] = snapshot_sha
        self.sync()
        with self.assertRaisesRegex(ValueError, "Unsupported or incomplete portable DTO"):
            portable_dtos(self.folder / "snapshot", snapshot)
        self.assertFalse(self.check())

    def test_storyboard_receipt_must_bind_the_applied_timing_bytes(self):
        self.detached_adoption("storyboard", lambda value: value.update(rangeDurationTicks=value["rangeDurationTicks"] + 30))

    def test_camera_receipt_must_bind_the_applied_plan_bytes(self):
        self.detached_adoption("shot_planning", lambda value: value["shots"][0]["camera"].update(movementDetail="Unapplied camera revision"))
    def test_pointer_is_required_for_each_real_mutation(self):
        self.value["native"]["interactions"] = [v for v in self.value["native"]["interactions"] if v.get("id") != "filmflow.sketch.apply"]; self.sync(); self.assertFalse(self.check())
    def test_menu_cannot_be_replaced_with_direct_present(self):
        self.value["native"]["interactions"] = [v for v in self.value["native"]["interactions"] if v.get("label") != "application-menu"]; self.sync(); self.assertFalse(self.check())
    def test_undo_cannot_be_flags_only(self):
        self.value["native"]["interactions"] = [v for v in self.value["native"]["interactions"] if v.get("characters") != "z"]; self.sync(); self.assertFalse(self.check())
    def test_producer_confirmation_is_not_native_confirmation(self):
        self.value["native"]["interactions"] = [v for v in self.value["native"]["interactions"] if v.get("id") != "filmflow.identity.confirm"]; self.sync(); self.assertFalse(self.check())
    def test_import_cannot_approve_phase(self): (self.folder / "gates-after.yaml").write_bytes(b"brief: approved\n"); self.sync(); self.assertFalse(self.check())
    def test_import_duration_cannot_change_range(self):
        self.edit("timing-applied.json", lambda value: value.update(rangeDurationTicks=12000)); self.assertFalse(self.check())
    def test_canonical_event_id_must_be_kept(self):
        self.edit("script-applied.json", lambda value: value["scenes"][0]["events"][0].update(id="1A.1")); self.assertFalse(self.check())
    def test_native_camera_choice_is_not_claimed_as_imported_provenance(self):
        for path in (self.folder / "adoptions").rglob("*.json"):
            value = json.loads(path.read_bytes())
            if value.get("phase") == "shot_planning":
                value["mapping"]["fields"] = ["camera.movement", "camera.movementDetail"]
                path.write_bytes(data(value))
                self.sync()
                self.assertFalse(self.check())
                return
        self.fail("The positive fixture has no actual camera adoption receipt")
    def test_stale_input_must_really_differ(self):
        (self.folder / "stale-source.json").write_bytes((self.folder / "snapshot/dto/get_shotlist.json").read_bytes()); self.sync(); self.assertFalse(self.check())
    def test_reopen_must_retain_exact_history(self):
        path = self.folder / "reopened/shot-planning/current.v1.json"; path.write_bytes(b"{}"); self.sync(); self.assertFalse(self.check())
    def test_live_read_during_offline_reopen_is_rejected(self): self.value["offlineReadCallCountAfter"] += 1; self.sync(); self.assertFalse(self.check())
    def test_archived_receipt_not_arbitrary_json(self):
        path = next(p for p in (self.folder / "adoptions").rglob("*.json") if p.name not in ("accepted.json",) and not p.name.startswith("identity")); path.write_bytes(b'{"fixture":true}'); self.sync(); self.assertFalse(self.check())
    def test_external_identical_bytes_are_not_local_evidence(self):
        path = self.folder / "source.png"; outside = self.root / "outside.png"; path.replace(outside); path.symlink_to(outside); self.assertFalse(self.check())
    def test_measured_scale_is_required(self): self.value["effectiveScale"] = 1.5; self.sync(); self.assertFalse(self.check())
