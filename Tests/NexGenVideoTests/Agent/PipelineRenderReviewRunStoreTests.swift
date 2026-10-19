import Foundation
import NexGenEngine
import Testing
@testable import NexGenVideo

@Suite("Review page and progress publication")
struct PipelineRenderReviewRunStoreTests {
    @Test func failedProgressWriteRollsBackPageAndAllowsSamePageRetry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runID = UUID(), authID = UUID()
        let manifest = reference("manifest-fixture", path: "render-review/manifests/fixture.json")
        let authorization = reference(authID.uuidString.lowercased(), path: "render-review/authorization.json")
        let delivery = reference("page-1", path: "render-review/delivery.json")
        let submission = PipelineRenderReviewRunReceipt.Submission(manifestID: manifest.id, pageID: "page-1",
            observations: [.init(itemID: "item-1", text: "Store rollback fixture, not a model review.")], findings: [])
        let response = try AgentModelResponseEvidence(sessionID: UUID(), turnID: UUID(), messageID: "fixture-message",
            modelID: "fixture-model", toolUseID: "fixture-write", toolName: AgentReviewChildRequest.writeTool,
            inputJSON: String(decoding: PlanningWriterIO.json(submission), as: UTF8.self))
        let raw: [String: Any] = ["runID": runID.uuidString, "authID": authID.uuidString,
            "manifestID": manifest.id, "pageID": submission.pageID, "kind": "page",
            "originalChatID": UUID().uuidString, "projectID": "store-fixture",
            "projectGenerationID": UUID().uuidString, "workingCopyGeneration": UUID().uuidString,
            "generationID": UUID().uuidString, "bootstrapSHA256": String(repeating: "a", count: 64),
            "response": try JSONSerialization.jsonObject(with: PlanningWriterIO.json(response))]
        let evidence = try JSONDecoder().decode(AgentReviewChildCallEvidence.self,
            from: JSONSerialization.data(withJSONObject: raw))
        let page = PipelineRenderReviewRunReceipt.Page(schema: "render-review-child-page/v2",
            authorization: authorization, delivery: delivery, submission: submission, writeEvidence: evidence)
        let journal = PipelineRenderReviewRunStore.Journal(schema: "render-review-run/v2", runID: runID,
            manifest: manifest, backend: "anthropicAPI", modelID: nil, authorizations: [authorization],
            children: [], status: .running, message: nil)
        let runDirectory = "render-review/runs/" + runID.uuidString.lowercased()
        _ = try ProjectLocalFile.ensureDirectory(runDirectory, dataRoot: root)
        let progressURL = root.appendingPathComponent(runDirectory + "/progress.v2.json")
        let oldBytes = try PlanningWriterIO.json(journal)
        try oldBytes.write(to: progressURL)
        let blockedDirectory = root.appendingPathComponent("render-review/runs/" + manifest.id)
        let blocker = Data("existing regular file must survive failed publication".utf8)
        try blocker.write(to: blockedDirectory)
        let pagePath = runDirectory + "/" + authID.uuidString.lowercased() + "/page-1/page.v2.json"
        let pageURL = root.appendingPathComponent(pagePath)
        #expect(throws: (any Error).self) {
            try PipelineRenderReviewRunStore.recordPage(page, journal: journal, dataRoot: root)
        }
        #expect(try pageURL.deletingLastPathComponent().resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
        #expect(!FileManager.default.fileExists(atPath: pageURL.path))
        #expect(try Data(contentsOf: progressURL) == oldBytes)
        #expect(try Data(contentsOf: blockedDirectory) == blocker)
        let retainedBlocker = root.appendingPathComponent("retained-blocker")
        try FileManager.default.moveItem(at: blockedDirectory, to: retainedBlocker)
        let result = try PipelineRenderReviewRunStore.recordPage(page, journal: journal, dataRoot: root)
        #expect(result.reference.path == pagePath)
        #expect(result.journal.children == [result.reference])
        #expect(result.journal.modelID == response.modelID)
        #expect(try Data(contentsOf: pageURL) == PlanningWriterIO.json(page))
        let currentURL = root.appendingPathComponent(PipelineRenderReviewRunStore.journalPath(manifestID: manifest.id))
        let committed = try PlanningWriterIO.json(result.journal)
        #expect(try Data(contentsOf: currentURL) == committed)
        #expect(try Data(contentsOf: progressURL) == committed)
        #expect(try Data(contentsOf: retainedBlocker) == blocker)
    }

    private func reference(_ id: String, path: String) -> CanonicalArtifactReferenceV1 {
        .init(id: id, role: "fixture", path: path, sha256: String(repeating: "a", count: 64))
    }
}
