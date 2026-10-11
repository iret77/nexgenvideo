import Foundation
import Testing
import NexGenEngine
@testable import NexGenVideo

@Suite("Production review and recovery")
struct ProductionRecoveryTests {
    @Test("Changing guessed values cannot evade the repair limit")
    func repairLimit() {
        var attempts = PipelineRepairAttempts()
        let firstFailure = attempts.record(scope: "project/session/shotlist", failure: "location")
        #expect(!firstFailure)
        let secondFailure = attempts.record(scope: "project/session/shotlist", failure: "environment")
        #expect(!secondFailure)
        let thirdFailure = attempts.record(scope: "project/session/shotlist", failure: "background")
        #expect(thirdFailure)
        let otherScope = attempts.record(scope: "other/session/shotlist", failure: "location")
        #expect(!otherScope)
        let successfulWrite = attempts.record(scope: "project/session/shotlist", failure: nil)
        #expect(!successfulWrite)
        let failureAfterSuccess = attempts.record(scope: "project/session/shotlist", failure: "location")
        #expect(!failureAfterSuccess)
    }

    @Test("Silence is measured from real events, not timer ticks")
    func activityTiming() {
        let start = Date(timeIntervalSince1970: 100)
        let waiting = AgentActivityTiming(startedAt: start, lastEventAt: nil)
        #expect(!waiting.isUnconfirmed(at: start.addingTimeInterval(59)))
        #expect(waiting.isUnconfirmed(at: start.addingTimeInterval(60)))
        let resumed = AgentActivityTiming(startedAt: start, lastEventAt: start.addingTimeInterval(90))
        #expect(resumed.elapsed(at: start.addingTimeInterval(100)) == 100)
        #expect(resumed.silence(at: start.addingTimeInterval(100)) == 10)
        #expect(!resumed.isUnconfirmed(at: start.addingTimeInterval(100)))
    }

    @Test("Reference identifiers expose the same syntax enforced by the writer")
    func identifierContract() throws {
        let pattern = try #require(PipelineExecutionIdentifierContract.schema("role")["pattern"] as? String)
        #expect("location".range(of: pattern, options: .regularExpression) == nil)
        #expect("environment".range(of: pattern, options: .regularExpression) == nil)
        #expect(CoreReferenceSemanticJobIDV1.referenceAnchor.range(of: pattern, options: .regularExpression) != nil)
        #expect("musicvideo.performance-anchor".range(of: pattern, options: .regularExpression) != nil)
        let contract = PipelineExecutionIdentifierContract.discovery
        let anchor = try #require(contract["reference_anchor"] as? [String: String])
        #expect(anchor["semantic_job_id"] == CoreReferenceSemanticJobIDV1.referenceAnchor)
        #expect(anchor["input_slot_id"] == CoreReferenceInputSlotIDV1.referenceAnchor)
    }

    @Test("Writer rejects entity kinds as semantic roles and accepts namespaced anchors")
    func referenceDemandValidation() throws {
        func demand(_ role: String) -> PipelineReferenceDemandInput {
            PipelineReferenceDemandInput(id: "street", assetPath: "assets/street.png", modality: .image,
                semanticJobID: role, isRequired: true, priority: 0, preservationScopeIDs: [],
                exclusionDemandIDs: [], inputSlotID: CoreReferenceInputSlotIDV1.referenceAnchor,
                modeID: "reference", identityLock: false, entityID: "main_street", canonIDs: [],
                stateID: nil, viewID: nil)
        }
        #expect(throws: PipelineExecutionShotInputValidationError.invalidIdentifier(
            field: "reference.semantic_job_id", value: "location")) {
            try demand("location").validate(path: "reference")
        }
        try demand(CoreReferenceSemanticJobIDV1.referenceAnchor).validate(path: "reference")
    }

    @Test("Offered approval expires on artifact or lineage changes")
    func reviewBinding() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("brief.yaml")
        let original = Data("approved creative direction".utf8)
        try original.write(to: file)
        let fingerprint = GateArtifactFingerprint(path: "brief.yaml", sha256: FileDigest.sha256(of: original), lineageSHA256: nil)
        #expect(fingerprint.matches(dataRoot: root))
        try Data("changed direction".utf8).write(to: file)
        #expect(!fingerprint.matches(dataRoot: root))
        try original.write(to: file)
        let lineage = PipelineLayout.url(PipelineLayout.lineageFile, in: root)
        try FileManager.default.createDirectory(at: lineage.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("new lineage".utf8).write(to: lineage)
        #expect(!fingerprint.matches(dataRoot: root))
    }

    @Test("Attention belongs to one pending review and never revives after acknowledgement")
    func attentionLifecycle() throws {
        let contract = try JSONDecoder().decode(ContractData.self, from: Data(#"{"phases":{"treatment":{"surface":"prose","task_class":"review"},"brief":{"surface":"prose","task_class":"review"}}}"#.utf8))
        let first = GateApproval(phase: "treatment")
        #expect(CockpitReviewAttention.titles(approval: first, acknowledged: [], contract: contract, surfaces: []) == ["Treatment"])
        let seen: Set<String> = [first.id]
        #expect(CockpitReviewAttention.titles(approval: first, acknowledged: seen, contract: contract, surfaces: []).isEmpty)
        #expect(CockpitReviewAttention.titles(approval: nil, acknowledged: seen, contract: contract, surfaces: []).isEmpty)
        let revision = GateApproval(phase: "treatment")
        #expect(CockpitReviewAttention.titles(approval: revision, acknowledged: seen, contract: contract, surfaces: []) == ["Treatment"])
        #expect(PipelineSurfaceRouting.route(for: "brief", contract: contract, availablePackSurfaces: [])?.destination == .tab(.story))
        #expect(CockpitTab.visibleTabs.contains(.storyboard))
    }

    @Test("Revising approved work is distinct from approving its contents")
    func revisionDecision() {
        let approval = GateApproval(phase: "storyboard", action: .rewind(gatesSHA256: "old", phases: ["storyboard", "bible"]))
        #expect(approval.isRewind)
        #expect(approval.decisionTitle == "Revise from Storyboard")
        #expect(approval.scoped(to: UUID()).action == approval.action)
        #expect(!approval.matchesRequest(GateApproval(phase: "storyboard")))
    }
}
