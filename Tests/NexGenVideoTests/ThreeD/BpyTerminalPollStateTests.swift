import Foundation
import Testing
@testable import NexGenVideo

struct BpyTerminalPollStateTests {
    @Test func oneFinalReadMayBeginAtOrAfterTheCollectionBoundary() throws {
        for now in [25.0, 25.01] {
            var polling = BpyTerminalPollState()
            try polling.begin(at: now, deadline: 25)
            #expect(polling.finalRead)
            try polling.end(at: 30, deadline: 25, terminal: true)
            #expect(throws: BpyRuntimeError.self) { try polling.begin(at: 30, deadline: 25) }
        }
    }

    @Test func anInFlightReadCrossingTheBoundaryIsAlreadyTheFinalRead() throws {
        var polling = BpyTerminalPollState()
        try polling.begin(at: 24.9, deadline: 25)
        try polling.end(at: 25.1, deadline: 25, terminal: true)
        #expect(polling.finalRead)
        #expect(throws: BpyRuntimeError.self) { try polling.begin(at: 25.1, deadline: 25) }
    }

    @Test func aStillRunningFinalReplyCannotBuyAnotherRead() throws {
        var polling = BpyTerminalPollState()
        try polling.begin(at: 24.9, deadline: 25)
        #expect(throws: BpyRuntimeError.self) { try polling.end(at: 26, deadline: 25, terminal: false) }
        #expect(throws: BpyRuntimeError.self) { try polling.begin(at: 26, deadline: 25) }
    }

    @Test func aReleaseObservedDuringAdmissionPollingUsesItsActualExecutionBoundary() throws {
        var polling = BpyTerminalPollState()
        try polling.begin(at: 9.9, deadline: 10)
        try polling.end(at: 10.1, deadline: 34.95, terminal: false)
        #expect(!polling.finalRead)
        try polling.begin(at: 10.2, deadline: 34.95)
        try polling.end(at: 10.3, deadline: 34.95, terminal: false)
    }

    @Test func onlyTheCommitTimeDeterminesTimelinessOfALateReply() {
        #expect(BpyTerminalPollState.timelyCommit(first: 0, timeout: 10, commit: 25))
        #expect(BpyTerminalPollState.timelyCommit(first: 0, timeout: 10, commit: 20))
        #expect(!BpyTerminalPollState.timelyCommit(first: 0, timeout: 10, commit: 25.001))
        #expect(!BpyTerminalPollState.timelyCommit(first: 2, timeout: 10, commit: 1))
        #expect(!BpyTerminalPollState.timelyCommit(first: 0, timeout: .infinity, commit: 25))
    }
}
