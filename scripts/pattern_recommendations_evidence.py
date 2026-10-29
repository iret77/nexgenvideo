"""Independent native Pattern-fit observations against the actual pack response."""
from collections import Counter
import hashlib
import json
from pathlib import Path


def validate(directory):
    root = Path(directory).resolve()

    def data(name):
        if not isinstance(name, str) or Path(name).is_absolute() or ".." in Path(name).parts:
            raise ValueError("Invalid pattern evidence path")
        path = root / name
        path.resolve().relative_to(root)
        if path.is_symlink() or not path.is_file():
            raise ValueError("Missing or aliased pattern evidence")
        return path.read_bytes()

    result = json.loads(data("pattern-result.json"))
    for key in ("nativeRecommendations", "exactProviderResult", "nativeExcludeInclude", "persistedWarnings",
                "nativeUndoRedo", "nativeNoPattern", "staleSnapshotRejected", "gatesUnchanged"):
        if result.get(key) is not True:
            raise ValueError("Missing native pattern observation: " + key)
    if result.get("liveProvider") is not False:
        raise ValueError("Pattern fixtures cannot claim live provider proof")
    provider_bytes = data("pattern-provider.json")
    if hashlib.sha256(provider_bytes).hexdigest() != result.get("providerSHA256"):
        raise ValueError("Actual provider response changed")
    provider = json.loads(provider_bytes)
    recommendations = provider["recommendations"]
    candidates = {row["pattern_id"]: row for row in recommendations["results"]}
    chosen = candidates[result["patternID"]]
    if chosen["excluded"]:
        raise ValueError("An excluded pattern was selected")
    for slot in recommendations["slots"].values():
        if slot is not None and (candidates[slot]["excluded"] or candidates[slot]["fit_band"] == "provisional" or candidates[slot]["rank"] is None):
            raise ValueError("A provisional or excluded candidate occupied a winning slot")
    coverage = provider["library_coverage"]
    groups = coverage["scored"] + coverage["unscored"] + coverage["invalid"]
    if len(set(groups)) != coverage["total"] or len(groups) != coverage["total"]:
        raise ValueError("Partial library coverage was misrepresented")
    evidence = result["evidence"]
    interactions = evidence["interactions"]
    progress = json.loads(data(evidence["progress"]))
    if progress.get("failure") is not None or progress.get("interactions") != interactions or progress.get("screenshots") != evidence["screenshots"]:
        raise ValueError("The actual native driver evidence differs from its summary")
    clicks = Counter(row.get("id") for row in interactions if row.get("kind") == "pointer")
    pattern_id = result["patternID"]
    for action in ("production.pattern.open", "production.pattern.details." + pattern_id,
                   "production.pattern.choose." + pattern_id, "production.pattern.none"):
        if clicks[action] < 1:
            raise ValueError("Missing actual native pointer action: " + action)
    if clicks["production.pattern.exclude." + pattern_id] < 2:
        raise ValueError("Native exclude/include was not exercised")
    states = {row.get("label"): row.get("evidence") for row in interactions if row.get("kind") == "verified-state"}
    visible = states["pattern visible provider values"]
    if visible["patternID"] != pattern_id or visible["library"] != f'{len(coverage["scored"])}/{coverage["total"]}':
        raise ValueError("The visible comparison did not describe the actual scored library")
    if abs(float(visible["index"]) - chosen["fit_score"]) > 0.500001:
        raise ValueError("The displayed Compatibility Index differs from the actual provider score")
    values = [float(x) for x in visible["confidenceCoverage"].split("|")]
    if values != [chosen["confidence"], chosen["input_coverage"]]:
        raise ValueError("The UI changed confidence or coverage")
    decision_bytes = data("pattern-decision.json")
    if hashlib.sha256(decision_bytes).hexdigest() != result.get("decisionSHA256"):
        raise ValueError("The native choice changed")
    decision = json.loads(decision_bytes)
    if decision["patternID"] != pattern_id or decision["restored"] is not False:
        raise ValueError("The native choice is not this actual initial selection")
    selected_result = data("pattern-selected.recommendations.json")
    if hashlib.sha256(selected_result).hexdigest() != decision["resultSHA256"] or selected_result != provider_bytes:
        raise ValueError("The selection did not bind the exact compared response")
    signature = data("pattern-selected.pattern.json")
    if hashlib.sha256(signature).hexdigest() != decision["selectedPatternSHA256"]:
        raise ValueError("The saved measured/documented/inferred signature changed")
    detail = json.loads(signature)
    if detail["id"] != pattern_id:
        raise ValueError("The choice substituted another signature")
    observed = states["pattern visible signature basis"]
    field = {"asl": "asl_range", "framing": "framing_mix"}.get(observed["field"], observed["field"])
    if observed["basis"] != detail[field]["basis"] or result["evidenceBasis"] != detail[field]["basis"]:
        raise ValueError("The native signature relabelled inferred data as measured")
    brief = data("pattern-selected.brief.yaml")
    if hashlib.sha256(brief).hexdigest() != decision["briefSHA256"]:
        raise ValueError("The decision lost the exact Brief it changed")
    warnings = chosen["exclusion_reasons"] + chosen["conflicts"]
    if chosen["fit_band"] == "provisional":
        warnings.append("Not ranked: inputs or confidence are incomplete.")
    if decision["warnings"] != warnings:
        raise ValueError("The deliberate choice discarded warnings")
    deliberate = chosen["fit_band"] in ("weak", "provisional") or bool(chosen["conflicts"])
    if result["nativeDeliberateChoice"] is not deliberate:
        raise ValueError("Wrong native warning branch claimed")
    if deliberate:
        if not decision["reason"].strip() or clicks["production.pattern.acknowledge"] < 1 or clicks["production.pattern.confirm"] < 1:
            raise ValueError("Deliberate choice had no native warning acknowledgement")
        if not any(row.get("kind") == "text" and row.get("field", {}).get("id") == "production.pattern.reason"
                   and row["field"].get("actual") == decision["reason"] for row in interactions):
            raise ValueError("The reason was not entered through its actual field")
    keys = [row for row in interactions if row.get("kind") == "keyboard" and row.get("code") == 6]
    if len(keys) < 2 or not any(row.get("modifiers", 0) & (1 << 17) for row in keys):
        raise ValueError("Native Undo and Redo were not exercised")
    if states.get("pattern stale snapshot refused") != {"apiNegativeOnly": True, "briefUnchanged": True}:
        raise ValueError("Missing explicit stale snapshot negative case")
    if data("pattern-gates-before.yaml") != data("pattern-gates-after.yaml"):
        raise ValueError("Pattern selection changed phase approval")
    screenshots = evidence["screenshots"]
    for suffix in ("comparison", "signature", "excluded", "selected", "optional-no-pattern"):
        matches = [name for name in screenshots if name.endswith("-" + suffix + ".png")]
        if len(matches) != 1 or not data(matches[0]).startswith(b"\x89PNG\r\n\x1a\n"):
            raise ValueError("Missing actual pattern screenshot: " + suffix)
    return {"patternID": pattern_id, "scored": len(coverage["scored"]), "total": coverage["total"], "deliberateChoice": deliberate}
