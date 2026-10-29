import binascii
import struct
import unittest
import zlib

from production_animated_still_owner_evidence import red_bounds


def image(width, height, bounds, *, extra=b""):
    pixels = bytearray()
    for y in range(height):
        pixels.append(0)
        for x in range(width):
            pixels.extend((200, 20, 20) if bounds[0] <= x <= bounds[2] and bounds[1] <= y <= bounds[3] else (210, 210, 210))
    def chunk(kind, payload):
        return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", binascii.crc32(kind + payload) & 0xffffffff)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(pixels + extra)) + chunk(b"IEND", b""))


class ActualDecodedShapeEvidence(unittest.TestCase):
    def test_reads_shape_from_real_compressed_pixels(self):
        self.assertEqual(red_bounds(image(32, 24, [7, 5, 15, 12])), [7, 5, 15, 12])
        self.assertEqual(red_bounds(image(32, 24, [9, 5, 18, 13])), [9, 5, 18, 13])

    def test_corrupt_png_is_not_accepted_as_motion(self):
        original = bytearray(image(32, 24, [7, 5, 15, 12]))
        original[-5] ^= 1
        with self.assertRaisesRegex(ValueError, "checksum"):
            red_bounds(bytes(original))

    def test_extra_raster_bytes_and_missing_red_shape_are_rejected(self):
        with self.assertRaisesRegex(ValueError, "raster length"):
            red_bounds(image(32, 24, [7, 5, 15, 12], extra=b"undeclared row"))
        with self.assertRaisesRegex(ValueError, "No known red"):
            red_bounds(image(32, 24, [99, 99, 100, 100]))


if __name__ == "__main__":
    unittest.main()
