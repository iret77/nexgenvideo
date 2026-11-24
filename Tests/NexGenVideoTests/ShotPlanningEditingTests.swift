import Testing
@testable import NexGenVideo

@Suite("Shot Planning editing state")
struct ShotPlanningEditingTests {
    private func state(hasPlan: Bool = true, reading: Bool = false, failed: Bool = false, projectOpen: Bool = true,
                       phasePending: Bool = true, jobRunning: Bool = false, decisionOpen: Bool = false,
                       followUpPending: Bool = false) -> ShotPlanningEditing {
        .init(hasPlan: hasPlan, reading: reading, failed: failed, projectOpen: projectOpen, phasePending: phasePending,
              jobRunning: jobRunning, decisionOpen: decisionOpen, followUpPending: followUpPending)
    }

    @Test func rereadingTheDisplayedPlanKeepsItEditableWithoutProgressOrNotice() {
        #expect(state(reading: true) == .editable)
        #expect(state(reading: true).notice == nil)
        #expect(state(reading: false) == .editable)
    }

    @Test func onlyTheFirstReadShowsProgress() {
        #expect(state(hasPlan: false, reading: true) == .loading)
        #expect(state(hasPlan: false, reading: false) == .unavailable)
        #expect(state(hasPlan: false, reading: true).notice == nil)
    }

    @Test func theJobNoticeAppearsOnlyWhileAJobRuns() {
        #expect(state(jobRunning: true) == .jobRunning)
        #expect(state(jobRunning: true).notice == "Wait for the current job before editing.")
        #expect(state(phasePending: false, jobRunning: true).notice == "Reopen Shot Planning to change approved decisions.")
    }

    @Test func decisionCardsPointToProductionAndOnlyFollowUpsToAIActivity() {
        #expect(state(reading: true, decisionOpen: true) == .decisionOpen)
        #expect(state(decisionOpen: true).notice == "Respond in Production, below the current phase, before editing.")
        #expect(state(decisionOpen: true, followUpPending: true) == .decisionOpen)
        #expect(state(followUpPending: true) == .followUpPending)
        #expect(state(followUpPending: true).notice?.contains("AI activity") == true)
        #expect(state(decisionOpen: true).notice?.contains("AI activity") == false)
    }

    @Test func aFailureLocksWithoutAJobNotice() {
        #expect(state(failed: true, jobRunning: true) == .failed)
        #expect(state(failed: true).notice == nil)
        #expect(state(projectOpen: false) == .unavailable)
    }
}
