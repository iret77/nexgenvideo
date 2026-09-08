"""Adapt the preserved source corpus to the existing production-library schema."""
import hashlib
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "docs/production-knowledge/ai-film-production-3.1.1"
DESTINATION = ROOT / "Engine/Sources/NexGenEngine/Resources/ProductionKnowledge"
PHASES = ["init", "analysis", "brief", "production_design", "treatment", "storyboard",
          "bible", "shotlist", "sanity", "frames", "render", "review", "assembly", "finish", "generic"]


def encoded(value):
    return (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode()


def materialize():
    inventory = json.loads((SOURCE / "inventory.json").read_text())
    contracts = {item["id"]: item for item in json.loads((SOURCE / "application-contracts.json").read_text())}
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
            ancestors = [candidate for candidate in chapters[chapter]
                         if len(candidate["ancestry"]) < len(section["ancestry"])
                         and section["ancestry"][:len(candidate["ancestry"])] == candidate["ancestry"]]
            links = sorted({entry_locations[reference] for link in section.get("localReferences", [])
                            for reference in link["entryIDs"]})
            entry = {
                "id": section["id"], "title": section["title"],
                "applicability": {"packIDs": [], "phases": PHASES, "intentTags": [chapter], "activeProfileIDs": []},
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
                           "activation": contract["trigger"], "consumerStatus": "runtime-consumer-pending"})
        library = {
            "schemaVersion": "creative-library.v1", "id": library_id, "version": "3.1.1",
            "applicability": {"packIDs": [], "phases": PHASES, "intentTags": [chapter], "activeProfileIDs": []},
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
    blueprint_library = dict(library)
    blueprint_library.update({
        "id": "film-production-blueprints",
        "applicability": {"packIDs": [], "phases": PHASES, "intentTags": ["style", "director", "cinematography"], "activeProfileIDs": []},
        "entries": [{
            "id": recipe["id"], "title": recipe["name"],
            "applicability": {"packIDs": [], "phases": PHASES, "intentTags": ["style", recipe["kind"]], "activeProfileIDs": []},
            "inputs": [], "outputIntent": "Resolve the selected style dimensions with explicit overrides and scoped observation criteria.",
            "guidance": [recipe["completeRecipeMarkdown"],
                         "Read film-production-director-recipes/director-recipes-056ac0ea6c03 and film-production-director-recipes/director-recipes-17cfc8bdffd7 for selection constraints, aliases, harmony and clashes."]
                        + ["Blueprint dimension " + key + ": " + value for key, value in recipe["dimensions"].items()],
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


if __name__ == "__main__":
    materialize()
