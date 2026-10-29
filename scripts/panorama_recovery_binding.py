"""Bind native Panorama Undo observations to retained canonical YAML and input events."""
import math
from pathlib import PurePosixPath

from production_bible_entity_evidence import parsed_yaml
from retained_spatial_evidence import digest, local, read, record, require


def validate_bindings(directory, entry, scale, first_receipt):
    try:
        return _validate(directory, entry, scale, first_receipt)
    except (KeyError, IndexError, TypeError, AttributeError) as error:
        raise ValueError("malformed retained Panorama recovery binding") from error


def _validate(directory, entry, scale, first_receipt):
    item = record(entry, "native panorama batch recovery")
    require(isinstance(item, dict), "invalid Panorama recovery observation")
    name = f"panorama-batch-{int(scale * 100)}"
    case = local(directory, name)
    snapshots = item.get("canonicalSnapshots")
    require(isinstance(snapshots, dict), "missing canonical Bible snapshots")
    values, raw = {}, {}
    for state, json_state in (("selected", "selected"), ("removed", "removed"),
                              ("after-undo", "after-undo"), ("before-blocked-undo", "removed"),
                              ("after-blocked-undo", "after-blocked-undo")):
        snapshot = snapshots.get(state)
        require(isinstance(snapshot, dict) and snapshot.get("file") == f"bible-{state}.yaml",
                "missing canonical Bible snapshot")
        path = local(case, snapshot["file"])
        require(snapshot.get("sha256") == digest(path), "canonical Bible snapshot bytes differ")
        raw[state] = path.read_bytes()
        values[state] = parsed_yaml(raw[state])
        require(isinstance(values[state], dict) and values[state] == read(case / f"bible-{json_state}.json"),
                "canonical YAML differs from observed Bible semantics: " + state)
        locations = values[state].get("locations")
        require(isinstance(locations, list) and all(isinstance(location, dict)
                and isinstance(location.get("attributes", {}), dict) and isinstance(location.get("scene3d", {}), dict)
                for location in locations), "invalid canonical Bible location shape")
    require(values["selected"] == values["after-undo"] != values["removed"],
            "successful Undo did not restore selected Bible semantics")
    require(values["removed"] == values["before-blocked-undo"] == values["after-blocked-undo"],
            "blocked Undo changed removed Bible semantics")
    require(raw["before-blocked-undo"] == raw["after-blocked-undo"], "blocked Undo changed canonical bytes")
    negative_before = case / "bible-negative-before.yaml"
    digest(negative_before)
    require(parsed_yaml(negative_before.read_bytes()) == read(case / "bible-initial.json"),
            "negative baseline YAML differs from actual initial Bible")
    for negative in ("panorama-alias", "copied-pov", "character-sheet"):
        path = case / f"bible-negative-after-{negative}.yaml"
        digest(path)
        require(path.read_bytes() == negative_before.read_bytes(), "refused write changed canonical bytes")

    actions = entry.get("interactions")
    require(isinstance(actions, list) and all(isinstance(action, dict) for action in actions), "invalid native event list")

    def observation(label):
        value = record(entry, label)
        require(isinstance(value, dict), "invalid native observation: " + label)
        return next(index for index, action in enumerate(actions) if action.get("label") == label), value

    def command_z(action):
        return (action.get("kind") == "keyboard" and action.get("characters") == "z"
                and type(action.get("code")) is int and action["code"] == 6
                and type(action.get("modifiers")) is int and action["modifiers"] == 1 << 20)

    ready_indices, undo_indices = [], []
    for attempt in (1, 2):
        invalid, _ = observation("actual invalid panorama list " + str(attempt))
        ready, value = observation("panorama removal undo ready " + str(attempt))
        require(value.get("managerOwned") is True and value.get("firstResponderIsTextEditor") is False,
                "Cmd-Z was not owned by the registered document Undo manager")
        require(any(action.get("kind") == "pointer" and action.get("id") == "bible.panorama.remove-invalid"
                    for action in actions[invalid + 1:ready]), "invalid list did not precede actual removal")
        baseline_label = "panorama successful undo feedback baseline" if attempt == 1 else "panorama undo toast baseline"
        baseline, value = observation(baseline_label)
        require(value.get("empty") is True and ready < baseline, "Undo feedback baseline was not empty after registration")
        undo = next((index for index in range(ready + 1, len(actions)) if command_z(actions[index])), None)
        require(undo is not None and baseline < undo, "empty baseline did not precede actual native Cmd-Z")
        ready_indices.append(ready)
        undo_indices.append(undo)
    restored, value = observation("panorama semantic undo restored")
    require(all(value.get(flag) is True for flag in ("semanticBibleRestored", "canRedo", "managerOwned", "feedbackEmpty", "phaseIdle"))
            and value.get("redoActionName") == "Remove Invalid Panorama Assignments", "successful Undo did not complete without feedback")
    second_invalid, _ = observation("actual invalid panorama list 2")
    require(undo_indices[0] < restored < second_invalid < ready_indices[1] < undo_indices[1], "successful Undo chronology differs")
    surface, value = observation("panorama undo surface")
    require(undo_indices[1] < surface and value.get("workspace") == "production"
            and value.get("feedback") == "production.feedback" and value.get("message") == item.get("undoError"),
            "visible Production refusal was not the actual post-Cmd-Z error")
    bounds, value = observation("production feedback bounded scrolling")
    dismiss = next((index for index in range(surface + 1, len(actions))
                    if actions[index].get("kind") == "pointer" and actions[index].get("id") == "production.feedback.dismiss"), None)
    require(dismiss is not None and surface < bounds < dismiss, "bounded feedback was not inspected before Dismiss")
    require(value.get("uiStateFixture") is True and value.get("maximumHeight") == 240,
            "bounded feedback layout fixture is not explicitly identified")

    def rectangle(key):
        coordinates = value.get(key)
        require(isinstance(coordinates, list) and len(coordinates) == 4
                and all(type(number) in (int, float) and math.isfinite(number) for number in coordinates), "invalid feedback rectangle")
        x, y, width, height = coordinates
        require(width > 0 and height > 0, "empty feedback rectangle")
        return x, y, width, height

    x, y, width, height = rectangle("viewport")
    _, _, _, content_height = rectangle("content")
    dx, dy, dw, dh = rectangle("dismiss")
    require(0 <= x and 0 <= y and x + width <= 960 and y + height <= 640 and abs(height - 240) < 1
            and content_height > height * 2 and 0 <= dx and 0 <= dy and dx + dw <= 960 and dy + dh <= 640
            and (dx + dw <= x or x + width <= dx or dy + dh <= y or y + height <= dy), "feedback viewport obscures Dismiss or exceeds window")
    for key in ("before", "after"):
        require(isinstance(value.get(key), list) and len(value[key]) == 2
                and all(type(number) in (int, float) and math.isfinite(number) for number in value[key]), "invalid feedback scroll position")
    require(value["before"] != value["after"], "feedback did not scroll")
    screenshot_indices = []
    for suffix in ("production-feedback-long-before-scroll.png", "production-feedback-long-after-scroll.png"):
        images = [image for image in entry.get("screenshots", []) if isinstance(image, str) and image.endswith("-" + suffix)]
        require(len(images) == 1, "missing actual bounded feedback screenshot")
        image = local(directory, images[0])
        digest(image)
        require(image.read_bytes().startswith(b"\x89PNG\r\n\x1a\n"), "missing actual bounded feedback screenshot")
        screenshot_indices.append(entry["screenshots"].index(images[0]))
    require(screenshot_indices[0] < screenshot_indices[1], "bounded feedback screenshots are reversed")

    for index in (0, 1):
        receipt = read(case / f"receipt-{index}.json")
        require(isinstance(receipt, dict) and isinstance(receipt.get("panorama"), dict)
                and isinstance(receipt["panorama"].get("path"), str), "invalid batch panorama receipt shape")
        views = receipt.get("views")
        require(isinstance(views, list) and all(isinstance(view, dict)
                and isinstance(view.get("geometry"), dict) and isinstance(view.get("image"), dict)
                and isinstance(view["image"].get("path"), str) for view in views), "invalid batch panorama view shape")
    second = read(case / "receipt-1.json")
    source = second.get("panorama", {})
    require(isinstance(source, dict) and item.get("selectedSourceSHA256") == source.get("sha256")
            == digest(case / "second-source.panorama") == first_receipt["panorama"]["sha256"], "second selection does not bind actual selected source")
    source_path = PurePosixPath(source.get("path", ""))
    require(source_path.name == "source.panorama", "source/view filename collision remains")
    views = second.get("views")
    require(isinstance(views, list) and all(isinstance(view, dict) for view in views), "invalid second view list")
    names = ["wide_front", "wide_right", "wide_back", "wide_left", "panorama"]
    geometry = [{"name": name, "yaw": yaw, "pitch": -5, "fov": 75}
                for name, yaw in zip(names[:4], (0, 90, 180, -90))]
    geometry.append({"name": "panorama", "yaw": 0, "pitch": 0, "fov": 60})
    require([view.get("geometry") for view in views] == geometry, "second native view geometry differs")
    require(all(view.get("image", {}).get("path") == str(source_path.parent / (name + ".png"))
                for view, name in zip(views, names)), "source/view filename collision or foreign view directory")
    return item, name
