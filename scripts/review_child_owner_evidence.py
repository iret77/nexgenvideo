"""Independent retained native child-review byte/coverage/authorization checks."""
import hashlib
import json
import math
from pathlib import Path


def require(value, message):
    if not value:
        raise ValueError(message)


def read(path):
    return json.loads(path.read_text())


def digest(path):
    require(path.is_file() and not path.is_symlink(), "missing regular child-review artifact")
    return hashlib.sha256(path.read_bytes()).hexdigest()


def local(root, name):
    path = Path(name)
    require(name and not path.is_absolute() and all(part not in (".", "..") for part in path.parts), "unsafe child-review artifact")
    value = root / path
    require(value.resolve().is_relative_to(root.resolve()), "child-review artifact escaped")
    return value


def validate(directory, expected_scale=None):
    directory = Path(directory)
    result = read(directory / "review-child-owner-result.json")
    scale = result.get("scale")
    require(not isinstance(scale, bool) and scale in (1, 1.25, 1.5)
            and (expected_scale is None or (not isinstance(expected_scale, bool) and expected_scale == scale))
            and result.get("liveAgent") is False, "actual native child-review scale or fixture scope differs")
    backends = result.get("backends", [])
    require([row.get("backend") for row in backends] == ["anthropicAPI", "claudeCode"], "both actual backend cases required")
    for record in backends:
        root = directory / record["backend"]
        require(read(root / "backend-result.json") == record and type(record.get("scale")) in (int, float) and record.get("scale") == scale
                and record.get("viewport") == [960, 640] and record.get("liveAgent") is False, "actual backend result differs")
        require(record.get("shotCount", 0) >= 34 and record.get("imageCount", 0) >= 34 and record.get("pageCount", 0) > 1,
                "34 actual shots and distinct images required")
        before = digest(root / "chat-before.json")
        require(before == digest(root / "chat-after.json") == record.get("chatSHA256Before") == record.get("chatSHA256After"), "originating chat or provider session changed")
        manifest = read(root / "actual-manifest.json")
        require(manifest.get("id") == record.get("manifestID") and len(manifest.get("snapshot", {}).get("shots", [])) == record["shotCount"]
                and len(manifest.get("derivatives", [])) == record["imageCount"] and len(manifest.get("pages", [])) == record["pageCount"], "actual manifest inventory differs")
        derivatives = {image["id"]: image for image in manifest["derivatives"]}
        require(len(derivatives) == record["imageCount"]
                and {image for page in manifest["pages"] for image in page.get("imageIDs", [])} == set(derivatives), "actual image page coverage incomplete")
        interrupted, final = read(root / "interrupted-journal.json"), read(root / "completed-journal.json")
        require(interrupted.get("status") == "interrupted" and final.get("status") == "completed"
                and interrupted.get("runID") == final.get("runID") and final.get("runID", "").lower() == record.get("runID")
                and interrupted.get("backend") == final.get("backend") == record["backend"], "actual interrupted/resumed run identity differs")
        auths = final.get("authorizations", [])
        require(len(interrupted.get("authorizations", [])) == 1 and len(auths) == record.get("authorizationCount") == 2
                and auths[0] == interrupted["authorizations"][0] and auths[0] != auths[1], "explicit resume did not require a new authorization")
        require(2 <= record.get("interruptedPages", 0) < record["pageCount"]
                and len(interrupted.get("children", [])) >= record["interruptedPages"]
                and all(child in final.get("children", []) for child in interrupted["children"]), "resume lost completed immutable receipts")
        index = read(root / "artifact-index.json")
        require(len(index) == record.get("receiptCount") and len({row["path"] for row in index}) == len(index), "actual artifact index differs")
        artifacts = {}
        for row in index:
            require(digest(local(root, row["artifact"])) == row.get("sha256"), "retained actual artifact bytes changed")
            artifacts[row["path"]] = row

        def bound(reference):
            require(reference.get("path") in artifacts and artifacts[reference["path"]]["sha256"] == reference.get("sha256"), "unbound actual receipt reference")
            return read(local(root, artifacts[reference["path"]]["artifact"]))

        require(bound(final["manifest"]) == manifest, "saved manifest bytes differ")
        checkpoint = record.get("committedPageCheckpoint", {})
        checkpoint_journal = read(root / "write-checkpoint-journal.json")
        held = checkpoint.get("page", {})
        require(checkpoint.get("shutdownHeld") is True and checkpoint.get("phaseLeaseHeld") is True
                and checkpoint.get("completedPages") == record["interruptedPages"]
                and checkpoint.get("publishedPages") == record["interruptedPages"] + 1
                and checkpoint_journal.get("status") == "running" and checkpoint_journal.get("runID") == final["runID"]
                and checkpoint_journal.get("authorizations") == interrupted["authorizations"]
                and checkpoint_journal.get("children") == interrupted["children"]
                and len(checkpoint_journal["children"]) == checkpoint["publishedPages"]
                and held in interrupted["children"] and held in final["children"], "committed page was orphaned across held shutdown/cancellation")
        held_page = bound(held)
        require(held_page.get("submission", {}).get("pageID") == checkpoint.get("pageID")
                and held_page.get("writeEvidence", {}).get("authID", "").lower() == checkpoint.get("authID"), "checkpoint names another actual page")
        auth_ids = {}
        for auth in auths:
            value = bound(auth)
            require(value.get("runID") == final["runID"] and value.get("backend") == record["backend"]
                    and value.get("manifest") == final["manifest"], "authorization belongs to another run")
            require(isinstance(value.get("id"), str) and value["id"], "authorization artifact lacks its own identity")
            auth_ids[auth["path"]] = value["id"]
        require(len({value.lower() for value in auth_ids.values()}) == 2,
                "explicit resume reused an authorization identity")
        require(checkpoint["authID"] == str(auth_ids[auths[0]["path"]]).lower()
                and all(bound(reference).get("authorization") == auths[0] for reference in interrupted["children"]),
                "held checkpoint was not authorized before Cancel")
        pages = {}
        synthesis = 0
        expected_calls = []
        expected_requests = set()
        request_contexts = {}
        for child in final.get("children", []):
            page = bound(child)
            delivery = bound(page["delivery"])
            submitted = page.get("submission", {})
            require(submitted.get("pageID") == delivery.get("pageID") and submitted.get("manifestID") == manifest["id"], "actual page binding differs")
            ids = delivery.get("itemIDs", [])
            observations = submitted.get("observations", [])
            require(ids and len(ids) == len(observations) and {value.get("itemID") for value in observations} == set(ids)
                    and all(0 < len(value.get("text", "").encode()) <= 512 for value in observations), "actual labelled observations incomplete")
            require(delivery.get("authorization") == page.get("authorization") and page["authorization"] in auths, "child authorized by another approval")
            require(child in interrupted["children"] or page["authorization"] == auths[1], "resumed child did not use the new approval")
            read_call, write_call = delivery.get("readEvidence", {}), page.get("writeEvidence", {})
            for call, tool in [(read_call, "get_render_review_page"), (write_call, "write_render_review_page")]:
                response = call.get("response", {})
                expected = "mcp__nexgen__" + tool if record["backend"] == "claudeCode" else tool
                require(call.get("runID") == final["runID"] and call.get("manifestID") == manifest["id"]
                        and call.get("authID") == auth_ids[page["authorization"]["path"]]
                        and call.get("pageID") == submitted["pageID"] and response.get("toolName") == expected
                        and response.get("modelID") == final.get("modelID") and response.get("messageID") and response.get("toolUseID"), "actual model response identity differs")
                canonical = json.dumps(json.loads(response["toolInputJSON"]), sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode()
                require(hashlib.sha256(canonical).hexdigest() == response.get("toolInputSHA256"), "actual response arguments changed")
                expected_calls.append((response["messageID"], response["toolUseID"], response["toolName"], response["modelID"], response["toolInputSHA256"]))
            require(read_call["response"]["messageID"] != write_call["response"]["messageID"]
                    and read_call["response"]["sessionID"] == write_call["response"]["sessionID"]
                    and read_call["generationID"] == write_call["generationID"], "write did not follow read in its own child context")
            request_key = (str(write_call["authID"]).lower(), submitted["pageID"])
            expected_requests.add(request_key)
            request_contexts[request_key] = {"runID": str(final["runID"]).lower(), "manifestID": manifest["id"],
                "backend": record["backend"], "kind": delivery.get("kind")}
            if delivery.get("kind") == "page":
                require(len(delivery.get("deliveredImages", [])) <= 2 and submitted["pageID"] not in pages, "page images exceeded bounds or page duplicated")
                pages[submitted["pageID"]] = delivery
            elif delivery.get("kind") == "synthesis":
                synthesis += 1
        require(synthesis == 1, "actual final synthesis receipt missing")
        require(set(pages) == {page["id"] for page in manifest["pages"]}, "not every actual manifest page completed")
        for page in manifest["pages"]:
            require(pages[page["id"]]["itemIDs"] == page["itemIDs"], "actual page item order changed")
            require([image.get("reference") for image in pages[page["id"]].get("deliveredImages", [])]
                    == [derivatives[image]["reference"] for image in page["imageIDs"]], "actual delivered image mapping differs")
        heartbeats = read(root / "actual-ui-heartbeats.json")
        require(heartbeats == record.get("heartbeats") and len(heartbeats.get("samples", [])) >= 2
                and 0 < heartbeats.get("maximumGapSeconds", 0) <= heartbeats.get("maximumAllowedGapSeconds", 0) == 0.5,
                "actual main-actor responsiveness evidence missing")
        require([row.get("label") for row in heartbeats.get("boundaries", [])] == ["prepare-start", "prepared", "completed"], "actual preparation/finalization boundaries missing")
        samples = heartbeats["samples"]
        require(all(type(value.get("time")) in (int, float) and math.isfinite(value["time"])
                    and type(value.get("gapSeconds")) in (int, float) and math.isfinite(value["gapSeconds"])
                    and 0 < value["gapSeconds"] <= 0.5 for value in samples)
                and abs(max(value["gapSeconds"] for value in samples) - heartbeats["maximumGapSeconds"]) < 0.000001
                and all(abs(current["time"] - prior["time"] - current["gapSeconds"]) < 0.000001
                        for prior, current in zip(samples, samples[1:])), "heartbeat maximum differs from actual retained samples")
        native = record.get("native", {})
        progress = read(local(root, native.get("progress", "")))
        actions = native.get("interactions", [])
        require(progress.get("failure") is None and progress.get("interactions") == actions
                and progress.get("screenshots") == native.get("screenshots"), "actual child-review native log differs")
        clicks = [row.get("id") for row in actions if row.get("kind") == "pointer"]
        required = ["render-review.agent.prepare", "render-review.agent.approve", "render-review.agent.cancel",
                    "render-review.agent.prepare", "render-review.agent.approve"]
        selected = [value for value in clicks if value in set(required)]
        require(selected == required, "native prepare/approve/cancel/explicit resume order differs")
        committed = [index for index, action in enumerate(actions) if action.get("label") == "actual committed page before cancellation"
            and action.get("evidence") == checkpoint]
        cancelled = [index for index, action in enumerate(actions) if action.get("kind") == "pointer" and action.get("id") == "render-review.agent.cancel"]
        waiting = [index for index, action in enumerate(actions) if action.get("label") == "actual Cancel waits for owned shutdown"
            and action.get("evidence") == {"pageID": checkpoint["pageID"], "phaseLeaseHeld": True, "registryActive": True, "state": "stopping"}]
        approvals = [i for i, action in enumerate(actions) if action.get("kind") == "pointer" and action.get("id") == "render-review.agent.approve"]
        require(len(committed) == len(cancelled) == len(waiting) == 1 and len(approvals) == 2
                and approvals[0] < committed[0] < cancelled[0] < waiting[0] < approvals[1], "native Cancel did not wait at the committed-page shutdown boundary")
        require(native.get("screenshots"), "actual child-review screenshots missing")
        require(any(name.endswith("-committed-page-shutdown-held.png") for name in native["screenshots"]), "committed-page native screenshot missing")
        for name in native["screenshots"]:
            path = local(root, name)
            require(path.stat().st_size > 1000 and path.read_bytes().startswith(b"\x89PNG\r\n\x1a\n"), "actual child-review PNG missing")
        requests = read(root / "actual-child-requests.json")
        require(len(requests) == record.get("childContexts") and len({(row["authID"], row["pageID"]) for row in requests}) == len(requests), "child context identity reused")
        held_requests = [row for row in requests if row.get("pageID") == checkpoint["pageID"]]
        require(len(held_requests) == 1 and held_requests[0].get("authID", "").lower() == checkpoint["authID"], "Resume repeated the already committed page context")
        require({(str(row["authID"]).lower(), row["pageID"]) for row in requests} == expected_requests
                and len(requests) == len(final["children"]), "actual requests differ from the complete retained child receipts")
        require(all(all(row.get(key) == value for key, value in request_contexts[(str(row["authID"]).lower(), row["pageID"])].items())
                    for row in requests), "actual request context differs from its retained child")
        completed_before_cancel = {bound(reference)["submission"]["pageID"] for reference in interrupted["children"]}
        require(all(sum(row.get("pageID") == page_id for row in requests) == 1 for page_id in completed_before_cancel),
                "Resume repeated a previously completed page context")
        wire_calls = []
        if record["backend"] == "anthropicAPI":
            bodies = sorted(root.glob("api-request-*.json"))
            require(bodies and len(bodies) == len(list(root.glob("api-response-*.sse"))), "actual API request/response wire evidence missing")
            require(all(read(path).get("model") == final["modelID"] for path in bodies), "actual API request model differs")
            for path in root.glob("api-response-*.sse"):
                events = [json.loads(line[6:]) for line in path.read_text().splitlines() if line.startswith("data: ")]
                starts = [row["message"] for row in events if row.get("type") == "message_start"]
                require(len(starts) == 1, "actual API response message identity missing")
                message = starts[0]
                for event in events:
                    block = event.get("content_block", {})
                    if event.get("type") != "content_block_start" or block.get("type") != "tool_use":
                        continue
                    fragments = [row["delta"]["partial_json"] for row in events if row.get("type") == "content_block_delta"
                                 and row.get("index") == event["index"] and row.get("delta", {}).get("type") == "input_json_delta"]
                    arguments = json.loads("".join(fragments)) if fragments else block["input"]
                    canonical = json.dumps(arguments, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode()
                    wire_calls.append((message["id"], block["id"], block["name"], message["model"], hashlib.sha256(canonical).hexdigest()))
        else:
            lines = read(root / "actual-cli-decoder-lines.json")
            require(lines and all(json.loads(line).get("type") == "assistant" for line in lines), "actual CLI decoder input lines missing")
            for line in lines:
                message = json.loads(line)["message"]
                for block in message["content"]:
                    if block.get("type") != "tool_use":
                        continue
                    canonical = json.dumps(block["input"], sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode()
                    wire_calls.append((message["id"], block["id"], block["name"], message["model"], hashlib.sha256(canonical).hexdigest()))
        require(len(wire_calls) == len(set(wire_calls)) == len(expected_calls) and set(wire_calls) == set(expected_calls),
                "retained backend responses do not bind the actual read/write receipt identities and inputs")
    return result
