import copy
import json
import plistlib
import subprocess
import sys
import tempfile
import unittest
import uuid
from pathlib import Path
from unittest import mock

import bpy_boundary_acceptance as driver
from bpy_boundary_acceptance import validate


FIXTURE = Path("/fixture/NexGenVideo.app")


class BoundaryStartupTests(unittest.TestCase):
    def test_boundary_fixture_declines_recording_without_mutating_original_app(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / "original.app"
            source = "a" * 40
            resources = app / "Contents/Resources"
            resources.mkdir(parents=True)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"NGVSourceCommit": source}))
            binary = app / "Contents/MacOS/NexGenVideo"
            binary.parent.mkdir()
            binary.write_text("#!" + sys.executable + '''
import json, os, sys
from pathlib import Path
output = Path(os.environ["NGV_SELFTEST_BPY_BOUNDARY"])
(output.parent / "launch-arguments.json").write_text(json.dumps(sys.argv[1:]))
for slot in range(2):
    Path(str(output) + ".slot" + str(slot) + ".json").write_text(json.dumps({"hostProcessIdentifier": os.getpid()}))
print("SELFTEST_BPY_BOUNDARY_OK", flush=True)
''')
            binary.chmod(0o755)
            for slot in range(2):
                service = app / f"Contents/XPCServices/NexGenVideoBpyService{slot}.xpc/Contents"
                runtime = service / "Resources/BpyRuntime"
                runtime.mkdir(parents=True)
                (runtime / "payload").write_bytes(b"paired original runtime")
                (service / "MacOS").mkdir()
                for name in ("NexGenVideoBpyService", "NexGenVideoBpySupervisor"):
                    (service / "MacOS" / name).write_bytes(b"controlled boundary executable")
            before = driver.paired(app)
            output = root / "evidence/boundary"
            with mock.patch.object(driver.platform, "system", return_value="Darwin"), \
                    mock.patch.object(driver, "runtime_identity", return_value={"osVersion": "27.0", "osBuild": "fixture", "architecture": "arm64"}), \
                    mock.patch.object(driver.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)), \
                    mock.patch.object(driver.subprocess, "check_output", return_value=""), \
                    mock.patch.object(driver, "validate") as validate:
                driver.run(app, output, source)
            self.assertEqual(json.loads((output / "launch-arguments.json").read_text()),
                             ["-hangDiagnosticMode", "disabled"])
            validate.assert_called_once()
            receipt = json.loads((output / "result.json").read_text())
            self.assertTrue(receipt["completed"])
            self.assertTrue(receipt["processReaped"])
            self.assertTrue(receipt["originalUnchanged"])
            self.assertTrue(receipt["originalSignatureVerifiedAfter"])
            self.assertEqual(receipt["exitCode"], 0)
            self.assertEqual(driver.paired(app), before)


class BoundaryProofTests(unittest.TestCase):
    def proofs(self):
        return [dict(slot=slot, serviceName=f"de.h5ventures.nexgenvideo.bpy-service-{slot}",
                     serviceExecutable=str(FIXTURE / f"Contents/XPCServices/NexGenVideoBpyService{slot}.xpc/Contents/MacOS/NexGenVideoBpyService"),
                     schema="nexgenvideo/bpy-boundary-probe/5", nonce=str(uuid.uuid4()),
                     serviceProcessIdentifier=10 + slot * 10, supervisorProcessIdentifier=11 + slot * 10,
                     childProcessIdentifier=12 + slot * 10, hostProcessIdentifier=1000, supervisorParentProcessIdentifier=1000,
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

    def test_cross_slot_service_and_execution_identities_are_independent(self):
        for field in ("serviceProcessIdentifier", "nonce"):
            with self.subTest(field=field):
                proofs = self.proofs()
                proofs[1][field] = proofs[0][field]
                with self.assertRaisesRegex(ValueError, "boundary slots shared their service or execution"):
                    validate(proofs, FIXTURE)

    def test_process_roles_are_distinct_and_cannot_claim_the_host_identity(self):
        for name, mutation, message in (
                ("child-is-supervisor", lambda item: item.update(childProcessIdentifier=item["supervisorProcessIdentifier"]),
                 "invalid boundary process identities"),
                ("host-is-service", lambda item: item.update(hostProcessIdentifier=item["serviceProcessIdentifier"],
                    supervisorParentProcessIdentifier=item["serviceProcessIdentifier"]), "invalid native parent chain")):
            with self.subTest(case=name):
                proofs = self.proofs(); mutation(proofs[0])
                with self.assertRaisesRegex(ValueError, message): validate(proofs, FIXTURE)

    def test_every_required_outcome_and_process_identity_is_checked(self):
        for slot in range(2):
            for key in ["allowedWriteSucceeded", "cleanupSupervisorGone", "cleanupChildGone",
                        "internalLinkedWritableDeduplicated", "healthyFollowupSucceeded",
                        "serviceProcessIdentifier", "supervisorProcessIdentifier", "childProcessIdentifier",
                        "hostProcessIdentifier", "supervisorParentProcessIdentifier", "childParentProcessIdentifier",
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


class RuntimeIdentityTests(unittest.TestCase):
    def test_supported_versions_keep_the_actual_runtime_identity(self):
        from unittest.mock import patch
        from bpy_boundary_acceptance import runtime_identity
        for version in ('26.6.2', '27.0', '27.0.1'):
            with self.subTest(version=version), patch('bpy_boundary_acceptance.platform.system', return_value='Darwin'), \
                patch('bpy_boundary_acceptance.platform.machine', return_value='arm64'), \
                patch('bpy_boundary_acceptance.subprocess.check_output', side_effect=lambda args, **kwargs:
                      version if '-productVersion' in args else 'actual-build'):
                self.assertEqual(runtime_identity(), {'osVersion': version, 'osBuild': 'actual-build', 'architecture': 'arm64'})

    def test_unsupported_or_unidentified_runtime_is_rejected(self):
        from unittest.mock import patch
        from bpy_boundary_acceptance import runtime_identity
        for version, architecture, system, build in (
                ('25.7.2', 'arm64', 'Darwin', 'build'), ('', 'arm64', 'Darwin', 'build'),
                ('invalid.0', 'arm64', 'Darwin', 'build'), ('27', 'arm64', 'Darwin', 'build'),
                ('27.0', 'x86_64', 'Darwin', 'build'), ('27.0', 'arm64', 'Linux', 'build'),
                ('27.0', 'arm64', 'Darwin', '')):
            with self.subTest(version=version, architecture=architecture, system=system, build=build), \
                patch('bpy_boundary_acceptance.platform.system', return_value=system), \
                patch('bpy_boundary_acceptance.platform.machine', return_value=architecture), \
                patch('bpy_boundary_acceptance.subprocess.check_output', side_effect=lambda args, **kwargs:
                      version if '-productVersion' in args else build), self.assertRaises(ValueError):
                runtime_identity()
