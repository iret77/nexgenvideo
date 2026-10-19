import copy
import hashlib
import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from retained_spatial_evidence import validate, validate_report


def put(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value))


def ref(directory, path, value=b"isolated validator fixture"):
    target = directory / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(value)
    return {"id": path, "role": "fixture", "path": path, "sha256": hashlib.sha256(value).hexdigest()}


def native(directory, name, scale, label, evidence):
    actions = [{"kind": "pointer", "id": "fixture.control"}, {"kind": "save-panel", "filename": evidence.get("export"),
                "nativeDirectoryAndFilenameTyped": True, "exactURLVerified": True}, {"kind": "verified-state", "label": label, "evidence": evidence}]
    screenshot = name + ".png"
    (directory / screenshot).write_bytes(b"isolated screenshot fixture")
    progress = name + ".json"
    put(directory / progress, {"interactions": actions, "screenshots": [screenshot], "failure": None})
    return {"interactions": actions, "screenshots": [screenshot], "progress": progress, "scale": scale,
            "viewport": [960, 640], "backingScale": 2}


def blockout_recovery_fixture(directory, entry, scale):
    name = f"blockout-recovery-{int(scale * 100)}"
    root = directory / name
    root.mkdir(exist_ok=True)
    original_bytes = (directory / f"native-blockout-plan-{int(scale * 100)}.mov.receipt.json").read_bytes()
    (root / "original-receipt.json").write_bytes(original_bytes)
    original = {"id": "original", "role": "host.native-blockout", "path": "shot-planning/native-blockouts/fixture.v1.json",
                "sha256": hashlib.sha256(original_bytes).hexdigest()}
    selected = {"shotID": "shot", "camera": {"spatialState": {"path": "state.json", "sha256": "s" * 64}, "blockingReference": original}}
    before = {"schema": "shot-planning-draft/v1", "header": {"revision": 1, "origin": "userRevision", "projectID": "fixture", "inputs": []},
              "storyboardRevision": 1, "shots": [selected, {"shotID": "other", "camera": {"blocking": ["Keep this other shot"], "spatialState": {"path": "other-state.json"}}}]}
    snapshots = {}

    def canonical(name, value):
        put(root / (name + ".json"), value)
        data = (root / (name + ".json")).read_bytes()
        (root / (name + ".version.json")).write_bytes(data)
        snapshots[name] = {"sha256": hashlib.sha256(data).hexdigest(), "currentPath": "shot-planning/current.v1.json",
                           "versionPath": f"shot-planning/v{value['header']['revision']}.v1.json"}

    canonical("before", before)
    prior = before
    (root / "missing.quarantine").write_bytes(original_bytes)
    (root / "tampered-receipt.bin").write_bytes(b"changed actual parser fixture receipt")
    for state in ("missing", "tampered"):
        canonical(state + "-snapshot", prior)
        snapshot_sha = snapshots[state + "-snapshot"]["sha256"]
        put(root / f"{state}-refusals.json", {"beforeSHA256": snapshot_sha, "afterSHA256": snapshot_sha,
                                           "staleError": "The blockout assignments changed. Reload Shot Planning before removing them.", "leaseError": "Finish the current production action before changing this plan."})
        put(root / f"{state}-damage.json", {"state": state, "path": original["path"], "expectedSHA256": original["sha256"],
            "shotID": "shot", "snapshotSHA256": snapshot_sha,
            "actualSHA256": None if state == "missing" else hashlib.sha256((root / "tampered-receipt.bin").read_bytes()).hexdigest()})
        removed = copy.deepcopy(prior)
        removed["header"]["revision"] += 1
        removed["shots"][0]["camera"].pop("blockingReference")
        undone = copy.deepcopy(prior)
        undone["header"]["revision"] = removed["header"]["revision"] + 1
        canonical(state + "-removed", removed); canonical(state + "-undo", undone)
        prior = undone
        entry["interactions"] += [
            {"kind": "verified-state", "label": "blockout recovery begin " + state, "evidence": {"state": state, "snapshotSHA256": snapshot_sha, "receiptSHA256": original["sha256"]}},
            {"kind": "pointer", "id": "shot-planning.blockout.recover"},
            {"kind": "verified-state", "label": "native-pointer", "evidence": {"target": "button.Remove all assignments"}},
            {"kind": "verified-state", "label": "blockout recovery complete " + state, "evidence": {"state": state, "snapshotSHA256": snapshot_sha,
                "removedSHA256": snapshots[state + "-removed"]["sha256"], "undoSHA256": snapshots[state + "-undo"]["sha256"]}}]
    cleared = copy.deepcopy(prior)
    cleared["header"]["revision"] += 1
    cleared["shots"][0]["camera"].pop("blockingReference")
    canonical("cleared", cleared)
    media = ref(root, "reattached.mov", b"isolated new MOV parser fixture")
    closure = root / "reattached.mov.evidence"
    output = ref(closure, "execution/blockout/ns/native-fresh/blockout.mov", (root / "reattached.mov").read_bytes())
    output["role"] = "host.plan-elevation-video"
    fresh = {"schema": "native-blockout-selection/v1", "shotID": "shot", "kind": "planElevation", "recordedAt": "fixture", "observation": "fixture",
             "output": output, "draft": ref(closure, "shot-planning/v2.v1.json"), "timing": ref(closure, "storyboard/timing/v1.json"),
             "stateReferences": [ref(closure, "state.json")]}
    put(root / "reattached-receipt.json", fresh)
    replacement = {"id": "fresh", "role": "host.native-blockout", "path": "shot-planning/native-blockouts/fresh.v1.json",
                   "sha256": hashlib.sha256((root / "reattached-receipt.json").read_bytes()).hexdigest()}
    after = copy.deepcopy(cleared)
    after["header"]["revision"] = cleared["header"]["revision"] + 1
    after["shots"][0]["camera"]["blockingReference"] = replacement
    canonical("reattached", after)
    evidence = {"directory": name, "shotID": "shot", "receiptSHA256": original["sha256"], "reattachedSHA256": replacement["sha256"],
                "canonicalSnapshots": snapshots, "reattachedOutput": {"media": "reattached.mov", "outputSHA256": media["sha256"], "durationValue": 24, "durationTimescale": 24}}
    evidence.update({flag: True for flag in ("missingReceiptRecovery", "tamperedReceiptRecovery", "explicitConfirmation",
                    "nativeSingleRemoval", "nativeReattachment", "nativeUndoAfterFileRestore", "staleSnapshotRejected", "competingLeaseRejected")})
    entry["interactions"] += [{"kind": "pointer", "id": "shot.blockout.remove"}, {"kind": "pointer", "id": "shot.blockout.plan"},
                              {"kind": "verified-state", "label": "native blockout recovery", "evidence": evidence}]
    put(directory / entry["progress"], {"interactions": entry["interactions"], "screenshots": entry["screenshots"], "failure": None})


def fixture(directory):
    for imported in (False, True):
        entries = []
        kind = "import" if imported else "plan"
        for scale in (1.0, 1.25, 1.5):
            name = f"native-blockout-{kind}-{int(scale * 100)}.mov"
            media = ref(directory, name)
            ref(directory, name.replace(".mov", "-export.mov"))
            closure = directory / (name + ".evidence")
            output = ref(closure, "execution/blockout/ns/native-owner/blockout.mov")
            output["role"] = "core.shot-blockout-video" if imported else "host.plan-elevation-video"
            receipt = {"schema": "native-blockout-selection/v1", "shotID": "shot", "kind": "importedGeometry" if imported else "planElevation",
                       "recordedAt": "fixture", "observation": "fixture", "output": output,
                       "draft": ref(closure, "shot-planning/v1.v1.json"), "timing": ref(closure, "storyboard/timing/v1.json"),
                       "stateReferences": [ref(closure, "state.json")]}
            if imported:
                receipt.update(original=ref(closure, "execution/blockout/ns/native-owner/original.mov"), originalName="Original.mov",
                               sourceStartValue=0, sourceDurationValue=24, sourceTimescale=24, sourceDurationTimescale=24)
            put(directory / (name + ".receipt.json"), receipt)
            fields = {"media": name, "kind": receipt["kind"], "shotID": "shot", "outputSHA256": media["sha256"],
                      "receiptSHA256": hashlib.sha256((directory / (name + ".receipt.json")).read_bytes()).hexdigest(),
                      "appearanceRejected": True, "nativeUndoRedo": True, "nativeFileExport": True, "export": name.replace(".mov", "-export.mov"), "durationValue": 24, "durationTimescale": 24}
            entry = native(directory, name, scale, "native retained blockout", fields)
            if not imported:
                blockout_recovery_fixture(directory, entry, scale)
            entries.append(entry)
        put(directory / f"native-blockout-{kind}-result.json", entries)
    source = ref(directory, "native-owner-panorama.png")
    entries = []
    for scale in (1.0, 1.25, 1.5):
        prefix = f"native-panorama-{int(scale * 100)}-"
        views = []
        for name, yaw, pitch, fov in [("wide_front", 0, -5, 75), ("wide_right", 90, -5, 75),
                                       ("wide_back", 180, -5, 75), ("wide_left", -90, -5, 75), ("owner_reverse", 180, 0, 60)]:
            image = ref(directory, prefix + name + ".png")
            image["path"] = "bible/ns/native-panorama-owner/" + name + ".png"
            views.append({"geometry": {"name": name, "yaw": yaw, "pitch": pitch, "fov": fov}, "image": image})
        panorama = ref(directory, prefix + "panorama.png")
        panorama["path"] = "bible/ns/native-panorama-owner/panorama.png"
        receipt_path = "bible/native-panorama-selections/owner.v1.json"
        receipt_file = directory / (prefix + "receipt.v1.json")
        put(receipt_file, {"schema": "native-panorama-selection/v1", "projectID": "fixture", "locationID": "room", "panorama": panorama,
                           "recordedAt": "fixture", "views": views})
        receipt_hash = hashlib.sha256(receipt_file.read_bytes()).hexdigest()
        appearance = ref(directory, prefix + "appearance-front.png")
        sheet = {"view": "front", "path": "bible/ns/appearance.png", "sha256": appearance["sha256"], "copy": appearance["path"]}
        for state in ("before", "after", "removed"):
            location = {"id": "room", "sheets": {"front": sheet["path"]}, "attributes": {}, "scene3d": {}}
            if state == "after":
                location["attributes"] = {"core.native-panorama-receipt": receipt_path, "core.native-panorama-receipt-sha256": receipt_hash}
                location["scene3d"] = {"panorama": panorama["path"], "povs": [view["geometry"] for view in views], "provider": "native-import"}
            put(directory / (prefix + "bible-" + state + ".json"), {"project": "fixture", "locations": [location]})
        fields = {"panoramaSHA256": source["sha256"], "receiptSHA256": receipt_hash, "receiptPath": receipt_path,
                  "viewCount": 5, "appearanceSheets": [sheet], "renderedFontPointSize": 13 * scale,
                  "invalidAspectRejected": True, "appearanceRejected": True, "nativeRemoval": True, "removalUndo": True,
                  "missingReceiptRecovery": True, "tamperedReceiptRecovery": True, "recoveryUndoAfterRestoringOriginalBytes": True,
                  "appearanceSheetsPreserved": True, "nativeUndoRedo": True, "bibleChanged": True, "locationID": "room"}
        entry = native(directory, prefix + "driver", scale, "native panorama selection", fields)
        entry["interactions"] += [{"kind": "pointer", "id": control} for control in
                                  ["bible.panorama.remove", "bible.panorama.remove-invalid", "bible.panorama.remove-invalid"]]
        case = directory / f"panorama-batch-{int(scale * 100)}"
        first_receipt = json.loads(receipt_file.read_text())
        first_location = json.loads((directory / (prefix + "bible-after.json")).read_text())["locations"][0]
        second_receipt = copy.deepcopy(first_receipt)
        second_receipt["locationID"] = "second"
        second_receipt["panorama"]["path"] = "bible/ns/native-panorama-second/source.panorama"
        second_receipt["views"][-1]["geometry"] = {"name": "panorama", "yaw": 0, "pitch": 0, "fov": 60}
        for view in second_receipt["views"]:
            view["image"]["path"] = "bible/ns/native-panorama-second/" + view["geometry"]["name"] + ".png"
        (case / "second-source.panorama").parent.mkdir(parents=True, exist_ok=True)
        (case / "second-source.panorama").write_bytes((directory / (prefix + "panorama.png")).read_bytes())
        for index, view in enumerate(second_receipt["views"]):
            source_name = views[index]["geometry"]["name"]
            (case / ("second-view-" + view["geometry"]["name"] + ".png")).write_bytes((directory / (prefix + source_name + ".png")).read_bytes())
        put(case / "receipt-0.json", first_receipt); put(case / "receipt-1.json", second_receipt)
        second_location = {"id": "second", "sheets": {"owner_appearance": "bible/ns/second-appearance.png"}, "reference_images": ["production_design/refs/lighting.png"],
            "scene3d": {"panorama": second_receipt["panorama"]["path"], "povs": [view["geometry"] for view in second_receipt["views"]], "provider": "native-import"},
            "attributes": {"core.native-panorama-receipt": "bible/native-panorama-selections/second.v1.json",
                           "core.native-panorama-receipt-sha256": hashlib.sha256((case / "receipt-1.json").read_bytes()).hexdigest()}}
        selected = {"project": "fixture", "locations": [first_location, second_location]}
        put(case / "bible-selected.json", selected); put(case / "bible-after-undo.json", selected)
        removed = copy.deepcopy(selected)
        for location in removed["locations"]:
            location["scene3d"] = {"panorama": "", "povs": [], "provider": ""}; location["attributes"] = {}
        put(case / "bible-removed.json", removed); put(case / "bible-after-blocked-undo.json", removed)
        initial = {"project": "fixture", "locations": [copy.deepcopy(first_location)]}
        if scale != 1.0:
            initial["locations"].append(copy.deepcopy(removed["locations"][1]))
        put(case / "bible-initial.json", initial)
        put(directory / (prefix + "bible-after.json"), initial)
        put(case / "bible-negative-before.yaml", initial)
        snapshots = {}
        for state, value in (("selected", selected), ("removed", removed), ("after-undo", selected), ("before-blocked-undo", removed), ("after-blocked-undo", removed)):
            name = "bible-" + state + ".yaml"
            put(case / name, value)
            snapshots[state] = {"file": name, "sha256": hashlib.sha256((case / name).read_bytes()).hexdigest()}
        for attempt in (1, 2):
            damage = [{"path": location["attributes"]["core.native-panorama-receipt"],
                       "expectedSHA256": location["attributes"]["core.native-panorama-receipt-sha256"],
                       "exists": index == 1, "actualSHA256": "changed" if index == 1 else None,
                       "state": "tampered" if index == 1 else "missing"} for index, location in enumerate(selected["locations"])]
            put(case / f"damage-{attempt}.json", damage)
            entry["interactions"].append({"kind": "verified-state", "label": f"actual invalid panorama list {attempt}", "evidence": {"visibleLocationIDs": "room,second"}})
            entry["interactions"].append({"kind": "pointer", "id": "bible.panorama.remove-invalid"})
            entry["interactions"].append({"kind": "verified-state", "label": "panorama removal undo ready " + str(attempt), "evidence": {
                "historyInitiallyEmpty": True, "canUndo": True, "menuEnabled": True,
                "managerOwned": True, "firstResponderIsTextEditor": False,
                "actionName": "Remove Invalid Panorama Assignments", "menuTitle": "Undo Remove Invalid Panorama Assignments"}})
            baseline = "panorama successful undo feedback baseline" if attempt == 1 else "panorama undo toast baseline"
            entry["interactions"].append({"kind": "verified-state", "label": baseline, "evidence": {"empty": True}})
            entry["interactions"].append({"kind": "keyboard", "code": 6, "characters": "z", "modifiers": 1 << 20})
            if attempt == 1:
                entry["interactions"].append({"kind": "verified-state", "label": "panorama semantic undo restored", "evidence": {
                    "semanticBibleRestored": True, "canRedo": True, "managerOwned": True, "feedbackEmpty": True, "phaseIdle": True,
                    "redoActionName": "Remove Invalid Panorama Assignments"}})
            else:
                entry["interactions"].append({"kind": "verified-state", "label": "panorama undo surface", "evidence": {
                    "workspace": "production", "feedback": "production.feedback", "message": "The panorama assignment is missing or changed."}})
                entry["interactions"].append({"kind": "verified-state", "label": "production feedback bounded scrolling", "evidence": {
                    "uiStateFixture": True, "maximumHeight": 240, "viewport": [10, 10, 600, 240],
                    "content": [10, 10, 600, 1200], "dismiss": [620, 10, 100, 30], "before": [0, 0], "after": [0, 100]}})
                for suffix in ("production-feedback-long-before-scroll", "production-feedback-long-after-scroll"):
                    screenshot = prefix + suffix + ".png"
                    (directory / screenshot).write_bytes(b"\x89PNG\r\n\x1a\n" + b"isolated layout screenshot fixture")
                    entry["screenshots"].append(screenshot)
                entry["interactions"].append({"kind": "pointer", "id": "production.feedback.dismiss"})
        for name in ("panorama-alias", "copied-pov", "character-sheet"):
            path = "copied-pov.png" if name in ("copied-pov", "character-sheet") else first_receipt["panorama"]["path"]
            arguments = {"characters": [{"sheets": [{"view": "front", "path": path}]}]} if name == "character-sheet" else {"locations": [{"id": "room", "sheets": [{"view": "negative_alias", "path": path}]}]}
            message = "A panorama geometry anchor cannot supply appearance, style or identity. Create a separate approved appearance sheet from this view."
            input_copy = "negative-input-" + name + ".bin"
            original = prefix + ("wide_front.png" if name in ("copied-pov", "character-sheet") else "panorama.png")
            (case / input_copy).write_bytes((directory / original).read_bytes())
            after_copy = "bible-negative-after-" + name + ".yaml"
            put(case / after_copy, initial)
            negative = {"case": name, "path": path, "sha256": hashlib.sha256((case / input_copy).read_bytes()).hexdigest(),
                "arguments": arguments, "isError": True, "error": message, "inputCopy": input_copy,
                "beforeCopy": "bible-negative-before.yaml", "afterCopy": after_copy,
                "bibleSHA256Before": hashlib.sha256((case / "bible-negative-before.yaml").read_bytes()).hexdigest(),
                "bibleSHA256After": hashlib.sha256((case / after_copy).read_bytes()).hexdigest()}
            put(case / (name + ".json"), negative)
            entry["interactions"].append({"kind": "verified-state", "label": "actual panorama sheet refusal " + name, "evidence": {"error": message, "canonicalUnchanged": True}})
        entry["interactions"].append({"kind": "verified-state", "label": "native panorama batch recovery", "evidence": {
            "directory": case.name, "locationIDs": ["room", "second"], "invalidCount": 2, "missingAndTampered": True,
            "subsetRefused": True, "oneUndoRestoredBoth": True, "brokenUndoRefusedVisibly": True, "noncollidingPanoramaView": True,
            "initialSecondLocationFixture": scale == 1.0, "selectedSourceSHA256": first_receipt["panorama"]["sha256"],
            "canonicalSnapshots": snapshots, "undoError": "The panorama assignment is missing or changed."}})
        entry["interactions"].append({"kind": "text", "field": {"id": "bible.panorama.fov", "fontPointSize": 13 * scale}})
        put(directory / entry["progress"], {"interactions": entry["interactions"], "screenshots": entry["screenshots"], "failure": None})
        entries.append(entry)
    put(directory / "native-panorama-result.json", entries)
    put(directory / "result.json", {"productionSpatial": {"nativePlanUI": json.loads((directory / "native-blockout-plan-result.json").read_text()),
        "nativeBlockoutImportUI": json.loads((directory / "native-blockout-import-result.json").read_text()), "nativePanoramaUI": entries}})


class RetainedSpatialEvidenceTests(unittest.TestCase):
    def update_recovery(self, change):
        path = self.root / "native-blockout-plan-result.json"
        entries = json.loads(path.read_text())
        entry = entries[0]
        evidence = next(action["evidence"] for action in entry["interactions"] if action.get("label") == "native blockout recovery")
        change(entry, evidence)
        put(path, entries)
        put(self.root / entry["progress"], {"interactions": entry["interactions"], "screenshots": entry["screenshots"], "failure": None})

    def change_canonical(self, name, change):
        root = self.root / "blockout-recovery-100"
        path = root / (name + ".json")
        value = json.loads(path.read_text())
        change(value)
        put(path, value)
        data = path.read_bytes()
        (root / (name + ".version.json")).write_bytes(data)
        sha = hashlib.sha256(data).hexdigest()

        def update(entry, evidence):
            evidence["canonicalSnapshots"][name]["sha256"] = sha
            evidence["canonicalSnapshots"][name]["versionPath"] = f"shot-planning/v{value['header']['revision']}.v1.json"
            for state in ("missing", "tampered"):
                if name == state + "-removed":
                    next(action["evidence"] for action in entry["interactions"] if action.get("label") == "blockout recovery complete " + state)["removedSHA256"] = sha
        self.update_recovery(update)

    def test_recovery_cannot_drop_confirmed_poses(self):
        self.change_canonical("missing-removed", lambda value: value["shots"][0]["camera"].pop("spatialState"))
        with self.assertRaises(ValueError):
            validate(self.root)

    def test_single_removal_cannot_change_another_shot(self):
        self.change_canonical("cleared", lambda value: value["shots"][1]["camera"].update(blocking=["changed other shot"]))
        with self.assertRaises(ValueError):
            validate(self.root)

    def test_single_removal_requires_exactly_next_revision(self):
        self.change_canonical("cleared", lambda value: value["header"].update(revision=12))
        with self.assertRaises(ValueError):
            validate(self.root)

    def test_mirror_and_current_must_have_same_exact_bytes(self):
        path = self.root / "blockout-recovery-100/missing-undo.version.json"
        path.write_bytes(path.read_bytes() + b" ")
        with self.assertRaises(ValueError):
            validate(self.root)

    def test_damage_snapshot_must_join_before_and_prior_undo(self):
        self.change_canonical("tampered-snapshot", lambda value: value["shots"][0]["camera"].update(blocking=["another snapshot"]))
        with self.assertRaises(ValueError):
            validate(self.root)

    def test_each_damage_requires_its_own_recovery_pointer(self):
        def update(entry, evidence):
            index = next(i for i, action in enumerate(entry["interactions"]) if action.get("id") == "shot-planning.blockout.recover")
            entry["interactions"].pop(index)
        self.update_recovery(update)
        with self.assertRaises(ValueError):
            validate(self.root)

    def test_confirmations_cannot_move_outside_their_damage_case(self):
        def update(entry, evidence):
            index = next(i for i, action in enumerate(entry["interactions"]) if action.get("label") == "native-pointer")
            entry["interactions"].append(entry["interactions"].pop(index))
        self.update_recovery(update)
        with self.assertRaises(ValueError):
            validate(self.root)

    def test_reattachment_requires_output_movie_and_source_bytes(self):
        (self.root / "blockout-recovery-100/reattached.mov.evidence/state.json").write_bytes(b"changed state")
        with self.assertRaises(ValueError):
            validate(self.root)

    def test_reattachment_rejects_changed_movie_bytes(self):
        (self.root / "blockout-recovery-100/reattached.mov").write_bytes(b"changed movie")
        with self.assertRaises(ValueError):
            validate(self.root)

    def test_reattachment_rejects_nonreceipt_json_even_with_matching_hashes(self):
        root = self.root / "blockout-recovery-100"
        put(root / "reattached-receipt.json", {"fixture": "not a native receipt"})
        sha = hashlib.sha256((root / "reattached-receipt.json").read_bytes()).hexdigest()
        self.change_canonical("reattached", lambda value: value["shots"][0]["camera"]["blockingReference"].update(sha256=sha))
        self.update_recovery(lambda entry, evidence: evidence.update(reattachedSHA256=sha))
        with self.assertRaises(ValueError):
            validate(self.root)

    def test_recovery_requires_native_confirmation_events(self):
        path = self.root / "native-blockout-plan-result.json"
        value = json.loads(path.read_text())
        value[0]["interactions"] = [event for event in value[0]["interactions"] if event.get("label") != "native-pointer"]
        put(path, value)
        progress = self.root / value[0]["progress"]
        original = json.loads(progress.read_text())
        original["interactions"] = value[0]["interactions"]
        put(progress, original)
        with self.assertRaises(ValueError):
            validate(self.root)

    def test_recovery_reattachment_must_have_fresh_actual_receipt(self):
        path = self.root / "blockout-recovery-100/reattached.json"
        value = json.loads(path.read_text())
        before = json.loads((path.parent / "before.json").read_text())
        value["shots"][0]["camera"]["blockingReference"] = before["shots"][0]["camera"]["blockingReference"]
        put(path, value)
        with self.assertRaises(ValueError):
            validate(self.root)

    def setUp(self):
        self.temp = TemporaryDirectory()
        self.root = Path(self.temp.name)
        fixture(self.root)

    def tearDown(self):
        self.temp.cleanup()

    def test_complete_isolated_validator_fixture(self):
        self.assertEqual(set(validate(self.root)), {"plan", "import", "panorama"})

    def test_changed_movie_rejected(self):
        (self.root / "native-blockout-import-100.mov").write_bytes(b"changed")
        with self.assertRaises(ValueError):
            validate(self.root)

    def test_missing_state_source_rejected(self):
        (self.root / "native-blockout-plan-100.mov.evidence/state.json").unlink()
        with self.assertRaises(ValueError):
            validate(self.root)

    def test_changed_receipt_rejected(self):
        (self.root / "native-blockout-plan-100.mov.receipt.json").write_text("{}")
        with self.assertRaises(ValueError):
            validate(self.root)

    def test_actual_scale_required(self):
        path = self.root / "native-blockout-plan-result.json"
        data = json.loads(path.read_text())
        data[0]["scale"] = 1.5
        put(path, data)
        with self.assertRaises(ValueError):
            validate(self.root)

    def test_failed_driver_rejected(self):
        path = self.root / "native-blockout-plan-100.mov.json"
        data = json.loads(path.read_text())
        data["failure"] = "focus failed"
        put(path, data)
        with self.assertRaises(ValueError):
            validate(self.root)

    def test_panorama_camera_change_rejected(self):
        path = self.root / "native-panorama-100-receipt.v1.json"
        data = json.loads(path.read_text())
        data["views"][-1]["geometry"]["yaw"] = 0
        put(path, data)
        with self.assertRaises(ValueError):
            validate(self.root)

    def test_changed_pov_bytes_rejected(self):
        (self.root / "native-panorama-100-owner_reverse.png").write_bytes(b"different viewpoint")
        with self.assertRaises(ValueError):
            validate(self.root)

    def edit_panorama(self, change):
        path = self.root / "native-panorama-result.json"
        data = json.loads(path.read_text())
        change(data)
        put(path, data)
        for entry in data:
            put(self.root / entry["progress"], {"interactions": entry["interactions"], "screenshots": entry["screenshots"], "failure": None})

    def test_panorama_requires_every_scale(self):
        self.edit_panorama(lambda entries: entries.pop())
        with self.assertRaises(ValueError): validate(self.root)

    def test_panorama_requires_each_observed_action(self):
        for flag in ("invalidAspectRejected", "appearanceSheetsPreserved", "bibleChanged", "nativeUndoRedo", "nativeRemoval", "removalUndo", "missingReceiptRecovery", "tamperedReceiptRecovery", "recoveryUndoAfterRestoringOriginalBytes", "appearanceRejected"):
            with self.subTest(flag=flag):
                fixture(self.root)
                self.edit_panorama(lambda entries: entries[0]["interactions"][2]["evidence"].__setitem__(flag, False))
                with self.assertRaises(ValueError): validate(self.root)

    def test_panorama_foreign_location_rejected(self):
        self.edit_panorama(lambda entries: entries[0]["interactions"][2]["evidence"].__setitem__("locationID", "other"))
        with self.assertRaises(ValueError): validate(self.root)

    def test_panorama_missing_location_rejected(self):
        self.edit_panorama(lambda entries: entries[0]["interactions"][2]["evidence"].pop("locationID"))
        with self.assertRaises(ValueError): validate(self.root)

    def test_panorama_receipt_bytes_rejected(self):
        path = self.root / "native-panorama-100-receipt.v1.json"
        value = json.loads(path.read_text()); value["recordedAt"] = "changed"; put(path, value)
        with self.assertRaises(ValueError): validate(self.root)

    def test_panorama_requires_unique_receipt(self):
        path = self.root / "native-panorama-100-receipt.v1.json"
        (self.root / "native-panorama-100-extra.v1.json").write_bytes(path.read_bytes())
        with self.assertRaises(ValueError): validate(self.root)

    def test_panorama_requires_receipt(self):
        (self.root / "native-panorama-100-receipt.v1.json").unlink()
        with self.assertRaises(ValueError): validate(self.root)

    def test_panorama_in_project_bytes_required(self):
        (self.root / "native-panorama-100-panorama.png").write_bytes(b"changed")
        with self.assertRaises(ValueError): validate(self.root)

    def test_panorama_cardinal_geometry_not_just_hash(self):
        path = self.root / "native-panorama-100-receipt.v1.json"
        value = json.loads(path.read_text()); value["views"][0]["geometry"]["yaw"] = 12; put(path, value)
        new_hash = hashlib.sha256(path.read_bytes()).hexdigest()
        self.edit_panorama(lambda entries: entries[0]["interactions"][2]["evidence"].__setitem__("receiptSHA256", new_hash))
        with self.assertRaises(ValueError): validate(self.root)

    def test_panorama_bible_pointer_hash_required(self):
        path = self.root / "native-panorama-100-bible-after.json"
        value = json.loads(path.read_text()); value["locations"][0]["attributes"]["core.native-panorama-receipt-sha256"] = "foreign"; put(path, value)
        with self.assertRaises(ValueError): validate(self.root)

    def test_panorama_appearance_cannot_be_empty(self):
        self.edit_panorama(lambda entries: entries[0]["interactions"][2]["evidence"].__setitem__("appearanceSheets", []))
        with self.assertRaises(ValueError): validate(self.root)

    def test_panorama_rendered_font_not_defaults(self):
        self.edit_panorama(lambda entries: entries[0]["interactions"][-1]["field"].__setitem__("fontPointSize", 13 * 1.5))
        with self.assertRaises(ValueError): validate(self.root)

    def test_cli_binds_actual_result(self):
        value = json.loads((self.root / "result.json").read_text()); value["productionSpatial"]["nativePanoramaUI"] = []
        put(self.root / "result.json", value)
        with self.assertRaises(ValueError): validate_report(self.root)

    def test_panorama_actual_removal_pointer_required(self):
        self.edit_panorama(lambda entries: entries[0]["interactions"].__setitem__(4, {"kind": "pointer", "id": "wrong.control"}))
        with self.assertRaises(ValueError): validate(self.root)

    def test_panorama_preserved_appearance_bytes_required(self):
        (self.root / "native-panorama-100-appearance-front.png").write_bytes(b"changed")
        with self.assertRaises(ValueError): validate(self.root)

    def test_panorama_removed_bible_cannot_keep_receipt(self):
        path = self.root / "native-panorama-100-bible-removed.json"
        value = json.loads(path.read_text()); value["locations"][0]["attributes"]["core.native-panorama-receipt"] = "retained"; put(path, value)
        with self.assertRaises(ValueError): validate(self.root)

    def test_batch_requires_two_independent_bound_receipts(self):
        path = self.root / "panorama-batch-100/receipt-1.json"
        value = json.loads(path.read_text()); value["locationID"] = "room"; put(path, value)
        with self.assertRaises(ValueError): validate(self.root)

    def test_batch_removal_preserves_all_appearance_fields(self):
        path = self.root / "panorama-batch-100/bible-removed.json"
        value = json.loads(path.read_text()); value["locations"][0]["sheets"] = {}; put(path, value)
        with self.assertRaises(ValueError): validate(self.root)

    def test_batch_undo_restores_both_not_only_selected_location(self):
        path = self.root / "panorama-batch-100/bible-after-undo.json"
        value = json.loads(path.read_text()); value["locations"][1]["scene3d"] = {}; put(path, value)
        with self.assertRaises(ValueError): validate(self.root)

    def test_broken_undo_cannot_reintroduce_invalid_assignment(self):
        path = self.root / "panorama-batch-100/bible-after-blocked-undo.json"
        value = json.loads(path.read_text()); value["locations"][1]["attributes"] = {"core.native-panorama-receipt": "bad"}; put(path, value)
        with self.assertRaises(ValueError): validate(self.root)

    def test_both_damaged_bytes_must_be_observed(self):
        path = self.root / "panorama-batch-100/damage-1.json"
        value = json.loads(path.read_text()); value[1]["actualSHA256"] = value[1]["expectedSHA256"]; put(path, value)
        with self.assertRaises(ValueError): validate(self.root)

    def test_copied_pov_refusal_requires_actual_byte_identity(self):
        path = self.root / "panorama-batch-100/copied-pov.json"
        value = json.loads(path.read_text()); value["sha256"] = "different"; put(path, value)
        with self.assertRaises(ValueError): validate(self.root)

    def test_sheet_alias_must_reach_actual_tool_payload(self):
        path = self.root / "panorama-batch-100/panorama-alias.json"
        value = json.loads(path.read_text()); value["arguments"]["locations"][0]["sheets"] = []; put(path, value)
        with self.assertRaises(ValueError): validate(self.root)

    def test_source_and_view_cannot_still_share_filename(self):
        case = self.root / "panorama-batch-100"
        path = case / "receipt-1.json"
        value = json.loads(path.read_text())
        value["views"][-1]["image"]["path"] = value["panorama"]["path"]
        put(path, value)
        receipt_hash = hashlib.sha256(path.read_bytes()).hexdigest()
        for state in ("selected", "after-undo"):
            path = case / ("bible-" + state + ".json")
            bible = json.loads(path.read_text())
            bible["locations"][1]["attributes"]["core.native-panorama-receipt-sha256"] = receipt_hash
            put(path, bible); put(case / ("bible-" + state + ".yaml"), bible)
        def rebind(item):
            for state in ("selected", "after-undo"):
                item["canonicalSnapshots"][state]["sha256"] = hashlib.sha256((case / ("bible-" + state + ".yaml")).read_bytes()).hexdigest()
        self.edit_batch_observation("native panorama batch recovery", rebind)
        for attempt in (1, 2):
            path = case / f"damage-{attempt}.json"
            damage = json.loads(path.read_text()); damage[1]["expectedSHA256"] = receipt_hash; put(path, damage)
        with self.assertRaisesRegex(ValueError, "source/view filename collision"): validate(self.root)

    def edit_batch_observation(self, label, change):
        def edit(entries):
            item = next(action for action in entries[0]["interactions"] if action.get("label") == label)
            change(item["evidence"])
        self.edit_panorama(edit)

    def test_registration_warning_cannot_pass_as_undo_refusal(self):
        self.edit_batch_observation("native panorama batch recovery", lambda item: item.__setitem__("undoError",
            "Bible updated; Undo is unavailable. The panorama assignment is missing or changed."))
        with self.assertRaises(ValueError): validate(self.root)

    def test_batch_flags_are_each_required(self):
        for flag in ("missingAndTampered", "subsetRefused", "oneUndoRestoredBoth", "brokenUndoRefusedVisibly", "noncollidingPanoramaView"):
            with self.subTest(flag=flag):
                fixture(self.root)
                self.edit_batch_observation("native panorama batch recovery", lambda item: item.__setitem__(flag, False))
                with self.assertRaises(ValueError): validate(self.root)

    def test_actual_undo_menu_readiness_required(self):
        for flag in ("historyInitiallyEmpty", "canUndo", "menuEnabled"):
            with self.subTest(flag=flag):
                fixture(self.root)
                self.edit_batch_observation("panorama removal undo ready 2", lambda item: item.__setitem__(flag, False))
                with self.assertRaises(ValueError): validate(self.root)

    def test_wrong_undo_menu_action_rejected(self):
        self.edit_batch_observation("panorama removal undo ready 2", lambda item: item.__setitem__("actionName", "Assign Panorama"))
        with self.assertRaises(ValueError): validate(self.root)

    def test_prior_toast_cannot_supply_refusal(self):
        self.edit_batch_observation("panorama undo toast baseline", lambda item: item.__setitem__("empty", False))
        with self.assertRaises(ValueError): validate(self.root)

    def test_keyboard_must_follow_actual_registration(self):
        def edit(entries):
            actions = entries[0]["interactions"]
            index = next(i for i, action in enumerate(actions) if action.get("label") == "panorama removal undo ready 2")
            key = next(action for action in actions[index + 1:] if action.get("kind") == "keyboard")
            key["modifiers"] = 0
        self.edit_panorama(edit)
        with self.assertRaises(ValueError): validate(self.root)

    def test_canonical_unchanged_hash_requires_actual_bytes(self):
        path = self.root / "panorama-batch-100/panorama-alias.json"
        value = json.loads(path.read_text())
        value["bibleSHA256Before"] = value["bibleSHA256After"] = "unchanged"
        put(path, value)
        with self.assertRaises(ValueError): validate(self.root)

    def test_negative_after_bytes_cannot_change(self):
        (self.root / "panorama-batch-100/bible-negative-after-copied-pov.yaml").write_bytes(b"changed actual Bible")
        with self.assertRaises(ValueError): validate(self.root)

    def test_submitted_negative_bytes_must_match_archived_input(self):
        (self.root / "panorama-batch-100/negative-input-character-sheet.bin").write_bytes(b"other image")
        with self.assertRaises(ValueError): validate(self.root)

    def test_broken_undo_cannot_change_raw_canonical_bytes(self):
        (self.root / "panorama-batch-100/bible-after-blocked-undo.yaml").write_bytes(b"other bytes")
        with self.assertRaises(ValueError): validate(self.root)

    def test_second_location_creation_is_observed_per_scale(self):
        self.edit_batch_observation("native panorama batch recovery", lambda item: item.__setitem__("initialSecondLocationFixture", False))
        with self.assertRaises(ValueError): validate(self.root)

    def test_malformed_sheet_payload_raises_value_error(self):
        path = self.root / "panorama-batch-100/character-sheet.json"
        value = json.loads(path.read_text()); value["arguments"]["characters"][0]["sheets"] = {"front": value["path"]}
        put(path, value)
        with self.assertRaises(ValueError): validate(self.root)

    def test_second_view_requires_actual_archived_pixels(self):
        (self.root / "panorama-batch-100/second-view-panorama.png").write_bytes(b"other viewpoint")
        with self.assertRaises(ValueError): validate(self.root)

    def test_undo_refusal_must_remain_in_production(self):
        self.edit_batch_observation("panorama undo surface", lambda item: item.__setitem__("workspace", "media"))
        with self.assertRaises(ValueError): validate(self.root)

    def test_undo_error_requires_actual_dismiss_control(self):
        def edit(entries):
            action = next(action for action in entries[0]["interactions"] if action.get("id") == "production.feedback.dismiss")
            action["id"] = "wrong.control"
        self.edit_panorama(edit)
        with self.assertRaises(ValueError): validate(self.root)
