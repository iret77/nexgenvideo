import unittest
from verify_bpy_signing import require_identity, require_entitlements, SANDBOX, INHERIT


class BpySigningTests(unittest.TestCase):
    def test_only_host_team_developer_id_with_hardened_runtime_is_accepted(self):
        valid = "Authority=Developer ID Application: Example (TEAM123)\nTeamIdentifier=TEAM123\nCodeDirectory flags=0x10000(runtime)\n"
        require_identity(valid, "TEAM123")
        for invalid in (valid.replace("TEAM123", "FOREIGN"),
                        valid.replace("Authority=Developer ID Application: Example (TEAM123)", "Signature=adhoc"),
                        valid.replace("0x10000(runtime)", "0x0(none)")):
            with self.assertRaises(ValueError):
                require_identity(invalid, "TEAM123")

    def test_sandbox_inheritance_cannot_be_absent_or_expand_authority(self):
        expected = {SANDBOX: True, INHERIT: True}
        require_entitlements(expected, expected)
        for invalid in ({}, {SANDBOX: True}, {SANDBOX: True, INHERIT: False},
                        dict(expected, **{"com.apple.security.network.client": True}),
                        dict(expected, **{"com.apple.security.files.user-selected.read-write": True})):
            with self.assertRaises(ValueError):
                require_entitlements(invalid, expected)
