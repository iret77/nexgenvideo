import copy
import json
import tempfile
import unittest
from pathlib import Path

import validate_pipeline_contract


class PipelineContractValidatorTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.repository = Path(self.temporary.name)
        self.pack_manifest = self.repository / "plugins/fixture.json"
        self.resource_root = (
            self.repository / "Sources/FixturePlugin/Resources/FixturePack"
        )
        self.resource_root.mkdir(parents=True)
        self.pack_manifest.parent.mkdir(parents=True)
        self.pack = {
            "id": "fixture",
            "target": "FixturePlugin",
            "pipelineContractVersion": 1,
            "resourceRoot": "FixturePack",
        }
        self.contract = {
            "schema": "pipeline-contract/v1",
            "contractID": "fixture.pipeline.v1",
            "packID": "fixture",
            "resourceRoot": "FixturePack",
            "hardStepsManifestID": "hardsteps/1.0",
            "display": {"title": "Fixture"},
            "phases": [
                {
                    "id": "setup",
                    "executionIndex": 0,
                    "dependencies": [],
                    "roles": ["intake", "canonical_writer", "review_gate"],
                    "selectors": {
                        "artifact": "fixture.setup",
                        "writer": "fixture.setup_writer",
                        "gate": "fixture.setup_gate",
                    },
                    "capabilities": {"phaseBound": [], "supporting": []},
                    "instructions": "phases/setup.md",
                },
                {
                    "id": "compose",
                    "executionIndex": 1,
                    "dependencies": ["setup"],
                    "roles": ["canonical_writer", "review_gate"],
                    "selectors": {
                        "artifact": "fixture.compose",
                        "writer": "fixture.compose_writer",
                        "gate": "fixture.compose_gate",
                        "lineage": "fixture.compose_lineage",
                    },
                    "capabilities": {
                        "phaseBound": ["write_phase_extension"],
                        "supporting": ["compile_prompt"],
                    },
                    "instructions": "phases/compose.md",
                },
            ],
        }
        (self.resource_root / "phases").mkdir()
        (self.resource_root / "phases/setup.md").write_text("Set up the fixture.")
        (self.resource_root / "phases/compose.md").write_text("Compose the fixture.")
        (self.resource_root / "hardsteps.json").write_text(
            json.dumps(
                {
                    "schema": "hardsteps/1.0",
                    "phases": [
                        {
                            "phase": "setup",
                            "steps": [
                                {
                                    "id": "setup.source",
                                    "attachAs": "song",
                                    "title": "Track",
                                }
                            ],
                        }
                    ],
                }
            )
        )
        self.write_fixture()

    def tearDown(self):
        self.temporary.cleanup()

    def write_fixture(self):
        self.pack_manifest.write_text(json.dumps(self.pack))
        (self.resource_root / "pipeline-contract.json").write_text(
            json.dumps(self.contract)
        )

    def assert_invalid(self, text):
        with self.assertRaisesRegex(
            validate_pipeline_contract.PipelineContractValidationError,
            text,
        ):
            validate_pipeline_contract.validate_pack_manifest(
                self.pack_manifest,
                self.repository,
            )

    def test_minimal_non_song_contract_is_valid(self):
        validate_pipeline_contract.validate_pack_manifest(
            self.pack_manifest,
            self.repository,
        )

    def test_rejects_unknown_fields_at_every_contract_level(self):
        mutations = [
            lambda contract: contract.update({"unknown": True}),
            lambda contract: contract["display"].update({"unknown": True}),
            lambda contract: contract["phases"][0].update({"unknown": True}),
            lambda contract: contract["phases"][0]["selectors"].update({"unknown": True}),
            lambda contract: contract["phases"][0]["capabilities"].update({"unknown": True}),
        ]
        pristine = copy.deepcopy(self.contract)
        for mutate in mutations:
            with self.subTest(mutate=mutate):
                self.contract = copy.deepcopy(pristine)
                mutate(self.contract)
                self.write_fixture()
                self.assert_invalid("unknown field")

    def test_rejects_missing_writer_gate_or_instructions(self):
        for field, message in (
            ("writer", "missing required field"),
            ("gate", "missing required field"),
        ):
            with self.subTest(field=field):
                self.contract = copy.deepcopy(self.contract)
                del self.contract["phases"][0]["selectors"][field]
                self.write_fixture()
                self.assert_invalid(message)
                self.setUp_contract()
        del self.contract["phases"][0]["instructions"]
        self.write_fixture()
        self.assert_invalid("missing required field")

    def setUp_contract(self):
        contract_path = self.resource_root / "pipeline-contract.json"
        self.contract = json.loads(contract_path.read_text())
        self.contract["phases"][0]["selectors"].update(
            {
                "artifact": "fixture.setup",
                "writer": "fixture.setup_writer",
                "gate": "fixture.setup_gate",
            }
        )

    def test_rejects_duplicate_ids_and_non_total_order(self):
        self.contract["phases"][1]["id"] = "setup"
        self.contract["phases"][1]["dependencies"] = ["setup"]
        self.write_fixture()
        self.assert_invalid("phase ids must be unique")

        self.contract["phases"][1]["id"] = "compose"
        self.contract["phases"][1]["dependencies"] = []
        self.write_fixture()
        self.assert_invalid("dependencies must be exactly")

    def test_rejects_missing_or_empty_resources(self):
        self.contract["phases"][1]["instructions"] = "phases/missing.md"
        self.write_fixture()
        self.assert_invalid("instructions is missing")

        self.contract["phases"][1]["instructions"] = "phases/compose.md"
        (self.resource_root / "phases/compose.md").write_text(" \n")
        self.write_fixture()
        self.assert_invalid("instructions are empty")

    def test_rejects_intake_and_hard_step_mismatch(self):
        self.contract["phases"][0]["roles"].remove("intake")
        self.write_fixture()
        self.assert_invalid("intake roles must match")

    def test_rejects_hard_steps_runtime_cannot_decode(self):
        hard_steps_path = self.resource_root / "hardsteps.json"
        manifest = json.loads(hard_steps_path.read_text())
        step = manifest["phases"][0]["steps"][0]
        for field in ("attachAs", "title"):
            with self.subTest(field=field):
                invalid = copy.deepcopy(manifest)
                del invalid["phases"][0]["steps"][0][field]
                hard_steps_path.write_text(json.dumps(invalid))
                self.assert_invalid(field)
        step["attachAs"] = "unsupported"
        hard_steps_path.write_text(json.dumps(manifest))
        self.assert_invalid("unsupported value")

    def test_rejects_intake_kind_owned_by_multiple_phases(self):
        hard_steps_path = self.resource_root / "hardsteps.json"
        manifest = json.loads(hard_steps_path.read_text())
        manifest["phases"].append(
            {
                "phase": "compose",
                "steps": [
                    {
                        "id": "compose.source",
                        "attachAs": "song",
                        "title": "Another track",
                    }
                ],
            }
        )
        self.contract["phases"][1]["roles"].append("intake")
        hard_steps_path.write_text(json.dumps(manifest))
        self.write_fixture()
        self.assert_invalid("declared in multiple phases")

    def test_rejects_undeclared_or_invalid_pipeline_version(self):
        del self.pack["pipelineContractVersion"]
        self.write_fixture()
        self.assert_invalid("pipelineContractVersion must be 1")
        self.pack["pipelineContractVersion"] = 2
        self.write_fixture()
        self.assert_invalid("pipelineContractVersion must be 1")

    def test_rejects_duplicate_json_keys(self):
        path = self.resource_root / "pipeline-contract.json"
        path.write_text('{"schema":"pipeline-contract/v1","schema":"duplicate"}')
        self.assert_invalid("duplicate JSON field")

    def test_extension_schema_uses_the_closed_host_subset(self):
        schema_path = self.resource_root / "schemas/compose.schema.json"
        schema_path.parent.mkdir()
        schema = {
            "type": "object",
            "additionalProperties": False,
            "properties": {
                "title": {"type": "string", "minLength": 1},
            },
            "required": ["title"],
        }
        schema_path.write_text(json.dumps(schema))
        phase = self.contract["phases"][1]
        phase["selectors"] = {
            "artifact": "host.generic_json_extension",
            "writer": "host.generic_json_extension",
            "gate": "host.generic_json_extension",
            "lineage": "host.generic_json_extension",
        }
        phase["extensionArtifact"] = {
            "relativePath": "extensions/compose.json",
            "schemaResource": "schemas/compose.schema.json",
        }
        self.write_fixture()
        validate_pipeline_contract.validate_pack_manifest(
            self.pack_manifest,
            self.repository,
        )

        schema["properties"]["title"]["pattern"] = "^.+$"
        schema_path.write_text(json.dumps(schema))
        self.assert_invalid("unsupported keyword")

    def test_extension_artifact_paths_use_macos_collision_rules(self):
        schemas = self.resource_root / "schemas"
        schemas.mkdir()
        schema = {
            "type": "object",
            "additionalProperties": False,
            "properties": {},
            "required": [],
        }
        for phase, path in (("setup", "extensions/Phase.json"), ("compose", "extensions/phase.json")):
            schema_path = schemas / f"{phase}.schema.json"
            schema_path.write_text(json.dumps(schema))
            declaration = self.contract["phases"][0 if phase == "setup" else 1]
            declaration["selectors"] = {
                "artifact": "host.generic_json_extension",
                "writer": "host.generic_json_extension",
                "gate": "host.generic_json_extension",
                "lineage": "host.generic_json_extension",
            }
            declaration["extensionArtifact"] = {
                "relativePath": path,
                "schemaResource": f"schemas/{phase}.schema.json",
            }
        self.write_fixture()
        self.assert_invalid("extension artifact paths must be unique")

if __name__ == "__main__":
    unittest.main()
