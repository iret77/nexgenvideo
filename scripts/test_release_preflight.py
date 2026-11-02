import contextlib
import io
import json
import plistlib
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import release_preflight


class ReleasePreflightTests(unittest.TestCase):
    def validate_registration(self, body, prefix=""):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "plugins").mkdir()
            pack = root / "Sources/MusicvideoPlugin/MusicvideoPack.swift"
            pack.parent.mkdir(parents=True)
            manifest = {
                "id": "musicvideo", "version": "0.6.0", "minAppVersion": "1.8.0",
                "projectSchema": "musicvideo/3.0.0",
                "migratesFrom": ["musicvideo/legacy", "musicvideo/1.0.0"],
            }
            (root / "plugins/musicvideo.json").write_text(json.dumps(manifest))
            pack.write_text(
                prefix +
                'let musicvideoMinAppVersion = "1.8.0"\n'
                'public let version = "0.6.0"\n'
                'public func register(_ registry: EngineRegistry) {\n' + body + "\n}"
            )
            catalog = root / "catalog.json"
            catalog.write_text('{"schema":"plugins/v2","plugins":[]}')
            with mock.patch.object(release_preflight, "ROOT", root):
                release_preflight.validate_plugin_version("1.8.0", catalog)

    def assert_rejected_registration(self, body, expected, prefix=""):
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            with self.assertRaises(SystemExit):
                self.validate_registration(body, prefix)
        self.assertIn(expected, stderr.getvalue())

    def test_plugin_version_accepts_current_registration(self):
        info = release_preflight.ROOT / "Sources/NexGenVideo/Resources/Info.plist"
        version = plistlib.loads(info.read_bytes())["CFBundleShortVersionString"]
        with tempfile.TemporaryDirectory() as directory:
            catalog = Path(directory) / "catalog.json"
            catalog.write_text('{"schema":"plugins/v2","plugins":[]}')
            release_preflight.validate_plugin_version(version, catalog)

    def test_project_migrations_accept_literal_calls_and_loops(self):
        bodies = [
            '''
registry.registerProjectSchemaMigration(from: "musicvideo/legacy", to: "musicvideo/3.0.0") { _ in }
registry.registerProjectSchemaMigration(
    from: "musicvideo/1.0.0",
    to: "musicvideo/3.0.0"
) { _ in }
''',
            '''
for source in [
    "musicvideo/legacy", /* a nested /* comment */ is harmless */
    "musicvideo/1.0.0",
] {
    registry . registerProjectSchemaMigration (
        from : source, to : "musicvideo/3.0.0"
    ) { projectURL in
        guard projectURL.isFileURL else { throw InvalidProject() }
    }
}
registry.registerPhasePlacement("script", after: "treatment")
''',
            '''
for source in ["musicvideo/legacy", /* ] */ "musicvideo/1.0.0"] {
    registry.registerProjectSchemaMigration(from: source, to: "musicvideo/3.0.0") { _ in
        let raw = #"a " } b"#
        let multiline = """
        a " } ] )
        """
        // }
        /* } */
        throw GateBlocked("} ) ]")
    }
}
''',
            '''
registry.registerProjectSchemaMigration(from: "musicvideo/legacy", to: "musicvideo/3.0.0", migrate: { _ in })
registry.registerProjectSchemaMigration(from: "musicvideo/1.0.0", to: "musicvideo/3.0.0", migrate: { _ in })
''',
        ]
        for body in bodies:
            with self.subTest(body=body):
                self.validate_registration(body)

    def test_project_migrations_reject_incomplete_and_wrong_bindings(self):
        template = '''
for source in [%s] {
    registry.registerProjectSchemaMigration(from: %s, to: %s) { _ in }
}
'''
        bodies = [
            (template % ('"musicvideo/legacy"', "source", '"musicvideo/3.0.0"'), "must register every migration declared"),
            (template % ('"musicvideo/legacy","musicvideo/1.0.0"', "source", '"musicvideo/2.0.0"'), "must register every migration declared"),
            (template % ('"musicvideo/legacy","musicvideo/1.0.0"', "other", '"musicvideo/3.0.0"'), "migration registration is not understood"),
            (template % ('"musicvideo/legacy","musicvideo/1.0.0"', "source", "source"), "must register every migration declared"),
            ('for source in schemas { registry.registerProjectSchemaMigration(from: source, to: "musicvideo/3.0.0") { _ in } }', "must register every migration declared"),
            ('for source in ["musicvideo/legacy","musicvideo/1.0.0"] { let source = "wrong"; registry.registerProjectSchemaMigration(from: source, to: "musicvideo/3.0.0") { _ in } }', "migration registration is not understood"),
        ]
        for expression in ('"musicvideo/3.0.0" + "-rc"', '"musicvideo/3.0.0".lowercased()'):
            bodies.extend([
                (template % ('"musicvideo/legacy","musicvideo/1.0.0"', "source", expression), "migration registration is not understood"),
                ('registry.registerProjectSchemaMigration(from: "musicvideo/legacy", to: ' + expression + ') { _ in }', "migration registration is not understood"),
            ])
        for body, expected in bodies:
            with self.subTest(body=body):
                self.assert_rejected_registration(body, expected)

    def test_project_migrations_ignore_non_registration_text(self):
        loop = '''
for source in ["musicvideo/legacy","musicvideo/1.0.0"] {
    registry.registerProjectSchemaMigration(from: source, to: "musicvideo/3.0.0") { _ in }
}
'''
        bodies = [
            "// " + loop.replace("\n", "\n// "),
            "/* " + loop + " */",
            "/* outer /* nested */ " + loop + " */",
            'let example = """' + loop + '"""',
            'let example = #"""' + loop + '"""#',
            "func helper() { " + loop + " }",
            "if false { " + loop + " }",
            "return; " + loop,
        ]
        for body in bodies:
            with self.subTest(body=body):
                self.assert_rejected_registration(body, "must register every migration declared")
        for body in (
            loop.replace("registry.registerProjectSchemaMigration", "another.registerProjectSchemaMigration"),
            loop.replace(" { _ in }\n}", " { _ in }\nreturn\n}"),
        ):
            with self.subTest(body=body):
                self.assert_rejected_registration(body, "migration registration is not understood")
        decoy = "struct Decoy { public func register(_ registry: EngineRegistry) {" + loop + "} }\n"
        self.assert_rejected_registration("", "migration registration is not understood", prefix=decoy)

    def test_musicvideo_pipeline_contract_matches_release_source(self):
        release_preflight.validate_pipeline_contract()

    def test_engine_registry_and_boundary_guards_match_current_source(self):
        release_preflight.validate_engine_registry_abi()
        release_preflight.validate_engine_boundary_abi()

    def test_capability_registry_public_shapes_are_pinned(self):
        self.assertEqual(
            release_preflight.ENGINE_BOUNDARY_VALUE_LAYOUTS[
                "CapabilityFieldDefinitionV1"
            ]["members"],
            [
                "let id: String",
                "let modalities: Set<CapabilityModalityV1>",
                "let valueType: CapabilityFieldValueTypeV1",
                "let endpointMergePolicy: CapabilityEndpointMergePolicyV1",
                "let requiresDefensiveDefault: Bool",
            ],
        )
        self.assertEqual(
            release_preflight.ENGINE_BOUNDARY_ENUM_LAYOUTS[
                "CapabilityEndpointMergePolicyV1"
            ]["cases"],
            [
                "maximum",
                "minimum",
                'booleanAnd = "boolean_and"',
                'endpointOverride = "endpoint_override"',
                'setIntersection = "set_intersection"',
                'intrinsicOnly = "intrinsic_only"',
            ],
        )

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
