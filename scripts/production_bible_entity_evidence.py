import base64
import hashlib
import json
from pathlib import Path
import re

import yaml


class EvidenceYAMLLoader(yaml.SafeLoader):
    pass


EvidenceYAMLLoader.add_implicit_resolver(
    "tag:yaml.org,2002:float",
    re.compile(r"^[-+]?(?:[0-9][0-9_]*(?:\.[0-9_]*)?|\.[0-9_]+)[eE][-+]?[0-9]+$"),
    list("-+0123456789."),
)


def require(value, message):
    if not value:
        raise ValueError(message)


def parsed_yaml(data):
    try:
        return yaml.load(data, Loader=EvidenceYAMLLoader)
    except yaml.YAMLError as error:
        raise ValueError("invalid retained Bible YAML") from error


def validate(native, directory):
    directory = Path(directory)

    def read(name):
        return json.loads((directory / name).read_bytes())

    evidence = read("bible-typed-evidence.json")
    require(evidence.get("schema") == "nexgenvideo/bible-typed-native-evidence/1"
            and evidence.get("status") == "source-only-pending"
            and evidence.get("humanIdentityQualityClaim") is False, "explicit evidence scope")
    before_raw = (directory / "bible-typed-before.yaml").read_bytes()
    require(hashlib.sha256(before_raw).hexdigest() == evidence["beforeSHA256"], "actual before Bible bytes")
    before = parsed_yaml(before_raw)
    raw = (directory / "bible-typed-source.yaml").read_bytes()
    bible = parsed_yaml(raw)
    reopened = read("bible-typed-reopened.json")
    pre_save = read("bible-typed-pre-save.json")
    saved_raw = (directory / "bible-typed-pre-save.yaml").read_bytes()
    saved = parsed_yaml(saved_raw)
    require(hashlib.sha256(raw).hexdigest() == evidence["bibleSHA256"]
            and hashlib.sha256(saved_raw).hexdigest() == pre_save["bibleSHA256"] == reopened["bibleSHA256"]
            and saved_raw == (directory / "bible-typed-reopened.yaml").read_bytes()
            and reopened["projectKey"] == pre_save["projectKey"] == evidence["projectKey"], "actual saved/reopened canonical bytes")
    for field in ("characters", "ensembles", "props", "locations", "look", "notes"):
        require(saved.get(field) == bible.get(field), "typed Bible state changed before Save")
    require(bible["look"] == before["look"] == evidence["look"], "Look changed during typed navigation")
    for field, identifier in (("characters", "owner_performer"), ("ensembles", "owner_ensemble"), ("props", "owner_prop")):
        prior = before.get(field, [])
        current = bible.get(field, [])
        require(isinstance(prior, list) and isinstance(current, list)
                and all(isinstance(value, dict) and value.get("id") != identifier for value in prior)
                and len(current) == len(prior) + 1 and current[:-1] == prior
                and isinstance(current[-1], dict) and current[-1].get("id") == identifier,
                "typed assignment must append one new entity and preserve existing entities")
    for field in ("locations", "notes"):
        require(bible.get(field) == before.get(field), "existing Bible locations and notes changed")
    image = (directory / "bible-typed-reference.png").read_bytes()
    require(image.startswith(b"\x89PNG\r\n\x1a\n"), "actual reference PNG")
    image_sha = hashlib.sha256(image).hexdigest()
    receipt = read("bible-typed-generation-receipt.json")
    package_bytes = (directory / "bible-typed-generation-package.json").read_bytes()
    package = json.loads(package_bytes)
    batch = read("bible-typed-generation-batch.json")
    journal = read("bible-typed-generation-journal.json")
    require(receipt["schema"] == "generation-output-receipt/v1" and receipt["modality"] == "image"
            and receipt["projectKey"] == evidence["projectKey"] == batch["payload"]["projectKey"]
            and receipt["output"]["sha256"] == image_sha, "actual generated image receipt")
    require(receipt["package"]["sha256"] == hashlib.sha256(package_bytes).hexdigest()
            and receipt["package"]["id"] == package["id"], "exact generation package")
    require(batch["schema"] == "generation-batch/v1" and batch["payload"]["phase"] == "bible"
            and len(batch["payload"]["items"]) == 1 and journal["batchID"] == batch["id"]
            and len(journal["executions"]) == 1, "actual Bible phase batch")
    item, execution = batch["payload"]["items"][0], journal["executions"][0]
    require(item["package"] == package and execution["itemID"] == item["id"]
            and execution["state"] == "complete" and execution["outputAssetIDs"] == [receipt["assetID"]]
            and journal.get("pricingOverrideItemIDs") == [item["id"]], "native approved exact output")
    for identifier in (evidence["projectKey"], reopened["projectKey"], pre_save["projectKey"], receipt["projectKey"],
                       batch["payload"]["projectKey"], receipt["assetID"], receipt["package"]["id"], package["id"],
                       item["id"], batch["id"], journal["batchID"], execution["itemID"], execution["transactionID"]):
        require(isinstance(identifier, str) and bool(identifier.strip()), "nonempty native identity")
    events = receipt["spendEvents"]
    require(events and events[0]["kind"] == "reserved" and any(event["kind"] == "submitted" for event in events)
            and all(event["kind"] != "released" and isinstance(event["transactionId"], str) and event["transactionId"].strip()
                    and event["transactionId"] == execution["transactionID"] for event in events), "actual submission transaction")
    requests = read("bible-typed-http.json")
    posts = [request for request in requests if request["method"] == "POST"]
    require(len(posts) == 1 and posts[0]["url"] == "https://queue.fal.run/fal-ai/flux/schnell", "actual isolated image endpoint")
    body = json.loads(base64.b64decode(posts[0]["bodyBase64"], validate=True))
    require(body["prompt"] == package["payload"]["prompt"] == receipt["input"]["prompt"]
            and receipt["input"]["model"] == "fal-ai/flux/schnell", "actual compiler/package/provider prompt")
    interactions = native["interactions"]
    pointers = {row.get("id") for row in interactions if row.get("kind") == "pointer"}
    require("generation-batch.approve" in pointers and "bible.look.select" in pointers, "actual native approval/Look pointers")
    states = [row.get("evidence") for row in interactions if row.get("kind") == "verified-state"
              and row.get("label") == "native typed Bible entities and source traversal"]
    require(states == [evidence], "actual native result joins retained evidence")
    entities = evidence["entities"]
    expected = [("character", "characters", "owner_performer", "front"),
                ("ensemble", "ensembles", "owner_ensemble", "group_wide"),
                ("prop", "props", "owner_prop", "front")]
    require(len(entities) == len(expected) and len({row["path"] for row in entities}) == len(expected), "typed entity count and distinct canonical source paths")
    for row, (kind, field, identifier, view) in zip(entities, expected):
        values = [value for value in bible[field] if value["id"] == identifier]
        require(len(values) == 1 and row["kind"] == kind and row["id"] == identifier and row["view"] == view,
                "actual typed canonical entity")
        entity = values[0]
        source_path = Path(row["path"])
        require(not source_path.is_absolute() and ".." not in source_path.parts
                and row["path"].startswith("bible/"), "project-local Bible reference")
        retained_image = row.get("retainedImage")
        require(isinstance(retained_image, str) and Path(retained_image).name == retained_image
                and not (directory / retained_image).is_symlink()
                and (directory / retained_image).read_bytes() == image, "actual per-entity canonical sheet bytes")
        require(entity["sheets"] == {view: row["path"]} and entity["reference_images"] == [row["path"]]
                and entity["sheets"][view] == row["path"] and row["path"] in entity["reference_images"]
                and row["sha256"] == image_sha and row["inspectorOpenedFromHidden"] is True, "canonical typed image/source binding")
        if kind == "ensemble":
            require(type(entity["member_count"]) is int and entity["member_count"] == 2, "actual ensemble cardinality")
        require("bible.entity.select." + kind + "." + identifier in pointers
                and "bible.sheet." + kind + "." + identifier + "." + view in pointers, "actual typed selection/source pointers")
        screenshots = [name for name in native["screenshots"] if name.endswith("-typed-bible-" + kind + ".png")]
        require(len(screenshots) == 1, "actual typed screenshot")
        require(Path(screenshots[0]).name == screenshots[0], "native screenshot path")
        data = (directory / screenshots[0]).read_bytes()
        require(len(data) > 1000 and data.startswith(b"\x89PNG\r\n\x1a\n"), "retained native image")
    require(evidence["lookInspectorOpenedFromHidden"] is True, "Look must open a hidden inspector")
    for suffix in ("-typed-bible-look.png", "-typed-bible-generation-approval.png"):
        images = [name for name in native["screenshots"] if name.endswith(suffix)]
        require(len(images) == 1 and Path(images[0]).name == images[0], "native Look / budget screenshot")
        data = (directory / images[0]).read_bytes()
        require(len(data) > 1000 and data.startswith(b"\x89PNG\r\n\x1a\n"), "retained Look / approval image")
    return evidence
