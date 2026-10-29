"""Independent byte/source joins for actual helper and decoded movie evidence; no provider claim."""
import argparse
import csv
import hashlib
import io
import json
import math
from pathlib import Path


def require(value, message):
    if not value:
        raise ValueError(message)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def integer(value, name, minimum=0):
    require(type(value) is int and value >= minimum, f"invalid {name}")
    return value


def fingerprint(source, revision, timeout):
    integer(timeout, "actual job timeout", 1)
    values = ["nexgenvideo/bpy-job/5", revision.upper() if revision else None, None,
              str(timeout), source, "0", "0", "0", "0", "0"]
    digest = hashlib.sha256()
    for value in values:
        digest.update(bytes([0 if value is None else 1]))
        if value is not None:
            encoded = value.encode()
            digest.update(len(encoded).to_bytes(8, "big"))
            digest.update(encoded)
    return digest.hexdigest()


def command(source, script):
    prefix, literal, suffix = source.split("\n", 2)
    require(prefix == "import json" and literal.startswith("ngv_command = json.loads(")
            and literal.endswith(")") and suffix.encode() == script, "command is not the retained helper program")
    settings = json.loads(literal[len("ngv_command = json.loads("):-1])
    require(type(settings) is str, "command settings are not a JSON string")
    return json.loads(settings), settings.encode()


def matrix(actual, expected):
    require(len(actual) == len(expected) == 16, "wrong matrix shape")
    require(all(type(a) in (int, float) and type(b) in (int, float) and math.isfinite(a) and math.isfinite(b)
                and abs(a - b) <= 0.000001 * max(1, abs(b)) for a, b in zip(actual, expected)),
            "render-evaluated transform differs from native pose")


def verify(directory, runtime_root):
    directory = Path(directory) / "evaluated-deformation"
    runtime_root = Path(runtime_root)

    def regular(path):
        require(path.is_file() and not path.is_symlink(), f"missing regular evidence: {path.name}")
        return path.read_bytes()

    def data(name):
        require(Path(name).name == name, "unsafe geometry filename")
        return regular(directory / name)

    def digest(name):
        return sha(data(name))

    def read(name):
        return json.loads(data(name))

    observation = read("observations.v1.json")
    geometry = read("evaluated-geometry.v1.json")
    state = read("state.v1.json")
    manifest = read("scene-manifest.v1.json")
    snapshot = read("snapshot.v1.json")
    require(observation["schema"] == "evaluated-geometry-acceptance/v1", "foreign observation")
    require(geometry["schema"] == "spatial-evaluated-geometry/v1", "foreign geometry proof")
    require(observation["geometrySHA256"] == digest("evaluated-geometry.v1.json"), "geometry bytes changed")
    require(geometry["sceneManifestSHA256"] == observation["sceneManifestSHA256"] == digest("scene-manifest.v1.json"), "scene manifest mismatch")
    require(geometry["stateSHA256"] == observation["stateSHA256"] == digest("state.v1.json"), "native state mismatch")
    require(state["sceneManifestSHA256"] == digest("scene-manifest.v1.json"), "native state belongs to another scene")
    require(geometry["sceneSHA256"] == manifest["sceneSHA256"] == digest("scene.blend"), "actual scene mismatch")
    require(geometry["snapshotSHA256"] == manifest["snapshotSHA256"] == digest("snapshot.v1.json"), "actual source snapshot mismatch")
    require(geometry["sceneRevision"].lower() == manifest["revision"].lower(), "foreign source revision")
    require(type(geometry["sceneFrameOrigin"]) is int and geometry["sceneFrameOrigin"] == 0, "implicit scene frame origin")
    integer(geometry["effectiveTimeoutSeconds"], "actual evaluation timeout", 1)
    retained = {"scriptSHA256": ("evaluated-scene-operations.py", "scene_operations.py"),
                "workerSHA256": ("evaluated-worker.py", "worker.py"),
                "runtimeLockSHA256": ("evaluated-runtime-lock.json", "runtime-lock.json"),
                "runtimeRecordSHA256": ("evaluated-runtime-record.csv", "site-packages/bpy-5.2.2.dist-info/RECORD")}
    for field, (name, installed) in retained.items():
        require(geometry[field] == digest(name) == sha(regular(runtime_root / installed)), "retained runtime source differs from actual bundled runtime")
    repository = Path(__file__).resolve().parents[1]
    for name, installed in list(retained.values())[:3]:
        require(data(name) == regular(repository / "Runtime/bpy" / installed), "actual runtime program differs from reviewed repository source")
    require(geometry["runtimeBinarySHA256"] == sha(regular(runtime_root / "site-packages/bpy/__init__.so")), "actual signed runtime binary mismatch")
    lock = read("evaluated-runtime-lock.json")
    build = lock["bpyWheelLayout"]["expectedRuntimeBinaryEvidence"]["buildHash"]
    record = list(csv.reader(io.StringIO(data("evaluated-runtime-record.csv").decode())))
    entries = [row for row in record if len(row) == 3 and row[0] == "bpy/__init__.so"]
    require(len(entries) == 1 and entries[0][1].startswith("sha256=") and int(entries[0][2]) > 0,
            "missing original wheel binary inventory")
    # Signing changes Mach-O bytes; RECORD remains the original wheel inventory.
    script = data("evaluated-scene-operations.py")
    source = data("scene-program.py").decode()
    require(observation["sourceProgramSHA256"] == sha(source.encode()), "actual source program changed")
    require(observation["simulationPreflightSHA256"] == digest("simulation-preflight.json"), "actual simulation preflight changed")
    simulation = read("simulation-preflight.json")
    require(simulation["isBaked"] is False and "Bake simulation caches" in simulation["reason"], "unbaked simulation was silently accepted")
    receipt = manifest["receipt"]
    require(receipt["jobFingerprint"] == fingerprint(source, None, observation["sourceJobTimeoutSeconds"]), "source job fingerprint is not reproducible")
    require(receipt["sceneSHA256"] == geometry["sceneSHA256"] and receipt["snapshotSHA256"] == geometry["snapshotSHA256"]
            and receipt["workerSHA256"] == geometry["workerSHA256"] and receipt["runtimeLockSHA256"] == geometry["runtimeLockSHA256"]
            and receipt["blenderBuildHash"] == build, "source receipt closure differs")
    actual, next_frame, jobs = [], 0, {receipt["jobID"].lower()}
    for chunk in geometry["chunks"]:
        start, end = integer(chunk["startFrame"], "chunk start"), integer(chunk["endFrame"], "chunk end")
        require(start == next_frame <= end < start + 120, "partial chunk coverage")
        require(chunk["jobID"].lower() not in jobs, "duplicate runtime job")
        jobs.add(chunk["jobID"].lower())
        require(chunk["filename"] == f"evaluated-bounds-{start}.v1.json", "wrong chunk filename")
        require(chunk["sha256"] == digest(chunk["filename"]), "changed evaluated bounds")
        source_name = f"evaluated-command-{start}.py"
        require(chunk["commandSHA256"] == digest(source_name), "actual evaluated command changed")
        settings, _ = command(data(source_name).decode(), script)
        part = dict(state, frames=state["frames"][start:end + 1])
        require(settings == {"kind": "evaluate_bounds", "cameraID": state["cameraID"], "state": part}, "actual evaluated command targets another state")
        require(chunk["jobFingerprint"] == fingerprint(data(source_name).decode(), manifest["revision"], geometry["effectiveTimeoutSeconds"]), "evaluated job fingerprint is not reproducible")
        name = f"evaluated-verification-{start}.v1.json"
        require(chunk["verificationSHA256"] == digest(name), "changed actual runtime verification")
        verification = read(name)
        require(verification["jobID"].lower() == chunk["jobID"].lower() and verification["fingerprint"] == chunk["jobFingerprint"], "foreign runtime receipt")
        require(verification["blenderBuildHash"] == build, "wrong pinned Blender")
        values = read(chunk["filename"])
        require(all(type(item.get("frame")) is int for item in values), "noninteger sampled frame")
        require([item["frame"] for item in values] == list(range(start, end + 1)), "wrong sampled frames")
        actual += values
        next_frame = end + 1
    require(actual == geometry["frames"] and next_frame == 2, "actual fixture frame coverage differs")
    require([item["frame"] for item in state["frames"]] == [0, 1], "wrong native state frames")
    require(state["frames"][0]["objects"] == state["frames"][1]["objects"], "fixture silently used object-transform motion")
    source_objects = {item["id"]: item for item in snapshot["objects"]}
    require(len(source_objects) == len(snapshot["objects"]), "duplicate snapshot objects")
    for role, name in [("boneObjectID", "RiggedMesh"), ("shapeObjectID", "ShapeMesh"),
                       ("modifierObjectID", "ModifierMesh"), ("curveObjectID", "CurveGeometry"), ("foreignObjectID", "ForeignMesh")]:
        require(observation[role] in source_objects and source_objects[observation[role]]["name"] == name, "deformation role differs from source object")
    require(len({observation[key] for key in ("boneObjectID", "shapeObjectID", "modifierObjectID", "curveObjectID", "foreignObjectID")}) == 5, "role alias")
    for frame in actual:
        require(type(frame["sceneFrame"]) is int and frame["sceneFrame"] == frame["frame"], "scene frame origin drift")
        require(frame["scene"] == "Deformation active" and frame["viewLayer"] == "ViewLayer", "foreign render scope")
        require(frame["metersPerUnit"] == snapshot["metersPerUnit"] and math.isfinite(frame["metersPerUnit"])
                and frame["metersPerUnit"] > 0, "evaluated units drift")
        poses = {item["objectID"]: item["matrixWorld"] for item in frame["objects"]}
        native = {item["objectID"]: item["matrixWorld"] for item in state["frames"][frame["frame"]]["objects"]}
        require(len(poses) == len(frame["objects"]) == len(native) == len(source_objects)
                and poses.keys() == native.keys() == source_objects.keys(), "native/evaluated object closure incomplete")
        for identity in poses:
            matrix(poses[identity], native[identity])
        matrix(frame["cameraMatrix"], native[state["cameraID"]])
        require(len({item["id"] for item in frame["meshes"]}) == len(frame["meshes"]), "duplicate evaluated instance")
        for mesh in frame["meshes"]:
            require(mesh["objectID"] in source_objects and mesh["objectID"] != observation["foreignObjectID"]
                    and len(mesh["minimum"]) == len(mesh["maximum"]) == 3, "foreign evaluated object")
            require(all(type(a) in (int, float) and type(b) in (int, float) and math.isfinite(a) and math.isfinite(b)
                        and a <= b for a, b in zip(mesh["minimum"], mesh["maximum"])), "invalid bounds")

    def bounds(role, index):
        values = [item for item in actual[index]["meshes"] if item["objectID"] == observation[role]]
        require(len(values) == 1, "missing unique actual deformation owner")
        return values[0]

    bone0, bone1 = bounds("boneObjectID", 0), bounds("boneObjectID", 1)
    shape0, shape1 = bounds("shapeObjectID", 0), bounds("shapeObjectID", 1)
    modifier0, modifier1 = bounds("modifierObjectID", 0), bounds("modifierObjectID", 1)
    curve = bounds("curveObjectID", 0)
    require(curve["maximum"][0] - curve["minimum"][0] > 0.9, "renderable curve geometry omitted")
    require(abs(bone1["minimum"][0] - bone0["minimum"][0] - 4) < 0.0001, "bone deformation lost or source object animation substituted")
    require(abs(shape1["minimum"][1] - shape0["minimum"][1] - 2) < 0.0001, "shape-key deformation lost")
    require(modifier1["maximum"][2] - modifier1["minimum"][2] > modifier0["maximum"][2] - modifier0["minimum"][2] + 1, "render-only animated modifier lost")
    clay = read("clay-proof.v1.json")
    require(clay["schema"] == "spatial-derivation-proof/v1" and clay["purpose"] == "geometry"
            and clay["stateKind"] == "shot_state" and clay["state"] == state, "foreign Clay state")
    require(clay["scene"]["manifestSHA256"] == digest("scene-manifest.v1.json")
            and clay["scene"]["revision"].lower() == manifest["revision"].lower()
            and clay["sceneSHA256"] == geometry["sceneSHA256"] and clay["sourceSnapshotSHA256"] == geometry["snapshotSHA256"]
            and clay["resourceClosureSHA256"] == manifest["resourceClosureSHA256"], "Clay source closure differs")
    for field, other in [("workerSHA256", "workerSHA256"), ("runtimeLockSHA256", "runtimeLockSHA256"),
                         ("rendererScriptSHA256", "scriptSHA256"), ("rendererBinarySHA256", "runtimeBinarySHA256")]:
        require(clay[field] == geometry[other], "Clay/evaluated runtime mismatch")
    require(clay["blenderBuildHash"] == build and clay["jobID"].lower() not in jobs, "Clay job identity mismatch")
    require(observation["clayCommandSHA256"] == digest("clay-command.py"), "Clay command bytes changed")
    clay_settings, raw_settings = command(data("clay-command.py").decode(), script)
    request = clay["request"]
    require(clay_settings == {"kind": "render_clay", "cameraID": state["cameraID"], "width": request["width"],
            "height": request["height"], "samples": request["samples"], "startFrame": 0, "endFrame": 1, "state": state}
            and request["owner"] == "shot_planning" and request["stateSHA256"] == digest("state.v1.json")
            and request["ownerBindingSHA256"] == digest("state.v1.json") and request["ownerArtifactSHA256"] == geometry["sceneSHA256"], "Clay request differs from evaluated source")
    require(clay["settingsSHA256"] == sha(raw_settings)
            and clay["jobFingerprint"] == fingerprint(data("clay-command.py").decode(), manifest["revision"], geometry["effectiveTimeoutSeconds"]), "Clay job fingerprint is not reproducible")
    for output in clay["outputs"]:
        require(output["sha256"] == digest(output["filename"]) and output["byteCount"] == len(data(output["filename"])), "actual Clay output changed")
    require({item["filename"] for item in clay["outputs"]} >= {"clay-00000000.png", "clay-00000001.png"}, "missing actual Clay frames")
    require(observation["movieSHA256"] == digest("plan.mov"), "plan movie bytes changed")
    integer(observation["durationValue"], "decoded duration", 1)
    integer(observation["durationTimescale"], "decoded timescale", 1)
    require(observation["durationValue"] * 12 == observation["durationTimescale"], "inexact decoded movie duration")
    require(type(observation["audioTrackCount"]) is int and observation["audioTrackCount"] == 0, "plan contains audio")
    frames = [digest(f"plan-frame-{index}.png") for index in range(2)]
    require(frames == observation["decodedFrameSHA256"] and frames[0] != frames[1], "actual decoded plan did not change")
    for index in range(2):
        require(data(f"plan-frame-{index}.png").startswith(b"\x89PNG\r\n\x1a\n"), "invalid decoded image")
    require(digest("clay-00000000.png") != digest("clay-00000001.png"), "actual Clay pixels did not change")
    return {"actualFrames": len(actual), "actualJobs": len(jobs) + 1, "runtimeBinarySHA256": geometry["runtimeBinarySHA256"]}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("evidence")
    parser.add_argument("--runtime-root", type=Path, required=True)
    arguments = parser.parse_args()
    print(json.dumps(verify(arguments.evidence, arguments.runtime_root), sort_keys=True))
