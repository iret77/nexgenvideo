"""Verify native image decisions against exported canonical generation artifacts."""
from collections import Counter
import hashlib
import json
import math
from pathlib import Path
import re


def digest(data):
    return hashlib.sha256(data).hexdigest()


def sha(value):
    return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value) is not None


def read(directory, name):
    if not isinstance(name, str) or not name or Path(name).is_absolute() or ".." in Path(name).parts:
        raise ValueError("Invalid frame evidence path")
    root = Path(directory).resolve()
    path = root / name
    path.resolve().relative_to(root)
    if any(parent.is_symlink() for parent in [path, *path.parents] if parent != root and root in parent.parents):
        raise ValueError("Aliased frame evidence")
    return path.read_bytes()


def states(interactions, label):
    return [row["evidence"] for row in interactions if row.get("kind") == "verified-state" and row.get("label") == label]


def files(directory, expected):
    return isinstance(expected, dict) and bool(expected) and all(
        sha(value) and digest(read(directory, name)) == value for name, value in expected.items())


def visible_group(row):
    try:
        viewport, frames = row["viewport"], row["frames"]
        if len(viewport) != 4 or not frames or len(frames) != len(row["ids"]):
            return False
        vx, vy, vw, vh = viewport
        for index, frame in enumerate(frames):
            if len(frame) != 4 or not all(type(value) in (int, float) and math.isfinite(value) for value in frame + viewport):
                return False
            x, y, width, height = frame
            if width <= 0 or height <= 0 or x < vx or y < vy or x + width > vx + vw or y + height > vy + vh:
                return False
            for other in frames[:index]:
                ox, oy, ow, oh = other
                if x < ox + ow and x + width > ox and y < oy + oh and y + height > oy:
                    return False
        return True
    except (KeyError, TypeError, ValueError):
        return False


def validate_auto_sketches(native, directory):
    try:
        interactions = native["interactions"]
        generated = states(interactions, "automatic Storyboard sketch through actual tools")
        clicks = Counter(row.get("id") for row in interactions if row.get("kind") == "pointer")
        discovery = states(interactions, "actual image catalog via isolated HTTP")
        if (len(generated) != 2 or len({row["momentID"] for row in generated}) != 2
            or len({row["shotID"] for row in generated}) != 1 or not discovery
            or clicks["generation-batch.approve"] < 2
            or any(row.get("liveProvider") is not False for row in discovery)):
            return False
        for row in generated:
            prefix = row["evidencePrefix"]
            if (row.get("nativeSpendApproval") is not True or row.get("staleAssignmentRejected") is not True
                or row.get("liveProvider") is not False or row.get("livePricing") is not False
                or prefix != "automatic-sketch-" + row["momentID"] or not files(directory, row["files"])
                or clicks["storyboard.sketch.inspect." + row["momentID"]] < 1):
                return False
            proof_bytes = read(directory, prefix + "-proof.json")
            proof = json.loads(proof_bytes)
            output = json.loads(read(directory, prefix + "-output.json"))
            generation = json.loads(read(directory, prefix + "-generation.json"))
            package = json.loads(read(directory, prefix + "-package.json"))
            source = proof["source"]["generated"]
            image = read(directory, prefix + "-image.png")
            prompt = read(directory, prefix + "-prompt.txt")
            if (proof.get("schema") != "storyboard-sketch-proof/v1" or proof["shotID"] != row["shotID"]
                or proof["momentID"] != row["momentID"] or digest(proof_bytes) != row["proofSHA256"]
                or digest(image) != row["imageSHA256"] or not image.startswith(b"\x89PNG\r\n\x1a\n")
                or proof["image"]["sha256"] != digest(image) or source["generationEventID"] != row["assetID"]
                or output["assetID"] != row["assetID"] or output["output"]["sha256"] != digest(image)
                or generation["image"] != proof["image"] or generation["shotID"] != row["shotID"]
                or generation["momentID"] != row["momentID"] or generation["outputReceipt"]["sha256"] != digest(read(directory, prefix + "-output.json"))
                or output["package"]["sha256"] != digest(read(directory, prefix + "-package.json"))
                or package["id"] != row["packageSHA256"] or output["package"]["id"] != package["id"]
                or source["compiledPrompt"]["sha256"] != digest(prompt) or digest(prompt) != row["promptSHA256"]
                or package["payload"]["prompt"].encode() != prompt
                or source["generationReceipt"]["sha256"] != digest(read(directory, prefix + "-generation.json"))
                or output["input"]["prompt"] != prompt.decode()):
                return False
        return True
    except (KeyError, TypeError, ValueError, OSError, AttributeError):
        return False


def validate(report, directory, scale):
    try:
        from generation_batch_busy_evidence import validate as validate_busy_batch
        native, frame, persistence = report["nativeEvidence"], report["frames"], report["persistence"]
        interactions = native["interactions"]
        viewport = report["viewport"]
        backing = viewport["backingScale"]
        if (report.get("workflow") != "core" or report.get("framesApproved") is not True
            or viewport["width"] != 960 or viewport["height"] != 640 or viewport["textScale"] != scale
            or isinstance(backing, bool) or not isinstance(backing, (int, float)) or not math.isfinite(backing) or backing <= 0
            or frame.get("roles") != ["start", "end"] or frame.get("liveProvider") is not False
            or not all(frame.get(key) is True for key in ("staleSelectionRejected", "oldAuditRejected", "redoPreservedSelection", "remixPreservedSelection"))
            or not all(frame["changedEvidence"].get(key) is True for key in ("changedPipelineCopyRejected", "changedHomeSourceRejected", "restoredExactEvidence"))
            or not all(persistence.get(key) is True for key in ("nativeSave", "candidateHistoryPreserved", "selectedFrameAndAuditsCurrent"))
            or persistence.get("reopenMethod") != "VideoProject.load" or not files(directory, persistence["files"])
            or not validate_auto_sketches(native, directory) or not validate_busy_batch(native, directory)):
            return False
        progress = json.loads(read(directory, native["progress"]))
        if (progress.get("failure") is not None or progress.get("interactions") != interactions
            or progress.get("screenshots") != native["screenshots"] or len(native["screenshots"]) < 12
            or len(set(native["screenshots"])) != len(native["screenshots"])):
            return False
        for image in native["screenshots"]:
            data = read(directory, image)
            if len(data) <= 1000 or not data.startswith(b"\x89PNG\r\n\x1a\n"):
                return False
        clicks = Counter(row.get("id") for row in interactions if row.get("kind") == "pointer")
        fields = [row["field"] for row in interactions if row.get("kind") == "text"
                  and row.get("field", {}).get("id", "").startswith(("frames.audit.reason.", "frames.iteration.note"))]
        if (len(fields) != 6 or any(value.get("stage") != "commit-requested" or value.get("commitInput") != "Tab"
            or not value.get("expected") or value.get("actual") != value["expected"]
            or not isinstance(value.get("fontPointSize"), (int, float))
            or abs(value["fontPointSize"] - 13 * scale) >= 0.5 for value in fields)):
            return False
        start = json.loads(read(directory, "frame-evidence/start-index.json"))
        end = json.loads(read(directory, "frame-evidence/end-index.json"))
        ids = frame["candidateIDs"]
        if (len(ids) != 3 or len(set(ids)) != 3 or not all(sha(value) for value in ids)
            or frame["selectedID"] != ids[-1] or frame["selectionHistory"] != ids
            or start["schema"] != "production-frame-candidates/v1" or start["shotID"] != frame["shotID"]
            or start["role"] != "start" or [value["id"] for value in start["candidates"]] != ids
            or start["active"] != ids[-1] or [value["candidateID"] for value in start["decisions"]] != ids
            or end["shotID"] != frame["shotID"] or end["role"] != "end" or end["active"] != frame["endCandidateID"]
            or len(end["candidates"]) != 1 or [value["candidateID"] for value in end["decisions"]] != [frame["endCandidateID"]]):
            return False
        rendered = states(interactions, "actual generated frame")
        if len(rendered) != 4 or len({value["candidateID"] for value in rendered}) != 4:
            return False
        generated = {value["candidateID"]: value for value in rendered}
        image_hashes = []
        for role, index in [("start", start), ("end", end)]:
            for reference in index["candidates"]:
                identifier = reference["id"]
                raw = read(directory, "frame-evidence/" + identifier + ".json")
                candidate = json.loads(raw)
                receipt, usage = candidate["receipt"], candidate["usage"]
                output_bytes = read(directory, "frame-evidence/" + identifier + "-output.json")
                package_bytes = read(directory, "frame-evidence/" + identifier + "-package.json")
                output, package = json.loads(output_bytes), json.loads(package_bytes)
                image = read(directory, "frame-evidence/" + identifier + ".png")
                observed = generated[identifier]
                references = [value["sha256"] for value in usage["plan"]["bindings"]]
                if (reference["sha256"] != identifier or digest(raw) != identifier
                    or receipt["schema"] != "production-frame-receipt/v1" or receipt["shotID"] != frame["shotID"]
                    or receipt["role"] != role or usage["role"] != role or usage["shotID"] != frame["shotID"]
                    or receipt["generation"] != output or output["package"]["sha256"] != digest(package_bytes)
                    or output["package"]["id"] != package["id"] or package["id"] != observed["packageSHA256"]
                    or output["assetID"] != observed["assetID"] or output["output"]["sha256"] != digest(image)
                    or usage["outputSHA256"] != digest(image) or observed["imageSHA256"] != digest(image)
                    or not image.startswith(b"\x89PNG\r\n\x1a\n") or observed.get("nativeSpendApproval") is not True
                    or observed.get("liveProvider") is not False or observed["referenceSHA256"] != references
                    or observed["uploadedSHA256"] != references or not references
                    or observed["planSHA256"] != package["payload"]["binding"]["frameReferencePlanSHA256"]
                    or observed["promptSHA256"] != digest(package["payload"]["prompt"].encode())
                    or package["payload"]["generationInput"]["frameReferencePlan"] != usage["plan"]
                    or clicks["frames.use." + identifier] < 1 or clicks["production.input.image.open." + identifier] < 1):
                    return False
                image_hashes.append(digest(image))
            audit = json.loads(read(directory, "frame-evidence/" + role + "-audit.json"))
            acceptance = json.loads(read(directory, "frame-evidence/" + role + "-acceptance.json"))
            active = generated[index["active"]]
            if (audit["shot_id"] != frame["shotID"] or audit["role"] != role or audit["render_sha256"] != active["imageSHA256"]
                or acceptance["schema"] != "frame-audit-acceptance/v1" or acceptance["imageSHA256"] != active["imageSHA256"]
                or acceptance["auditSHA256"] != digest(read(directory, "frame-evidence/" + role + "-audit.yaml"))
                or not acceptance["reason"].strip()
                or acceptance["acceptedChecks"] != sorted(key for key, value in audit["checks"].items() if value["status"] in ("minor", "blocking"))):
                return False
        if len(set(image_hashes)) != 4:
            return False
        for kind, selected in [("redo", [ids[0]]), ("remix", ids[:2])]:
            events = states(interactions, "native frame " + kind)
            if len(events) != 1 or set(events[0]["candidateIDs"]) != set(selected):
                return False
            recipe_bytes = read(directory, "frame-evidence/" + events[0]["iterationSHA256"] + "-iteration.json")
            recipe = json.loads(recipe_bytes)
            if (digest(recipe_bytes) != events[0]["iterationSHA256"]
                or recipe["kind"] != kind or recipe["shotID"] != frame["shotID"] or recipe["role"] != "start"
                or {value["candidate"]["id"] for value in recipe["sources"]} != set(selected)
                or any(not value["aspects"] for value in recipe["sources"])):
                return False
        audits = states(interactions, "native frame deviations accepted")
        if (len(audits) != 4 or {value["imageSHA256"] for value in audits} != set(image_hashes)
            or any(value.get("qualityClaim") is not False or value.get("overall") != "minor" for value in audits)
            or clicks["generation-batch.approve"] < 6 or clicks["frames.iteration.submit"] != 2
            or clicks["frames.redo." + ids[0]] != 1 or clicks["frames.remix." + frame["shotID"] + ".start"] != 1
            or any(clicks["frames.pick." + identifier] != 1 for identifier in ids[:2])
            or clicks["frames.audit.accept." + frame["shotID"] + ".start"] != 3
            or clicks["frames.audit.accept." + frame["shotID"] + ".end"] != 1
            or not any(value.get("path") == ["File", "Save"] for value in states(interactions, "application-menu"))):
            return False
        return any(row.get("kind") == "visible-group" and set(row.get("ids", [])) == {"frames.iteration.cancel", "frames.iteration.submit"}
                   and visible_group(row) for row in interactions)
    except (KeyError, TypeError, ValueError, OSError, AttributeError):
        return False
