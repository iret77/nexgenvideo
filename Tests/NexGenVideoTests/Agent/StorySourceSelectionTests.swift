import Foundation
import NexGenEngine
import Testing
@testable import NexGenVideo

struct StorySourceSelectionTests {
    @Test func foreignProjectSelectionCannotCreateCanonicalSource() throws {
        let (home, root, access) = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        try selectGreenfield(projectID: "Different project", dataRoot: root)
        #expect(throws: (any Error).self) { try PipelineStorySourceWriter.bindCurrentSelection(access: access) }
    }

    @Test func reselectingNativeChoiceInvalidatesPriorCanonicalBinding() throws {
        let (home, root, access) = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        try selectGreenfield(projectID: "Actual project", dataRoot: root)
        let first = try PipelineStorySourceWriter.bindCurrentSelection(access: access)
        try PipelineStorySourceWriter.requireConfirmed(first, workflowID: "core.production.v2", dataRoot: root)
        try selectGreenfield(projectID: "Actual project", dataRoot: root)
        #expect(throws: (any Error).self) {
            try PipelineStorySourceWriter.requireConfirmed(first, workflowID: "core.production.v2", dataRoot: root)
        }
        let current = try PipelineStorySourceWriter.bindCurrentSelection(access: access)
        try PipelineStorySourceWriter.requireConfirmed(current, workflowID: "core.production.v2", dataRoot: root)
        #expect(first.declineReceipt != current.declineReceipt)
    }

    @Test func mutuallyMatchingForeignReceiptAndHeaderCannotAuthorizeActualProject() throws {
        let (home, root, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let receipt = try selectGreenfield(projectID: "Different project", dataRoot: root)
        let value = StorySourceV1(header: .init(projectID: "Different project", revision: 1,
            origin: .userRevision, inputs: [receipt]), declineReceipt: receipt)
        #expect(throws: (any Error).self) {
            try PipelineStorySourceWriter.requireConfirmed(value, workflowID: "core.production.v2", dataRoot: root)
        }
    }

    private func fixture() throws -> (URL, URL, PipelinePlanningWriteAccess) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = try ProjectScaffold.initProject(home: home, name: "Actual project", mode: .generic)
        try ProjectPluginSettings.setProductionContract(.current, projectURL: home)
        let store = YAMLArtifactStore(dataRoot: root)
        var gates = try store.load(Gates.self, at: PipelineLayout.gatesFile)
        GatesOperations.approve(&gates, phase: "project_init")
        try store.save(gates, to: PipelineLayout.gatesFile)
        let brief = try Brief(project: "Actual project", generated: "fixture", mission: .singleRelease,
            targetPlatform: "Native film", aspectRatio: .landscape16x9, projectMode: "generic", conceptType: .narrative,
            visualMedium: .liveActionRealistic, figures: .artistOnly, lyricsIntegration: .literal)
        try store.save(brief, to: PipelineLayout.briefFile)
        return (home, root, try PipelinePlanningWriteAccess(dataRoot: root,
            declaration: .init(packName: nil, binding: nil, productionContract: .current), phase: "brief"))
    }

    @discardableResult
    private func selectGreenfield(projectID: String, dataRoot: URL) throws -> CanonicalArtifactReferenceV1 {
        let id = UUID().uuidString.lowercased()
        let bytes = try JSONSerialization.data(withJSONObject: ["schema": "story-source-selection/v1", "id": id,
            "projectID": projectID, "workflowID": "core.production.v2", "selectedAt": "fixture"], options: [.sortedKeys])
        let path = "brief/source-selections/\(id).v1.json"
        _ = try ProjectLocalFile.ensureDirectory("brief/source-selections", dataRoot: dataRoot)
        try bytes.write(to: dataRoot.appendingPathComponent(path))
        try bytes.write(to: dataRoot.appendingPathComponent("brief/story-source-selection.v1.json"))
        return .init(id: "story-source.selection", role: "host.story-source-selection", path: path, sha256: FileDigest.sha256(of: bytes))
    }
}
