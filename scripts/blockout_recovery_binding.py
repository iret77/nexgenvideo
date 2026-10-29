"""Require cause-specific recovery refusals and actual ordered native reattachment."""
from retained_spatial_evidence import local, read, record, require


def validate_bindings(directory, entry, scale):
    item = record(entry, "native blockout recovery")
    name = f"blockout-recovery-{int(scale * 100)}"
    root = local(directory, name)
    for state in ("missing", "tampered"):
        refusals = read(root / (state + "-refusals.json"))
        require(isinstance(refusals, dict)
                and refusals.get("staleError") == "The blockout assignments changed. Reload Shot Planning before removing them."
                and refusals.get("leaseError") == "Finish the current production action before changing this plan.",
                "recovery refusal must identify the actual stale snapshot and competing mutation lease")
    actions = entry.get("interactions")
    require(isinstance(actions, list) and all(isinstance(action, dict) for action in actions), "invalid blockout event list")
    record(entry, "blockout recovery complete tampered")
    complete = next(index for index, action in enumerate(actions) if action.get("label") == "blockout recovery complete tampered")
    recovery = next(index for index, action in enumerate(actions) if action.get("label") == "native blockout recovery")
    removes = [index for index, action in enumerate(actions) if action.get("kind") == "pointer"
               and action.get("id") == "shot.blockout.remove" and complete < index < recovery]
    plans = [index for index, action in enumerate(actions) if action.get("kind") == "pointer"
             and action.get("id") == "shot.blockout.plan" and complete < index < recovery]
    require(len(removes) == len(plans) == 1 and removes[0] < plans[0],
            "actual single removal must precede native plan reattachment after recovery")
    return item, name
