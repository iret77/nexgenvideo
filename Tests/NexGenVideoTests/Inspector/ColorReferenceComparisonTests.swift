import Foundation
import Testing
@testable import NexGenVideo

@MainActor @Suite("Native reference color proposal contract")
struct ColorReferenceComparisonTests {
    @Test func schemaRequiresExactScopeAndOnlySupportedBoundedControls() throws {
        let input: [String: Any] = ["comparisonID": UUID().uuidString, "clipID": "clip", "referenceID": "reference",
            "rationale": "Creative exposure proposal, not a measurement.", "grade": ["exposure": 0.5, "temperature": 7200]]
        try validateToolInput(in: input, against: ColorReferenceProposal.schema, path: "propose_color_match")
        let decoded = try JSONDecoder().decode(ColorReferenceProposal.self, from: JSONSerialization.data(withJSONObject: input))
        try decoded.validate()
        #expect(decoded.applyArguments["clipIds"] as? [String] == ["clip"])
        #expect(decoded.applyArguments["exposure"] as? Double == 0.5)
        var changed = input
        let invalidGrades: [[String: Any]] = [["exposure": 5], ["clipIds": ["foreign"]], ["lut": ["path": "outside.cube"]], ["exposure": true]]
        for invalid in invalidGrades {
            changed["grade"] = invalid
            #expect(throws: (any Error).self) { try validateToolInput(in: changed, against: ColorReferenceProposal.schema, path: "propose_color_match") }
        }
        changed = input; changed["untrusted"] = true
        #expect(throws: (any Error).self) { try validateToolInput(in: changed, against: ColorReferenceProposal.schema, path: "propose_color_match") }
        let invalid = ColorReferenceProposal(comparisonID: UUID(), clipID: "clip", referenceID: "reference", rationale: "", grade: ["exposure": .infinity])
        #expect(throws: (any Error).self) { try invalid.validate() }
    }

    @Test func agentCannotMintNativeComparisonOrMutateThroughUnscopedProposal() async throws {
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [Fixtures.clip(id: "clip", start: 0, duration: 30)])]))
        let before = harness.editor.timeline
        let input: [String: Any] = ["comparisonID": UUID().uuidString, "clipID": "clip", "referenceID": "reference",
            "rationale": "Unscoped proposal", "grade": ["exposure": 0.5]]
        let result = await harness.runRaw("propose_color_match", args: input)
        #expect(result.isError)
        #expect(harness.editor.timeline == before)
    }

    @Test func sourceEvidenceRejectsChangedAndMissingActualBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("reference.png")
        let original = Data("actual-source-byte-fixture".utf8)
        try original.write(to: file)
        let source = ColorReferenceComparisonStore.Source(url: file, hash: FileDigest.sha256(of: original))
        try source.requireCurrent()
        try Data("replacement-source".utf8).write(to: file)
        #expect(throws: (any Error).self) { try source.requireCurrent() }
        try original.write(to: file); try source.requireCurrent()
        try FileManager.default.removeItem(at: file)
        #expect(throws: (any Error).self) { try source.requireCurrent() }
    }
}
