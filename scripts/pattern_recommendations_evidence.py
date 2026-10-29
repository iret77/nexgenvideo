"""Independent native Pattern-fit observations against the actual pack response."""
from collections import Counter
import hashlib
import json
import math
import yaml
from pathlib import Path


def _validate(directory):
    root = Path(directory).resolve()

    def data(name):
        if not isinstance(name, str) or Path(name).is_absolute() or ".." in Path(name).parts:
            raise ValueError("Invalid pattern evidence path")
        path = root / name
        path.resolve().relative_to(root)
        if any(value.is_symlink() for value in (path, *path.parents) if value != root) or not path.is_file():
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
    if len(candidates) != len(recommendations["results"]):
        raise ValueError("Duplicate pattern candidate")
    chosen = candidates[result["patternID"]]
    if type(chosen.get("fit_score")) not in (float, int) or not math.isfinite(chosen["fit_score"]):
        raise ValueError("The actual candidate has no finite score")
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
    for action in ("production.pattern.details." + pattern_id,
                   "production.pattern.choose." + pattern_id, "production.pattern.none"):
        if clicks[action] < 1:
            raise ValueError("Missing actual native pointer action: " + action)
    if clicks["production.pattern.exclude." + pattern_id] < 2:
        raise ValueError("Native exclude/include was not exercised")
    observations = [row for row in interactions if row.get("kind") == "verified-state"]
    labels = [row.get("label") for row in observations]
    if any(not isinstance(label, str) for label in labels) or len(set(labels)) != len(labels):
        raise ValueError("Duplicate or invalid visible pattern observation")
    states = {row["label"]: row.get("evidence") for row in observations}

    def response_binding(value, raw, excluded):
        if not isinstance(value, dict) or set(value) != {"sha256", "mode", "excluded", "fingerprint"} \
                or value["sha256"] != hashlib.sha256(raw).hexdigest() or value["excluded"] != excluded \
                or value["mode"] not in ("conservative", "balanced", "experimental") \
                or not isinstance(value["fingerprint"], str) or len(value["fingerprint"]) != 64 \
                or any(letter not in "0123456789abcdef" for letter in value["fingerprint"]):
            raise ValueError("The actual view response is not bound to its complete provider bytes/options")
        return value
    visible = states["pattern visible provider values"]
    initial_binding = response_binding(visible.get("responseBinding"), provider_bytes, [])
    if visible["patternID"] != pattern_id or visible["library"] != f'{len(coverage["scored"])}/{coverage["total"]}':
        raise ValueError("The visible comparison did not describe the actual scored library")
    visible_index = float(visible["index"])
    if not math.isfinite(visible_index) or abs(visible_index - chosen["fit_score"]) > 0.500001:
        raise ValueError("The displayed Compatibility Index differs from the actual provider score")
    values = [float(x) for x in visible["confidenceCoverage"].split("|")]
    if len(values) != 2 or any(not math.isfinite(a) or abs(a - b) > 0.000001
                               for a, b in zip(values, [chosen["confidence"], chosen["input_coverage"]])):
        raise ValueError("The UI changed confidence or coverage")
    decision_bytes = data("pattern-decision.json")
    if hashlib.sha256(decision_bytes).hexdigest() != result.get("decisionSHA256"):
        raise ValueError("The native choice changed")
    decision = json.loads(decision_bytes)
    if decision.get("inputFingerprint") != initial_binding["fingerprint"]:
        raise ValueError("The actual view response fingerprint differs from the committed choice")
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
    if len(keys) != 2 or [row.get("modifiers") for row in keys] != [1 << 20, (1 << 20) | (1 << 17)]:
        raise ValueError("Native Undo and Redo were not exercised")
    stale = states.get("pattern stale snapshot refused", {})
    if stale.get("apiNegativeOnly") is not True or stale.get("briefUnchanged") is not True \
            or "Reload recommendations" not in stale.get("message", ""):
        raise ValueError("Missing explicit stale snapshot negative case")
    if data("pattern-gates-before.yaml") != data("pattern-gates-after.yaml"):
        raise ValueError("Pattern selection changed phase approval")
    observed_states = {}
    state_files = {}
    for stage in ("before", "selected", "after-stale", "undo", "redo", "none"):
        state = json.loads(data("pattern-state-" + stage + ".json"))
        if states.get("pattern persisted " + stage) != state:
            raise ValueError("The persisted pattern snapshot differs from the driver: " + stage)
        records = state["files"]
        paths = [record["canonicalPath"] for record in records]
        if len(paths) != len(set(paths)):
            raise ValueError("Duplicate persisted pattern source")
        retained = {}
        for record in records:
            path = record["canonicalPath"]
            if Path(path).is_absolute() or ".." in Path(path).parts:
                raise ValueError("Invalid canonical pattern source")
            raw = data(record["retainedPath"])
            if hashlib.sha256(raw).hexdigest() != record["sha256"]:
                raise ValueError("The retained project pattern bytes changed")
            retained[path] = raw
        project = yaml.safe_load(retained["project.yaml"])
        brief_state = yaml.safe_load(retained["brief.yaml"])
        if not isinstance(state["sourceRoot"], str) or not Path(state["sourceRoot"]).is_absolute() \
                or not state["projectID"] or project["project"] != state["projectID"] \
                or brief_state["project"] != state["projectID"] \
                or brief_state.get("director_pattern") != state["selectedID"] \
                or hashlib.sha256(retained["brief.yaml"]).hexdigest() != state["briefSHA256"]:
            raise ValueError("The pattern snapshot lost its canonical project/Brief binding")
        current = retained.get("brief/pattern-selection.current.v1.json")
        if state["decisionID"] is None:
            if current is not None:
                raise ValueError("An absent pattern pointer has persisted bytes")
        else:
            pointer = json.loads(current)
            prefix = "brief/pattern-selections/" + state["decisionID"]
            if pointer["id"] != state["decisionID"] or pointer["projectID"] != state["projectID"] \
                    or pointer.get("patternID") != state["selectedID"] \
                    or retained[prefix + ".v1.json"] != current \
                    or retained[prefix + ".brief.yaml"] != retained["brief.yaml"] \
                    or brief_state.get("generator") != "brief-native@pattern-selection/" + state["decisionID"] \
                    or pointer["briefSHA256"] != state["briefSHA256"] \
                    or hashlib.sha256(retained[prefix + ".recommendations.json"]).hexdigest() != pointer["resultSHA256"]:
                raise ValueError("The current pattern pointer differs from its immutable source closure")
            if state["selectedID"] is not None:
                signature_bytes = retained[prefix + ".pattern.json"]
                if hashlib.sha256(signature_bytes).hexdigest() != pointer["selectedPatternSHA256"] \
                        or json.loads(signature_bytes)["id"] != state["selectedID"]:
                    raise ValueError("The restored signature differs from its actual choice")
            observed_states[stage] = pointer
        state_files[stage] = (state, retained)
    initial, selected, after_stale, undo, redo, none = [state_files[x] for x in
        ("before", "selected", "after-stale", "undo", "redo", "none")]
    if any(state["sourceRoot"] != initial[0]["sourceRoot"] or state["projectID"] != initial[0]["projectID"]
           or files["project.yaml"] != initial[1]["project.yaml"]
           or files["gates.yaml"] != data("pattern-gates-before.yaml") for state, files in state_files.values()):
        raise ValueError("Pattern observations changed project identity or approval")
    if selected[0]["selectedID"] != pattern_id or initial[0]["selectedID"] == pattern_id \
            or selected[1] != after_stale[1] or selected[0]["decisionID"] != after_stale[0]["decisionID"] \
            or undo[0]["selectedID"] != initial[0]["selectedID"] \
            or redo[0]["selectedID"] != pattern_id or none[0]["selectedID"] is not None:
        raise ValueError("The retained pattern state sequence does not prove selection/refusal/Undo/Redo/none")
    if observed_states["selected"] != decision or observed_states["selected"]["restored"] is not False \
            or observed_states["undo"]["restored"] is not True or observed_states["redo"]["restored"] is not True \
            or observed_states["none"]["restored"] is not False \
            or len({observed_states[stage]["id"] for stage in ("selected", "undo", "redo", "none")}) != 4:
        raise ValueError("Pattern Undo/Redo did not publish distinct authenticated revisions")
    for stage, excluded, enabled in (("excluded", [pattern_id], False), ("included", [], True)):
        response_state = states["pattern comparison " + stage]
        response_bytes = data(response_state["response"])
        response = json.loads(response_bytes)
        actual = next(row for row in response["recommendations"]["results"] if row["pattern_id"] == pattern_id)
        binding = response_binding(response_state.get("responseBinding"), response_bytes, excluded)
        same_input = binding["fingerprint"] == initial_binding["fingerprint"]
        if same_input != (not excluded):
            raise ValueError("The actual view response fingerprint differs from its exclusion options")
        expected_library = response["library_coverage"]
        values = [float(value) for value in response_state["confidenceCoverage"].split("|")]
        actual_index = response_state.get("index")
        actual_score = actual.get("fit_score")
        index_matches = actual_index is None if actual_score is None else (isinstance(actual_index, str)
            and math.isfinite(float(actual_index)) and abs(float(actual_index) - actual_score) <= 0.500001)
        if binding["mode"] != initial_binding["mode"] or not index_matches or len(values) != 2 \
                or any(not math.isfinite(value) or abs(value - expected) > 0.000001
                       for value, expected in zip(values, [actual["confidence"], actual["input_coverage"]])) \
                or response_state["library"] != f'{len(expected_library["scored"])}/{expected_library["total"]}':
            raise ValueError("Exclude/include does not match its actual rendered response")
        if response_state["sha256"] != hashlib.sha256(response_bytes).hexdigest() \
                or response_state["excludedIDs"] != excluded or response_state["chooseEnabled"] is not enabled \
                or actual["excluded"] is not bool(excluded) \
                or (not excluded and response_bytes != provider_bytes):
            raise ValueError("Exclude/include lost its actual response or disabled native choice")
    def index(label):
        matches = [i for i, row in enumerate(interactions) if row.get("kind") == "verified-state" and row.get("label") == label]
        if len(matches) != 1:
            raise ValueError("Missing or duplicate ordered pattern observation: " + label)
        return matches[0]
    stages = [index("pattern persisted " + stage) for stage in ("before", "selected", "after-stale", "undo", "redo", "none")]
    if stages != sorted(stages):
        raise ValueError("The persisted pattern observations are out of order")
    key_positions = [interactions.index(row) for row in keys]
    choose_position = next(i for i, row in enumerate(interactions) if row.get("kind") == "pointer" and row.get("id") == "production.pattern.choose." + pattern_id)
    none_position = next(i for i, row in enumerate(interactions) if row.get("kind") == "pointer" and row.get("id") == "production.pattern.none")
    exclude_positions = [i for i, row in enumerate(interactions) if row.get("kind") == "pointer" and row.get("id") == "production.pattern.exclude." + pattern_id]
    if not stages[0] < exclude_positions[0] < index("pattern comparison excluded") < exclude_positions[1] \
            < index("pattern comparison included") < choose_position < stages[1] < index("pattern stale snapshot refused") < stages[2] \
            < key_positions[0] < stages[3] < key_positions[1] < stages[4] < none_position < stages[5]:
        raise ValueError("The native actions do not cause the retained pattern state transitions")

    if not stages[0] < index("pattern visible provider values") < choose_position \
            or not stages[0] < index("pattern visible signature basis") < choose_position:
        raise ValueError("The rendered pattern observations are not before the actual choice")
    if deliberate:
        reason_positions = [i for i, row in enumerate(interactions) if row.get("kind") == "text"
                            and row.get("field", {}).get("id") == "production.pattern.reason"]
        acknowledge_positions = [i for i, row in enumerate(interactions) if row.get("kind") == "pointer"
                                 and row.get("id") == "production.pattern.acknowledge"]
        confirm_positions = [i for i, row in enumerate(interactions) if row.get("kind") == "pointer"
                             and row.get("id") == "production.pattern.confirm"]
        if len(reason_positions) != 1 or len(acknowledge_positions) != 1 or len(confirm_positions) != 1 \
                or not choose_position < reason_positions[0] < acknowledge_positions[0] < confirm_positions[0] < stages[1]:
            raise ValueError("Deliberate warning decisions are outside the actual choose/save interval")

    screenshots = evidence["screenshots"]
    for suffix in ("comparison", "signature", "excluded", "included", "selected", "undo", "redo", "optional-no-pattern"):
        matches = [name for name in screenshots if name.endswith("-" + suffix + ".png")]
        if len(matches) != 1 or not data(matches[0]).startswith(b"\x89PNG\r\n\x1a\n"):
            raise ValueError("Missing actual pattern screenshot: " + suffix)
    return {"patternID": pattern_id, "scored": len(coverage["scored"]), "total": coverage["total"], "deliberateChoice": deliberate}


def validate(directory):
    try:
        return _validate(directory)
    except (KeyError, TypeError, AttributeError, IndexError, StopIteration, OSError, yaml.YAMLError) as error:
        raise ValueError("Malformed or incomplete native pattern evidence") from error
