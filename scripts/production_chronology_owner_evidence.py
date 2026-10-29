import argparse
import hashlib
import json
from pathlib import Path
import re


def require(condition, message):
    if not condition:
        raise ValueError(message)


def gate(bytes_, phase):
    text = bytes_.decode("utf-8")
    block = re.search(r"(?m)^  " + re.escape(phase) + r":\s*\n((?:^    .*\n|^\s*\n)+)", text)
    require(block is not None, "Actual gate phase is absent: " + phase)
    approved = re.findall(r"(?m)^    approved: (true|false)\s*$", block.group(1))
    require(len(approved) == 1, "Actual gate approval is ambiguous: " + phase)
    return approved[0] == "true"


def validate(output):
    output = Path(output)
    result = json.loads((output / "chronology-result.json").read_text())
    progress = json.loads((output / "chronology-owner.json").read_text())
    require(result["schema"] == "chronology-owner-acceptance/v1", "Unknown chronology evidence")
    require(progress.get("failure") is None, "Native chronology interaction failed")
    require(result["runtimeToolCalls"] == 6 and result["providerGenerations"] == 0,
            "Chronology corrections bypassed the canonical tool or submitted paid media")
    expected = {"unknownOrder", "discontinuity", "unresolvedDecision"}
    require({row["defect"] for row in result["cases"]} == expected and len(result["cases"]) == 3,
            "Missing or repeated negative chronology case")
    observations = progress["interactions"]
    for row in result["cases"]:
        directory = output / row["defect"]
        draft = json.loads((directory / "draft.v2.json").read_text())
        repaired = json.loads((directory / "repaired.v2.json").read_text())
        require(draft["schema"] == repaired["schema"] == "story-causality/v2", "A legacy graph replaced actual V2 evidence")
        require(draft["header"]["projectID"] == repaired["header"]["projectID"], "The correction changed project identity")
        require(repaired["header"]["revision"] == draft["header"]["revision"] + 1 == row["repairedRevision"],
                "The correction did not append a new immutable revision")
        require(draft["header"]["revision"] == row["draftRevision"], "Reported revision differs from actual bytes")
        require([b["id"] for b in draft["beats"]] == [b["id"] for b in repaired["beats"]] == ["beat-red", "beat-blue"],
                "Repair replaced stable story identity")
        for name, graph in [("draft", draft), ("repaired", repaired)]:
            actual = (directory / (name + ".md")).read_bytes()
            digest = hashlib.sha256(actual).hexdigest()
            require(digest == graph["treatmentReference"]["sha256"] == row[name + "TreatmentSHA256"],
                    "Graph does not bind the actual archived Treatment bytes")
            require(all(beat["excerpt"] in actual.decode("utf-8") for beat in graph["beats"]),
                    "Chronology contains invented Treatment excerpts")
        changes = repaired["stateChanges"]
        require(len(changes) == 2 and changes[0]["after"] == changes[1]["before"] and not repaired["unresolvedDecisions"],
                "The repaired state sequence remains discontinuous or unresolved")
        relation = repaired["temporalRelations"]
        require(len(relation) == 1 and relation[0]["kind"] == "before"
                and relation[0]["firstBeatID"] == "beat-red" and relation[0]["secondBeatID"] == "beat-blue",
                "Native correction did not resolve actual world-time order")
        if row["defect"] == "unknownOrder":
            require(draft["temporalRelations"][0]["kind"] == "unknown", "Unknown-order case has no actual unknown edge")
        elif row["defect"] == "discontinuity":
            require(draft["stateChanges"][0]["after"] != draft["stateChanges"][1]["before"], "State-jump case has no actual state jump")
        else:
            require(bool(draft["unresolvedDecisions"]), "Decision case contains no actual unresolved decision")
        before = (directory / "draft-gates.yaml").read_bytes()
        refused = (directory / "refused-gates.yaml").read_bytes()
        approved = (directory / "repaired-gates.yaml").read_bytes()
        require(before == refused and not gate(refused, "treatment"), "Gate refusal mutated actual approval bytes")
        require(gate(approved, "treatment") and not gate(approved, "script"), "Native approval did not preserve downstream pending state")
        require(any(x.get("kind") == "verified-state" and x.get("label") == "chronology repaired " + row["defect"]
                    for x in observations), "The actual native correction was not observed")
    inputs = [x for x in observations if x.get("kind") == "text"]
    require(len([x for x in inputs if x.get("field", {}).get("id") == "story.prose.input.Revise treatment"]) == 6,
            "Native Treatment revision text was not actually entered six times")
    pointers = [x.get("id") for x in observations if x.get("kind") == "pointer"]
    require(pointers.count("story.prose.action.Revise treatment") == 6, "Revision buttons were not actually clicked")
    require(pointers.count("pipeline.overview.approve.treatment") == 3, "Repairs were not natively approved")
    require(pointers.count("pipeline.overview.dock.diagnostics") == 3, "Refusals were not actually inspected")
    menus = [x for x in observations if x.get("kind") == "menu"]
    require(len([x for x in menus if x.get("id") == "pipeline.overview.actions.treatment"
                 and x.get("item") == "Rewind to here…" and x.get("closed")]) == 3,
            "Explicit native rewinds were bypassed")
    screenshots = progress["screenshots"]
    require(len(screenshots) >= 6, "Missing actual refusal/rewind screenshots")
    for filename in screenshots:
        require(Path(filename).name == filename and (output / filename).read_bytes().startswith(b"\x89PNG\r\n\x1a\n"),
                "Invalid native screenshot")
    return {"schema": "independent-chronology-owner-verification/v1", "cases": sorted(expected), "nativeInputVerified": True}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    arguments = parser.parse_args()
    print(json.dumps(validate(arguments.output), indent=2))
