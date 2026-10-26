import copy
import unittest
import uuid
from pathlib import Path

from bpy_boundary_acceptance import validate


FIXTURE = Path("/fixture/NexGenVideo.app")


class BoundaryProofTests(unittest.TestCase):
    def proofs(self):
        return [dict(slot=slot, serviceName=f"de.h5ventures.nexgenvideo.bpy-service-{slot}",
                     serviceExecutable=str(FIXTURE / f"Contents/XPCServices/NexGenVideoBpyService{slot}.xpc/Contents/MacOS/NexGenVideoBpyService"),
                     schema="nexgenvideo/bpy-boundary-probe/4", nonce=str(uuid.uuid4()),
                     serviceProcessIdentifier=10 + slot * 10, supervisorProcessIdentifier=11 + slot * 10,
                     childProcessIdentifier=12 + slot * 10, supervisorParentProcessIdentifier=10 + slot * 10,
                     childParentProcessIdentifier=11 + slot * 10, serviceStartAbsoluteTime=100 + slot,
                     supervisorStartAbsoluteTime=200 + slot, childStartAbsoluteTime=300 + slot,
                     allowedWriteSucceeded=True, outsideWriteDeniedErrno=1, forkDeniedErrno=35,
                     networkDeniedErrno=13, signalDeniedErrnos=[1, 1, 1], unlinkedBytesObserved=1048576,
                     unlinkedLimitReason="disk", cleanupSupervisorGone=True, cleanupChildGone=True,
                     internalLinkedWritableDeduplicated=True, healthyFollowupSucceeded=True,
                     fileportRetentionDenied=False, fileportRetentionDeniedErrno=0,
                     fileportBytesObserved=1048576, fileportLimitReason="disk") for slot in range(2)]

    def test_both_resource_outcomes_require_actual_denial_or_accounting(self):
        proofs = self.proofs()
        validate(proofs, FIXTURE)
        proofs[1].update(fileportRetentionDenied=True, fileportRetentionDeniedErrno=1, fileportBytesObserved=0)
        validate(proofs, FIXTURE)
        proofs[1]["fileportRetentionDenied"] = False
        with self.assertRaises(ValueError):
            validate(proofs, FIXTURE)

    def test_missing_slot_or_shared_execution_is_not_success(self):
        proofs = self.proofs()
        for value in [[], proofs[:1], [proofs[0], proofs[0]]]:
            with self.assertRaises(ValueError):
                validate(value, FIXTURE)

    def test_every_required_outcome_and_process_identity_is_checked(self):
        for slot in range(2):
            for key in ["allowedWriteSucceeded", "cleanupSupervisorGone", "cleanupChildGone",
                        "internalLinkedWritableDeduplicated", "healthyFollowupSucceeded",
                        "serviceProcessIdentifier", "supervisorProcessIdentifier", "childProcessIdentifier",
                        "supervisorParentProcessIdentifier", "childParentProcessIdentifier",
                        "serviceStartAbsoluteTime", "supervisorStartAbsoluteTime", "childStartAbsoluteTime"]:
                proofs = self.proofs()
                proofs[slot][key] = False
                with self.subTest(slot=slot, key=key), self.assertRaises(ValueError):
                    validate(proofs, FIXTURE)

    def test_denials_and_retained_bytes_cannot_be_missing_or_boolean(self):
        for key, invalid in [("outsideWriteDeniedErrno", 0), ("forkDeniedErrno", 0),
                             ("networkDeniedErrno", True), ("signalDeniedErrnos", [True, 1, 1]),
                             ("unlinkedBytesObserved", 1048575), ("unlinkedLimitReason", ""),
                             ("fileportBytesObserved", 0), ("nonce", "invalid")]:
            proofs = copy.deepcopy(self.proofs())
            proofs[0][key] = invalid
            with self.subTest(key=key), self.assertRaises(ValueError):
                validate(proofs, FIXTURE)

    def test_swapped_or_foreign_slot_identity_is_refused(self):
        for key, invalid in [("slot", 1), ("slot", False), ("serviceName", "de.h5ventures.nexgenvideo.bpy-service-1"),
                             ("serviceExecutable", "/foreign/NexGenVideoBpyService")]:
            proofs = self.proofs()
            proofs[0][key] = invalid
            with self.subTest(key=key), self.assertRaises(ValueError):
                validate(proofs, FIXTURE)
