import Testing
@testable import NexGenVideo

@Suite("Phase control readiness")
struct PhaseControlReadinessTests {
    @Test func checkingAndBusyNeverReportAFailure() {
        #expect(PhaseControlReadiness.checking.dockMessage == "Checking phase readiness…")
        #expect(PhaseControlReadiness.busy("Edit Shot Planning").dockMessage == "Wait for Edit Shot Planning to finish.")
        #expect(PhaseControlReadiness.busy("shot_planning").dockMessage == "Wait for \(PhaseDisplay.label("shot_planning")) to finish.")
        #expect(PhaseControlReadiness.busy("shot_planning").dockMessage?.contains("shot_planning") == false)
        for state in [PhaseControlReadiness.checking, .busy("Edit Shot Planning"), .busy("storyboard")] {
            #expect(state.dockMessage?.hasPrefix(PhaseControlReadiness.failurePrefix) == false)
            #expect(state.failure == nil)
            #expect(!state.isReady)
        }
    }

    @Test func failureNamesItsRealReason() {
        let reason = "The project pipeline is not initialized."
        let state = PhaseControlReadiness.failed(reason)
        #expect(state.dockMessage == PhaseControlReadiness.failurePrefix + " " + reason)
        #expect(state.failure == reason)
    }

    @Test func controlResultsMapToBusyFailedOrReady() {
        let lock = NativeGateApprovalReadiness.blocked("Can't change pipeline gates while Edit Shot Planning is running. Wait for the phase to finish.")
        #expect(PhaseControlReadiness(.init(mutations: lock, approval: lock, activeOperation: "Edit Shot Planning"))
            == .busy("Edit Shot Planning"))
        let broken = NativeGateApprovalReadiness.blocked("gates.yaml is unreadable.")
        #expect(PhaseControlReadiness(.init(mutations: broken, approval: broken)) == .failed("gates.yaml is unreadable."))
        let ready = PhaseControlReadiness(.init(mutations: .ready, approval: .blocked("Incomplete")))
        #expect(ready == .ready)
        #expect(ready.dockMessage == nil)
    }
}
