import unittest

import release_preflight


class ReleasePreflightTests(unittest.TestCase):
    def test_musicvideo_pipeline_contract_matches_release_source(self):
        release_preflight.validate_pipeline_contract()

    def test_engine_registry_and_boundary_guards_match_current_source(self):
        release_preflight.validate_engine_registry_abi()
        release_preflight.validate_engine_boundary_abi()

    def test_multiline_enum_associated_values_are_pinned(self):
        source = """
public enum Example {
    case first(value: String)
    case second(
        name: String,
        count: Int
    )
}
"""
        self.assertEqual(
            release_preflight.enum_case_declarations(source),
            ["first(value: String)", "second( name: String, count: Int )"],
        )

    def test_multiline_protocol_requirements_are_pinned(self):
        source = """
public protocol Example: Sendable {
    func first(value: String) -> Int
    func second(
        name: String,
        count: Int
    ) throws -> String
}
"""
        declaration = release_preflight.braced_declaration(
            source,
            "public protocol Example: Sendable {",
        )
        self.assertIsNotNone(declaration)
        self.assertEqual(
            release_preflight.protocol_method_declarations(declaration),
            ["first(value: String) -> Int", "second( name: String, count: Int ) throws -> String"],
        )


if __name__ == "__main__":
    unittest.main()
