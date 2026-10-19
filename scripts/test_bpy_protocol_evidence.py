import base64
import copy
import hashlib
import json
import unittest

from bpy_protocol_evidence import CHUNK_BYTES, fingerprint, validate


def encoded(value):
    return base64.b64encode(json.dumps(value).encode()).decode()


def decoded(value):
    return json.loads(base64.b64decode(value))


def fixture(*, restored=b"restored", completed_by_authorization=False):
    session = "00000000-0000-0000-0000-000000000001"
    owner, staged, reserved, other, unknown, reclaimed, recovered = [
        "00000000-0000-0000-0000-%012d" % n for n in range(2, 9)]
    requests, chunks, responses = {}, {}, {}
    limits = dict(inputBytes=100, timeoutSeconds=120)

    def add(label, fields, ok=True, target=session, **response):
        requests[label] = encoded(dict(sessionID=target, **fields))
        responses[label] = encoded(dict(ok=ok, **response))

    add("foreign-open", dict(documentID="parser-fixture", limits=limits), False)
    add("foreign-status", dict(jobID=owner), False)
    add("foreign-close", {}, False)
    add("owner-after-foreign-close", dict(jobID=owner), state="confirmed", jobID=owner)
    add("confirm-replay", dict(jobID=owner, revision="revision-a", sceneSHA256=hashlib.sha256(b"ab").hexdigest()), state="confirmed", jobID=owner)
    preparation = dict(id=reclaimed, servicePID=123, serviceStart=100)
    for label in ("reservation-first-owner", "reservation-new-owner", "reservation-survived-stale-close"):
        add(label, dict(documentID="parser-fixture", limits=limits), target=reclaimed, storagePreparation=preparation)
    add("reservation-failed-bookmark", dict(documentID="parser-fixture", limits=limits,
        storage=dict(bookmark=base64.b64encode(bytes([1, 2, 3])).decode())), False, target=reclaimed)
    add("reservation-stale-close", {}, False, target=reclaimed)
    add("reservation-stale-reopen", dict(documentID="parser-fixture", limits=limits), False,
        target=reclaimed, message="invalid open request")
    add("reservation-cleanup", {}, target=reclaimed)
    good_hash = hashlib.sha256(b"{}").hexdigest()
    for label, job, size, sha, final, data, ok, name, offset in (
        ("invalid-final-hash", staged, 2, "0" * 64, True, b"{}", False, "probe.json", 0),
        ("valid-final-after-failure", staged, 2, good_hash, True, b"{}", True, "probe.json", 0),
        ("reserve-global-input-budget", reserved, 98, good_hash, False, b"\x00", True, "probe.json", 0),
        ("cross-job-budget-refused", other, 2, good_hash, True, b"{}", False, "probe.json", 0),
        ("budget-released-after-cancel", other, 2, good_hash, True, b"{}", True, "probe.json", 0),
        ("literal-part-name", staged, 2, good_hash, True, b"{}", True, "foo.part", 0),
        ("partial-input", staged, 2, good_hash, False, b"{", True, "foo", 0),
        ("completed-partial-input", staged, 2, good_hash, True, b"}", True, "foo", 1),
    ):
        add(label, dict(jobID=job, name=name, totalBytes=size, sha256=sha, offset=offset, finalChunk=final), ok)
        chunks[label] = base64.b64encode(data).decode()
    for label, job in (("cancel-reservation", reserved), ("cancel-unrelated-unknown-job", unknown),
                       ("cleanup-staged", staged), ("cleanup-reserved", reserved), ("cleanup-other", other)):
        add(label, dict(jobID=job), label == "cleanup-staged")
    request = dict(sessionID=session, jobID=staged, expectedRevision="revision-a",
        source="assert set(p.name for p in input_dir.iterdir()) == {'foo', 'foo.part', 'probe.json'}; assert all((input_dir / n).read_text() == '{}' for n in ['foo', 'foo.part', 'probe.json'])",
        inputNames=["foo", "foo.part", "probe.json"], diagnosticDeniedPaths=[], diagnosticAutoexecPositiveControl=False,
        diagnosticSupervisorIdentityWriteFailure=False, diagnosticSupervisorIdentityCaptureFailure=False)
    input_records = [dict(name=name, totalBytes=2, sha256=good_hash) for name in request["inputNames"]]
    request["fingerprint"] = fingerprint(request, limits, input_records)
    partial_request = dict(request, inputNames=["foo.part", "probe.json"],
                           source="assert all((input_dir / n).read_text() == '{}' for n in ['foo.part', 'probe.json'])")
    partial_request["fingerprint"] = fingerprint(partial_request, limits, input_records[1:])
    requests["submit-with-partial-input"] = encoded(partial_request)
    responses["submit-with-partial-input"] = encoded(dict(ok=False))
    for label, state in (("service-submit", "accepted"), ("service-submit-replay", "running")):
        requests[label] = encoded(request)
        responses[label] = encoded(dict(ok=True, state=state, jobID=staged, jobFingerprint=request["fingerprint"],
                                        joinedExistingJob=label == "service-submit-replay"))
    status = dict(sessionID=session, jobID=staged)
    common = dict(ok=True, jobID=staged, jobFingerprint=request["fingerprint"])
    needs_authorization = dict(common, state="running", activeProcessAuthorizationID=unknown,
        activeProcessIdentifier=456, activeProcessStartAbsoluteTime=200,
        activeProcessExecutable="/parser-fixture.app/Contents/Helpers/NexGenVideoBpySupervisor")
    authorize = dict(status, authorizationID=unknown, processIdentifier=456, processStartAbsoluteTime=200,
                     processExecutable=needs_authorization["activeProcessExecutable"])
    completion = [dict(method="jobStatus", request=encoded(status), response=encoded(needs_authorization)),
                  dict(method="authorizeProcess", request=encoded(authorize),
                       response=encoded(dict(common, state="awaitingConfirmation" if completed_by_authorization else "running")))]
    if not completed_by_authorization:
        completion.append(dict(method="jobStatus", request=encoded(status), response=encoded(dict(common, state="awaitingConfirmation"))))
    final_poll = [item for item in completion if item["method"] == "jobStatus"][-1]
    requests["service-completed"], responses["service-completed"] = final_poll["request"], final_poll["response"]
    restore = []
    for offset in range(0, len(restored), CHUNK_BYTES):
        chunk = restored[offset:offset + CHUNK_BYTES]
        restore.append(dict(method="restoreCheckpoint", request=encoded(dict(sessionID=recovered,
            revision="revision-e", sha256=hashlib.sha256(restored).hexdigest(), offset=offset,
            totalBytes=len(restored), finalChunk=offset + len(chunk) == len(restored))),
            response=encoded(dict(ok=True, confirmedRevision="revision-e")),
            chunkBytes=len(chunk), chunkSHA256=hashlib.sha256(chunk).hexdigest()))
    restore.append(dict(restore[-1], method="restoreCheckpointReplay"))
    order = ["foreign-open", "foreign-status", "foreign-close", "owner-after-foreign-close",
        "reservation-first-owner", "reservation-failed-bookmark", "reservation-new-owner", "reservation-stale-close",
        "reservation-stale-reopen", "reservation-survived-stale-close", "reservation-cleanup", "confirm-replay", "invalid-final-hash",
        "valid-final-after-failure", "reserve-global-input-budget", "cross-job-budget-refused", "cancel-reservation",
        "budget-released-after-cancel", "cancel-unrelated-unknown-job", "literal-part-name", "partial-input",
        "submit-with-partial-input", "completed-partial-input", "service-submit", "service-submit-replay"]
    order += ["service-completed"] * (1 if completed_by_authorization else 2)
    order += ["cleanup-staged", "cleanup-reserved", "cleanup-other"]
    return dict(schema="nexgenvideo/bpy-native-protocol-evidence/2", requests=requests, chunks=chunks,
        responses=responses, exchangeOrder=order, completion=completion, restore=restore,
        restoreOpen=dict(method="openSession", request=encoded(dict(sessionID=recovered, confirmedRevision="revision-e")),
            response=encoded(dict(ok=True, confirmedRevision="revision-e", runtime=dict(serviceProcessIdentifier=124)))))


class ProtocolEvidenceTests(unittest.TestCase):
    def check(self, evidence, restored=b"restored"):
        raw = json.dumps(evidence).encode()
        validate(evidence, dict(nativeProtocolEvidenceFile="native-protocol-evidence.json",
            nativeProtocolEvidenceSHA256=hashlib.sha256(raw).hexdigest(), serviceRecoveryRevision="revision-e", serviceA=123),
            raw, b"ab", restored)

    def change(self, evidence, group, label, **fields):
        value = decoded(evidence[group][label])
        value.update(fields)
        evidence[group][label] = encoded(value)

    def test_parser_fixture_and_actual_authorization_completion_shapes(self):
        self.check(fixture())
        self.check(fixture(completed_by_authorization=True))

    def test_false_flag_and_missing_response(self):
        for label in ("foreign-open", "cross-job-budget-refused", "cleanup-staged", "submit-with-partial-input", "reservation-stale-close"):
            evidence = fixture()
            self.change(evidence, "responses", label, ok=not decoded(evidence["responses"][label])["ok"])
            with self.assertRaises(ValueError):
                self.check(evidence)
        evidence = fixture()
        del evidence["responses"]["service-submit-replay"]
        with self.assertRaises(ValueError):
            self.check(evidence)

    def test_request_identity_or_fingerprint_drift(self):
        for field, value in (("sessionID", "00000000-0000-0000-0000-000000000099"),
                             ("jobID", "00000000-0000-0000-0000-000000000099"), ("source", "different source")):
            evidence = fixture()
            self.change(evidence, "requests", "service-submit", **{field: value})
            with self.assertRaises(ValueError):
                self.check(evidence)
        evidence = fixture()
        for label in ("service-submit", "service-submit-replay"):
            self.change(evidence, "requests", label, fingerprint="b" * 64)
        with self.assertRaises(ValueError):
            self.check(evidence)

    def test_completed_request_must_name_actual_staged_job(self):
        evidence = fixture()
        self.change(evidence, "requests", "service-completed", jobID="00000000-0000-0000-0000-000000000099")
        evidence["completion"][-1]["request"] = evidence["requests"]["service-completed"]
        with self.assertRaises(ValueError):
            self.check(evidence)

    def test_missing_or_changed_actual_authorization_exchange(self):
        for change in ("missing", "lease", "response", "poll", "order"):
            evidence = fixture(completed_by_authorization=True)
            if change == "missing":
                evidence["completion"].pop()
            elif change == "lease":
                request = decoded(evidence["completion"][1]["request"])
                evidence["completion"][1]["request"] = encoded(dict(request, processIdentifier=999))
            elif change == "response":
                response = decoded(evidence["completion"][1]["response"])
                evidence["completion"][1]["response"] = encoded(dict(response, jobFingerprint="b" * 64))
            elif change == "poll":
                self.change(evidence, "responses", "service-completed", state="awaitingConfirmation")
            else:
                evidence["completion"].reverse()
            with self.assertRaises(ValueError):
                self.check(evidence)

    def test_actual_multichunk_restore_and_exact_last_replay(self):
        restored = b"a" * CHUNK_BYTES + b"tail"
        self.check(fixture(restored=restored), restored)
        for change in ("suffix", "missing-upload", "gap", "chunk-hash", "replay-request", "replay-response", "foreign-session", "wrong-open"):
            evidence = fixture(restored=restored)
            if change == "suffix":
                last = evidence["restore"][-1]
                request = decoded(last["request"])
                last.update(request=encoded(dict(request, offset=len(restored) - CHUNK_BYTES)),
                            chunkBytes=CHUNK_BYTES, chunkSHA256=hashlib.sha256(restored[-CHUNK_BYTES:]).hexdigest())
            elif change == "missing-upload":
                evidence["restore"].pop(0)
            elif change == "gap":
                request = decoded(evidence["restore"][1]["request"])
                evidence["restore"][1]["request"] = encoded(dict(request, offset=CHUNK_BYTES - 1))
            elif change == "chunk-hash":
                evidence["restore"][0]["chunkSHA256"] = "b" * 64
            elif change == "replay-request":
                raw = base64.b64decode(evidence["restore"][-1]["request"])
                evidence["restore"][-1]["request"] = base64.b64encode(raw + b" ").decode()
            elif change == "replay-response":
                evidence["restore"][-1]["response"] = encoded(dict(ok=False, confirmedRevision="revision-e"))
            elif change == "foreign-session":
                request = decoded(evidence["restore"][0]["request"])
                evidence["restore"][0]["request"] = encoded(dict(request, sessionID="00000000-0000-0000-0000-000000000099"))
            else:
                evidence["restoreOpen"]["response"] = encoded(dict(ok=True, confirmedRevision="revision-e", runtime=dict(serviceProcessIdentifier=123)))
            with self.assertRaises(ValueError):
                self.check(evidence, restored)

    def test_single_chunk_requires_actual_original_upload(self):
        evidence = fixture()
        evidence["restore"] = evidence["restore"][-1:]
        with self.assertRaises(ValueError):
            self.check(evidence)

    def test_changed_chunks_partial_contract_and_boolean_integer(self):
        for label in ("valid-final-after-failure", "budget-released-after-cancel", "literal-part-name", "partial-input", "completed-partial-input"):
            evidence = fixture()
            evidence["chunks"][label] = base64.b64encode(b"changed").decode()
            with self.assertRaises(ValueError):
                self.check(evidence)
        for label, fields in (("reserve-global-input-budget", dict(totalBytes=True)),
                              ("completed-partial-input", dict(offset=True)),
                              ("literal-part-name", dict(name="foo.part.part")),
                              ("submit-with-partial-input", dict(inputNames=["foo.part"])),
                              ("reservation-stale-close", dict(sessionID="00000000-0000-0000-0000-000000000099"))):
            evidence = fixture()
            self.change(evidence, "requests", label, **fields)
            with self.assertRaises(ValueError):
                self.check(evidence)

    def test_null_timeout_matches_omitted_but_invalid_values_are_refused(self):
        evidence = fixture()
        request = decoded(evidence["requests"]["service-submit"])
        records = [decoded(evidence["requests"][label]) for label in
                   ("completed-partial-input", "literal-part-name", "valid-final-after-failure")]
        limits = decoded(evidence["requests"]["foreign-open"])["limits"]
        self.assertEqual(fingerprint(dict(request, timeoutSeconds=None), limits, records), request["fingerprint"])
        for timeout in (True, 0, -1, "120"):
            with self.assertRaises(ValueError):
                fingerprint(dict(request, timeoutSeconds=timeout), limits, records)

    def test_partial_submit_or_stale_close_order_cannot_be_rearranged(self):
        for first, second in (("submit-with-partial-input", "completed-partial-input"),
                              ("reservation-stale-close", "reservation-new-owner")):
            evidence = fixture()
            order = evidence["exchangeOrder"]
            a, b = order.index(first), order.index(second)
            order[a], order[b] = order[b], order[a]
            with self.assertRaises(ValueError):
                self.check(evidence)

    def test_retained_result_or_checkpoint_digest(self):
        evidence = fixture()
        raw = json.dumps(evidence).encode()
        with self.assertRaises(ValueError):
            validate(copy.deepcopy(evidence), dict(nativeProtocolEvidenceFile="native-protocol-evidence.json",
                nativeProtocolEvidenceSHA256="0" * 64), raw, b"ab", b"restored")
        with self.assertRaises(ValueError):
            self.check(evidence, b"changed")

    def test_stale_close_cannot_release_replacement_reservation(self):
        evidence = fixture()
        self.change(evidence, "responses", "reservation-stale-reopen", ok=True)
        with self.assertRaises(ValueError):
            self.check(evidence)

    def test_stale_reopen_uses_exact_valid_replacement_request(self):
        for change in ("broken-bookmark", "different-bytes", "unrelated-refusal"):
            evidence = fixture()
            if change == "broken-bookmark":
                evidence["requests"]["reservation-stale-reopen"] = evidence["requests"]["reservation-failed-bookmark"]
            elif change == "different-bytes":
                raw = base64.b64decode(evidence["requests"]["reservation-stale-reopen"])
                evidence["requests"]["reservation-stale-reopen"] = base64.b64encode(raw + b" ").decode()
            else:
                self.change(evidence, "responses", "reservation-stale-reopen", message="XPC connection is unavailable")
            with self.assertRaises(ValueError):
                self.check(evidence)

    def test_stale_reopen_precedes_replacement_reopen(self):
        evidence = fixture()
        order = evidence["exchangeOrder"]
        first, second = order.index("reservation-stale-reopen"), order.index("reservation-survived-stale-close")
        order[first], order[second] = order[second], order[first]
        with self.assertRaises(ValueError):
            self.check(evidence)


if __name__ == "__main__":
    unittest.main()
