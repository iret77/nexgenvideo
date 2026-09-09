import Foundation
import Testing
@testable import NexGenEngine

@Suite("Bible identity variants")
struct BibleIdentityVariantsTests {
    private func fixture() throws -> (URL, Bible) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "bible-variants-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("bible/mouse"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("bible/mouse-red"),
            withIntermediateDirectories: true
        )
        try Data("base".utf8).write(
            to: root.appendingPathComponent("bible/mouse/front.png")
        )
        try Data("variant".utf8).write(
            to: root.appendingPathComponent("bible/mouse-red/front.png")
        )
        try YAMLArtifactStore(dataRoot: root).save(
            ProjectMeta(project: "demo", mode: .section),
            to: PipelineLayout.projectFile
        )
        let bible = try Bible(
            project: "demo",
            generated: "2026-09-09T00:00:00Z",
            generator: "test",
            look: LookGuide(style: "ink animation"),
            characters: [
                try Character(
                    id: "mouse",
                    name: "Mouse",
                    visualPrompt: "A grey mouse in a purple waistcoat.",
                    attributes: [
                        "species": "grey mouse",
                        "wardrobe": "purple waistcoat",
                    ],
                    sheets: ["front": "bible/mouse/front.png"]
                ),
                try Character(
                    id: "mouse_red",
                    name: "Mouse — red outfit",
                    visualPrompt: "The same grey mouse in a red waistcoat.",
                    attributes: [
                        "species": "grey mouse",
                        "wardrobe": "red waistcoat",
                    ],
                    sheets: ["front": "bible/mouse-red/front.png"]
                ),
            ]
        )
        return (root, bible)
    }

    @Test("derived entity preserves unchanged attributes and binds base Canon")
    func validInheritance() throws {
        let (root, bible) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifact = BibleIdentityVariantsV1(
            project: "demo",
            revision: 1,
            variants: [
                BibleIdentityVariantV1(
                    baseEntityID: "mouse",
                    variantEntityID: "mouse_red",
                    changedAttributes: ["wardrobe": "red waistcoat"],
                    inheritedIdentityPaths: ["bible/mouse/front.png"]
                ),
            ]
        )

        try BibleIdentityVariantStoreV1.save(
            artifact,
            bible: bible,
            dataRoot: root
        )
        #expect(try BibleIdentityVariantStoreV1.loadIfPresent(
            dataRoot: root
        ) == artifact)
    }

    @Test("an undeclared identity change is rejected")
    func rejectsIdentityDrift() throws {
        let (root, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let drifted = try Bible(
            project: "demo",
            generated: "2026-09-09T00:00:00Z",
            generator: "test",
            look: LookGuide(style: "ink animation"),
            characters: [
                try Character(
                    id: "mouse",
                    name: "Mouse",
                    visualPrompt: "A grey mouse in a purple waistcoat.",
                    attributes: [
                        "species": "grey mouse",
                        "wardrobe": "purple waistcoat",
                    ],
                    sheets: ["front": "bible/mouse/front.png"]
                ),
                try Character(
                    id: "mouse_red",
                    name: "Mouse — red outfit",
                    visualPrompt: "A black cat in a red waistcoat.",
                    attributes: [
                        "species": "black cat",
                        "wardrobe": "red waistcoat",
                    ],
                    sheets: ["front": "bible/mouse-red/front.png"]
                ),
            ]
        )
        let artifact = BibleIdentityVariantsV1(
            project: "demo",
            revision: 1,
            variants: [
                BibleIdentityVariantV1(
                    baseEntityID: "mouse",
                    variantEntityID: "mouse_red",
                    changedAttributes: ["wardrobe": "red waistcoat"],
                    inheritedIdentityPaths: ["bible/mouse/front.png"]
                ),
            ]
        )

        #expect(throws: BibleIdentityVariantValidationErrorV1.self) {
            try BibleIdentityVariantStoreV1.validate(
                artifact,
                bible: drifted,
                dataRoot: root
            )
        }
    }
}
