import Testing
@testable import NexGenVideo

@Suite("Shot Planning editing state")
struct ShotPlanningEditingTests {
    private func state(hasPlan: Bool = true, reading: Bool = false, failed: Bool = false, projectOpen: Bool = true,
                       phasePending: Bool = true, jobRunning: Bool = false, requestOpen: Bool = false) -> ShotPlanningEditing {
        .init(hasPlan: hasPlan, reading: reading, failed: failed, projectOpen: projectOpen, phasePending: phasePending,
              jobRunning: jobRunning, requestOpen: requestOpen)
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
        #expect(state(reading: true, requestOpen: true) == .requestOpen)
        #expect(state(requestOpen: true).notice != state(jobRunning: true).notice)
        #expect(state(phasePending: false, jobRunning: true).notice == "Reopen Shot Planning to change approved decisions.")
    }

    @Test func aFailureLocksWithoutAJobNotice() {
        #expect(state(failed: true, jobRunning: true) == .failed)
        #expect(state(failed: true).notice == nil)
        #expect(state(projectOpen: false) == .unavailable)
    }
}
