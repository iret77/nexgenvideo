import base64
import unittest

from replay_key import decode_base64_key


class ReplayKeyTests(unittest.TestCase):
    def test_accepts_one_key_with_file_whitespace(self):
        encoded = base64.b64encode(bytes(range(32))).decode()
        self.assertEqual(decode_base64_key(f"  {encoded}\n"), bytes(range(32)))

    def test_rejects_invalid_base64_and_wrong_key_length(self):
        with self.assertRaisesRegex(ValueError, "Invalid replay key"):
            decode_base64_key("not base64")
        with self.assertRaisesRegex(ValueError, "Invalid replay key"):
            decode_base64_key(base64.b64encode(bytes(range(31))).decode())


if __name__ == "__main__":
    unittest.main()
