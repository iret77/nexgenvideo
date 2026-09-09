import Foundation
import Testing
@testable import NexGenEngine

@Suite("Frame semantic reference provenance")
struct FrameReferenceUsageTests {
    private struct Provider: FrameReferencePlanProviding {
        let plan: FrameReferencePlanV1

        func planFrameReferences(
            dataRoot: URL,
            shotID: String,
            maxReferenceImages: Int
        ) -> FrameReferencePlanV1? {
            guard shotID == plan.shotID,
                  maxReferenceImages == plan.maxReferenceImages else {
                return nil
            }
            return plan
        }
    }

    @Test("approval verifies output bytes and the recomputed ordered plan")
    func currentProof() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("frame-reference-usage-\(UUID().uuidString)")
        let root = home.appendingPathComponent("pipeline")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("frames/reference-usage"),
            withIntermediateDirectories: true
        )
        let reference = root.appendingPathComponent("bible/ari-front.png")
        let output = home.appendingPathComponent("media/s001-start.jpg")
        try FileManager.default.createDirectory(
            at: reference.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("reference".utf8).write(to: reference)
        try Data("output".utf8).write(to: output)
        let plan = FrameReferencePlanV1(
            shotID: "s001",
            maxReferenceImages: 1,
            bindings: [
                FrameReferenceBindingV1(
                    path: "bible/ari-front.png",
                    sha256: try FileDigest.sha256(of: reference),
                    role: "character",
                    entityID: "ari",
                    viewID: "front",
                    purpose: "identity",
                    requirementIDs: ["character:ari"],
                    isRequired: true,
                    priority: 1_000
                ),
            ]
        )
        let usage = FrameReferenceUsageV1(
            shotID: "s001",
            role: "start",
            outputPath: "media/s001-start.jpg",
            outputSHA256: try FileDigest.sha256(of: output),
            modelID: "image/model",
            generationPackageID: String(repeating: "a", count: 64),
            plan: plan
        )
        try FrameReferenceUsageStoreV1.encode(usage).write(
            to: root.appendingPathComponent(
                FrameReferenceUsageStoreV1.path(
                    shotID: "s001",
                    role: "start"
                )
            )
        )

        try FrameReferenceUsageStoreV1.requireCurrent(
            shotID: "s001",
            role: "start",
            framePath: "media/s001-start.jpg",
            modelID: "image/model",
            provider: Provider(plan: plan),
            dataRoot: root
        )

        try Data("changed".utf8).write(to: reference)
        #expect(throws: (any Error).self) {
            try FrameReferenceUsageStoreV1.requireCurrent(
                shotID: "s001",
                role: "start",
                framePath: "media/s001-start.jpg",
                modelID: "image/model",
                provider: Provider(plan: plan),
                dataRoot: root
            )
        }
    }
}
