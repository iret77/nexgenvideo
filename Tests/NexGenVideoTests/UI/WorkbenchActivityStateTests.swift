import Foundation
import Testing
@testable import NexGenVideo

@Suite("Workbench activity status")
struct WorkbenchActivityStateTests {
    @Test func waitingDecisionRemainsVisibleWhileTheAgentTurnIsOpen() {
        let waiting = AgentSurfaceState.Input(hasGateApproval: true, isStreaming: true)
        #expect(WorkbenchActivityState.agent(waiting, batchPaused: false, batchError: false) == .needsAttention)
        var writing = waiting
        writing.gateApprovalIsWriting = true
        #expect(WorkbenchActivityState.agent(writing, batchPaused: false, batchError: false) == .working)
    }

    @Test func aRunningPhaseDoesNotAdvertiseAnUnavailableGateDecision() {
        let running = AgentSurfaceState.Input(hasGateApproval: true, gateApprovalBlocked: true, phaseIsRunning: true)
        #expect(WorkbenchActivityState.agent(running, batchPaused: false, batchError: false) == .working)
    }

    @Test func usableDecisionsStayVisibleAlongsideGeneration() {
        #expect(WorkbenchActivityState.agent(.init(hasDialog: true, hasSpendRun: true), batchPaused: false, batchError: false) == .needsAttention)
        #expect(WorkbenchActivityState.agent(.init(hasGateApproval: true, hasBatchRun: true), batchPaused: false, batchError: false) == .needsAttention)
        #expect(WorkbenchActivityState.agent(.init(hasGateApproval: true, gateApprovalBlocked: true, hasBatchRun: true), batchPaused: false, batchError: false) == .working)
    }

    @Test func runningGenerationExplainsDecisionsAndPausedBatchesInActivity() {
        let decision = "Respond in Production, below the current phase."
        #expect(WorkbenchActivityState.attentionDetail(.init(hasDialog: true, hasSpendRun: true),
            batchPaused: false, decisionLocation: decision) == decision)
        #expect(WorkbenchActivityState.attentionDetail(.init(hasGateApproval: true, hasBatchRun: true),
            batchPaused: false, decisionLocation: decision) == decision)
        #expect(WorkbenchActivityState.attentionDetail(.init(hasGateApproval: true, gateApprovalBlocked: true, hasBatchRun: true),
            batchPaused: false, decisionLocation: decision) == nil)
        #expect(WorkbenchActivityState.attentionDetail(.init(hasBatchRun: true), batchPaused: true,
            decisionLocation: decision) == String(localized: "Generation needs attention. Review Generation batches below."))
        #expect(WorkbenchActivityState.agent(.init(hasBatchRun: true), batchPaused: true, batchError: false) == .needsAttention)
        #expect(WorkbenchActivityState.agent(.init(hasSpendRun: true), batchPaused: true, batchError: false) == .needsAttention)
        #expect(WorkbenchActivityState.agent(.init(hasHostFollowUp: true), batchPaused: false, batchError: false) == .idle)
        #expect(WorkbenchActivityState.agent(.init(isStreaming: true), batchPaused: true, batchError: false) == .working)
    }

    @Test func pausedOrFailedWorkDoesNotDisappearAsIdle() {
        #expect(WorkbenchActivityState.agent(.init(), batchPaused: true, batchError: false) == .needsAttention)
        #expect(WorkbenchActivityState.agent(.init(), batchPaused: true, batchError: true) == .needsAttention)
        #expect(WorkbenchActivityState.agent(.init(), batchPaused: false, batchError: true) == .failed)
        #expect(WorkbenchActivityState.agent(.init(hasTurnFailure: true), batchPaused: false, batchError: false) == .failed)
        #expect(WorkbenchActivityState.agent(.init(hasSpendRun: true, hasTurnFailure: true), batchPaused: false, batchError: false) == .working)
    }

    @Test func exportFailureAndGenerationProgressRemainIndependent() {
        let generation = WorkbenchActivityState.agent(.init(hasBatchRun: true), batchPaused: false, batchError: false)
        #expect(generation == .working)
        #expect(WorkbenchActivityState.export(.failed) == .failed)
        #expect(WorkbenchActivityState.export(.interrupted) == .needsAttention)
        #expect(WorkbenchActivityState.export(.cancelling) == .working)
        #expect(WorkbenchActivityState.export(.completed) == .idle)
        #expect(WorkbenchActivityState.export(.cancelled) == .idle)
    }

    @Test @MainActor func newerBatchesDoNotHideOlderUnknownSubmissionsAndDismissalPreservesJobs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("activity-\(UUID().uuidString).ngv")
        try Fixtures.prepareProjectPackage(at: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let editor = EditorViewModel()
        editor.projectURL = root
        let (_, package) = try await GenerationPackageFixture.prepare(editor: editor)
        let projectID = try #require(editor.projectId)
        #expect(package.payload.binding.projectKey == projectID)
        func batch() throws -> GenerationBatch {
            try GenerationBatch(payload: .init(nonce: UUID(), projectKey: projectID, phase: nil,
                items: (0..<2).map { .init(id: UUID().uuidString, purpose: "View \($0)", package: package) }))
        }
        let old = try batch(), newer = try batch()
        var journal = try GenerationBatchJournal(approving: old, authorityID: "fixture", at: Date(timeIntervalSince1970: 1))
        try journal.stop(itemID: old.payload.items[0].id, state: .blocked, detail: "Submission outcome unknown")
        let newerJournal = try GenerationBatchJournal(approving: newer, authorityID: "fixture", at: Date(timeIntervalSince1970: 2))
        let coordinator = editor.generationBatchCoordinator
        coordinator.record(.init(batch: old, journal: journal))
        coordinator.record(.init(batch: newer, journal: newerJournal))
        let notice = try #require(coordinator.activityNotices(projectID: projectID).first)
        #expect(notice.batchID == old.id && notice.needsAttention)
        #expect(coordinator.activityNotices(projectID: UUID().uuidString).isEmpty)
        coordinator.acknowledgeActivity(notice, projectID: projectID)
        #expect(coordinator.activityNotices(projectID: projectID).isEmpty)
        #expect(coordinator.snapshots.first { $0.batch.id == old.id }?.journal == journal)
        try journal.stop(itemID: old.payload.items[1].id, state: .failed, detail: "Provider failed")
        coordinator.record(.init(batch: old, journal: journal))
        #expect(coordinator.activityNotices(projectID: projectID).count == 1)
        coordinator.acknowledgeActivity(notice, projectID: projectID)
        #expect(coordinator.activityNotices(projectID: projectID).count == 1)
        let restored = GenerationBatchCoordinator()
        restored.record(.init(batch: old, journal: journal))
        #expect(restored.activityNotices(projectID: projectID).count == 1)

        let pauses = GenerationBatchCoordinator()
        pauses.record(.init(batch: newer, journal: newerJournal))
        func pause() {
            pauses.recordPause(batchID: newer.id, reason: .hostBusy, detail: "Current phase",
                message: "Generation is paused while another pipeline job runs.")
        }
        pause()
        let paused = try #require(pauses.activityNotices(projectID: projectID).first)
        #expect(pauses.activityError != nil)
        pauses.acknowledgeActivity(paused, projectID: projectID)
        #expect(pauses.activityError == nil)
        #expect(WorkbenchActivityState.agent(.init(),
            batchPaused: !pauses.activityNotices(projectID: projectID).isEmpty,
            batchError: pauses.activityError != nil) == .idle)
        #expect(pauses.snapshots.first?.journal == newerJournal)
        pause()
        let repeated = try #require(pauses.activityNotices(projectID: projectID).first)
        #expect(repeated != paused)
        pauses.acknowledgeActivity(paused, projectID: projectID)
        #expect(pauses.activityNotices(projectID: projectID) == [repeated])
        #expect(WorkbenchActivityState.agent(.init(), batchPaused: true,
            batchError: pauses.activityError != nil) == .needsAttention)
        pauses.clearPause(batchID: newer.id)
        #expect(pauses.activityError == nil)
        #expect(pauses.activityNotices(projectID: projectID).isEmpty)
        pause()
        let another = try #require(pauses.activityNotices(projectID: projectID).first)
        pauses.recordPause(batchID: old.id, reason: .requestRefused, detail: "Separate request", message: "Separate refusal")
        pauses.acknowledgeActivity(another, projectID: projectID)
        #expect(pauses.activityError == "Separate refusal")
        pauses.clearPause(batchID: newer.id)
        #expect(pauses.activityError == "Separate refusal")
    }
}
