"""Check an actually paused/continued native batch against its durable journals."""
import json

from production_frames_owner_evidence import digest, read, sha, states


def validate(native, directory):
    try:
        interactions = native["interactions"]
        paused = states(interactions, "approved batch paused by competing host lease")
        continued = states(interactions, "approved batch explicitly continued")
        if len(paused) != 1 or len(continued) != 1:
            return False
        paused, continued = paused[0], continued[0]
        batch_id = paused["batchID"]
        prefix = "batch-busy-evidence/"
        before_bytes = read(directory, prefix + "journal-approved.json")
        paused_bytes = read(directory, prefix + "journal-paused.json")
        before, after = json.loads(before_bytes), json.loads(read(directory, prefix + "journal-complete.json"))
        batch_bytes = read(directory, prefix + "batch.json")
        batch = json.loads(batch_bytes)
        requests = json.loads(read(directory, prefix + "requests.json"))
        counts = [before["revision"], after["revision"], paused["requestCountBeforeContinue"],
                  paused["spendEventCountBefore"], paused["spendEventCountPaused"],
                  paused["catalogWaiterCount"], paused["idleSettleMilliseconds"]]
        if any(type(value) is not int or value < 0 for value in counts):
            return False
        if (digest(batch_bytes) != paused["batchSHA256"] or before_bytes != paused_bytes or digest(before_bytes) != paused["journalSHA256"]
            or digest(paused_bytes) != paused["pausedSHA256"]
            or before["batchID"] != batch_id or after["batchID"] != batch_id or batch["id"] != batch_id
            or continued["batchID"] != batch_id or not before.get("authorityID")
            or after["authorityID"] != before["authorityID"] or after["approvedAt"] != before["approvedAt"]
            or paused["requestCountBeforeContinue"] != 0
            or paused["spendEventCountBefore"] != paused["spendEventCountPaused"]
            or paused.get("continueEnabledWhileBusy") is not False or paused.get("continueEnabledWhenIdle") is not True
            or paused.get("activeBatchBeforeRelease") != batch_id or paused.get("catalogBarrierResumed") is not True
            or paused.get("catalogWaiterCount") != 1 or paused.get("pauseReason") != "hostBusy"
            or paused.get("pauseLabel") != "Isolated competing native edit" or paused.get("idleSettleMilliseconds", 0) < 250
            or paused.get("liveProvider") is not False or continued.get("liveProvider") is not False
            or len(before["executions"]) != 1 or len(after["executions"]) != 1
            or len(batch["payload"]["items"]) != 1 or after["revision"] <= before["revision"]):
            return False
        queued, complete, item = before["executions"][0], after["executions"][0], batch["payload"]["items"][0]
        if (queued["state"] != "queued" or queued["itemID"] != item["id"]
            or queued.get("transactionID") is not None or queued.get("providerRequestID") is not None
            or queued["outputAssetIDs"] != [] or complete["itemID"] != item["id"]
            or complete["state"] != "complete" or not complete.get("transactionID")
            or not complete.get("providerRequestID") or complete["outputAssetIDs"] != [continued["assetID"]]
            or not requests or any(not sha(row["bodySHA256"]) for row in requests)):
            return False
        endpoint = "https://queue.fal.run/" + item["package"]["payload"]["target"]["endpoint"]
        upload_endpoint = "https://rest.fal.ai/storage/upload/initiate?storage_type=fal-cdn-v3"
        posts = [row for row in requests if row["method"] == "POST"]
        puts = [row for row in requests if row["method"] == "PUT"]
        submissions = [row for row in posts if row["url"] == endpoint]
        if (len(submissions) != 1 or any(row["url"] not in (endpoint, upload_endpoint) for row in posts)
            or sum(row["url"] == upload_endpoint for row in posts) != len(puts)):
            return False
        for index, row in enumerate(requests):
            if row.get("bodyFile") != f"request-{index}.bin" or digest(read(directory, prefix + row["bodyFile"])) != row["bodySHA256"]:
                return False
        submitted = json.loads(read(directory, prefix + submissions[0]["bodyFile"]))
        click_indices = [index for index, row in enumerate(interactions)
                         if row.get("kind") == "pointer" and row.get("id") == "generation-batch.continue." + batch_id]
        if len(click_indices) != 1:
            return False
        paused_index = next(i for i, row in enumerate(interactions) if row.get("label") == "approved batch paused by competing host lease")
        continued_index = next(i for i, row in enumerate(interactions) if row.get("label") == "approved batch explicitly continued")
        screenshots = native["screenshots"]
        for label in ["batch-paused-host-busy", "batch-paused-host-idle"]:
            matching = [name for name in screenshots if name.endswith("-" + label + ".png")]
            if len(matching) != 1 or not read(directory, matching[0]).startswith(b"\x89PNG\r\n\x1a\n"):
                return False
        generated = [(index, row["evidence"]) for index, row in enumerate(interactions)
                     if row.get("kind") == "verified-state" and row.get("label") == "actual generated frame"]
        for index, row in generated:
            if row["candidateID"] != continued["candidateID"]:
                continue
            frame_package = json.loads(read(directory, "frame-evidence/" + row["candidateID"] + "-package.json"))
            return (item["package"] == frame_package
                    and paused_index < click_indices[0] < index < continued_index
                    and complete["providerRequestID"] == row.get("providerRequestID")
                    and row.get("modelEndpoint") == item["package"]["payload"]["target"]["endpoint"]
                    and row.get("role") == "start" and row["assetID"] == continued["assetID"]
                    and row["imageSHA256"] == continued["outputSHA256"]
                    and row["packageSHA256"] == item["package"]["id"]
                    and [value["bodySHA256"] for value in puts] == row["uploadedSHA256"] == row["referenceSHA256"]
                    and [value["url"] for value in puts] == [f"https://upload.invalid/frame-input-{i}.png" for i in range(len(puts))]
                    and submitted["image_urls"] == [f"https://media.invalid/frame-input-{i}.png" for i in range(len(puts))]
                    and digest(submitted["prompt"].encode()) == row["promptSHA256"])
        return False
    except (KeyError, TypeError, ValueError, OSError, AttributeError, StopIteration):
        return False
