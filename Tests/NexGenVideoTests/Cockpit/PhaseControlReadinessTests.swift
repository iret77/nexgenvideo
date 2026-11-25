import Testing
@testable import NexGenVideo

@Suite("Phase control readiness")
struct PhaseControlReadinessTests {
    @Test func checkingAndBusyNeverReportAFailure() {
        #expect(PhaseControlReadiness.checking.dockMessage == "Checking phase readiness…")
        #expect(PhaseControlReadiness.busy("Edit Shot Planning").dockMessage == "Wait for Edit Shot Planning to finish.")
        #expect(PhaseControlReadiness.busy("shot_planning").dockMessage == "Wait for \(PhaseDisplay.label("shot_planning")) to finish.")
        #expect(PhaseControlReadiness.busy("shot_planning").dockMessage?.contains("shot_planning") == false)
        #expect(PhaseControlReadiness.busy("Approve shot_planning").dockMessage == "Wait for Approve \(PhaseDisplay.label("shot_planning")) to finish.")
        for state in [PhaseControlReadiness.checking, .busy("Edit Shot Planning"), .busy("storyboard")] {
            #expect(state.dockMessage?.hasPrefix(PhaseControlReadiness.failurePrefix) == false)
            #expect(state.failure == nil)
            #expect(!state.isReady)
        }
    }

    @Test func failureNamesItsRealReason() {
        let reason = "The project pipeline is not initialized."
        let state = PhaseControlReadiness.failed(reason)
        #expect(state.dockMessage?.hasPrefix(PhaseControlReadiness.failurePrefix) == true)
        #expect(state.dockMessage?.contains(reason) == false)
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

    @Test func recheckingKeepsTheSettledControlsWithoutClaimingReadiness() {
        let ready = PhaseDockReadiness(phase: "storyboard", mutation: .ready, approval: .ready)
        let checking = PhaseDockReadiness(phase: "storyboard", mutation: .checking,
                                          approval: .blocked("Checking approval readiness."))
        let layout = PhaseDockLayout.resolve(phase: "storyboard", current: checking, settled: ready, saving: false)
        #expect(layout.settling && layout.checking && !layout.waiting)
        #expect(layout.message == PhaseControlReadiness.checking.dockMessage)
        #expect(layout.reservedMessages(showing: layout.message) == [PhaseDockReadiness.readyMessage])
        #expect(layout.stable?.approves == true)
        #expect(layout.stable?.diagnostic == nil && layout.stable?.offersRetry == false)
        #expect(layout.reservedStatuses(for: .checking) == [.ready])

        let settled = PhaseDockLayout.resolve(phase: "storyboard", current: ready, settled: ready, saving: false)
        #expect(!settled.settling && settled.reservedMessages(showing: settled.message).isEmpty)
        #expect(settled.message == PhaseDockReadiness.readyMessage)
        #expect(settled.reservedMessages(showing: "Review the phase decision below.") == [PhaseDockReadiness.readyMessage])

        let stalePhase = PhaseDockLayout.resolve(phase: "storyboard",
            current: .init(phase: "treatment", mutation: .ready, approval: .ready), settled: ready, saving: false)
        #expect(stalePhase.checking && stalePhase.message == PhaseControlReadiness.checking.dockMessage)
    }

    @Test func busyAndSavingNameTheirOperationInsideTheSettledLayout() {
        let blocked = PhaseDockReadiness(phase: "storyboard", mutation: .ready,
            approval: .blocked("Storyboard incomplete.", userMessage: "Storyboard needs current story relationships."))
        let busy = PhaseDockLayout.resolve(phase: "storyboard",
            current: .init(phase: "storyboard", mutation: .busy("Edit location"), approval: .ready), settled: blocked, saving: false)
        #expect(busy.message == "Wait for Edit location to finish.")
        #expect(busy.waiting && !busy.checking)
        #expect(busy.reservedMessages(showing: busy.message) == ["Storyboard needs current story relationships."])
        #expect(busy.stable?.approves == false && busy.stable?.diagnostic == "Storyboard incomplete.")
        #expect(busy.reservedStatuses(for: .waiting) == [.incomplete])

        let saving = PhaseDockLayout.resolve(phase: "storyboard", current: blocked, settled: blocked, saving: true)
        #expect(saving.settling && !saving.checking && !saving.waiting)
        #expect(saving.message == PhaseDockReadiness.savingMessage)
        #expect(saving.reservedMessages(showing: saving.message) == ["Storyboard needs current story relationships."])
    }

    @Test func aFirstCheckOrAnotherPhasesResultShowsANeutralPlaceholder() {
        let checking = PhaseDockReadiness(phase: "storyboard", mutation: .checking, approval: .blocked("Checking."))
        let failedElsewhere = PhaseDockReadiness(phase: "treatment", mutation: .failed("gates.yaml is unreadable."),
                                                 approval: .ready)
        for settled in [nil, failedElsewhere] {
            let layout = PhaseDockLayout.resolve(phase: "storyboard", current: checking, settled: settled, saving: false)
            #expect(layout.stable == nil)
            #expect(layout.message == PhaseControlReadiness.checking.dockMessage)
            #expect(layout.reservedMessages(showing: layout.message) == [PhaseDockReadiness.readyMessage,
                PipelineReadinessPresentation.message(for: .artifact, phase: "storyboard")])
            #expect(layout.reservedStatuses(for: .checking) == [.incomplete])
        }
    }

    @Test func approvedPhaseRecheckAddsNoRowAndKeepsAFailureSlot() {
        let quiet = PhaseDockRevisionLayout.resolve(mutation: .checking, settled: .ready)
        #expect(quiet.settling && quiet.reason == nil && quiet.reserved == nil && !quiet.offersRetry)

        let failure = PhaseControlReadiness.failed("gates.yaml is unreadable.")
        let retrying = PhaseDockRevisionLayout.resolve(mutation: .checking, settled: failure)
        #expect(retrying.reason == "Checking whether this phase can be revised…")
        #expect(retrying.reserved == failure.revisionMessage && retrying.offersRetry)

        let settled = PhaseDockRevisionLayout.resolve(mutation: failure, settled: failure)
        #expect(!settled.settling && settled.reason == failure.revisionMessage && settled.reserved == nil)
    }

    @Test func readableOperationLabelsStayAsWritten() {
        #expect(PhaseControlReadiness.operationName("Edit location") == "Edit location")
        #expect(PhaseControlReadiness.operationName("Add reviewed source range") == "Add reviewed source range")
        #expect(PhaseControlReadiness.operationName("Approve storyboard") == "Approve \(PhaseDisplay.label("storyboard"))")
        #expect(PhaseControlReadiness.operationName("Rewind pack_only_phase") == "Rewind Pack Only Phase")
    }
}
