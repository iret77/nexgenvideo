import hashlib
import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
import uuid

from agent_backend_live_evidence import validate


def fixture(backend):
    """Synthetic parser fixture, never a live backend result."""
    cases = []
    for operation in ("echo", "hold"):
        nonce, receipt = str(uuid.uuid4()), str(uuid.uuid4())
        args = json.dumps(dict(nonce=nonce, operation=operation), sort_keys=True, separators=(",", ":"))
        cases.append(dict(operation=operation, sessionID=str(uuid.uuid4()), turnID=str(uuid.uuid4()),
            nonce=nonce, receipt=receipt, toolUseID=str(uuid.uuid4()), messageID="synthetic-message", modelID="synthetic-model",
            toolName="mcp__nexgen__acceptance_echo" if backend == "claudeCode" else "acceptance_echo",
            toolInputJSON=args, inputSHA256=hashlib.sha256(args.encode()).hexdigest(),
            interfaceLanguage="en", schemaValidated=True, ownedRuntimeStopped=True, mcpStopped=True,
            usesLocalMCP=backend == "claudeCode", mcpPort=19000 if backend == "claudeCode" else 0,
            receiptReturned=operation == "echo", cancelledWhileToolPending=operation == "hold",
            responseText="The actual fixture receipt was received: " + receipt if operation == "echo" else ""))
    return dict(schema="agent-backend-live/v1", backend=backend, sourceSHA="a" * 40, processID=123,
                installedCLIVersion="1.2.3" if backend == "claudeCode" else None,
                discoveredAPIModelID="synthetic-model" if backend == "anthropicAPI" else None,
                liveProvider=True, mediaGeneration=False, nativeUI=False, cases=cases)


class AgentBackendLiveEvidenceTests(unittest.TestCase):
    def check(self, value, expected=True):
        with TemporaryDirectory() as root:
            path = Path(root) / "result.json"; path.write_text(json.dumps(value))
            if expected: validate(path, value["backend"], "a" * 40, "1.2.3", "synthetic-model")
            else:
                with self.assertRaises(ValueError): validate(path, value["backend"], "a" * 40, "1.2.3", "synthetic-model")

    def test_both_synthetic_shapes(self):
        for backend in ("claudeCode", "anthropicAPI"): self.check(fixture(backend))

    def test_controlled_child_evidence_cannot_claim_live(self):
        value = fixture("anthropicAPI"); value["liveProvider"] = False; self.check(value, False)

    def test_changed_nonce_or_tool_input_hash_rejected(self):
        for key, changed in (("nonce", str(uuid.uuid4())), ("inputSHA256", "f" * 64)):
            value = fixture("claudeCode"); value["cases"][0][key] = changed; self.check(value, False)

    def test_returned_receipt_and_real_pending_cancel_required(self):
        for index, key in ((0, "receiptReturned"), (1, "cancelledWhileToolPending"), (1, "ownedRuntimeStopped")):
            value = fixture("anthropicAPI"); value["cases"][index][key] = False; self.check(value, False)
        value = fixture("claudeCode"); value["cases"][0]["responseText"] = "A response without the actual returned host receipt."
        self.check(value, False)

    def test_source_and_transport_binding_required(self):
        value = fixture("claudeCode"); value["sourceSHA"] = "b" * 40; self.check(value, False)
        value = fixture("anthropicAPI"); value["cases"][0]["usesLocalMCP"] = True; self.check(value, False)

    def test_reused_case_identity_and_missing_model_refused(self):
        value = fixture("claudeCode"); value["cases"][1]["sessionID"] = value["cases"][0]["sessionID"]; self.check(value, False)
        value = fixture("anthropicAPI"); value["cases"][0]["modelID"] = ""; self.check(value, False)

    def test_installed_cli_and_discovered_api_identity_required(self):
        value = fixture("claudeCode"); value["installedCLIVersion"] = None; self.check(value, False)
        value = fixture("anthropicAPI"); value["discoveredAPIModelID"] = "a-different-model"; self.check(value, False)

    def test_consistent_but_unrequested_version_and_model_refused(self):
        value = fixture("claudeCode"); value["installedCLIVersion"] = "1.2.4"; self.check(value, False)
        value = fixture("anthropicAPI"); value["discoveredAPIModelID"] = "fallback-model"
        for case in value["cases"]: case["modelID"] = "fallback-model"
        self.check(value, False)

    def test_pending_tool_did_not_return_its_receipt(self):
        value = fixture("claudeCode"); value["cases"][1]["responseText"] = value["cases"][1]["receipt"]
        self.check(value, False)


if __name__ == "__main__": unittest.main()
