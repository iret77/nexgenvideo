"""Read the retained real-backend transport smoke, never controlled-child evidence."""
import argparse
import hashlib
import json
import re
import uuid
from pathlib import Path


def require(value, message):
    if not value:
        raise ValueError(message)


def validate(path, backend, source, expected_cli_version=None, expected_api_model=None):
    result = json.loads(Path(path).read_text())
    require(backend in ("claudeCode", "anthropicAPI") and re.fullmatch(r"[0-9a-f]{40}", source), "invalid backend/source")
    require(result.get("schema") == "agent-backend-live/v1" and result.get("backend") == backend
            and result.get("sourceSHA") == source and result.get("liveProvider") is True
            and result.get("mediaGeneration") is False and result.get("nativeUI") is False
            and type(result.get("processID")) is int and result["processID"] > 0, "actual live backend envelope missing")
    if backend == "claudeCode":
        require(isinstance(result.get("installedCLIVersion"), str)
                and re.fullmatch(r"[0-9]+[.][0-9]+[.][0-9]+", result["installedCLIVersion"])
                and result["installedCLIVersion"] == expected_cli_version
                and result.get("discoveredAPIModelID") is None, "actual installed CLI identity missing")
    else:
        require(result.get("installedCLIVersion") is None
                and isinstance(result.get("discoveredAPIModelID"), str)
                and result["discoveredAPIModelID"] and result["discoveredAPIModelID"] == expected_api_model,
                "actual requested API discovery identity missing")
    cases = result["cases"]
    require(len(cases) == 2 and [case["operation"] for case in cases] == ["echo", "hold"], "roundtrip/cancel cases missing")
    sessions, turns, calls, nonces = set(), set(), set(), set()
    for case in cases:
        for key in ("sessionID", "turnID", "nonce", "receipt"):
            uuid.UUID(case[key])
        sessions.add(case["sessionID"]); turns.add(case["turnID"]); calls.add(case["toolUseID"])
        nonces.add(case["nonce"])
        require(case["toolUseID"] and case["messageID"] and case["modelID"], "actual provider identity missing")
        if backend == "anthropicAPI":
            require(case["modelID"] == result["discoveredAPIModelID"], "response differs from selected discovered model")
        require(case["toolName"] == ("mcp__nexgen__acceptance_echo" if backend == "claudeCode" else "acceptance_echo"), "wrong actual tool")
        args = json.loads(case["toolInputJSON"])
        require(args == {"nonce": case["nonce"], "operation": case["operation"]}, "actual schema input differs")
        canonical = json.dumps(args, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode()
        require(hashlib.sha256(canonical).hexdigest() == case["inputSHA256"], "response input hash differs")
        require(case.get("schemaValidated") is True and case.get("ownedRuntimeStopped") is True
                and case.get("mcpStopped") is True and case["interfaceLanguage"][:2] in ("en", "de"), "language/schema/owned shutdown missing")
        require(case.get("usesLocalMCP") is (backend == "claudeCode")
                and type(case.get("mcpPort")) is int
                and (0 < case["mcpPort"] <= 65535 if backend == "claudeCode" else case["mcpPort"] == 0), "actual tool transport differs")
        if case["operation"] == "echo":
            require(case.get("receiptReturned") is True and case.get("cancelledWhileToolPending") is False
                    and case["receipt"] in case["responseText"] and len(case["responseText"]) >= 40, "actual tool receipt was not consumed")
        else:
            require(case.get("receiptReturned") is False and case.get("cancelledWhileToolPending") is True
                    and case["receipt"] not in case["responseText"], "real in-flight cancellation missing")
    require(len(sessions) == len(turns) == len(calls) == len(nonces) == 2, "backend cases reused an identity")
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("path", type=Path); parser.add_argument("--backend", required=True); parser.add_argument("--source", required=True)
    parser.add_argument("--expected-cli-version"); parser.add_argument("--expected-api-model")
    args = parser.parse_args()
    validate(args.path, args.backend, args.source, args.expected_cli_version, args.expected_api_model)
