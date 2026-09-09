import Foundation
import Testing
@testable import NexGenEngine

@Suite("Canon-grounded story causality")
struct StoryCausalityTests {
    private let body = "A key falls. The mouse picks up the key. The mouse opens the door."

    private func draft(edges: [StoryCausalityDraftV1.Edge]? = nil,
                       decisions: [StoryCausalityDraftV1.Decision] = [],
                       mode: StoryCausalityDraftV1.Mode = .narrative,
                       beats: [StoryCausalityDraftV1.Beat]? = nil,
                       affected: [String] = ["fall", "pickup", "open"]) -> StoryCausalityDraftV1 {
        .init(mode: mode, applicationReason: "The visible key motivates access to the room.", beats: beats ?? [
            .init(id: "fall", sceneID: "door", excerpt: "A key falls.", elementIDs: ["key"], causalException: nil),
            .init(id: "pickup", sceneID: "door", excerpt: "The mouse picks up the key.", elementIDs: ["key"], causalException: nil),
            .init(id: "open", sceneID: "door", excerpt: "The mouse opens the door.", elementIDs: ["key"], causalException: nil),
        ], chronology: ["fall", "pickup", "open"], edges: edges ?? [
            .init(cause: "fall", consequence: "pickup", relation: .therefore, reason: "The visible fallen key draws attention."),
            .init(cause: "pickup", consequence: "open", relation: .therefore, reason: "Possession permits unlocking."),
        ], elements: [.init(id: "key", label: "Door key", introductionBeatID: "fall", payoffBeatIDs: ["open"], noPayoffReason: nil)],
        stateChanges: [.init(elementID: "key", beatID: "pickup", causeBeatID: "fall", before: "on the floor", after: "in hand", excerpt: "picks up the key")],
        unresolvedDecisions: decisions, changeReview: .init(reviewer: "director", upstreamCause: "Establish the means of entry.",
            downstreamConsequence: "The room becomes accessible.", affectedBeatIDs: affected,
            checks: StoryCausalityDraftV1.ReviewQuestion.allCases.map {
                .init(question: $0, verdict: .satisfied, explanation: "The visible key introduction, pickup and door payoff form the reviewed chain.")
            }))
    }

    @Test("cycles and uncited canon cannot pass as structural truth")
    func structuralFailures() throws {
        try draft().validate(body: body, approval: true)
        #expect(throws: (any Error).self) { try draft().validate(body: "A different story.") }
        #expect(throws: (any Error).self) {
            try draft(edges: [.init(cause: "open", consequence: "fall", relation: .but, reason: "Backwards cause")]).validate(body: body)
        }
        #expect(throws: (any Error).self) { try draft(edges: []).validate(body: body) }
        try draft(edges: [], mode: .abstract).validate(body: body)
    }

    @Test("unresolved choices remain draftable but cannot be approved")
    func unresolvedChoices() throws {
        let value = draft(decisions: [.init(id: "entry", affectedBeatIDs: ["open"], question: "Who enters the room?", alternatives: ["mouse", "cat"])])
        try value.validate(body: body)
        #expect(throws: (any Error).self) { try value.validate(body: body, approval: true) }
    }

    @Test("upstream revisions include downstream dependencies")
    func affectedClosure() throws {
        let original = draft()
        var beats = original.beats
        beats[0] = .init(id: "fall", sceneID: "door", excerpt: "A brass key falls.", elementIDs: ["key"], causalException: nil)
        let revised = draft(beats: beats)
        #expect(revised.affectedBeats(comparedWith: original) == Set(["fall", "pickup", "open"]))
        #expect(throws: (any Error).self) {
            try draft(beats: beats, affected: ["fall"]).validate(body: body.replacingOccurrences(of: "A key", with: "A brass key"), previous: original)
        }
    }

    @Test("exact source binding, immutable history and deletion detection")
    func storeCurrency() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = try ProjectScaffold.initProject(home: home, name: "causality")
        defer { try? FileManager.default.removeItem(at: home) }
        let brief = try Brief(project: "causality", generated: "2026-09-08T12:00:00Z", mission: .demo,
            targetPlatform: "YouTube", aspectRatio: .landscape16x9, projectMode: "section", budgetEur: 50,
            conceptType: .narrative, visualMedium: .animation2d,
            visualMediumNotes: "Restrained hand-drawn animation.",
            figures: .none, lyricsIntegration: .metaphorical)
        try YAMLArtifactStore(dataRoot: root).save(brief, to: PipelineLayout.briefFile)
        let treatment = Treatment(meta: try .init(project: "causality", version: 1, generated: "2026-09-08T12:00:00Z",
            origin: .agentProposal, generator: "test", summaryOneline: "The key permits entry."), bodyMarkdown: body)
        try StoryCausalityStoreV1.write(treatment: treatment, draft: draft(), dataRoot: root)
        #expect(try StoryCausalityStoreV1.requireCurrent(dataRoot: root)?.treatmentVersion == 1)
        #expect(throws: (any Error).self) { try StoryCausalityStoreV1.write(treatment: treatment, draft: draft(), dataRoot: root) }
        let current = root.appendingPathComponent(PipelineLayout.treatmentCurrentFile)
        let saved = try Data(contentsOf: current)
        try (saved + Data("\nchanged".utf8)).write(to: current)
        #expect(throws: (any Error).self) { try StoryCausalityStoreV1.requireCurrent(dataRoot: root) }
        try saved.write(to: current)
        try FileManager.default.removeItem(at: root.appendingPathComponent(StoryCausalityPlanV1.relativePath))
        #expect(throws: (any Error).self) { try StoryCausalityStoreV1.requireCurrent(dataRoot: root) }
        #expect(try StoryCausalityStoreV1.history(dataRoot: root, through: 1)?.draft == draft())
    }
}
