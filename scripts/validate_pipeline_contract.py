#!/usr/bin/env python3
import json
import re
import sys
import unicodedata
from pathlib import Path
from typing import Any


CURRENT_SCHEMA = "pipeline-contract/v1"
CURRENT_VERSION = 1
CONTRACT_RESOURCE = "pipeline-contract.json"
HARD_STEPS_RESOURCE = "hardsteps.json"
ROLES = {
    "intake",
    "deterministic_runner",
    "canonical_writer",
    "review_gate",
    "utility",
}
GENERIC_SELECTOR = "host.generic_json_extension"
IDENTIFIER = re.compile(r"^[A-Za-z][A-Za-z0-9._-]*$")
PHASE_ID = re.compile(r"^[A-Za-z][A-Za-z0-9_]*$")
CAPABILITY_ID = re.compile(r"^[a-z][a-z0-9_]*$")
SELECTOR_ID = re.compile(r"^[A-Za-z][A-Za-z0-9._-]*$")
EXTENSION_SCHEMA_TYPES = {"array", "boolean", "integer", "number", "object", "string"}
EXTENSION_SCHEMA_KEYWORDS = {
    "$id",
    "$schema",
    "additionalProperties",
    "description",
    "enum",
    "items",
    "maxItems",
    "maxLength",
    "minItems",
    "minLength",
    "properties",
    "required",
    "title",
    "type",
}
HARD_STEP_KINDS = {"script", "character", "location", "style", "song", "lyrics"}
HARD_STEP_BOOLEAN_FIELDS = {"multiple", "required", "repeatable"}
HARD_STEP_STRING_FIELDS = {
    "intro",
    "prompt",
    "namePrompt",
    "addAnotherLabel",
    "itemTitle",
    "skipLabel",
    "doneLabel",
    "addFileLabel",
    "symbol",
    "confirmLabel",
}
MUSICVIDEO_PHASES = [
    "project_init",
    "analysis",
    "brief",
    "production_design",
    "treatment",
    "storyboard",
    "bible",
    "shotlist",
    "sanity",
    "frames",
    "render",
]
MUSICVIDEO_INSTRUCTIONS = {
    "project_init": "phases/project-init.md",
    "analysis": "phases/analysis.md",
    "brief": "phases/brief.md",
    "production_design": "phases/production-design.md",
    "treatment": "phases/treatment.md",
    "storyboard": "phases/storyboard.md",
    "bible": "phases/bible.md",
    "shotlist": "phases/shotlist.md",
    "sanity": "phases/sanity.md",
    "frames": "phases/frame.md",
    "render": "phases/render.md",
}


class PipelineContractValidationError(ValueError):
    pass


def _object_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise PipelineContractValidationError(f"duplicate JSON field {key!r}")
        result[key] = value
    return result


def _reject_nonfinite(value: str) -> None:
    raise PipelineContractValidationError(f"non-finite JSON number {value!r}")


def load_json(path: Path, context: str) -> Any:
    try:
        with path.open(encoding="utf-8") as handle:
            return json.load(
                handle,
                object_pairs_hook=_object_pairs,
                parse_constant=_reject_nonfinite,
            )
    except PipelineContractValidationError:
        raise
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise PipelineContractValidationError(f"{context} is unreadable or invalid JSON: {error}") from error


def require_object(
    value: Any,
    *,
    required: set[str],
    optional: set[str] | None = None,
    context: str,
) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise PipelineContractValidationError(f"{context} must be an object")
    optional = optional or set()
    missing = sorted(required - value.keys())
    unknown = sorted(value.keys() - required - optional)
    if missing:
        raise PipelineContractValidationError(
            f"{context} is missing required field(s): {', '.join(missing)}"
        )
    if unknown:
        raise PipelineContractValidationError(
            f"{context} contains unknown field(s): {', '.join(unknown)}"
        )
    return value


def nonempty_string(value: Any, context: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise PipelineContractValidationError(f"{context} must be a non-empty string")
    return value


def string_list(
    value: Any,
    context: str,
    *,
    allowed: set[str] | None = None,
    pattern: re.Pattern[str] | None = None,
) -> list[str]:
    if not isinstance(value, list):
        raise PipelineContractValidationError(f"{context} must be an array")
    result: list[str] = []
    for index, item in enumerate(value):
        item = nonempty_string(item, f"{context}[{index}]")
        if allowed is not None and item not in allowed:
            raise PipelineContractValidationError(f"{context}[{index}] has unsupported value {item!r}")
        if pattern is not None and pattern.fullmatch(item) is None:
            raise PipelineContractValidationError(f"{context}[{index}] has invalid value {item!r}")
        result.append(item)
    if len(result) != len(set(result)):
        raise PipelineContractValidationError(f"{context} must contain unique values")
    return result


def safe_relative_path(value: Any, context: str) -> str:
    value = nonempty_string(value, context)
    if value.startswith("/") or "\\" in value:
        raise PipelineContractValidationError(f"{context} must be a safe relative path")
    components = value.split("/")
    if any(component in {"", ".", ".."} for component in components):
        raise PipelineContractValidationError(f"{context} must be a safe relative path")
    return value


def resource_file(root: Path, relative_path: Any, context: str) -> Path:
    relative_path = safe_relative_path(relative_path, context)
    current = root
    for component in relative_path.split("/"):
        current = current / component
        if current.is_symlink():
            raise PipelineContractValidationError(f"{context} must not traverse a symbolic link")
    try:
        root_resolved = root.resolve(strict=True)
        resolved = current.resolve(strict=True)
    except OSError as error:
        raise PipelineContractValidationError(f"{context} is missing: {relative_path}") from error
    if root_resolved not in resolved.parents or not resolved.is_file():
        raise PipelineContractValidationError(f"{context} must resolve to a regular file inside the resource root")
    return resolved


def validate_display(value: Any, context: str) -> None:
    display = require_object(
        value,
        required={"title"} if context == "display" else {"label"},
        optional={"localizationTable"} if context == "display" else {"localizationKey"},
        context=context,
    )
    primary = "title" if context == "display" else "label"
    nonempty_string(display[primary], f"{context}.{primary}")
    optional = "localizationTable" if context == "display" else "localizationKey"
    if optional in display:
        nonempty_string(display[optional], f"{context}.{optional}")


def _schema_value_matches_type(value: Any, schema_type: str) -> bool:
    if schema_type == "object":
        return isinstance(value, dict)
    if schema_type == "array":
        return isinstance(value, list)
    if schema_type == "string":
        return isinstance(value, str)
    if schema_type == "boolean":
        return isinstance(value, bool)
    if schema_type == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if schema_type == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    return False


def _schema_bound(node: dict[str, Any], name: str, context: str) -> int | None:
    if name not in node:
        return None
    value = node[name]
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise PipelineContractValidationError(f"{context}.{name} must be a non-negative integer")
    return value


def validate_extension_schema_node(value: Any, context: str, *, root: bool = False) -> None:
    if not isinstance(value, dict):
        raise PipelineContractValidationError(f"{context} must be an object")
    unknown = sorted(value.keys() - EXTENSION_SCHEMA_KEYWORDS)
    if unknown:
        raise PipelineContractValidationError(
            f"{context} contains unsupported keyword(s): {', '.join(unknown)}"
        )
    schema_type = value.get("type")
    if not isinstance(schema_type, str) or schema_type not in EXTENSION_SCHEMA_TYPES:
        raise PipelineContractValidationError(f"{context}.type is unsupported or missing")
    if root and schema_type != "object":
        raise PipelineContractValidationError("extension schema root must have type object")
    for key in ("$id", "$schema", "description", "title"):
        if key in value:
            nonempty_string(value[key], f"{context}.{key}")

    object_keywords = {"properties", "required", "additionalProperties"}
    if schema_type == "object":
        if value.get("additionalProperties") is not False:
            raise PipelineContractValidationError(
                f"{context}.additionalProperties must be false"
            )
        properties = value.get("properties")
        if not isinstance(properties, dict):
            raise PipelineContractValidationError(f"{context}.properties must be an object")
        for name, child in properties.items():
            if not name or "." in name or "/" in name:
                raise PipelineContractValidationError(f"{context} has invalid property name {name!r}")
            validate_extension_schema_node(child, f"{context}.{name}")
        required = string_list(value.get("required", []), f"{context}.required")
        if not set(required).issubset(properties):
            raise PipelineContractValidationError(f"{context}.required names an unknown property")
    elif object_keywords & value.keys():
        raise PipelineContractValidationError(f"{context} uses object-only keywords")

    array_keywords = {"items", "minItems", "maxItems"}
    if schema_type == "array":
        if "items" not in value:
            raise PipelineContractValidationError(f"{context}.items is required")
        validate_extension_schema_node(value["items"], f"{context}[]")
        minimum = _schema_bound(value, "minItems", context)
        maximum = _schema_bound(value, "maxItems", context)
        if minimum is not None and maximum is not None and minimum > maximum:
            raise PipelineContractValidationError(f"{context}.minItems exceeds maxItems")
    elif array_keywords & value.keys():
        raise PipelineContractValidationError(f"{context} uses array-only keywords")

    string_keywords = {"minLength", "maxLength"}
    if schema_type == "string":
        minimum = _schema_bound(value, "minLength", context)
        maximum = _schema_bound(value, "maxLength", context)
        if minimum is not None and maximum is not None and minimum > maximum:
            raise PipelineContractValidationError(f"{context}.minLength exceeds maxLength")
    elif string_keywords & value.keys():
        raise PipelineContractValidationError(f"{context} uses string-only keywords")

    if "enum" in value:
        enum_values = value["enum"]
        if not isinstance(enum_values, list) or not enum_values:
            raise PipelineContractValidationError(f"{context}.enum must be a non-empty array")
        encoded = [json.dumps(item, sort_keys=True, separators=(",", ":")) for item in enum_values]
        if len(encoded) != len(set(encoded)) or not all(
            _schema_value_matches_type(item, schema_type) for item in enum_values
        ):
            raise PipelineContractValidationError(
                f"{context}.enum values must be unique and match type {schema_type}"
            )


def validate_extension_artifact(value: Any, resource_root: Path, phase_id: str) -> None:
    extension = require_object(
        value,
        required={"relativePath", "schemaResource"},
        context=f"phase {phase_id} extensionArtifact",
    )
    artifact_path = safe_relative_path(
        extension["relativePath"],
        f"phase {phase_id} extensionArtifact.relativePath",
    )
    if not artifact_path.startswith("extensions/") or not artifact_path.endswith(".json"):
        raise PipelineContractValidationError(
            f"phase {phase_id} extensionArtifact.relativePath must be an extensions/*.json path"
        )
    schema_path = resource_file(
        resource_root,
        extension["schemaResource"],
        f"phase {phase_id} extension schema",
    )
    schema = load_json(schema_path, f"phase {phase_id} extension schema")
    validate_extension_schema_node(
        schema,
        f"phase {phase_id} extension schema",
        root=True,
    )


def validate_hard_steps(resource_root: Path, expected_schema: str) -> set[str]:
    path = resource_file(resource_root, HARD_STEPS_RESOURCE, "hard-step manifest")
    manifest = load_json(path, "hard-step manifest")
    if not isinstance(manifest, dict):
        raise PipelineContractValidationError("hard-step manifest must be an object")
    if manifest.get("schema") != expected_schema:
        raise PipelineContractValidationError(
            "pipeline contract hardStepsManifestID does not match hardsteps.json schema"
        )
    phases = manifest.get("phases")
    if not isinstance(phases, list):
        raise PipelineContractValidationError("hardsteps.json phases must be an array")
    phase_ids: list[str] = []
    step_ids: list[str] = []
    kind_owners: dict[str, str] = {}
    for index, value in enumerate(phases):
        if not isinstance(value, dict):
            raise PipelineContractValidationError(f"hardsteps.json phases[{index}] must be an object")
        phase_id = nonempty_string(value.get("phase"), f"hardsteps.json phases[{index}].phase")
        if PHASE_ID.fullmatch(phase_id) is None:
            raise PipelineContractValidationError(f"hardsteps.json has invalid phase id {phase_id!r}")
        steps = value.get("steps")
        if not isinstance(steps, list):
            raise PipelineContractValidationError(f"hardsteps.json phase {phase_id} needs a steps array")
        phase_ids.append(phase_id)
        for step_index, step in enumerate(steps):
            if not isinstance(step, dict):
                raise PipelineContractValidationError(
                    f"hardsteps.json phase {phase_id} step {step_index} must be an object"
                )
            context = f"hardsteps.json phase {phase_id} step {step_index}"
            step_ids.append(nonempty_string(step.get("id"), f"{context}.id"))
            attach_as = nonempty_string(step.get("attachAs"), f"{context}.attachAs")
            if attach_as not in HARD_STEP_KINDS:
                raise PipelineContractValidationError(
                    f"{context}.attachAs has unsupported value {attach_as!r}"
                )
            owner = kind_owners.setdefault(attach_as, phase_id)
            if owner != phase_id:
                raise PipelineContractValidationError(
                    f"hard-step intake kind {attach_as!r} is declared in multiple phases"
                )
            nonempty_string(step.get("title"), f"{context}.title")
            if "accept" in step and step["accept"] is not None:
                accept = step["accept"]
                if not isinstance(accept, list) or not all(
                    isinstance(value, str) for value in accept
                ):
                    raise PipelineContractValidationError(
                        f"{context}.accept must be an array of strings"
                    )
            for field in HARD_STEP_BOOLEAN_FIELDS:
                if field in step and step[field] is not None and not isinstance(step[field], bool):
                    raise PipelineContractValidationError(f"{context}.{field} must be a boolean")
            for field in HARD_STEP_STRING_FIELDS:
                if field in step and step[field] is not None and not isinstance(step[field], str):
                    raise PipelineContractValidationError(f"{context}.{field} must be a string")
            if "textField" in step and step["textField"] is not None:
                text_field = step["textField"]
                if not isinstance(text_field, dict):
                    raise PipelineContractValidationError(f"{context}.textField must be an object")
                if not isinstance(text_field.get("placeholder"), str):
                    raise PipelineContractValidationError(
                        f"{context}.textField.placeholder must be a string"
                    )
                if (
                    "multiline" in text_field
                    and text_field["multiline"] is not None
                    and not isinstance(text_field["multiline"], bool)
                ):
                    raise PipelineContractValidationError(
                        f"{context}.textField.multiline must be a boolean"
                    )
    if len(phase_ids) != len(set(phase_ids)):
        raise PipelineContractValidationError("hardsteps.json phase declarations must be unique")
    if len(step_ids) != len(set(step_ids)):
        raise PipelineContractValidationError("hardsteps.json step ids must be unique")
    return {phase_id for phase_id, value in zip(phase_ids, phases) if value.get("steps")}


def validate_musicvideo_contract(contract: dict[str, Any]) -> None:
    phase_ids = [phase["id"] for phase in contract["phases"]]
    if phase_ids != MUSICVIDEO_PHASES:
        raise PipelineContractValidationError(
            "musicvideo phases must remain exactly: " + ", ".join(MUSICVIDEO_PHASES)
        )
    instructions = {phase["id"]: phase["instructions"] for phase in contract["phases"]}
    if instructions != MUSICVIDEO_INSTRUCTIONS:
        raise PipelineContractValidationError("musicvideo phase instruction mapping changed")


def validate_contract(contract: Any, *, pack_id: str, resource_root_name: str, resource_root: Path) -> None:
    contract = require_object(
        contract,
        required={
            "schema",
            "contractID",
            "packID",
            "resourceRoot",
            "hardStepsManifestID",
            "display",
            "phases",
        },
        optional={"policyIDs", "postPipelineCapabilities"},
        context="pipeline contract",
    )
    if contract["schema"] != CURRENT_SCHEMA:
        raise PipelineContractValidationError(f"pipeline contract schema must be {CURRENT_SCHEMA}")
    contract_id = nonempty_string(contract["contractID"], "pipeline contract contractID")
    if IDENTIFIER.fullmatch(contract_id) is None:
        raise PipelineContractValidationError("pipeline contract contractID is invalid")
    if contract["packID"] != pack_id:
        raise PipelineContractValidationError("pipeline contract packID does not match the pack manifest")
    if contract["resourceRoot"] != resource_root_name:
        raise PipelineContractValidationError("pipeline contract resourceRoot does not match the pack manifest")
    hard_steps_id = nonempty_string(contract["hardStepsManifestID"], "pipeline contract hardStepsManifestID")
    validate_display(contract["display"], "display")
    string_list(contract.get("policyIDs", []), "pipeline contract policyIDs", pattern=IDENTIFIER)
    string_list(
        contract.get("postPipelineCapabilities", []),
        "pipeline contract postPipelineCapabilities",
        pattern=CAPABILITY_ID,
    )

    phases = contract["phases"]
    if not isinstance(phases, list) or not phases:
        raise PipelineContractValidationError("pipeline contract phases must be a non-empty array")
    phase_ids: list[str] = []
    intake_phases: set[str] = set()
    extension_paths: list[str] = []
    for index, value in enumerate(phases):
        phase = require_object(
            value,
            required={
                "id",
                "executionIndex",
                "dependencies",
                "roles",
                "selectors",
                "capabilities",
                "instructions",
            },
            optional={"display", "policyIDs", "extensionArtifact"},
            context=f"phase {index}",
        )
        phase_id = nonempty_string(phase["id"], f"phase {index}.id")
        if PHASE_ID.fullmatch(phase_id) is None:
            raise PipelineContractValidationError(f"phase {index}.id is invalid")
        phase_ids.append(phase_id)
        execution_index = phase["executionIndex"]
        if isinstance(execution_index, bool) or not isinstance(execution_index, int):
            raise PipelineContractValidationError(f"phase {phase_id}.executionIndex must be an integer")
        if execution_index != index:
            raise PipelineContractValidationError(
                "executionIndex values must be contiguous and declaration-ordered from zero"
            )
        dependencies = string_list(phase["dependencies"], f"phase {phase_id}.dependencies", pattern=PHASE_ID)
        expected_dependencies = [] if index == 0 else [phase_ids[index - 1]]
        if dependencies != expected_dependencies:
            raise PipelineContractValidationError(
                f"phase {phase_id}.dependencies must be exactly {expected_dependencies!r}"
            )
        roles = string_list(phase["roles"], f"phase {phase_id}.roles", allowed=ROLES)
        if "canonical_writer" not in roles or "review_gate" not in roles:
            raise PipelineContractValidationError(
                f"phase {phase_id} requires canonical_writer and review_gate roles"
            )
        if "intake" in roles:
            intake_phases.add(phase_id)

        selectors = require_object(
            phase["selectors"],
            required={"artifact", "writer", "gate"},
            optional={"runner", "lineage", "deterministicSteps"},
            context=f"phase {phase_id} selectors",
        )
        for name in ("artifact", "writer", "gate"):
            selector = nonempty_string(selectors[name], f"phase {phase_id} selectors.{name}")
            if SELECTOR_ID.fullmatch(selector) is None:
                raise PipelineContractValidationError(f"phase {phase_id} selectors.{name} is invalid")
        runner = selectors.get("runner")
        if runner is not None:
            runner = nonempty_string(runner, f"phase {phase_id} selectors.runner")
            if SELECTOR_ID.fullmatch(runner) is None:
                raise PipelineContractValidationError(f"phase {phase_id} selectors.runner is invalid")
        if ("deterministic_runner" in roles) != (runner is not None):
            raise PipelineContractValidationError(
                f"phase {phase_id} deterministic_runner role and runner selector disagree"
            )
        lineage = selectors.get("lineage")
        if lineage is not None:
            lineage = nonempty_string(lineage, f"phase {phase_id} selectors.lineage")
            if SELECTOR_ID.fullmatch(lineage) is None:
                raise PipelineContractValidationError(f"phase {phase_id} selectors.lineage is invalid")
        if index > 0 and lineage is None:
            raise PipelineContractValidationError(f"post-init phase {phase_id} requires a lineage selector")
        deterministic_steps = string_list(
            selectors.get("deterministicSteps", []),
            f"phase {phase_id} selectors.deterministicSteps",
            pattern=IDENTIFIER,
        )
        if "deterministic_runner" not in roles and deterministic_steps:
            raise PipelineContractValidationError(
                f"phase {phase_id} declares deterministic steps without a runner"
            )

        capabilities = require_object(
            phase["capabilities"],
            required={"phaseBound", "supporting"},
            context=f"phase {phase_id} capabilities",
        )
        phase_bound = string_list(
            capabilities["phaseBound"],
            f"phase {phase_id} capabilities.phaseBound",
            pattern=CAPABILITY_ID,
        )
        supporting = string_list(
            capabilities["supporting"],
            f"phase {phase_id} capabilities.supporting",
            pattern=CAPABILITY_ID,
        )
        overlap = sorted(set(phase_bound) & set(supporting))
        if overlap:
            raise PipelineContractValidationError(
                f"phase {phase_id} grants capabilities as both phase-bound and supporting: {', '.join(overlap)}"
            )
        instruction_path = resource_file(
            resource_root,
            phase["instructions"],
            f"phase {phase_id} instructions",
        )
        try:
            instructions = instruction_path.read_text(encoding="utf-8")
        except (OSError, UnicodeError) as error:
            raise PipelineContractValidationError(f"phase {phase_id} instructions are unreadable: {error}") from error
        if not instructions.strip():
            raise PipelineContractValidationError(f"phase {phase_id} instructions are empty")
        if "display" in phase:
            validate_display(phase["display"], f"phase {phase_id} display")
        string_list(phase.get("policyIDs", []), f"phase {phase_id} policyIDs", pattern=IDENTIFIER)

        generic_values = {
            selectors["artifact"],
            selectors["writer"],
            selectors["gate"],
            lineage,
        }
        if "extensionArtifact" in phase:
            if generic_values != {GENERIC_SELECTOR}:
                raise PipelineContractValidationError(
                    f"phase {phase_id} extensionArtifact requires all generic host selectors"
                )
            validate_extension_artifact(phase["extensionArtifact"], resource_root, phase_id)
            extension_paths.append(
                unicodedata.normalize(
                    "NFC",
                    unicodedata.normalize(
                        "NFC",
                        phase["extensionArtifact"]["relativePath"],
                    ).casefold(),
                )
            )
        elif GENERIC_SELECTOR in generic_values:
            raise PipelineContractValidationError(
                f"phase {phase_id} uses a generic host selector without extensionArtifact"
            )

    if len(phase_ids) != len(set(phase_ids)):
        raise PipelineContractValidationError("pipeline contract phase ids must be unique")
    if len(extension_paths) != len(set(extension_paths)):
        raise PipelineContractValidationError("extension artifact paths must be unique")
    hard_step_phases = validate_hard_steps(resource_root, hard_steps_id)
    unknown_hard_step_phases = sorted(hard_step_phases - set(phase_ids))
    if unknown_hard_step_phases:
        raise PipelineContractValidationError(
            "hard steps reference unknown phase(s): " + ", ".join(unknown_hard_step_phases)
        )
    if hard_step_phases != intake_phases:
        raise PipelineContractValidationError(
            "pipeline intake roles must match hard-step phases with steps exactly"
        )
    if pack_id == "musicvideo":
        validate_musicvideo_contract(contract)


def validate_pack_manifest(pack_manifest_path: Path, repository_root: Path | None = None) -> None:
    pack_manifest_path = pack_manifest_path.resolve()
    repository_root = (repository_root or Path(__file__).resolve().parent.parent).resolve()
    manifest = load_json(pack_manifest_path, str(pack_manifest_path))
    if not isinstance(manifest, dict):
        raise PipelineContractValidationError("pack manifest must be an object")
    pack_id = nonempty_string(manifest.get("id"), "pack manifest id")
    target = nonempty_string(manifest.get("target"), "pack manifest target")
    pipeline_version = manifest.get("pipelineContractVersion")
    if isinstance(pipeline_version, bool) or pipeline_version != CURRENT_VERSION:
        raise PipelineContractValidationError(
            f"pack manifest pipelineContractVersion must be {CURRENT_VERSION}"
        )
    resource_root_name = safe_relative_path(manifest.get("resourceRoot"), "pack manifest resourceRoot")
    resource_root = repository_root / "Sources" / target / "Resources" / resource_root_name
    if resource_root.is_symlink() or not resource_root.is_dir():
        raise PipelineContractValidationError(
            f"pack resource root is missing or not a real directory: {resource_root}"
        )
    contract_path = resource_file(resource_root, CONTRACT_RESOURCE, "pipeline contract resource")
    contract = load_json(contract_path, "pipeline contract resource")
    validate_contract(
        contract,
        pack_id=pack_id,
        resource_root_name=resource_root_name,
        resource_root=resource_root,
    )


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: validate_pipeline_contract.py plugins/<pack>.json")
    try:
        validate_pack_manifest(Path(sys.argv[1]))
    except PipelineContractValidationError as error:
        raise SystemExit(f"!! invalid pipeline contract: {error}") from error
    print(f"Pipeline contract passed: {sys.argv[1]}")


if __name__ == "__main__":
    main()
