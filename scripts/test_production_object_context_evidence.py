import hashlib
import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from production_object_context_evidence import validate, validate_owner


def put(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, sort_keys=True))


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def object_context_fixture(directory, expected_scale=None):
    entries = []
    for scale in ((1.0, 1.25, 1.5) if expected_scale is None else (expected_scale,)):
        case = directory / f"object-context-{int(scale * 100)}"
        case.mkdir(parents=True, exist_ok=True)
        (case / "actual-assembled-source.mov").write_bytes(b"isolated validator movie fixture")
        (case / "actual-input-reference").write_bytes(b"isolated validator reference fixture")
        output_sha, reference_sha = sha(case / "actual-assembled-source.mov"), sha(case / "actual-input-reference")
        package_id = "a" * 64
        generation = {"model": "fixture-model", "generationPackageID": package_id}
        put(case / "actual-generation-input.json", generation)
        put(case / "actual-generation-package.json", {"schema": "generation-package/v1", "id": package_id,
            "payload": {"generationInput": {"model": "fixture-model"}, "prompt": "Compiled fixture prompt",
                        "references": [{"assetID": "reference", "sourceSHA256": reference_sha}]}})
        put(case / "actual-output-receipt.json", {"projectKey": "project", "assetID": "event", "input": generation, "output": {"sha256": output_sha}})
        put(case / "actual-take.json", {"schema": "production-render-record/v1", "projectKey": "project", "shotID": "shot",
                                       "takeID": "take", "generation": {"id": "event"}, "output": {"sha256": output_sha}})
        put(case / "actual-assembly.json", {"placements": [{"shotID": "shot", "clipID": "clip", "takeID": "take", "output": {"sha256": output_sha}}]})
        put(case / "actual-assembly-host.json", {"schema": "production-assembly-host/v1", "projectKey": "project", "fps": 30,
            "media": [{"mediaID": "media", "source": {"sha256": output_sha}}], "tracks": [{"clips": [{"id": "clip", "mediaRef": "media"}]}]})
        put(case / "actual-production-plan.json", {"header": {"revision": 1}, "executionPlan": {"shots": [{"id": "shot"}]}})
        old_messages = [{"id": "actual-old-user", "role": "user", "blocks": [{"text": "isolated old user fixture"}]},
                        {"id": "actual-old-assistant", "role": "assistant", "blocks": [{"text": "isolated old assistant fixture"}]}]
        legacy = {"id": "old-session", "title": "Earlier production discussion", "messages": old_messages}
        put(case / "initial-legacy-conversation.json", legacy)
        for state in ("before", "after"):
            put(case / ("history-prefix-" + state + ".json"), old_messages)
            put(case / ("canonical-" + state + ".json"), {"canonical/script.json": "unchanged"})
        retained = [{"id": "retained", "messagesSHA256": "unchanged"}]
        put(case / "other-conversations-before.json", retained)
        put(case / "conversations-after-reopen.json", retained)
        actions = []
        def pointer(identifier):
            actions.append({"kind": "pointer", "id": identifier})
        def record(label, evidence):
            actions.append({"kind": "verified-state", "label": label, "evidence": evidence})
        for control in ("production.plan.select.shot", "production.object.clip.clip", "asset.media.original.reference",
                        "asset.media.original.reference", "production.object.shot.shot", "agent.history.select.old-session"):
            pointer(control)
        nav = {"shotID": "shot", "clipID": "clip", "mediaID": "media", "referenceAssetID": "reference",
               "generationPackageID": package_id, "modelID": "fixture-model", "outputSHA256": output_sha,
               "referenceSHA256": reference_sha, "visibleModelID": "fixture-model", "visibleSubmittedPrompt": "Compiled fixture prompt",
               "visibleGenerationReceipt": "Verified", "changedOriginalRefused": True,
               "changedOriginalError": "The original input revision changed. Relink the recorded source before opening it."}
        record("verified object navigation", nav)
        for kind in ("shot", "timeline", "source"):
            captured = {"workspace": "production" if kind == "shot" else "edit", "editingFPS": 30, "timelineFrame": 45,
                        "label": "Shot 1" if kind == "shot" else kind + " range", "target": kind}
            if kind == "shot":
                captured.update(planningShotID="shot", planningRevision=1)
                actions.append({"kind": "menu", "id": "agent.task.choose", "item": "Revise Selected Object"})
            else:
                if kind == "timeline":
                    captured.update(timelineRange={"start": 15, "end": 45}, clips=[{"clipID": "clip", "mediaRef": "media"}])
                    actions.extend([{"kind": "keyboard", "code": code} for code in (34, 31)])
                else:
                    captured.update(source={"assetID": "media", "range": {"start": 15, "end": 45}, "playheadFrame": 45,
                                            "inSeconds": 0.5, "outSeconds": 1.5})
                    pointer("source.in.media"); pointer("source.out.media")
                pointer("inspector.task.stage"); pointer("production.plan.select.shot")
            pointer("agent.task.run")
            request = {"kind": kind, "sessionID": "old-session", "turnID": "turn-" + kind,
                       "rawAppContext": "<app-context>Captured selection: " + json.dumps(captured) + "</app-context>",
                       "selection": captured, "stagedTitle": "Revise: " + captured["label"], "workspaceChangedAfterStage": kind != "shot"}
            put(case / ("request-" + kind + ".json"), request)
            record("actual captured task " + kind, request)
        pointer("agent.history.delete.old-session"); pointer("agent.history.delete.old-session")
        record("native-pointer", {"target": "button.Delete “" + legacy["title"] + "”"})
        actions.append({"kind": "text", "field": {"id": "agent.composer.input", "fontPointSize": 13 * scale}})
        history = {"sessionID": "old-session", "legacyFormatFixture": True, "oldMessageCount": 2, "continuedTurns": 3,
                   "prefixSHA256": sha(case / "history-prefix-before.json"), "deleteCancelled": True, "nativeDeleteConfirmed": True,
                   "nativeSaveReopen": True, "otherConversationsPreserved": True, "originalPackageSHA256": "original",
                   "originalPackageAfterSHA256": "original", "renderedFontPointSize": 13 * scale, "liveAgent": False}
        record("older conversation continued and deleted", history)
        (case / "native.png").write_bytes(b"\x89PNG\r\n\x1a\n" + b"isolated validator screenshot fixture" * 40)
        entry = {"interactions": actions, "screenshots": ["native.png"], "progress": "native-object-context.json",
                 "scale": scale, "viewport": [960, 640], "backingScale": 2, "liveAgent": False}
        put(case / entry["progress"], {"interactions": actions, "screenshots": entry["screenshots"], "failure": None})
        put(case / "object-context-result.json", entry)
        entries.append(entry)
    put(directory / "object-context-result.json", entries)
    return entries


class ProductionObjectContextEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = TemporaryDirectory()
        self.root = Path(self.temp.name)
        object_context_fixture(self.root)
        self.case = self.root / "object-context-100"

    def tearDown(self):
        self.temp.cleanup()

    def edit(self, mutate):
        entries = json.loads((self.root / "object-context-result.json").read_text())
        mutate(entries[0])
        entry = entries[0]
        put(self.case / entry["progress"], {"interactions": entry["interactions"], "screenshots": entry["screenshots"], "failure": None})
        put(self.case / "object-context-result.json", entry)
        put(self.root / "object-context-result.json", entries)

    def request(self, kind, mutate):
        value = json.loads((self.case / ("request-" + kind + ".json")).read_text())
        mutate(value)
        value["rawAppContext"] = "<app-context>Captured selection: " + json.dumps(value["selection"]) + "</app-context>"
        put(self.case / ("request-" + kind + ".json"), value)
        def replace(entry):
            for action in entry["interactions"]:
                if action.get("label") == "actual captured task " + kind: action["evidence"] = value
        self.edit(replace)

    def test_complete_isolated_file_validator_fixture(self):
        self.assertEqual(len(validate(self.root)), 3)

    def test_all_scales_required(self):
        entries = json.loads((self.root / "object-context-result.json").read_text()); entries.pop()
        put(self.root / "object-context-result.json", entries)
        with self.assertRaises(ValueError): validate(self.root)

    def test_actual_output_bytes_required(self):
        (self.case / "actual-assembled-source.mov").write_bytes(b"changed")
        with self.assertRaises(ValueError): validate(self.root)

    def test_actual_reference_bytes_required(self):
        (self.case / "actual-input-reference").write_bytes(b"changed")
        with self.assertRaises(ValueError): validate(self.root)

    def test_source_model_not_visible_claim_alone(self):
        value = json.loads((self.case / "actual-output-receipt.json").read_text()); value["input"]["model"] = "other"
        put(self.case / "actual-output-receipt.json", value)
        with self.assertRaises(ValueError): validate(self.root)

    def test_submitted_prompt_actual_package_required(self):
        value = json.loads((self.case / "actual-generation-package.json").read_text()); value["payload"]["prompt"] = "other"
        put(self.case / "actual-generation-package.json", value)
        with self.assertRaises(ValueError): validate(self.root)

    def test_actual_assembly_media_binding_required(self):
        value = json.loads((self.case / "actual-assembly-host.json").read_text()); value["tracks"][0]["clips"][0]["mediaRef"] = "other"
        put(self.case / "actual-assembly-host.json", value)
        with self.assertRaises(ValueError): validate(self.root)

    def test_wrong_shot_rejected(self):
        self.request("shot", lambda request: request["selection"].__setitem__("planningShotID", "other"))
        with self.assertRaises(ValueError): validate(self.root)

    def test_timeline_range_even_if_raw_request_agrees_rejected(self):
        self.request("timeline", lambda request: request["selection"]["timelineRange"].__setitem__("end", 46))
        with self.assertRaises(ValueError): validate(self.root)

    def test_source_must_not_borrow_timeline_range(self):
        self.request("source", lambda request: request["selection"].__setitem__("timelineRange", {"start": 15, "end": 45}))
        with self.assertRaises(ValueError): validate(self.root)

    def test_source_clock_not_inferred(self):
        self.request("source", lambda request: request["selection"]["source"].__setitem__("outSeconds", 2.0))
        with self.assertRaises(ValueError): validate(self.root)

    def test_title_and_payload_same_scope(self):
        self.request("timeline", lambda request: request.__setitem__("stagedTitle", "Revise: Shot 1"))
        with self.assertRaises(ValueError): validate(self.root)

    def test_different_session_rejected(self):
        self.request("timeline", lambda request: request.__setitem__("sessionID", "new-session"))
        with self.assertRaises(ValueError): validate(self.root)

    def test_actual_native_stage_required(self):
        self.edit(lambda entry: entry["interactions"].__setitem__(next(i for i, action in enumerate(entry["interactions"]) if action.get("id") == "inspector.task.stage"), {"kind": "pointer", "id": "wrong"}))
        with self.assertRaises(ValueError): validate(self.root)

    def test_native_object_link_required(self):
        self.edit(lambda entry: entry["interactions"].__setitem__(4, {"kind": "pointer", "id": "wrong"}))
        with self.assertRaises(ValueError): validate(self.root)

    def test_prefix_messages_cannot_be_replaced(self):
        put(self.case / "history-prefix-after.json", [])
        with self.assertRaises(ValueError): validate(self.root)

    def test_deleted_history_must_stay_deleted_after_reopen(self):
        value = json.loads((self.case / "conversations-after-reopen.json").read_text()); value.append({"id": "old-session"})
        put(self.case / "conversations-after-reopen.json", value)
        with self.assertRaises(ValueError): validate(self.root)

    def test_other_conversations_must_survive(self):
        put(self.case / "conversations-after-reopen.json", [])
        with self.assertRaises(ValueError): validate(self.root)

    def test_defaults_do_not_prove_actual_font(self):
        self.edit(lambda entry: next(action for action in entry["interactions"] if action.get("kind") == "text")["field"].__setitem__("fontPointSize", 19.5))
        with self.assertRaises(ValueError): validate(self.root)

    def test_driver_failure_rejected(self):
        value = json.loads((self.case / "native-object-context.json").read_text()); value["failure"] = "pointer covered"
        put(self.case / "native-object-context.json", value)
        with self.assertRaises(ValueError): validate(self.root)

    def test_missing_screenshot_rejected(self):
        (self.case / "native.png").unlink()
        with self.assertRaises((ValueError, FileNotFoundError)): validate(self.root)

    def test_owner_cannot_replace_native_evidence(self):
        with self.assertRaises(ValueError): validate_owner(self.root, {"objectContext": []})

    def test_outer_owner_runs_exactly_its_actual_scale(self):
        entries = object_context_fixture(self.root, expected_scale=1.25)
        self.assertEqual(len(validate(self.root, expected_scale=1.25)), 1)
        owner = {"viewport": {"textScale": 1.25}, "objectContext": entries}
        self.assertEqual(validate_owner(self.root, owner, expected_scale=1.25), entries)
        with self.assertRaises(ValueError): validate_owner(self.root, owner, expected_scale=1.0)
        with self.assertRaises(ValueError): validate(self.root)

    def test_nested_scale_duplication_cannot_substitute_for_outer_case(self):
        entries = json.loads((self.root / "object-context-result.json").read_text())
        with self.assertRaises(ValueError): validate_owner(self.root, {"viewport": {"textScale": 1.0}, "objectContext": entries}, expected_scale=1.0)
