import argparse
import hashlib
import json
from pathlib import Path
import re
from uuid import UUID


def validate(directory):
    directory = Path(directory)
    result = json.loads((directory / "result.json").read_bytes())
    if result.get("schema") != "nexgenvideo/bpy-runtime-acceptance/2" \
            or result.get("untrustedExitEvidenceFile") != "native-untrusted-exits.json":
        raise ValueError("worker evidence identity")
    data = (directory / "native-untrusted-exits.json").read_bytes()
    if hashlib.sha256(data).hexdigest() != result.get("untrustedExitEvidenceSHA256"):
        raise ValueError("worker evidence bytes")
    evidence = json.loads(data)
    if not isinstance(evidence, list) or len(evidence) != 2:
        raise ValueError("worker exit coverage")
    identifiers = set()
    for item, code in zip(evidence, (71, 72)):
        expected_source = f"import os\nos.write(1, b'UNTRUSTED_EXIT_REACHED\\n')\nos._exit({code})"
        if type(item.get("exitCode")) is not int or item["exitCode"] != code \
                or item.get("source") != expected_source:
            raise ValueError("actual untrusted exit source")
        response = item["response"]
        identifier = UUID(response["jobID"])
        if identifier in identifiers or response.get("ok") is not True \
                or response.get("state") != "failed" \
                or response.get("message") != f"worker reported exit {code} without an observed resource limit" \
                or "UNTRUSTED_EXIT_REACHED\n" not in response.get("stdout", "") \
                or not re.fullmatch(r"[a-f0-9]{64}", response.get("jobFingerprint", "")) \
                or response.get("outputs") != []:
            raise ValueError("untrusted exit became native evidence")
        identifiers.add(identifier)
    if result.get("rlimitASAllocationDenied") is not True \
            or result.get("outOfMemoryState") not in ("failed", "resourceLimited"):
        raise ValueError("independent allocation controls")
    return {"schema": "nexgenvideo/bpy-worker-evidence-validation/1", "untrustedExits": [71, 72]}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    try:
        print(json.dumps(validate(args.directory), sort_keys=True))
    except (ValueError, KeyError, TypeError, OSError) as error:
        parser.exit(1, f"worker evidence rejected: {error}\n")
