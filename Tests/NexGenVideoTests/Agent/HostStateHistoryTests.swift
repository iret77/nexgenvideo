import Foundation
import Testing
import NexGenEngine
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

    @Test("line changes against the prior approval use host-verified texts only")
    func priorLineChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("prior-diff-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("storyboard"), withIntermediateDirectories: true)
        let old = "scene: 1\nlocation: street\nprop: lamp\n"
        let new = "scene: 1\nlocation: rooftop\nprop: lamp\n"
        try Data(new.utf8).write(to: root.appendingPathComponent("storyboard/current.yaml"))
        let newSHA = FileDigest.sha256(of: Data(new.utf8))
        let fingerprint = GateArtifactFingerprint(path: "storyboard/current.yaml", sha256: newSHA, lineageSHA256: nil)
        let prior = GatePriorApproval(sha256: FileDigest.sha256(of: Data(old.utf8)), revisionReason: nil, text: old)
        let changes = try #require(GateApproval.priorChanges(prior: prior, fingerprint: fingerprint, dataRoot: root))
        #expect(changes.lines == [
            .init(kind: .removed, number: 2, text: "location: street"),
            .init(kind: .inserted, number: 2, text: "location: rooftop"),
        ])
        #expect(!changes.isTruncated)
        let tampered = GateArtifactFingerprint(path: "storyboard/current.yaml",
            sha256: String(repeating: "c", count: 64), lineageSHA256: nil)
        #expect(GateApproval.priorChanges(prior: prior, fingerprint: tampered, dataRoot: root) == nil)
        let withoutText = GatePriorApproval(sha256: prior.sha256, revisionReason: nil)
        #expect(GateApproval.priorChanges(prior: withoutText, fingerprint: fingerprint, dataRoot: root) == nil)
        #expect(ArtifactLineDiff.verifiedText(path: "../outside.yaml", sha256: newSHA, dataRoot: root) == nil)
    }

    @Test("approved records keep their verified text through persistence")
    func approvedTextRoundTrips() throws {
        let approved = AgentHostStateRecord(state: .approved, phase: "storyboard", toolName: "approve_gate",
            action: .none, artifactPath: "storyboard/current.yaml", byteComparison: nil, previousSHA256: nil,
            currentSHA256: String(repeating: "a", count: 64), approvedText: "scene: 1\n")
        let decoded = try JSONDecoder().decode(AgentHostStateRecord.self, from: JSONEncoder().encode(approved))
        #expect(decoded == approved)
        let prior = GateApproval.priorApproval(phase: "storyboard", in: [decoded])
        #expect(prior?.text == "scene: 1\n")
        let legacy = try JSONDecoder().decode(AgentHostStateRecord.self, from: Data(
            #"{"state":"approved","phase":"bible","toolName":"approve_gate","action":"none"}"#.utf8))
        #expect(legacy.approvedText == nil && legacy.resetPhases == nil && legacy.note == nil)
    }

    @Test("work time accumulates per category and closes intervals once")
    func workTimeIntervals() {
        var time = AgentWorkTime()
        time.add(120, to: .turn)
        time.add(30, to: .tool)
        time.add(600, to: .provider)
        time.add(-5, to: .waiting)
        #expect(time.agentSeconds == 90)
        #expect(time.providerSeconds == 600)
        #expect(time.waitingSeconds == 0)
        var intervals = AgentWorkTimeIntervals()
        let session = UUID()
        let start = Date(timeIntervalSince1970: 1_000)
        intervals.begin("batch-wait:a", sessionID: session, category: .waiting, at: start)
        intervals.begin("batch-wait:a", sessionID: session, category: .waiting, at: start.addingTimeInterval(50))
        intervals.rekey("batch-wait:a", to: "batch-wait:b")
        #expect(intervals.end("batch-wait:a") == nil)
        let closed = intervals.end("batch-wait:b", at: start.addingTimeInterval(45))
        #expect(closed?.sessionID == session)
        #expect(closed?.seconds == 45)
        #expect(intervals.end("batch-wait:b") == nil)
        intervals.begin("external", sessionID: nil, category: .waiting)
        #expect(intervals.end("external") == nil)
    }

    @Test("tool time and failed attempts land on the originating chat")
    func toolTimeRecordsPerChat() throws {
        let editor = EditorViewModel()
        let service = editor.agentService
        service.newChat()
        let session = try #require(service.currentSessionId)
        service.recordToolTime(4, failed: false, origin: .inAppChat(sessionID: session))
        service.recordToolTime(2, failed: true, origin: .inAppChat(sessionID: session))
        service.recordToolTime(9, failed: true, origin: .externalMCP(sessionID: UUID()))
        #expect(service.currentWorkTime?.toolSeconds == 6)
        #expect(service.currentWorkTime?.failedAttempts == 1)
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
