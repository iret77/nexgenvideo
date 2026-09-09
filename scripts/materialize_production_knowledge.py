"""Adapt the preserved source corpus to the existing production-library schema."""
import hashlib
import json
from pathlib import Path
from production_style_verification import bindings


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "docs/production-knowledge/ai-film-production-3.1.1"
DESTINATION = ROOT / "Engine/Sources/NexGenEngine/Resources/ProductionKnowledge"
PHASES = ["init", "analysis", "brief", "production_design", "treatment", "storyboard",
          "bible", "shotlist", "sanity", "frames", "render", "review", "assembly", "finish", "generic"]

CONTRACT_PHASES = {
    "orchestration": PHASES,
    "blueprints": ["brief", "production_design", "storyboard", "sanity", "review", "generic"],
    "craft": ["production_design", "treatment", "storyboard", "shotlist", "sanity", "frames", "render", "review", "assembly", "finish", "generic"],
    "genres": ["brief", "production_design", "treatment", "storyboard", "generic"],
    "story": ["brief", "treatment", "storyboard", "generic"],
    "assets": ["production_design", "storyboard", "bible", "shotlist", "frames", "render", "generic"],
    "canon": PHASES,
    "video": ["shotlist", "frames", "render", "review", "generic"],
    "image": ["production_design", "bible", "frames", "review", "generic"],
    "style": ["brief", "production_design", "storyboard", "bible", "shotlist", "sanity", "frames", "render", "review", "generic"],
    "animation": ["production_design", "storyboard", "bible", "frames", "review", "generic"],
    "feasibility": ["storyboard", "shotlist", "sanity", "frames", "render", "review", "generic"],
    "runbooks": PHASES,
    "post": ["analysis", "sanity", "render", "review", "assembly", "finish", "generic"],
    "dialects": ["frames", "render", "generic"],
    "routes": ["frames", "render", "generic"],
    "evidence": ["analysis", "production_design", "frames", "render", "review", "generic"],
    "glossary": PHASES,
    "examples": ["generic"],
    "packaging": ["generic"],
}

CONTRACT_CONSUMERS = {
    "orchestration": ["PipelineAgentHarness", "PromptCompiler", "NativeGateWriter"],
    "blueprints": ["ProductionStyleAdvisorV1", "ProductionStyleStoreV1", "TimelineStyleReview"],
    "craft": ["SpatialProductionPlanV1", "PipelineShotlistWriter", "TimelineStyleReview"],
    "genres": ["ProductionStyleAdvisorV1", "PipelineAgentHarness"],
    "story": ["StoryCausalityPlanV1", "TreatmentCausalityWriter", "StoryboardPlanWriter"],
    "assets": ["ReferencePlannerV2", "ConfirmedIdentityAssetStoreV1", "SpatialProductionPlanV1"],
    "canon": ["PipelineAgentHarness", "PipelineLineageStore", "GenerationPackageV1"],
    "video": ["VideoPromptIRV1", "VideoPromptDialectCompilerV1", "PipelineProductionRouting"],
    "image": ["PromptCompiler", "ReferencePlannerV2", "FrameAuditAcceptanceStoreV1"],
    "style": ["ProductionStyleStoreV1", "PromptCompiler", "TimelineStyleReview"],
    "animation": ["PromptCompiler", "ReferencePlannerV2", "FrameAuditAcceptanceStoreV1"],
    "feasibility": ["ExecutionPlanValidator", "PipelineProductionRouting", "TakeRepairPlan"],
    "runbooks": ["PipelineAgentHarness", "get_production_knowledge"],
    "post": ["PipelineRenderTakeStore", "TimelineStyleReview", "MusicAssemblyProofV1"],
    "dialects": ["PromptDialectRegistry", "VideoPromptDialectCompilerV1"],
    "routes": ["CatalogCapabilityRuntime", "PipelineProductionRouting", "GenerationPackageV1"],
    "evidence": ["RouteReceiptV1", "GenerationPackageV1", "get_production_knowledge"],
    "glossary": ["get_production_knowledge", "PipelineAgentHarness"],
    "examples": ["get_production_knowledge", "semantic acceptance fixtures"],
    "packaging": ["get_production_knowledge provenance archive"],
}

RUNBOOK_PHASES = {
    "workflows-6f957f7120f1": PHASES,
    "workflows-d91a72e57720": ["production_design", "bible", "frames", "generic"],
    "workflows-ef7dba1933ce": ["frames", "render", "review", "generic"],
    "workflows-9ff2b6097758": ["storyboard", "shotlist", "render", "review", "assembly", "generic"],
    "workflows-0979effa719d": ["render", "review", "generic"],
    "workflows-de63f05d633e": ["storyboard", "shotlist", "render", "review", "generic"],
    "workflows-35ea99e846a8": ["brief", "production_design", "sanity", "review", "generic"],
    "workflows-ca2a59d14ade": ["frames", "render", "review", "generic"],
    "workflows-4d964bcaead8": PHASES,
    "workflows-a32d2b8635bd": ["storyboard", "shotlist", "frames", "render", "review", "assembly", "generic"],
}


def encoded(value):
    return (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode()


def ordered_unique(values):
    return list(dict.fromkeys(values))


def section_phases(section, contract_id):
    return RUNBOOK_PHASES.get(section["id"], CONTRACT_PHASES[contract_id])


def materialize():
    inventory = json.loads((SOURCE / "inventory.json").read_text())
    contract_items = json.loads((SOURCE / "application-contracts.json").read_text())
    for contract in contract_items:
        contract["runtimeStatus"] = "provenance-only" if contract["id"] == "packaging" else "runtime-active"
        contract["runtimeConsumers"] = CONTRACT_CONSUMERS[contract["id"]]
    (SOURCE / "application-contracts.json").write_bytes(encoded(contract_items))
    contracts = {item["id"]: item for item in contract_items}
    precedence = json.loads((SOURCE / "precedence.json").read_text())
    adaptation = "\n".join(item["id"] + ": " + item["ngvApplication"] for item in precedence["overrides"])
    chapters = {Path(item["output"]).stem: json.loads((SOURCE / item["output"]).read_text())
                for item in inventory["files"]}
    entry_locations = {section["id"]: "film-production-" + chapter + "/" + section["id"]
                       for chapter, sections in chapters.items() for section in sections}
    units = json.loads((SOURCE / "units.json").read_text())
    manifest_path = DESTINATION / "manifest.json"
    manifest = json.loads(manifest_path.read_text())
    manifest["resources"] = [item for item in manifest["resources"] if not item["id"].startswith("film-production-")]
    ledger = []
    for source_file in inventory["files"]:
        chapter = Path(source_file["output"]).stem
        library_id = "film-production-" + chapter
        entries = []
        for section in chapters[chapter]:
            contract = contracts[section["applicationContract"]]
            phases = section_phases(section, contract["id"])
            section["runtimeStatus"] = contract["runtimeStatus"]
            ancestors = [candidate for candidate in chapters[chapter]
                         if len(candidate["ancestry"]) < len(section["ancestry"])
                         and section["ancestry"][:len(candidate["ancestry"])] == candidate["ancestry"]]
            links = sorted({entry_locations[reference] for link in section.get("localReferences", [])
                            for reference in link["entryIDs"]})
            entry = {
                "id": section["id"], "title": section["title"],
                "applicability": {"packIDs": [], "phases": phases, "intentTags": ordered_unique([chapter, contract["id"]]), "activeProfileIDs": []},
                "inputs": [], "outputIntent": "Source knowledge for " + contract["consumer"],
                "guidance": [section["contentMarkdown"]]
                            + ["Required ancestor context: " + ancestor["contentMarkdown"] for ancestor in ancestors]
                            + (["Read applicable linked procedures and exceptions by exact entryID: " + ", ".join(links)] if links else []),
                "verifyCriteria": contract["checks"],
                "incompatibilities": ["Source examples are not project canon. Provider and platform claims retain their source date and require current route evidence."],
            }
            entries.append(entry)
            ledger.append({"sectionID": section["id"], "source": section["source"],
                           "resourceID": library_id, "entryID": section["id"], "version": "3.1.1",
                           "applicationContract": section["applicationContract"], "issues": contract["issues"],
                           "units": [unit for unit in units if unit["entryID"] == section["id"]],
                           "ancestorEntryIDs": [entry_locations[item["id"]] for item in ancestors],
                           "linkedEntryIDs": links,
                           "activation": contract["trigger"],
                           "consumerStatus": contract["runtimeStatus"],
                           "runtimeConsumers": contract["runtimeConsumers"],
                           "verification": contract["checks"],
                           "disposition": "Preserved as provenance and retrievable context only."
                           if contract["id"] == "packaging" else
                           "Complete runtime entry, selectively available to both agent backends and phase consumers."})
        (SOURCE / source_file["output"]).write_bytes(encoded(chapters[chapter]))
        contract_ids = sorted({section["applicationContract"] for section in chapters[chapter]})
        library = {
            "schemaVersion": "creative-library.v1", "id": library_id, "version": "3.1.1",
            "applicability": {"packIDs": [], "phases": sorted({phase for entry in entries for phase in entry["applicability"]["phases"]}), "intentTags": ordered_unique([chapter] + contract_ids), "activeProfileIDs": []},
            "entries": entries,
            "provenance": {"sourceURL": "https://github.com/iret77/ai-film-production",
                           "sourceCommit": inventory["sourceCommit"], "sourceSections": [source_file["sourcePath"]],
                           "adaptation": "Complete source sections. Apply these NGV adaptations before source imperatives:\n" + adaptation},
            "license": {"spdxIdentifier": "MIT", "copyrightNotice": "Copyright (c) 2026 iret77",
                        "sourceURL": "https://github.com/iret77/ai-film-production/blob/" + inventory["sourceCommit"] + "/LICENSE"},
        }
        relative = "libraries/" + library_id + ".v3.json"
        data = encoded(library)
        (DESTINATION / relative).write_bytes(data)
        manifest["resources"].append({"kind": "library", "id": library_id, "version": "3.1.1",
                                      "path": relative, "sha256": hashlib.sha256(data).hexdigest()})
    recipes = json.loads((SOURCE / "blueprints.json").read_text())
    director_sections = {section["id"]: section for section in chapters["director-recipes"]}
    selection_section = director_sections["director-recipes-056ac0ea6c03"]["contentMarkdown"]
    recipe_offset = selection_section.index(recipes[0]["completeRecipeMarkdown"])
    selection_procedure = selection_section[:recipe_offset].rstrip()
    harmony = director_sections["director-recipes-17cfc8bdffd7"]["contentMarkdown"]
    blueprint_library = dict(library)
    blueprint_library.update({
        "id": "film-production-blueprints",
        "applicability": {"packIDs": [], "phases": CONTRACT_PHASES["blueprints"], "intentTags": ["style", "director", "cinematography", "blueprints"], "activeProfileIDs": []},
        "entries": [{
            "id": recipe["id"], "title": recipe["name"],
            "applicability": {"packIDs": [], "phases": CONTRACT_PHASES["blueprints"], "intentTags": ordered_unique(["style", "blueprints", recipe["kind"]]), "activeProfileIDs": []},
            "inputs": [], "outputIntent": "Resolve the selected style dimensions with explicit overrides and scoped observation criteria.",
            "guidance": [recipe["completeRecipeMarkdown"],
                         "Selection and synthesis procedure:\n" + selection_procedure,
                         "Pairing procedure:\n" + harmony]
                        + ["Blueprint dimension " + key + ": " + value for key, value in recipe["dimensions"].items()]
                        + ["Blueprint verification: " + json.dumps(binding, ensure_ascii=False, sort_keys=True) for binding in bindings(recipe)],
            "verifyCriteria": [recipe["verifyText"], recipe["verificationBinding"]],
            "incompatibilities": ["Do not claim sequence criteria from a still or replace the Musicvideo master song with the recipe's score suggestions."],
        } for recipe in recipes],
        "provenance": {"sourceURL": "https://github.com/iret77/ai-film-production",
                       "sourceCommit": inventory["sourceCommit"],
                       "sourceSections": [recipe["id"] + ":" + recipe["source"]["path"] + ":" + str(recipe["source"]["line"]) for recipe in recipes],
                       "adaptation": "Complete named recipes with separately retrieved governing selection and synthesis rules.\n" + adaptation},
    })
    relative = "libraries/film-production-blueprints.v3.json"
    data = encoded(blueprint_library)
    (DESTINATION / relative).write_bytes(data)
    manifest["resources"].append({"kind": "library", "id": blueprint_library["id"], "version": "3.1.1",
                                  "path": relative, "sha256": hashlib.sha256(data).hexdigest()})
    manifest_path.write_bytes(encoded(manifest))
    (SOURCE / "runtime-ledger.json").write_bytes(encoded({"schemaVersion": 1, "sections": ledger}))
    index = json.loads((SOURCE / "index.json").read_text())
    for section in index:
        section["runtimeStatus"] = contracts[section["applicationContract"]]["runtimeStatus"]
    (SOURCE / "index.json").write_bytes(encoded(index))
    coverage_path = SOURCE / "coverage.md"
    coverage = coverage_path.read_text()
    coverage = coverage.replace(
        "This is an exhaustive section ledger, not a claim of runtime completion. Complete body and source hash are in each chapter JSON; source lines remain available even when headings repeat. Every runtime row remains open until its consumer acceptance passes.",
        "This is the exhaustive source-to-runtime disposition ledger. Complete body and source hash are in each chapter JSON; source lines remain available even when headings repeat. Runtime-active rows are selectively available to both agent backends and the named typed consumers; dated evidence remains subject to live route checks."
    )
    coverage = coverage.replace(
        "extracted completely; consumer pending",
        "runtime-active; complete entry plus typed/agent consumer"
    )
    coverage = coverage.replace(
        "dated evidence; adapter pending",
        "runtime-active dated evidence; live route gate remains authoritative"
    )
    coverage_path.write_text(coverage)
    bundle_manifest_path = SOURCE / "bundle-manifest.json"
    bundle_manifest = json.loads(bundle_manifest_path.read_text())
    files = []
    for path in sorted(SOURCE.rglob("*")):
        if not path.is_file() or path == bundle_manifest_path or "__pycache__" in path.parts:
            continue
        data = path.read_bytes()
        files.append({
            "path": str(path.relative_to(SOURCE)),
            "bytes": len(data),
            "sha256": hashlib.sha256(data).hexdigest(),
        })
    bundle_manifest["files"] = files
    bundle_manifest_path.write_bytes(encoded(bundle_manifest))


if __name__ == "__main__":
    materialize()
