import unittest

from ci_changes import classify


class CIChangesTests(unittest.TestCase):
    def test_documentation_does_not_allocate_a_mac(self):
        self.assertEqual(classify(["README.md", "docs/CONCEPT.md"]), dict(
            build_required=False, bundle_required=False, ui_required=False,
        ))

    def test_ui_specification_renders_without_compiling(self):
        self.assertEqual(classify(["docs/ui/agent-chat.html"]), dict(
            build_required=False, bundle_required=False, ui_required=True,
        ))

    def test_runtime_pack_prose_is_not_documentation_only(self):
        plan = classify(["Sources/MusicvideoPlugin/Resources/MusicvideoPack/phases/story.md"])
        self.assertTrue(plan["build_required"])
        self.assertTrue(plan["bundle_required"])

    def test_leaf_app_change_only_builds_and_tests(self):
        self.assertEqual(classify(["Sources/NexGenVideo/Timeline/ClipView.swift"]), dict(
            build_required=True, bundle_required=False, ui_required=False,
        ))

    def test_build_graph_and_diagnostics_always_exercise_the_bundle(self):
        for path in ("Package.swift", "Engine/Sources/A.swift", "Sources/HangDiagnostics/A.swift",
                     "Sources/HangStackSampler/A.c", "Sources/NexGenVideoDiagnostics/main.swift",
                     "scripts/bundle.sh", ".github/workflows/ci.yml", ".github/workflows/bundle.yml"):
            with self.subTest(path=path):
                self.assertTrue(classify([path])["bundle_required"])

    def test_unknown_and_empty_diffs_fail_safe(self):
        self.assertTrue(classify(["unexpected.config"])["build_required"])
        self.assertTrue(all(classify([]).values()))


if __name__ == "__main__":
    unittest.main()
