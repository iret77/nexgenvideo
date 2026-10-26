"""Verify native source-mode decisions against captured bytes and canonical host receipts."""
import hashlib
import json
from collections import Counter
from production_frames_owner_evidence import read, visible_group


def require(value, reason):
    if not value:
        raise ValueError(reason)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def validate_next_shot_navigation(native, first_take_id, next_take_id, next_shot_id, selection_sha256):
    rows = [row for row in native["interactions"] if row.get("kind") == "verified-state"
            and row.get("label") == "native next open shot in sheet and workspace"]
    require(len(rows) == 1, "Native next-shot navigation receipt is absent or ambiguous")
    evidence = rows[0]["evidence"]
    require(evidence.get("selectionAndReviewUnchanged") is True, "Navigation did not preserve review and selection truth")
    require(evidence == {"firstTakeID": first_take_id, "nextTakeID": next_take_id,
                        "nextShotID": next_shot_id, "selectionAndReviewUnchanged": True,
                        "selectionSHA256Before": selection_sha256, "selectionSHA256After": selection_sha256},
            "Next-shot navigation changed selection or references another actual Take")
    clicks = [row for row in native["interactions"] if row.get("kind") == "pointer" and row.get("id") == "take.next"]
    require(len(clicks) == 2 and len({row["window"] for row in clicks}) == 2,
            "Next-shot navigation did not click both the sheet and workspace")
    main_windows = {row["window"] for row in native["interactions"]
                    if row.get("kind") == "pointer" and row.get("id") == "take.open"}
    require(main_windows == {clicks[1]["window"]} and clicks[0]["window"] not in main_windows,
            "Next-shot navigation did not bind the main window and its separate sheet")
    for label in ["sheet-before", "sheet-after", "workspace-before", "workspace-after"]:
        require(sum(name.endswith("-next-shot-" + label + ".png") for name in native["screenshots"]) == 1,
                "Next-shot navigation has no unique before/after native image")


def validate(directory, kind):
    require(kind in {"aiEnhanced", "frameContinuation", "nativeExtension"}, "Unknown actual source recipe")
    result = json.loads(read(directory, "result.json"))
    request = json.loads(read(directory, "source-provider.json"))
    require(result["kind"] == request["kind"] == kind and result["liveProvider"] is False
            and result["actualAccountEntitlementClaim"] is False
            and result["semanticGenerationQualityClaim"] is False, "Source evidence makes an unsupported provider claim")
    require(result["nativeGenerationApproval"] and result["nativeDraftChoice"] and result["nativePreRenderInspection"],
            "The actual native source decisions are absent")
    for name, expected in result["canonicalFiles"].items():
        require(sha(read(directory, "canonical/" + name)) == expected, "Canonical evidence bytes changed: " + name)
    inventory = json.loads(read(directory, "canonical/references.json"))
    entries = {(r["path"], r["sha256"]): r["file"] for r in inventory}
    require(len(entries) == len(inventory), "Ambiguous canonical source inventory")

    def ref_bytes(reference):
        key = reference["path"], reference["sha256"]
        require(key in entries, "Actual exact-byte reference not captured: " + reference["path"])
        data = read(directory, "canonical/" + entries[key])
        require(sha(data) == reference["sha256"], "Actual reference SHA differs from its bytes")
        return data

    def ref_json(reference):
        return json.loads(ref_bytes(reference))

    projection = json.loads(read(directory, "canonical/projection.json"))
    assembly = json.loads(read(directory, "canonical/assembly.json"))
    require(projection["schema"] == "shotlist/v5", "A legacy shot plan was substituted")
    shots = projection["executionPlan"]["shots"]
    ids = [row["id"] for row in shots]
    require(ids == result["shotIDs"] == [row["shotID"] for row in assembly["placements"]] and len(set(ids)) == 2,
            "Assembly does not preserve the two actual stable shot UUIDs")
    records = [json.loads(ref_bytes({"path": row["path"], "sha256": row["sha256"]}))
               for row in inventory if row["path"].startswith("renders/production-records/")
               and not row["path"].rsplit("/", 1)[1].startswith("current-")]
    by_shot = {row["shotID"]: row for row in records if row.get("schema") == "production-render-record/v1"}
    require(request["shotID"] in by_shot, "No actual canonical record for the source recipe")
    record = by_shot[request["shotID"]]
    generated = ref_json(record["generation"])
    package = ref_json(generated["package"])
    submission = ref_json(record["submission"])
    require(record["takeID"] == request["takeID"] and record["output"]["sha256"] == request["outputSHA256"]
            and generated["output"] == record["output"] and sha(ref_bytes(record["output"])) == request["outputSHA256"],
            "The actual output differs from its canonical Take or completed receipt")
    require(generated["modality"] == package["payload"]["modality"] == "video"
            and generated["package"]["id"] == package["id"] == request["packageSHA256"]
            and package["payload"]["generationInput"]["model"] == request["modelID"],
            "The output has no matching actual generation package")
    events = generated["spendEvents"]
    require([e["kind"] for e in events] == ["reserved", "submitted", "settled"]
            and all(e.get("money") is None for e in events)
            and events[1]["providerRequestId"] == request["providerRequestID"],
            "Actual submitted/settled request evidence is absent or invented")
    batch = json.loads(read(directory, "source-approved-batch.json"))
    require(batch["authorityAvailable"] and batch["batch"]["id"] == request["batchID"]
            and batch["batch"]["payload"]["items"][0]["package"] == package
            and batch["journal"]["executions"][0]["state"] == "complete"
            and batch["journal"]["approvedAt"], "No actual host-approved completed batch binds this generation package")
    uploaded = read(directory, "source-provider-upload.bin")
    require(sha(uploaded) == request["inputSHA256"] and len(submission["inputs"]) == 1
            and submission["inputs"][0]["sha256"] == sha(uploaded), "The provider received substituted or mixed source bytes")
    compiled = ref_json(submission["compiledPrompt"])
    require(compiled["text"] == package["payload"]["prompt"] and compiled["shotID"] == request["shotID"],
            "The actual compiled record changed")
    require(sha(package["payload"]["prompt"].encode()) == request["compiledSHA256"], "The actual compiled prompt differs")
    body = request["submittedEnvelope"]
    materialization = ref_json(package["payload"]["routing"]["productionMaterialization"])
    selections = [ref_json(ref) for ref in materialization["sourceMedia"]]
    timings = {row["shotID"]: row for row in projection["timings"]}
    if kind == "aiEnhanced":
        require(shots[0]["source_mode"] == "ai_enhanced" and shots[1]["source_mode"] == "imported"
                and not projection["chains"] and submission.get("predecessor") is None, "AI source mode was replaced by generation or a chain")
        native = projection["sourceInputRanges"][0]
        expected_stale_hash = native["source"]["sha256"]
        require(native["shotID"] == ids[0] and native["startTicks"] == native["timebase"]["ticksPerSecond"]
                and native["durationTicks"] == 6 * native["timebase"]["ticksPerSecond"]
                and native["durationTicks"] != timings[ids[0]]["durationTicks"], "Native original range was confused with the output trim")
        require(len(selections) == 1, "AI source was not materialized from one actual range")
        media = selections[0]
        require(media["selection"]["source"] == native["source"] and media["selection"]["startTicks"] == native["startTicks"]
                and media["selection"]["durationTicks"] == native["durationTicks"]
                and media["output"]["sha256"] == sha(uploaded)
                and media["durationValue"] * native["timebase"]["ticksPerSecond"] == native["durationTicks"] * media["durationTimescale"],
                "Actual conditioning export does not prove the exact original interval")
        require(ref_bytes(native["source"]) and request["modelID"] == "runway/aleph2"
                and body["model"] == "aleph2" and body["videoUri"].startswith("runway://")
                and set(body) == {"model", "videoUri", "promptText", "ratio"}, "AI enhancement did not use the actual transform endpoint")
    else:
        require(all(row["source_mode"] == "generated" for row in shots) and len(projection["chains"]) == 1,
                "The actual Chain was replaced by imported output")
        chain = projection["chains"][0]
        predecessor = submission["predecessor"]
        expected_stale_hash = by_shot[ids[0]]["output"]["sha256"]
        require(chain["kind"] == kind and chain["shotID"] == ids[1] and chain["predecessorShotID"] == ids[0]
                and predecessor["shotID"] == ids[0] and predecessor["takeID"] == by_shot[ids[0]]["takeID"]
                and predecessor["selectedEndTicks"] == predecessor["fullDurationTicks"], "Chain uses an unrelated or non-endpoint predecessor")
        first_selection = ref_json(predecessor["selectionReceipt"])
        first_range = ref_json(first_selection["nativeRange"])
        require(first_range["range"]["endFrame"] * predecessor["sourceTimebase"]["ticksPerSecond"]
                == predecessor["selectedEndTicks"] * first_range["range"]["fps"], "The actual native predecessor range does not end at the source end")
        if kind == "frameContinuation":
            require(predecessor["lastFrame"] == submission["inputs"][0] and sha(ref_bytes(predecessor["lastFrame"])) == sha(uploaded)
                    and not selections and body["image_url"] and "end_image_url" not in body and "image_urls" not in body
                    and "video_urls" not in body and "audio_urls" not in body,
                    "Frame continuation did not use its predecessor's exact sole last frame")
        else:
            require(len(selections) == 1 and predecessor.get("lastFrame") is None
                    and selections[0]["selection"]["source"] == by_shot[ids[0]]["output"]
                    and selections[0]["output"]["path"] == predecessor["outputVideo"]["path"]
                    and selections[0]["output"]["sha256"] == predecessor["outputVideo"]["sha256"]
                    and selections[0]["output"]["sha256"] == sha(uploaded), "Native extension lost its actual reviewed predecessor range")
            require(request["modelID"] == "runway/seedance2_5" and body["model"] == "seedance2_5" and body["mode"] == "extend"
                    and set(body) == {"model", "mode", "promptVideo", "promptText", "duration", "audio"},
                    "Transform or independent references were relabelled as genuine extension")
    require(body.get("promptText", body.get("prompt")) == package["payload"]["prompt"], "Raw or changed prompt reached the content adapter")
    stale = json.loads(read(directory, "stale-input.json"))
    require(stale == result["staleInput"] and stale["changedSHA256"] != stale["originalSHA256"] == stale["restoredSHA256"]
            and stale["originalSHA256"] == expected_stale_hash
            and stale["changedSHA256"] == sha(read(directory, "stale-input-changed.bin"))
            and stale["actualPreparationRefused"] and stale["spendEventsUnchanged"]
            and stale["restoredPreparationAccepted"] and stale["preparationBoundary"] == "PipelineProductionInputMaterializer.prepare"
            and stale["requestCountsBefore"] == stale["requestCountsAfter"] and stale["reason"].strip(),
            "The controlled stale-source refusal was not causal or sent a request")
    for row in assembly["placements"]:
        if row.get("takeID"):
            selected = ref_json(row["selectionReceipt"])
            require(selected["takeID"] == row["takeID"] and row["nativeRange"] == selected["nativeRange"],
                    "Actual assembly does not use its explicitly reviewed native Take range")
            ref_bytes(row["nativeRange"])
    native = result["nativeEvidence"]
    if kind != "aiEnhanced":
        validate_next_shot_navigation(native, by_shot[ids[0]]["takeID"], by_shot[ids[1]]["takeID"],
                                      ids[1], predecessor["selectionReceipt"]["sha256"])
    clicks = Counter(row.get("id") for row in native["interactions"] if row.get("kind") == "pointer")
    required = ["pipeline.overview.approve.shot_planning", "pipeline.overview.approve.bible",
                "render-review.record-native", "generation-batch.approve", "take.use", "production.assembly.build",
                "sequence.build", "export.start"]
    require(all(clicks[name] for name in required) and len(native["screenshots"]) >= 8
            and any(row.get("kind") == "visible-group" and visible_group(row) for row in native["interactions"]),
            "Actual native source decisions or bounded UI evidence are absent")
    require(result["nativeFullFilmReview"] and result["nativeStyleReview"] and result["nativeExportWorkspace"] and result["actualOutputQC"]
            and sha(read(directory, result["movie"])) == result["outputSHA256"], "The actual natively reviewed/exported film is absent")
    return {"schema": "independent-source-video-owner-verification/v1", "kind": kind,
            "actualInputSHA256": sha(uploaded), "actualOutputSHA256": request["outputSHA256"],
            "actualSourceAndRangeBound": True, "liveProvider": False, "semanticGenerationQualityClaim": False}
