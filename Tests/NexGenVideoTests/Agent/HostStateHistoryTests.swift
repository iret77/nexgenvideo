import Foundation
import Testing
@testable import NexGenVideo

@MainActor
@Suite("Host state history and revision loops")
struct HostStateHistoryTests {
    @Test("a later approval marks the earlier review request as superseded")
    func laterApprovalSupersedesReviewRequest() {
        let checked = record(.checked, phase: "bible")
        let approved = record(.approved, phase: "bible")
        let states = projectedStates(turns: [[checked], [approved]])
        #expect(states.map(\.id) == [checked.id, approved.id])
        #expect(states.map(\.disposition) == [.superseded, .current])
    }

    @Test("an allowed revision marks every reset approval as historical")
    func revisionResetsDownstreamApprovals() {
        let treatment = record(.approved, phase: "treatment")
        let storyboard = record(.approved, phase: "storyboard")
        let bible = record(.approved, phase: "bible")
        let brief = record(.approved, phase: "brief")
        let rewound = record(.rewound, phase: "treatment",
            resetPhases: ["treatment", "storyboard", "bible"], note: "Location count changed")
        let states = projectedStates(turns: [[brief], [treatment], [storyboard, bible], [rewound]])
        let byID = Dictionary(uniqueKeysWithValues: states.map { ($0.id, $0.disposition) })
        #expect(byID[brief.id] == .current)
        #expect(byID[treatment.id] == .resetByRevision)
        #expect(byID[storyboard.id] == .resetByRevision)
        #expect(byID[bible.id] == .resetByRevision)
        #expect(byID[rewound.id] == .current)
    }

    @Test("a declined revision keeps earlier approvals current")
    func declinedRevisionKeepsApprovals() {
        let approved = record(.approved, phase: "treatment")
        let declined = record(.declined, phase: "treatment", resetPhases: ["treatment", "storyboard"])
        let states = projectedStates(turns: [[approved], [declined]])
        #expect(states.map(\.disposition) == [.current, .current])
    }

    @Test("a later rejected write never hides an unrepaired partial write")
    func repairRequiredSurvivesLaterRejection() {
        let partial = record(.persistedPhaseRecordFailed, phase: "storyboard")
        let rejected = record(.writeRejected, phase: "storyboard")
        let states = projectedStates(turns: [[partial], [rejected]])
        #expect(states.map(\.disposition) == [.current, .current])
        let persisted = record(.persisted, phase: "storyboard")
        let repaired = projectedStates(turns: [[partial], [rejected], [persisted]])
        #expect(repaired.map(\.disposition) == [.superseded, .superseded, .current])
    }

    @Test("a declined approval replaces its own review request in place")
    func declinedApprovalReplacesRequest() throws {
        let checked = record(.checked, phase: "bible")
        let declined = AgentHostStateRecord(id: checked.id, state: .declined, phase: "bible",
            toolName: "approve_gate", action: .none, artifactPath: nil, byteComparison: nil,
            previousSHA256: nil, currentSHA256: nil)
        let message = AgentMessage(role: .assistant, blocks: [], hostStateRecords: [checked, declined])
        let turns = AgentTranscriptProjection.turns(
            messages: [AgentMessage(role: .user, blocks: [.text("Continue.")], hidden: true), message],
            isStreaming: false
        )
        let states = turns.flatMap(\.items).compactMap { item -> AgentHostState? in
            guard case .hostState(let state) = item else { return nil }
            return state
        }
        #expect(states.count == 1)
        #expect(states.first?.record.state == .declined)
    }

    @Test("prior approval evidence compares exact host-recorded bytes")
    func priorApprovalEvidence() {
        let first = String(repeating: "a", count: 64)
        let second = String(repeating: "b", count: 64)
        let records = [
            record(.approved, phase: "storyboard", currentSHA256: first),
            record(.rewound, phase: "treatment", resetPhases: ["treatment", "storyboard"], note: "Fewer locations"),
        ]
        let prior = GateApproval.priorApproval(phase: "storyboard", in: records)
        #expect(prior == GatePriorApproval(sha256: first, revisionReason: "Fewer locations"))
        var changed = GateApproval(phase: "storyboard",
            artifactFingerprint: .init(path: "storyboard/current.yaml", sha256: second, lineageSHA256: nil))
        changed.priorApproval = prior
        #expect(changed.priorComparison == .changed(revisionReason: "Fewer locations"))
        var identical = GateApproval(phase: "storyboard",
            artifactFingerprint: .init(path: "storyboard/current.yaml", sha256: first, lineageSHA256: nil))
        identical.priorApproval = prior
        #expect(identical.priorComparison == .identical)
        #expect(identical.scoped(to: UUID()).priorApproval == prior)
        #expect(GateApproval.priorApproval(phase: "bible", in: records) == nil)
    }

    @Test("a second revision request without new user direction is refused")
    func revisionLoopNeedsNewDirection() {
        let editor = EditorViewModel()
        let service = editor.agentService
        let session = ToolCallOrigin.inAppChat(sessionID: UUID())
        let other = ToolCallOrigin.inAppChat(sessionID: UUID())
        #expect(service.admitRevisionRequest(origin: session))
        #expect(!service.admitRevisionRequest(origin: session))
        #expect(service.admitRevisionRequest(origin: other))
        service.recordUserDirection()
        #expect(service.admitRevisionRequest(origin: session))
        #expect(service.admitRevisionRequest(origin: .direct))
        #expect(service.admitRevisionRequest(origin: .direct))
    }

    @Test("continuing after a revision pause does not authorize another revision")
    func revisionPauseContinuesWithoutRewind() {
        let editor = EditorViewModel()
        let service = editor.agentService
        service.newChat()
        let external = ToolCallOrigin.externalMCP(sessionID: UUID())
        #expect(service.admitRevisionRequest(origin: external))
        #expect(!service.admitRevisionRequest(origin: external))
        service.pausePipelineRepair(tool: "rewind", detail: "loop", origin: external, kind: .unrequestedRevision)
        #expect(service.currentPipelineRepairFailure?.kind == .unrequestedRevision)
        #expect(service.toolCallBlockReason(tool: .getProjectState, args: [:], origin: external) != nil)
        service.retryPipelineRepair()
        #expect(service.currentPipelineRepairFailure == nil)
        #expect(service.toolCallBlockReason(tool: .getProjectState, args: [:], origin: external) == nil)
        #expect(service.admitRevisionRequest(origin: external))
    }

    @Test("byte-identical and failed writes both count toward the no-progress limit")
    func noProgressIncludesUnchangedWrites() {
        #expect(PipelineRepairAttempts.noProgress(isError: true, errorText: "zone", byteComparison: .changed) == "zone")
        #expect(PipelineRepairAttempts.noProgress(isError: false, errorText: "", byteComparison: .unchanged) != nil)
        #expect(PipelineRepairAttempts.noProgress(isError: false, errorText: "", byteComparison: .changed) == nil)
        #expect(PipelineRepairAttempts.noProgress(isError: false, errorText: "", byteComparison: .created) == nil)
        #expect(PipelineRepairAttempts.scope(projectRoot: "/p", phase: "storyboard", tool: "write_storyboard")
            == PipelineRepairAttempts.scope(projectRoot: "/p", phase: "storyboard", tool: "write_phase_extension"))
        #expect(PipelineRepairAttempts.scope(projectRoot: "/p", phase: "storyboard", tool: "write_storyboard")
            != PipelineRepairAttempts.scope(projectRoot: "/p", phase: "bible", tool: "write_storyboard"))
    }

    private func record(
        _ state: AgentHostStateRecord.State,
        phase: String,
        resetPhases: [String]? = nil,
        note: String? = nil,
        currentSHA256: String? = nil
    ) -> AgentHostStateRecord {
        AgentHostStateRecord(state: state, phase: phase, toolName: "write_\(phase)", action: .none,
            artifactPath: nil, byteComparison: nil, previousSHA256: nil, currentSHA256: currentSHA256,
            resetPhases: resetPhases, note: note)
    }

    private func projectedStates(turns: [[AgentHostStateRecord]]) -> [AgentHostState] {
        let messages = turns.enumerated().flatMap { index, records in
            [
                AgentMessage(role: .user, blocks: [.text("Continue \(index).")], hidden: true),
                AgentMessage(role: .assistant, blocks: [], hostStateRecords: records),
            ]
        }
        return AgentTranscriptProjection.turns(messages: messages, isStreaming: false)
            .flatMap(\.items)
            .compactMap { item -> AgentHostState? in
                guard case .hostState(let state) = item else { return nil }
                return state
            }
    }
}
