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
        batch = json.loads(read(directory, prefix + "batch.json"))
        requests = json.loads(read(directory, prefix + "requests.json"))
        if (before_bytes != paused_bytes or digest(before_bytes) != paused["journalSHA256"]
            or digest(paused_bytes) != paused["pausedSHA256"]
            or before["batchID"] != batch_id or after["batchID"] != batch_id or batch["id"] != batch_id
            or continued["batchID"] != batch_id or not before.get("authorityID")
            or after["authorityID"] != before["authorityID"] or after["approvedAt"] != before["approvedAt"]
            or paused["requestCountBeforeContinue"] != 0
            or paused["spendEventCountBefore"] != paused["spendEventCountPaused"]
            or paused.get("continueEnabledWhileBusy") is not False or paused.get("continueEnabledWhenIdle") is not True
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
        if sum(row["method"] == "POST" and row["url"] == endpoint for row in requests) != 1:
            return False
        clicks = [row.get("id") for row in interactions if row.get("kind") == "pointer"]
        if clicks.count("generation-batch.continue." + batch_id) != 1:
            return False
        generated = states(interactions, "actual generated frame")
        return any(row["candidateID"] == continued["candidateID"] and row["assetID"] == continued["assetID"]
                   and row["imageSHA256"] == continued["outputSHA256"]
                   and row["packageSHA256"] == item["package"]["id"] for row in generated)
    except (KeyError, TypeError, ValueError, OSError, AttributeError):
        return False
