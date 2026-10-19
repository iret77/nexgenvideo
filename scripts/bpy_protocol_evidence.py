import argparse
import base64
import hashlib
import json
from pathlib import Path
from uuid import UUID


CHUNK_BYTES = 4 * 1024 * 1024


def require(condition, message):
    if not condition:
        raise ValueError(message)


def decode(value):
    return base64.b64decode(value, validate=True)


def object_bytes(value):
    result = json.loads(decode(value))
    require(isinstance(result, dict), "exchange object")
    return result


def integer(value, minimum=0):
    return type(value) is int and value >= minimum


def fingerprint(request, limits, inputs):
    timeout = request.get("timeoutSeconds")
    require(integer(limits.get("timeoutSeconds"), 1), "session timeout")
    require(timeout is None or integer(timeout, 1), "requested timeout")
    effective = limits["timeoutSeconds"] if timeout is None else min(timeout, limits["timeoutSeconds"])
    values = ["nexgenvideo/bpy-job/5", request.get("expectedRevision"),
              None if timeout is None else str(timeout), str(effective), request["source"], str(len(inputs))]
    for item in inputs:
        values += [item["name"], str(item["totalBytes"]), item["sha256"]]
    paths = request["diagnosticDeniedPaths"]
    require(isinstance(paths, list) and all(isinstance(path, str) for path in paths), "diagnostic paths")
    values += [str(len(paths))] + paths
    for key in ("diagnosticAutoexecPositiveControl", "diagnosticSupervisorIdentityWriteFailure",
                "diagnosticSupervisorIdentityCaptureFailure"):
        require(type(request[key]) is bool, "diagnostic flag")
        values.append("1" if request[key] else "0")
    digest = hashlib.sha256()
    for value in values:
        digest.update(b"\x00" if value is None else b"\x01")
        if value is not None:
            data = value.encode()
            digest.update(len(data).to_bytes(8, "big"))
            digest.update(data)
    return digest.hexdigest()


def validate_restore(evidence, result, checkpoint, original_session):
    opening = evidence["restoreOpen"]
    require(opening["method"] == "openSession", "restore open method")
    opened, ready = object_bytes(opening["request"]), object_bytes(opening["response"])
    session = str(UUID(opened["sessionID"]))
    revision = result["serviceRecoveryRevision"]
    require(session != original_session and revision == opened["confirmedRevision"], "recovered session/revision")
    require(ready.get("ok") is True and ready.get("confirmedRevision") == revision, "restore open response")
    runtime = ready["runtime"]
    require(integer(result["serviceA"], 2) and integer(runtime["serviceProcessIdentifier"], 2)
            and runtime["serviceProcessIdentifier"] != result["serviceA"], "actual restarted service")
    exchanges = evidence["restore"]
    require(isinstance(exchanges, list) and len(exchanges) >= 2 and len(checkpoint) > 0, "actual restore exchanges")
    original, replay = exchanges[:-1], exchanges[-1]
    require(len(original) == (len(checkpoint) + CHUNK_BYTES - 1) // CHUNK_BYTES, "complete actual restore upload")
    offset = 0
    for index, exchange in enumerate(original):
        request, response = object_bytes(exchange["request"]), object_bytes(exchange["response"])
        size = min(CHUNK_BYTES, len(checkpoint) - offset)
        require(exchange["method"] == "restoreCheckpoint" and request["sessionID"] == opened["sessionID"], "restore owner")
        require(integer(request["offset"]) and request["offset"] == offset
                and integer(request["totalBytes"], 1) and request["totalBytes"] == len(checkpoint), "restore contiguous range")
        require(request["revision"] == revision and request["sha256"] == hashlib.sha256(checkpoint).hexdigest(), "actual restored checkpoint")
        require(type(request["finalChunk"]) is bool and request["finalChunk"] == (index == len(original) - 1), "restore final boundary")
        require(integer(exchange["chunkBytes"], 1) and exchange["chunkBytes"] == size
                and exchange["chunkSHA256"] == hashlib.sha256(checkpoint[offset:offset + size]).hexdigest(), "actual chunk bytes")
        require(response.get("ok") is True and response.get("confirmedRevision") == revision, "restore response")
        offset += size
    last = original[-1]
    require(replay["method"] == "restoreCheckpointReplay"
            and decode(replay["request"]) == decode(last["request"])
            and integer(replay["chunkBytes"], 1) and replay["chunkBytes"] == last["chunkBytes"]
            and replay["chunkSHA256"] == last["chunkSHA256"], "exact last uploaded chunk replay")
    replayed = object_bytes(replay["response"])
    require(replayed.get("ok") is True and replayed.get("confirmedRevision") == revision, "actual replay response")


def validate_completion(evidence, requests, responses, session, job, expected_fingerprint):
    exchanges = evidence["completion"]
    require(isinstance(exchanges, list) and len(exchanges) > 0, "completion exchanges")
    pending = None
    authorizations = set()
    last_poll = None
    for index, exchange in enumerate(exchanges):
        request, response = object_bytes(exchange["request"]), object_bytes(exchange["response"])
        require(str(UUID(request["sessionID"])) == session and request["jobID"] == job, "completion request identity")
        require(response.get("ok") is True and response.get("jobID") == job
                and response.get("jobFingerprint") == expected_fingerprint, "completion response identity")
        if exchange["method"] == "jobStatus":
            require(pending is None and set(request) == {"sessionID", "jobID"}, "status before pending authorization")
            last_poll = exchange
            pending = response if response.get("activeProcessAuthorizationID") is not None else None
        else:
            require(exchange["method"] == "authorizeProcess" and pending is not None, "actual authorization predecessor")
            identifier = str(UUID(request["authorizationID"]))
            require(identifier not in authorizations, "authorization replay")
            authorizations.add(identifier)
            for actual, source in (("authorizationID", "activeProcessAuthorizationID"),
                                   ("processIdentifier", "activeProcessIdentifier"),
                                   ("processStartAbsoluteTime", "activeProcessStartAbsoluteTime"),
                                   ("processExecutable", "activeProcessExecutable")):
                require(request[actual] == pending[source], "authorization lease: " + actual)
            require(integer(request["processIdentifier"], 2) and integer(request["processStartAbsoluteTime"], 1)
                    and request["processExecutable"].endswith("/Contents/Helpers/NexGenVideoBpySupervisor"), "actual supervisor identity")
            require(response.get("activeProcessAuthorizationID") is None, "authorization acknowledged")
            pending = None
        require(response.get("state") in (("awaitingConfirmation",) if index == len(exchanges) - 1 else ("accepted", "running")), "completion order/state")
    require(pending is None and len(authorizations) > 0 and last_poll is not None, "actual host authorization completed")
    require(decode(last_poll["request"]) == decode(evidence["requests"]["service-completed"])
            and decode(last_poll["response"]) == decode(evidence["responses"]["service-completed"]), "archived final status poll")
    require(requests["service-completed"] == {"sessionID": requests["service-submit"]["sessionID"], "jobID": job}, "completed request target")


def validate_reservation(requests, responses, owner_session):
    labels = ("reservation-first-owner", "reservation-failed-bookmark", "reservation-new-owner",
              "reservation-stale-close", "reservation-stale-reopen", "reservation-survived-stale-close", "reservation-cleanup")
    opened = requests[labels[0]]
    session = str(UUID(opened["sessionID"]))
    require(session != owner_session, "reservation must not reuse owner session")
    require(all(str(UUID(requests[label]["sessionID"])) == session for label in labels), "reservation session binding")
    require(opened == requests[labels[2]] == requests[labels[4]] == requests[labels[5]]
            and opened.get("storage") is None, "same valid reservation contract")
    failed = requests[labels[1]]
    require({key: value for key, value in failed.items() if key != "storage"} == opened, "failed open contract")
    require(decode(failed["storage"]["bookmark"]) == bytes([1, 2, 3]), "actual invalid bookmark")
    require(requests[labels[3]] == requests[labels[6]] == {"sessionID": opened["sessionID"]}, "stale close target")
    require(responses[labels[4]].get("message") == "invalid open request", "stale reservation owner refusal")
    for label in (labels[0], labels[2], labels[5]):
        preparation = responses[label]["storagePreparation"]
        require(preparation["id"] == opened["sessionID"] and integer(preparation["servicePID"], 2)
                and integer(preparation["serviceStart"], 1), "actual reservation preparation")
    return set(labels)


def validate(evidence, result, raw_bytes, checkpoint_bytes, restored_checkpoint_bytes):
    require(evidence.get("schema") == "nexgenvideo/bpy-native-protocol-evidence/2", "protocol schema")
    require(result.get("nativeProtocolEvidenceFile") == "native-protocol-evidence.json", "evidence filename")
    require(result.get("nativeProtocolEvidenceSHA256") == hashlib.sha256(raw_bytes).hexdigest(), "evidence digest")
    requests = {key: object_bytes(value) for key, value in evidence["requests"].items()}
    responses = {key: object_bytes(value) for key, value in evidence["responses"].items()}
    chunks = {key: decode(value) for key, value in evidence["chunks"].items()}
    expected = {
        "foreign-open", "foreign-status", "foreign-close", "owner-after-foreign-close", "confirm-replay",
        "invalid-final-hash", "valid-final-after-failure", "reserve-global-input-budget", "cross-job-budget-refused",
        "cancel-reservation", "budget-released-after-cancel", "cancel-unrelated-unknown-job", "service-submit",
        "service-submit-replay", "service-completed", "cleanup-staged", "cleanup-reserved", "cleanup-other",
        "literal-part-name", "partial-input", "submit-with-partial-input", "completed-partial-input",
    }
    session = str(UUID(requests["foreign-open"]["sessionID"]))
    reservations = validate_reservation(requests, responses, session)
    require(decode(evidence["requests"]["reservation-stale-reopen"])
            == decode(evidence["requests"]["reservation-new-owner"]), "exact valid replacement reservation request")
    require(set(requests) == expected | reservations == set(responses), "request/response coverage")
    require(set(chunks) == {"invalid-final-hash", "valid-final-after-failure", "reserve-global-input-budget",
        "cross-job-budget-refused", "budget-released-after-cancel", "literal-part-name", "partial-input",
        "completed-partial-input"}, "actual staging chunk coverage")
    poll_count = sum(item["method"] == "jobStatus" for item in evidence["completion"])
    expected_order = ["foreign-open", "foreign-status", "foreign-close", "owner-after-foreign-close",
        "reservation-first-owner", "reservation-failed-bookmark", "reservation-new-owner", "reservation-stale-close",
        "reservation-stale-reopen", "reservation-survived-stale-close", "reservation-cleanup", "confirm-replay", "invalid-final-hash",
        "valid-final-after-failure", "reserve-global-input-budget", "cross-job-budget-refused", "cancel-reservation",
        "budget-released-after-cancel", "cancel-unrelated-unknown-job", "literal-part-name", "partial-input",
        "submit-with-partial-input", "completed-partial-input", "service-submit", "service-submit-replay"]
    expected_order += ["service-completed"] * poll_count + ["cleanup-staged", "cleanup-reserved", "cleanup-other"]
    require(evidence["exchangeOrder"] == expected_order, "actual exchange order")
    refused = {"foreign-open", "foreign-status", "foreign-close", "invalid-final-hash", "cross-job-budget-refused",
               "cancel-reservation", "cancel-unrelated-unknown-job", "cleanup-reserved", "cleanup-other",
               "reservation-failed-bookmark", "reservation-stale-close", "reservation-stale-reopen", "submit-with-partial-input"}
    for key in expected | reservations:
        require(type(responses[key].get("ok")) is bool and responses[key]["ok"] == (key not in refused), "response outcome: " + key)
    for key in expected:
        require(str(UUID(requests[key]["sessionID"])) == session, "session identity")
    for key in ("reservation-first-owner", "reservation-new-owner", "reservation-survived-stale-close"):
        require(responses[key]["storagePreparation"]["servicePID"] == result["serviceA"], "reservation service identity")
    owner = requests["owner-after-foreign-close"]
    require(requests["foreign-status"] == owner and responses["owner-after-foreign-close"].get("jobID") == owner["jobID"], "foreign status target")
    require(responses["owner-after-foreign-close"].get("state") == "confirmed", "owner survived foreign close")
    confirm = requests["confirm-replay"]
    require(confirm["jobID"] == owner["jobID"], "confirmation target")
    require(confirm["sceneSHA256"] == hashlib.sha256(checkpoint_bytes).hexdigest(), "actual checkpoint digest")
    require(responses["confirm-replay"].get("state") == "confirmed"
            and responses["confirm-replay"].get("jobID") == owner["jobID"], "confirmation replay")
    validate_restore(evidence, result, restored_checkpoint_bytes, session)
    good, bad = requests["valid-final-after-failure"], requests["invalid-final-hash"]
    require({key: value for key, value in good.items() if key != "sha256"}
            == {key: value for key, value in bad.items() if key != "sha256"}, "retry same slot")
    require(chunks["valid-final-after-failure"] == chunks["invalid-final-hash"] == b"{}", "retry same bytes")
    require(good["sha256"] == hashlib.sha256(b"{}").hexdigest() and bad["sha256"] != good["sha256"], "hash refusal")
    limits = requests["foreign-open"]["limits"]
    require(integer(limits["inputBytes"], 8), "probe input budget")
    reserved, blocked, released = (requests[label] for label in ("reserve-global-input-budget", "cross-job-budget-refused", "budget-released-after-cancel"))
    for item in (good, reserved, blocked, released):
        require(integer(item["totalBytes"], 1) and integer(item["offset"]) and item["offset"] == 0, "staging range")
    require(reserved["totalBytes"] + good["totalBytes"] == limits["inputBytes"], "global reservation")
    require(reserved["finalChunk"] is False and len(chunks["reserve-global-input-budget"]) == 1, "partial reservation")
    require(blocked == released and blocked["totalBytes"] == 2
            and chunks["cross-job-budget-refused"] == chunks["budget-released-after-cancel"] == b"{}", "released budget retry")
    job_ids = [good["jobID"], reserved["jobID"], blocked["jobID"]]
    require(len(set(job_ids)) == 3, "distinct staging jobs")
    require(requests["cancel-reservation"]["jobID"] == reserved["jobID"], "reservation cancellation")
    require(requests["cancel-unrelated-unknown-job"]["jobID"] not in job_ids, "unrelated cancellation")
    submitted = requests["service-submit"]
    require(decode(evidence["requests"]["service-submit"]) == decode(evidence["requests"]["service-submit-replay"])
            and submitted["jobID"] == good["jobID"], "exact service replay")
    literal, partial, completed = (requests[label] for label in ("literal-part-name", "partial-input", "completed-partial-input"))
    require(literal["name"] == "foo.part" and partial["name"] == completed["name"] == "foo", "literal .part and sibling names")
    for item in (literal, partial, completed):
        require(item["jobID"] == good["jobID"] and integer(item["totalBytes"], 1)
                and item["totalBytes"] == 2 and item["sha256"] == good["sha256"], "partial job input identity")
    require(integer(literal["offset"]) and literal["offset"] == 0 and literal["finalChunk"] is True and chunks["literal-part-name"] == b"{}", "literal .part completed bytes")
    require(integer(partial["offset"]) and partial["offset"] == 0 and partial["finalChunk"] is False
            and integer(completed["offset"]) and completed["offset"] == 1 and completed["finalChunk"] is True
            and chunks["partial-input"] == b"{" and chunks["completed-partial-input"] == b"}", "partial sibling completed bytes")
    refused_run = requests["submit-with-partial-input"]
    require(refused_run["jobID"] == good["jobID"] and refused_run["expectedRevision"] == confirm["revision"]
            and refused_run["inputNames"] == ["foo.part", "probe.json"]
            and refused_run["fingerprint"] == fingerprint(refused_run, limits, [literal, good]), "valid refused partial-input submit")
    require(submitted["expectedRevision"] == confirm["revision"]
            and submitted["inputNames"] == ["foo", "foo.part", "probe.json"], "staged input binding")
    require(submitted["source"] == "assert set(p.name for p in input_dir.iterdir()) == {'foo', 'foo.part', 'probe.json'}; assert all((input_dir / n).read_text() == '{}' for n in ['foo', 'foo.part', 'probe.json'])", "actual job reads exact completed inputs")
    actual_fingerprint = fingerprint(submitted, limits, [completed, literal, good])
    require(submitted["fingerprint"] == actual_fingerprint, "request fingerprint")
    for key in ("service-submit", "service-submit-replay", "service-completed"):
        require(responses[key].get("jobID") == good["jobID"]
                and responses[key].get("jobFingerprint") == actual_fingerprint, "service identity: " + key)
    require(responses["service-submit-replay"].get("joinedExistingJob") is True, "service joined replay")
    validate_completion(evidence, requests, responses, session, good["jobID"], actual_fingerprint)
    for key, identifier in zip(("cleanup-staged", "cleanup-reserved", "cleanup-other"), job_ids):
        require(requests[key]["jobID"] == identifier, "cleanup ownership")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("evidence", type=Path)
    args = parser.parse_args()
    raw = (args.evidence / "native-protocol-evidence.json").read_bytes()
    validate(json.loads(raw), json.loads((args.evidence / "result.json").read_bytes()), raw,
             (args.evidence / "native-protocol-checkpoint.blend").read_bytes(),
             (args.evidence / "native-protocol-restored-checkpoint.blend").read_bytes())
