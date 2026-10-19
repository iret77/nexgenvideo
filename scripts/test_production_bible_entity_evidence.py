import base64
import hashlib
import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

import yaml

from production_bible_entity_evidence import validate


def put(root, name, value):
    (root / name).write_text(json.dumps(value, sort_keys=True))


def fixture(root, project_key="project"):
    image = b"\x89PNG\r\n\x1a\n" + b"validator-only image bytes" * 50
    (root / "bible-typed-reference.png").write_bytes(image)
    image_sha = hashlib.sha256(image).hexdigest()
    look = {"style": "Controlled reference", "lighting_anchor": "soft light"}
    before = dict(look=look, locations=[dict(id="existing_location", name="Existing location")], notes="Existing notes")
    for field in ("characters", "ensembles", "props"):
        before[field] = [dict(id="existing_" + field, name="Existing " + field)]
    bible, entities, pointers, screenshots = json.loads(json.dumps(before)), [], [], []
    for kind, field, identifier, view in (("character", "characters", "owner_performer", "front"),
                                         ("ensemble", "ensembles", "owner_ensemble", "group_wide"),
                                         ("prop", "props", "owner_prop", "front")):
        path = "bible/namespace/typed-" + identifier + ".png"
        value = dict(id=identifier, sheets={view: path}, reference_images=[path])
        if kind == "ensemble":
            value["member_count"] = 2
        bible[field].append(value)
        retained = "bible-typed-source-" + kind + ".png"
        (root / retained).write_bytes(image)
        entities.append(dict(retainedImage=retained, kind=kind, id=identifier, view=view, path=path,
                             sha256=image_sha, inspectorOpenedFromHidden=True))
        pointers += [dict(kind="pointer", id="bible.entity.select." + kind + "." + identifier),
                     dict(kind="pointer", id="bible.sheet." + kind + "." + identifier + "." + view)]
        name = "fixture-typed-bible-" + kind + ".png"
        (root / name).write_bytes(image)
        screenshots.append(name)
    raw = yaml.safe_dump(bible).encode()
    (root / "bible-typed-before.yaml").write_text(yaml.safe_dump(before))
    for name in ("bible-typed-source.yaml", "bible-typed-pre-save.yaml", "bible-typed-reopened.yaml"):
        (root / name).write_bytes(raw)
    evidence = dict(schema="nexgenvideo/bible-typed-native-evidence/1", status="source-only-pending",
                    humanIdentityQualityClaim=False, projectKey=project_key, bibleSHA256=hashlib.sha256(raw).hexdigest(),
                    look=look, lookInspectorOpenedFromHidden=True, entities=entities,
                    beforeSHA256=hashlib.sha256((root / "bible-typed-before.yaml").read_bytes()).hexdigest())
    put(root, "bible-typed-evidence.json", evidence)
    put(root, "bible-typed-pre-save.json", dict(projectKey=project_key, bibleSHA256=evidence["bibleSHA256"]))
    put(root, "bible-typed-reopened.json", dict(projectKey=project_key, bibleSHA256=evidence["bibleSHA256"]))
    package = dict(id="package", payload=dict(prompt="Compiled fixture prompt"))
    put(root, "bible-typed-generation-package.json", package)
    package_sha = hashlib.sha256((root / "bible-typed-generation-package.json").read_bytes()).hexdigest()
    put(root, "bible-typed-generation-receipt.json", dict(schema="generation-output-receipt/v1", modality="image",
        projectKey=project_key, assetID="asset", output=dict(sha256=image_sha), package=dict(id="package", sha256=package_sha),
        input=dict(prompt="Compiled fixture prompt", model="fal-ai/flux/schnell"),
        spendEvents=[dict(kind=kind, transactionId="transaction") for kind in ("reserved", "submitted")]))
    put(root, "bible-typed-generation-batch.json", dict(schema="generation-batch/v1", id="batch",
        payload=dict(phase="bible", projectKey=project_key, items=[dict(id="item", package=package)])))
    put(root, "bible-typed-generation-journal.json", dict(batchID="batch", pricingOverrideItemIDs=["item"],
        executions=[dict(itemID="item", state="complete", outputAssetIDs=["asset"], transactionID="transaction")]))
    put(root, "bible-typed-http.json", [dict(method="POST", url="https://queue.fal.run/fal-ai/flux/schnell",
        bodyBase64=base64.b64encode(json.dumps(dict(prompt="Compiled fixture prompt")).encode()).decode())])
    pointers += [dict(kind="pointer", id="generation-batch.approve"), dict(kind="pointer", id="bible.look.select")]
    for suffix in ("look", "generation-approval"):
        name = "fixture-typed-bible-" + suffix + ".png"
        (root / name).write_bytes(image)
        screenshots.append(name)
    return dict(interactions=pointers + [dict(kind="verified-state", label="native typed Bible entities and source traversal", evidence=evidence)],
                screenshots=screenshots)


class BibleEntityEvidenceTests(unittest.TestCase):
    def test_existing_entities_locations_notes_and_new_ids_are_independently_bound(self):
        for field in ("characters", "ensembles", "props", "locations", "notes", "preexisting-owner"):
            with self.subTest(field=field), TemporaryDirectory() as temp:
                root = Path(temp); native = fixture(root)
                evidence = json.loads((root / "bible-typed-evidence.json").read_bytes())
                if field == "preexisting-owner":
                    before = yaml.safe_load((root / "bible-typed-before.yaml").read_bytes())
                    before["characters"][0]["id"] = "owner_performer"
                    (root / "bible-typed-before.yaml").write_text(yaml.safe_dump(before))
                    evidence["beforeSHA256"] = hashlib.sha256((root / "bible-typed-before.yaml").read_bytes()).hexdigest()
                else:
                    bible = yaml.safe_load((root / "bible-typed-source.yaml").read_bytes())
                    if field == "notes": bible[field] = "Changed existing notes"
                    else: bible[field][0]["name"] = "Changed existing entity"
                    raw = yaml.safe_dump(bible).encode()
                    for name in ("bible-typed-source.yaml", "bible-typed-pre-save.yaml", "bible-typed-reopened.yaml"):
                        (root / name).write_bytes(raw)
                    evidence["bibleSHA256"] = hashlib.sha256(raw).hexdigest()
                    for name in ("bible-typed-pre-save.json", "bible-typed-reopened.json"):
                        value = json.loads((root / name).read_bytes()); value["bibleSHA256"] = evidence["bibleSHA256"]
                        put(root, name, value)
                put(root, "bible-typed-evidence.json", evidence); native["interactions"][-1]["evidence"] = evidence
                with self.assertRaisesRegex(ValueError, "preserve existing entities|locations and notes"):
                    validate(native, root)

    def test_independent_yaml_and_source_join(self):
        with TemporaryDirectory() as temp:
            root = Path(temp)
            validate(fixture(root), root)

    def test_changed_yaml_image_package_and_saved_bytes(self):
        for name in ("bible-typed-source.yaml", "bible-typed-reference.png",
                     "bible-typed-generation-package.json", "bible-typed-reopened.yaml"):
            with self.subTest(name=name), TemporaryDirectory() as temp:
                root = Path(temp)
                native = fixture(root)
                (root / name).write_bytes((root / name).read_bytes() + b"changed")
                with self.assertRaises((ValueError, yaml.YAMLError)):
                    validate(native, root)

    def test_missing_native_source_selection_and_false_hidden_state(self):
        with TemporaryDirectory() as temp:
            root = Path(temp)
            native = fixture(root)
            native["interactions"] = [row for row in native["interactions"] if row.get("id") != "bible.sheet.prop.owner_prop.front"]
            with self.assertRaises(ValueError):
                validate(native, root)
        with TemporaryDirectory() as temp:
            root = Path(temp)
            native = fixture(root)
            evidence = json.loads((root / "bible-typed-evidence.json").read_bytes())
            evidence["entities"][0]["inspectorOpenedFromHidden"] = False
            put(root, "bible-typed-evidence.json", evidence)
            native["interactions"][-1]["evidence"] = evidence
            with self.assertRaises(ValueError):
                validate(native, root)

    def test_wrong_canonical_type_project_or_transaction(self):
        for name, mutate in (
            ("bible-typed-generation-receipt.json", lambda value: value.update(projectKey="foreign")),
            ("bible-typed-generation-journal.json", lambda value: value["executions"][0].update(transactionID="foreign")),
            ("bible-typed-generation-batch.json", lambda value: value["payload"].update(phase="frames")),
        ):
            with self.subTest(name=name), TemporaryDirectory() as temp:
                root = Path(temp)
                native = fixture(root)
                value = json.loads((root / name).read_bytes())
                mutate(value)
                put(root, name, value)
                with self.assertRaises(ValueError):
                    validate(native, root)

    def test_null_or_empty_shared_identifiers_are_not_valid_joins(self):
        for identifier in (None, "", " "):
            with self.subTest(identifier=identifier), TemporaryDirectory() as temp:
                root = Path(temp); native = fixture(root)
                receipt = json.loads((root / "bible-typed-generation-receipt.json").read_bytes())
                journal = json.loads((root / "bible-typed-generation-journal.json").read_bytes())
                journal["executions"][0]["transactionID"] = identifier
                for event in receipt["spendEvents"]: event["transactionId"] = identifier
                put(root, "bible-typed-generation-receipt.json", receipt); put(root, "bible-typed-generation-journal.json", journal)
                with self.assertRaisesRegex(ValueError, "nonempty native identity"):
                    validate(native, root)

    def test_swapped_typed_source_path_is_not_a_shared_asset_pass(self):
        with TemporaryDirectory() as temp:
            root = Path(temp); native = fixture(root)
            evidence = json.loads((root / "bible-typed-evidence.json").read_bytes())
            evidence["entities"][0]["path"] = evidence["entities"][1]["path"]
            put(root, "bible-typed-evidence.json", evidence); native["interactions"][-1]["evidence"] = evidence
            with self.assertRaises(ValueError): validate(native, root)

    def test_actual_per_entity_copy_is_hash_bound(self):
        with TemporaryDirectory() as temp:
            root = Path(temp); native = fixture(root)
            evidence = json.loads((root / "bible-typed-evidence.json").read_bytes())
            image = root / evidence["entities"][1]["retainedImage"]
            image.write_bytes(b"different actual sheet")
            with self.assertRaisesRegex(ValueError, "actual per-entity canonical sheet bytes"):
                validate(native, root)

    def test_yaml_does_not_construct_python_objects(self):
        with TemporaryDirectory() as temp:
            root = Path(temp)
            native = fixture(root)
            from production_bible_entity_evidence import parsed_yaml
            with self.assertRaisesRegex(ValueError, "invalid retained Bible YAML"):
                parsed_yaml(b"!!python/tuple [1, 2]")
            invalid = b"!!python/tuple [1, 2]"
            (root / "bible-typed-before.yaml").write_bytes(invalid)
            evidence = json.loads((root / "bible-typed-evidence.json").read_bytes())
            evidence["beforeSHA256"] = hashlib.sha256(invalid).hexdigest()
            put(root, "bible-typed-evidence.json", evidence)
            native["interactions"][-1]["evidence"] = evidence
            with self.assertRaisesRegex(ValueError, "invalid retained Bible YAML"):
                validate(native, root)


if __name__ == "__main__":
    unittest.main()
