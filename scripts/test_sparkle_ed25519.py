import base64
import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

HAS_CRYPTOGRAPHY = importlib.util.find_spec("cryptography") is not None


@unittest.skipUnless(HAS_CRYPTOGRAPHY, "cryptography is installed only in the release DMG virtualenv")
class SparkleEd25519Tests(unittest.TestCase):
    def setUp(self):
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        import sparkle_ed25519  # noqa: E402

        from cryptography.hazmat.primitives import serialization
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

        self.module = sparkle_ed25519
        self.serialization = serialization
        self.key = Ed25519PrivateKey.generate()
        self.dir = tempfile.TemporaryDirectory()
        self.key_path = Path(self.dir.name) / "key.der"
        self.key_path.write_bytes(self.key.private_bytes(
            serialization.Encoding.DER,
            serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption(),
        ))

    def tearDown(self):
        self.dir.cleanup()
        sys.path.pop(0)

    def test_signature_verifies_with_the_public_key(self):
        payload = Path(self.dir.name) / "NexGenVideo.dmg"
        payload.write_bytes(b"dmg bytes")
        signature = base64.b64decode(self.module.sign(self.key_path, payload))
        self.key.public_key().verify(signature, b"dmg bytes")

    def test_check_rejects_a_non_ed25519_key(self):
        from cryptography.hazmat.primitives.asymmetric import ec

        other = Path(self.dir.name) / "ec.der"
        other.write_bytes(ec.generate_private_key(ec.SECP256R1()).private_bytes(
            self.serialization.Encoding.DER,
            self.serialization.PrivateFormat.PKCS8,
            self.serialization.NoEncryption(),
        ))
        with self.assertRaises(ValueError):
            self.module.main(["check", str(other)])


if __name__ == "__main__":
    unittest.main()
