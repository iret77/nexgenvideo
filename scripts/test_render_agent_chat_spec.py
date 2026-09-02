import binascii
import struct
import tempfile
import unittest
import zlib
from pathlib import Path

import render_agent_chat_spec


def png_chunk(kind, payload):
    checksum = binascii.crc32(kind + payload) & 0xFFFFFFFF
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", checksum)


def write_rgb_png(path, width, height, pixel):
    rows = bytearray()
    for y in range(height):
        rows.append(0)
        for x in range(width):
            rows.extend(pixel(x, y))
    path.write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + png_chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        + png_chunk(b"IDAT", zlib.compress(rows))
        + png_chunk(b"IEND", b"")
    )


class AgentChatSpecRendererTests(unittest.TestCase):
    def test_blank_capture_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "blank.png"
            write_rgb_png(path, 20, 20, lambda _x, _y: (9, 10, 12))
            with self.assertRaisesRegex(RuntimeError, "appears blank"):
                render_agent_chat_spec.validate_visual_content(path)

    def test_visually_populated_capture_is_accepted(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "populated.png"
            write_rgb_png(
                path,
                20,
                20,
                lambda x, y: ((x * 17) % 256, (y * 19) % 256, ((x + y) * 13) % 256),
            )
            render_agent_chat_spec.validate_visual_content(path)

    def test_normative_document_declares_the_complete_capture_matrix(self):
        repository = Path(__file__).resolve().parent.parent
        source = repository / "docs/ui/agent-chat.html"
        self.assertEqual(
            render_agent_chat_spec.declared_states(source),
            render_agent_chat_spec.STATES,
        )

    def test_capture_dom_requires_ready_state_and_all_agent_widths(self):
        state = "empty"
        content = (
            '<body data-capture-state="empty" data-render-ready="true">'
            '<section data-state-section="empty">'
            '<article aria-label="240 point Agent panel, Empty"></article>'
            '<article aria-label="400 point Agent panel, Empty"></article>'
            '<article aria-label="640 point Agent panel, Empty"></article>'
            "</section></body>"
        )
        render_agent_chat_spec.validate_capture_dom(content, state)
        with self.assertRaisesRegex(RuntimeError, "did not reach"):
            render_agent_chat_spec.validate_capture_dom(
                content.replace('data-render-ready="true"', ""),
                state,
            )

    def test_reduce_motion_capture_requires_an_explicit_dom_marker(self):
        state = "stress"
        content = (
            '<body data-capture-state="stress" data-render-ready="true" '
            'data-reduce-motion="true">'
            '<section data-state-section="stress">'
            '<article aria-label="240 point Agent panel, Stress"></article>'
            '<article aria-label="400 point Agent panel, Stress"></article>'
            '<article aria-label="640 point Agent panel, Stress"></article>'
            "</section></body>"
        )
        render_agent_chat_spec.validate_capture_dom(content, state, True)
        with self.assertRaisesRegex(RuntimeError, "did not reach"):
            render_agent_chat_spec.validate_capture_dom(
                content.replace('data-reduce-motion="true"', ""),
                state,
                True,
            )


if __name__ == "__main__":
    unittest.main()
