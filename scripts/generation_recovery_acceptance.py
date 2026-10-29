"""Drive two actual app processes and independently verify durable generation recovery."""
import argparse
import base64
import binascii
import hashlib
import json
import os
from pathlib import Path
import subprocess
import struct
import sys

from manual_generation_extended_evidence import _file, _wav_duration


def generation_recovery_evidence(rows, output, scale):
    try:
        records = [row for row in rows if row.get("event") == "generation-recovery"]
        processes = [row for row in rows if row.get("event") == "generation-recovery-process"]
        completions = [row for row in rows if row.get("event") == "completed" and row.get("case") == "generationrecovery"]
        if (len(records) != 2 or [row.get("stage") for row in records] != ["prepare", "resume"]
            or len(processes) != 2 or [row.get("stage") for row in processes] != ["prepare", "resume"]
            or len(completions) != 2 or any(row.get("event") == "failed" for row in rows)
            or any(row.get("scale") != scale for row in records + processes + completions)
            or any(row.get("exitCode") != 0 for row in processes)
            or any(row.get("liveProvider") is not False for row in records)):
            return False, []
        if records[0]["processID"] == records[1]["processID"] or any(a["processID"] != b["processID"] for a, b in zip(records, processes)):
            return False, []
        directory = "generation-recovery-" + str(round(scale * 100))
        if any(row.get("directory") != directory for row in records):
            return False, []
        def load(name):
            return json.loads(_file(output, directory + "/" + name).read_bytes())
        state = load("state.json")
        first, second = [load(stage + "-journal.json") for stage in ("prepare", "resume")]
        batches = [load(stage + "-batch.json") for stage in ("prepare", "resume")]
        logs = [load(stage + "-spend.json") for stage in ("prepare", "resume")]
        requests = [load(stage + "-http.json") for stage in ("prepare", "resume")]
        if (batches[0] != batches[1] or state["batchID"] != batches[0]["id"]
            or any(row.get("batchID") != state["batchID"] for row in records)
            or state["processID"] != records[0]["processID"] or len(state["itemIDs"]) != 3
            or state["itemIDs"] != [item["id"] for item in batches[0]["payload"]["items"]]
            or state["packageIDs"] != [item["package"]["id"] for item in batches[0]["payload"]["items"]]
            or first["authorityID"] != second["authorityID"] or not first["authorityID"]
            or first["approvedAt"] != second["approvedAt"] or first["pricingOverrideItemIDs"] != second["pricingOverrideItemIDs"]
            or first["batchID"] != state["batchID"] or second["batchID"] != state["batchID"]
            or [item["state"] for item in first["executions"]] != ["complete", "running", "canceled"]
            or [item["state"] for item in second["executions"]] != ["complete", "complete", "canceled"]
            or first["executions"][0] != second["executions"][0] or first["executions"][2] != second["executions"][2]
            or first["executions"][1]["providerRequestID"] != state["acceptedRequestID"]
            or second["executions"][1]["providerRequestID"] != state["acceptedRequestID"]
            or first["executions"][1]["transactionID"] != second["executions"][1]["transactionID"]
            or first["executions"][1]["providerRequestResumable"] is not True
            or second["executions"][1]["providerRequestResumable"] is not True
            or first["executions"][0]["outputAssetIDs"] != [state["firstOutputID"]]
            or first["executions"][2].get("transactionID") is not None
            or first["executions"][2].get("providerRequestID") is not None
            or first["executions"][2]["placeholders"]):
            return False, []
        posts = [[request for request in stage if request["method"] == "POST"] for stage in requests]
        if len(posts[0]) != 2 or posts[1] or not requests[1] or any(request["method"] != "GET" for request in requests[1]):
            return False, []
        for index, post in enumerate(posts[0]):
            package = batches[0]["payload"]["items"][index]["package"]["payload"]
            body = json.loads(base64.b64decode(post["body"], validate=True))
            if (post["url"] != "https://queue.fal.run/fal-ai/elevenlabs/music"
                or package["operation"] != "audio" or package["modality"] != "audio"
                or body.get("prompt") != package["prompt"] or body.get("music_length_ms") != 3000
                or body.get("force_instrumental") is not True):
                return False, []
        if (not any(request["url"].endswith(state["acceptedRequestID"] + "/status") for request in requests[1])
            or not any(request["url"].endswith(state["acceptedRequestID"]) for request in requests[1])):
            return False, []
        submissions = [[event for event in log["spendEvents"] if event["kind"] == "submitted"] for log in logs]
        reservations = [[event for event in log["spendEvents"] if event["kind"] == "reserved"] for log in logs]
        if (len(submissions[0]) != 2 or submissions[0] != submissions[1] or len(reservations[0]) != 2
            or reservations[0] != reservations[1]
            or submissions[0][1]["providerRequestId"] != state["acceptedRequestID"]):
            return False, []
        images = records[0]["screenshots"] + records[1]["screenshots"]
        if (len(images) != 3 or len(set(images)) != 3
            or any(not any(name.endswith("-" + label + ".png") for name in images) for label in
                ("review-before-one-approval", "remaining-canceled-known-job-retained", "restarted-history-and-results"))
            or any((path := _file(output, name)).stat().st_size < 1000 or not path.read_bytes().startswith(b"\x89PNG\r\n\x1a\n") for name in images)):
            return False, []
        for index, record in enumerate(records):
            actions = record["interactions"]
            pointers = [item["id"] for item in actions if item.get("kind") == "pointer"]
            if index == 0:
                if pointers.count("generation-batch.approve") != 1 or pointers.count("agent.stop") != 1:
                    return False, []
                if not any(item.get("kind") == "keyboard" and item.get("characters") == "s" for item in actions):
                    return False, []
            else:
                outputs = [state["firstOutputID"], second["executions"][1]["outputAssetIDs"][0]]
                if any(pointers.count("generation-batch.open." + output) != 1 for output in outputs) or "generation-batch.approve" in pointers:
                    return False, []
            for item_id in state["itemIDs"]:
                if not any(item.get("kind") == "visible-group" and item.get("ids") == ["generation-batch.state." + item_id] for item in actions):
                    return False, []
        first_bytes = _file(output, directory + "/first-output.wav").read_bytes()
        second_bytes = _file(output, directory + "/second-output.wav").read_bytes()
        if (_wav_duration(first_bytes) != 3 or _wav_duration(second_bytes) != 3 or first_bytes == second_bytes
            or hashlib.sha256(first_bytes).hexdigest() != state["firstOutputSHA256"]):
            return False, []
        prepared = [item["evidence"] for item in records[0]["interactions"] if item.get("kind") == "verified-state"
                    and item.get("label") == "native queued requests stopped before process restart"]
        if (len(prepared) != 1 or prepared[0].get("batchID") != state["batchID"]
            or prepared[0].get("acceptedRequestID") != state["acceptedRequestID"] or prepared[0].get("providerSubmissions") != 2
            or prepared[0].get("completedRetained") is not True or prepared[0].get("thirdCanceledWithoutSubmission") is not True):
            return False, []
        verified = [item["evidence"] for item in records[1]["interactions"] if item.get("kind") == "verified-state"
                    and item.get("label") == "actual process restart resumes only the recorded audio job"]
        if (len(verified) != 1 or verified[0].get("previousProcessID") != records[0]["processID"]
            or verified[0].get("providerSubmissions") != 0 or verified[0].get("acceptedRequestID") != state["acceptedRequestID"]
            or verified[0].get("firstOutputSHA256") != hashlib.sha256(first_bytes).hexdigest()
            or verified[0].get("secondOutputSHA256") != hashlib.sha256(second_bytes).hexdigest()
            or not all(verified[0].get(key) is True for key in ("completedRetained", "thirdStillCanceled", "nativeHistoryResultsOpened"))):
            return False, []
        return True, images
    except (KeyError, IndexError, TypeError, ValueError, OSError, OverflowError, struct.error, binascii.Error):
        return False, []


def run_generation_recovery(executable, output, scale):
    chunks, results = [], []
    for stage in ("prepare", "resume"):
        environment = {**os.environ, "NGV_WORKSPACE_UI_ACCEPTANCE": "1", "NGV_WORKSPACE_UI_EVIDENCE": str(Path(output).resolve()),
            "NGV_WORKSPACE_UI_SCALE": str(scale), "NGV_WORKSPACE_UI_CASE": "generationrecovery",
            "NGV_GENERATION_RECOVERY_STAGE": stage, "NGV_INSPECTOR_UI_ACCEPTANCE": "1"}
        with subprocess.Popen([str(executable), "-ApplePersistenceIgnoreState", "YES"], stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=environment, text=True) as process:
            try:
                text, _ = process.communicate(timeout=180)
                code = process.returncode
            except subprocess.TimeoutExpired:
                process.terminate()
                try: text, _ = process.communicate(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill(); text, _ = process.communicate()
                code = 124
            chunks.append(text)
            meta = {"event": "generation-recovery-process", "stage": stage, "scale": scale, "processID": process.pid, "exitCode": code}
            chunks.append(json.dumps(meta) + "\n"); results.append(meta)
        if code:
            break
    return "\n".join(chunks), next((item["exitCode"] for item in results if item["exitCode"]), 0)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--executable", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--scale", type=float, choices=(1.0, 1.25, 1.5), default=1.5)
    args = parser.parse_args(); args.output.mkdir(parents=True, exist_ok=True)
    text, code = run_generation_recovery(args.executable, args.output, args.scale)
    (args.output / ("generation-recovery-" + str(round(args.scale * 100)) + ".log")).write_text(text)
    rows = []
    for line in text.splitlines():
        try: value = json.loads(line)
        except ValueError: continue
        if isinstance(value, dict): rows.append(value)
    valid, images = generation_recovery_evidence(rows, args.output, args.scale)
    print(json.dumps({"generationRecoveryVerified": valid, "screenshots": images, "processExitCode": code}))
    return 0 if valid and code == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
