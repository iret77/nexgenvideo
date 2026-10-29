"""Independent checks for the bounded native color-reference scenario, not live AI quality."""
import base64
import hashlib
import json
from pathlib import Path


def validate(directory):
    root = Path(directory).resolve()

    def read(name):
        if not isinstance(name, str) or Path(name).is_absolute() or ".." in Path(name).parts:
            raise ValueError("Invalid color evidence path")
        path = root / name
        path.resolve().relative_to(root)
        if path.is_symlink() or not path.is_file():
            raise ValueError("Missing actual color evidence")
        return path.read_bytes()

    result = json.loads(read("color-reference-result.json"))
    for key in ("nativeMeasuredComparison", "actualToolReadout", "nativeProposalDiscard", "nativeProposalApply",
                "nativeUndoRedo", "nativeStaleRefusal", "sourceProjectPreserved"):
        if result.get(key) is not True:
            raise ValueError("Missing color owner observation: " + key)
    if result.get("liveAgent") is not False or result.get("directMutationRefusals") != 3:
        raise ValueError("Unproved AI availability or missing actual mutation refusals")
    request_bytes, proposal_bytes = read("actual-color-request.json"), read("actual-color-proposal.json")
    for data, key in ((request_bytes, "requestSHA256"), (proposal_bytes, "proposalSHA256")):
        if hashlib.sha256(data).hexdigest() != result.get(key):
            raise ValueError("Actual bounded model evidence changed")
    request, proposal = json.loads(request_bytes), json.loads(proposal_bytes)
    if request["scope"] != {key: proposal[key] for key in ("comparisonID", "clipID", "referenceID")}:
        raise ValueError("The proposal was not bound to the actual requested comparison")
    if proposal["clipID"] != result["clipID"] or proposal["referenceID"] != result["referenceID"]:
        raise ValueError("The proposal targeted another clip or reference")
    if proposal["grade"] != {"exposure": 0.5} or not proposal["rationale"]:
        raise ValueError("The isolated response did not exercise the declared grade")
    blocks = json.loads(read("actual-color-tool.json"))
    text = next(row["text"] for row in blocks if row["kind"] == "text")
    scopes = json.loads(text)
    if not all(key in scopes for key in ("clip", "reference", "gap")) or len(request["imageSHA256"]) != 2:
        raise ValueError("The actual comparison lost its frames or measured scopes")
    actual_images = [hashlib.sha256(base64.b64decode(row["base64"], validate=True)).hexdigest()
                     for row in blocks if row["kind"] == "image"]
    if actual_images != request["imageSHA256"]:
        raise ValueError("The actual model request did not contain the measured frames")
    actions = result["interactions"]
    progress = json.loads(read(result["progress"]))
    if progress.get("failure") is not None or progress["interactions"] != actions or progress["screenshots"] != result["screenshots"]:
        raise ValueError("The driver output differs from the returned owner evidence")
    clicks = [row.get("id") for row in actions if row.get("kind") == "pointer"]
    for action, minimum in (("color.reference.open", 1), ("color.reference.choose", 1),
                            ("library.pick." + result["referenceID"], 1), ("color.reference.measure", 3),
                            ("color.reference.propose", 3), ("color.reference.apply", 2), ("color.reference.discard", 1)):
        if clicks.count(action) < minimum:
            raise ValueError("Missing actual native color action: " + action)
    if len([row for row in actions if row.get("kind") == "keyboard" and row.get("code") == 6]) < 3:
        raise ValueError("The native Undo/Redo sequence is missing")
    fields = [row for row in actions if row.get("kind") == "text"]
    if not any(row.get("field", {}).get("id") == "inspector.adjust.value.color.exposure.ev" for row in fields):
        raise ValueError("The stale rejection was not triggered by a native independent edit")
    observations = [row["evidence"] for row in actions if row.get("kind") == "verified-state" and row.get("label") == "actual native color measurement"]
    if len(observations) != 3 or any(row["toolSHA256"] != hashlib.sha256(read("actual-color-tool.json")).hexdigest() for row in observations):
        raise ValueError("The visible native readout was not checked against the actual color tool")
    values = [float(value) for value in observations[-1]["mean"].split("|")]
    if values != [scopes["clip"]["luma"]["mean"], scopes["reference"]["luma"]["mean"], scopes["gap"]["lumaMean"]]:
        raise ValueError("The native readout changed measured color values")
    if len(result["screenshots"]) < 4 or any(not read(name).startswith(b"\x89PNG\r\n\x1a\n") for name in result["screenshots"]):
        raise ValueError("Actual native color screenshots are missing")
    return result
