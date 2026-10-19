"""Verify attributed native decisions against immutable take/review/history bytes."""
import json

from production_technical_owner_evidence import digest, read, states


OPERATIONS = ["stop", "reroll", "revisePrompt", "changeReference", "changeModel",
              "cleanRewriteWithReference", "cleanRewriteWithModel", "simplifyShot", "rescueRange"]
LABELS = ["Stop generating this shot", "Reroll the unchanged prompt", "Change one prompt line",
          "Change one reference", "Change model or provider route", "Clean rewrite and change a reference",
          "Clean rewrite and change model", "Rewind and simplify the shot", "Use reviewed source ranges"]
POLICY = {"rollsPerPrompt": 5, "failuresBeforeRewrite": 4, "cleanFailuresBeforeModelLimit": 3,
          "channelsBeforeModelLimit": 3, "iterationsBeforeSimplification": 12}


def validate(native, root):
    try:
        rows = native["interactions"]
        beginnings, endings = states(rows, "native take repair decisions begin"), states(rows, "native take repair decisions complete")
        if len(beginnings) != 1 or len(endings) != 1:
            return False
        start = next(i for i, row in enumerate(rows) if row.get("kind") == "verified-state" and row.get("label") == "native take repair decisions begin")
        end = next(i for i, row in enumerate(rows) if row.get("kind") == "verified-state" and row.get("label") == "native take repair decisions complete")
        if end <= start:
            return False
        scoped = rows[start + 1:end]
        choices = states(scoped, "native attributed repair decision")
        pending = states(scoped, "native repair choice pending")
        if len(choices) != len(states(rows, "native attributed repair decision")) or len(pending) != len(states(rows, "native repair choice pending")):
            return False
        if (len(beginnings) != 1 or len(endings) != 1 or [value["operation"] for value in choices] != OPERATIONS
            or [value["operation"] for value in pending] != OPERATIONS[1:]
            or any(value["continueEnabled"] is not False for value in pending)):
            return False
        first, last = beginnings[0], endings[0]
        if first["takeID"] != last["takeID"] or first["shotID"] != last["shotID"] or first["files"] != last["files"]:
            return False
        files = first["files"]
        for when in ("before", "after"):
            if not files or any(digest(read(root, "take-repair-evidence/" + when + "/" + name)) != sha for name, sha in files.items()):
                return False
        take_id = first["takeID"]
        take_paths = [name for name in files if name.endswith("/" + take_id + ".v1.json")]
        if len(take_paths) != 1:
            return False
        take = json.loads(read(root, "take-repair-evidence/before/" + take_paths[0]))
        review_path = "renders/takes/reviews/" + take_id + "/current.v1.json"
        review = json.loads(read(root, "take-repair-evidence/before/" + review_path))
        if (take["schema"] != "render-take/v1" or take["id"] != take_id or take["shotID"] != first["shotID"]
            or review["schema"] != "take-review/v1" or review["takeID"] != take_id or review["reviewer"] != "native-user"
            or review["outputSHA256"] != take["output"]["sha256"]
            or [value["pass"] for value in review["findings"]] != ["identity"]
            or review["findings"][0]["verdict"] != "rejected"
            or "gates.yaml" not in files or "lineage.json" not in files
            or "renders/takes/index-" + take["phase"] + ".v1.json" not in files):
            return False
        identifiers, turns = set(), set()
        for event, operation, title in zip(choices, OPERATIONS, LABELS):
            identifier = event["id"]
            if identifier in identifiers:
                return False
            identifiers.add(identifier)
            actual_files = event["files"]
            expected_files = {identifier + ".json", operation + "-current.json", operation + "-turn.json"}
            if set(actual_files) != expected_files or any(digest(read(root, "take-repair-evidence/" + name)) != sha for name, sha in actual_files.items()):
                return False
            archive = read(root, "take-repair-evidence/" + identifier + ".json")
            if digest(archive) != identifier or read(root, "take-repair-evidence/" + operation + "-current.json") != archive:
                return False
            plan = json.loads(archive)
            if (plan["schema"] != "take-repair-plan/v1" or plan["operation"] != operation or plan["takeID"] != take_id
                or plan["reviewSHA256"] != files[review_path] or plan["reason"] != event["reason"] or not plan["reason"].strip()
                or plan["decidedBy"] != "native-user" or not plan["decidedAt"] or plan["policy"] != POLICY
                or any(type(value) is not int for value in plan["policy"].values())):
                return False
            expected_guard = "paused" if operation in ("stop", "simplifyShot", "rescueRange") else "unchanged-reroll-allowed" if operation == "reroll" else "unchanged-request-rejected"
            if event["unchangedRequestGuard"] != expected_guard:
                return False
            messages = json.loads(read(root, "take-repair-evidence/" + operation + "-turn.json"))
            users = [value for value in messages if value["role"] == "user"]
            assistants = [value for value in messages if value["role"] == "assistant"]
            if len(users) != 1 or not assistants:
                return False
            user = users[0]
            if user["id"] in turns:
                return False
            turns.add(user["id"])
            presentation = user["userPresentation"]
            selected = presentation["choiceRecord"]["selections"]
            commands = "\n".join(value["text"] for value in user["blocks"] if value["kind"] == "text")
            if (user["hidden"] is not True or presentation["typedText"] != plan["reason"]
                or selected != [{"label": "Shot", "values": [first["shotID"]]}, {"label": "Decision", "values": [title]}]
                or f"Read get_render_manifest for {take['phase']}" not in commands
                or "Any generation still needs the existing spend approval." not in commands
                or not any(block.get("kind") == "text" and block.get("text") == "Acceptance transport received render."
                    for assistant in assistants for block in assistant["blocks"])):
                return False
        sequence = []
        for row in scoped:
            kind = row.get("kind")
            if kind == "menu" and row.get("id") == "take.repair.operation": sequence.append(("menu", row.get("item")))
            elif kind == "verified-state" and row.get("label") == "native repair choice pending": sequence.append(("pending", row["evidence"]["operation"]))
            elif kind == "text" and row.get("field", {}).get("id") == "take.repair.reason": sequence.append(("reason", row["field"]["actual"]))
            elif kind == "pointer" and row.get("id") in ("take.repair.save", "take.repair.continue"): sequence.append(("click", row["id"]))
            elif kind == "verified-state" and row.get("label") == "native attributed repair decision": sequence.append(("decision", row["evidence"]["operation"]))
        expected = []
        for index, (operation, label, choice) in enumerate(zip(OPERATIONS, LABELS, choices)):
            expected.append(("menu", label))
            if index: expected.append(("pending", operation))
            expected.extend([("reason", choice["reason"]), ("click", "take.repair.save"),
                ("click", "take.repair.continue"), ("decision", operation)])
        if sequence != expected:
            return False
        limits = [(index, row["field"]) for index, row in enumerate(scoped)
                  if row.get("kind") == "text" and row.get("field", {}).get("id") == "take.repair.rolls"]
        first_save = next(index for index, row in enumerate(scoped)
                          if row.get("kind") == "pointer" and row.get("id") == "take.repair.save")
        if ([field.get("actual") for _, field in limits] != ["0", "5"]
                or any(field.get("actual") != field.get("expected") or index >= first_save for index, field in limits)):
            return False
        selected = [row["item"] for row in scoped if row.get("kind") == "menu" and row.get("id") == "take.repair.operation" and row.get("closed") is True]
        if selected != LABELS:
            return False
        for action in ("save", "continue"):
            if sum(row.get("kind") == "pointer" and row.get("id") == "take.repair." + action for row in scoped) != len(OPERATIONS):
                return False
        fields = [row["field"] for row in scoped if row.get("kind") == "text" and row.get("field", {}).get("id") == "take.repair.reason"]
        if [value["actual"] for value in fields] != [value["reason"] for value in choices] or any(value["expected"] != value["actual"] for value in fields):
            return False
        for before, after in (("providerRequestsBefore", "providerRequestsAfter"), ("spendEventsBefore", "spendEventsAfter")):
            if (type(first[before]) is not int or type(last[before]) is not int or type(last[after]) is not int
                    or first[before] < 0 or first[before] != last[before] or last[before] != last[after]):
                return False
        for suffix in ["take-repair-limits", "take-repair-rescue"] + ["take-repair-" + operation for operation in OPERATIONS[1:-1]]:
            images = [name for name in native["screenshots"] if name.endswith("-" + suffix + ".png")]
            if len(images) != 1 or not read(root, images[0]).startswith(b"\x89PNG\r\n\x1a\n"):
                return False
        legacy = states(rows, "native take repair stop and rescue")
        if (len(legacy) != 1 or legacy[0]["stopSHA256"] != choices[0]["id"]
            or legacy[0]["rescueSHA256"] != choices[-1]["id"] or legacy[0]["reviewSHA256"] != files[review_path]
            or any(legacy[0].get(key) is not True for key in
                   ("invalidLimitBlocked", "staleContinuationBlocked", "actualGenerationGuardBlocked"))):
            return False
        return True
    except (KeyError, TypeError, ValueError, OSError, AttributeError, StopIteration):
        return False
