import Foundation
import Testing
@testable import NexGenVideo
import NexGenEngine

@Suite("Pipeline execution-plan composer contract")
struct PipelineExecutionPlanComposerContractTests {
    @Test("shot references and execution demands have the same exact path set")
    func exactReferencePathSet() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = demand(id: "first", path: "refs/first.png")
        let second = demand(id: "second", path: "refs/second.png")

        try PipelineExecutionPlanComposer.validateReferenceCorrespondence(
            shotID: "shot-001",
            referenceImageRefs: ["refs/first.png"],
            referenceDemands: [first],
            dataRoot: fixture.dataRoot
        )

        #expect(throws: PipelineExecutionPlanComposerError.referenceSetMismatch(
            "shot-001"
        )) {
            try PipelineExecutionPlanComposer.validateReferenceCorrespondence(
                shotID: "shot-001",
                referenceImageRefs: ["refs/first.png", "refs/second.png"],
                referenceDemands: [first],
                dataRoot: fixture.dataRoot
            )
        }
        #expect(throws: PipelineExecutionPlanComposerError.referenceSetMismatch(
            "shot-001"
        )) {
            try PipelineExecutionPlanComposer.validateReferenceCorrespondence(
                shotID: "shot-001",
                referenceImageRefs: ["refs/first.png"],
                referenceDemands: [first, second],
                dataRoot: fixture.dataRoot
            )
        }
    }

    @Test("identity assets are unique and stable after reference merging")
    func mergedIdentityAssetIDs() throws {
        let identifiers = try PipelineExecutionPlanComposer.identityAssetIDs(
            referenceDemands: [
                demand(id: "first", path: "refs/first.png"),
                demand(id: "duplicate", path: "refs/first.png"),
                demand(id: "second", path: "refs/second.png"),
            ],
            demandAssetIDs: [
                "first": "asset-b",
                "duplicate": "asset-b",
                "second": "asset-a",
            ]
        )

        #expect(identifiers == ["asset-a", "asset-b"])
        #expect(throws: PipelineExecutionPlanComposerError.invalidReference("first")) {
            _ = try PipelineExecutionPlanComposer.identityAssetIDs(
                referenceDemands: [demand(id: "first", path: "refs/first.png")],
                demandAssetIDs: [:]
            )
        }
    }

    @Test("blocking aliases emit the Shot character reference spelling")
    func canonicalBlockingOutput() throws {
        let shotBlocking = try CharacterBlocking(
            characterRef: "Claude_Mouse",
            position: "left third",
            pose: "standing",
            gaze: "toward camera",
            relationToSet: "beside the doorway"
        )
        let blocking = try PipelineExecutionPlanComposer.executionBlocking(
            shotID: "shot-001",
            shotBlocking: [shotBlocking],
            inputBlocking: [
                PipelineExecutionBlockingInput(
                    entityID: " claude-mouse ",
                    anchorDemandID: nil,
                    performance: "Hold the mark."
                ),
            ],
            demandAssetIDs: [:]
        )

        #expect(blocking.map(\.entityID) == ["Claude_Mouse"])
    }

    @Test("core semantic aliases never become generic reference jobs")
    func canonicalCoreDemandAlias() {
        let input = PipelineReferenceDemandInput(
            id: "audio-timing",
            assetPath: "media/shot-audio.m4a",
            modality: .audio,
            semanticJobID: "core.audio_timing",
            isRequired: true,
            priority: 0,
            preservationScopeIDs: [],
            exclusionDemandIDs: [],
            inputSlotID: "core.input.audio_timing",
            modeID: "audio-to-video",
            identityLock: false,
            entityID: nil,
            canonIDs: [],
            stateID: nil,
            viewID: nil
        )

        #expect(PipelineExecutionPlanComposer.genericReferenceDemandIDs([input]).isEmpty)
    }

    private func demand(id: String, path: String) -> PipelineReferenceDemandInput {
        PipelineReferenceDemandInput(
            id: id,
            assetPath: path,
            modality: .image,
            semanticJobID: "look.identity",
            isRequired: true,
            priority: 1,
            preservationScopeIDs: [],
            exclusionDemandIDs: [],
            inputSlotID: "reference.image",
            modeID: "reference-to-video",
            identityLock: true,
            entityID: "Claude Mouse",
            canonIDs: [],
            stateID: nil,
            viewID: nil
        )
    }

    private struct Fixture {
        let projectRoot: URL
        let dataRoot: URL

        init() throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            projectRoot = root
            dataRoot = root.appendingPathComponent("pipeline", isDirectory: true)
            let references = dataRoot.appendingPathComponent("refs", isDirectory: true)
            try FileManager.default.createDirectory(
                at: references,
                withIntermediateDirectories: true
            )
            try Data("first".utf8).write(
                to: references.appendingPathComponent("first.png")
            )
            try Data("second".utf8).write(
                to: references.appendingPathComponent("second.png")
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: projectRoot)
        }
    }
}
