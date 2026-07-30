import Testing
@testable import NexGenVideo

@Suite("Main-thread hang watchdog")
struct MainThreadHangWatchdogTests {
    @Test func capturesOneReportForAnUnansweredProbe() {
        var state = MainThreadHangProbeState(
            stallThreshold: 8,
            monitorSuspensionThreshold: 3.5
        )

        #expect(state.tick(at: 0) == .ping(1))
        for tick in 1...7 {
            #expect(state.tick(at: TimeInterval(tick)) == nil)
        }
        #expect(state.tick(at: 8) == .capture(stallSeconds: 8))
        #expect(state.tick(at: 9) == nil)
    }

    @Test func acknowledgedProbeStartsANewHeartbeat() {
        var state = MainThreadHangProbeState(
            stallThreshold: 8,
            monitorSuspensionThreshold: 3.5
        )

        #expect(state.tick(at: 0) == .ping(1))
        state.acknowledge(1)
        #expect(state.tick(at: 1) == .ping(2))
        state.acknowledge(2)
        #expect(state.tick(at: 2) == .ping(3))
    }

    @Test func monitorSuspensionDoesNotReportAMainThreadHang() {
        var state = MainThreadHangProbeState(
            stallThreshold: 8,
            monitorSuspensionThreshold: 3.5
        )

        #expect(state.tick(at: 0) == .ping(1))
        #expect(state.tick(at: 20) == .ping(2))
    }

    @Test func monitorSuspensionDoesNotDuplicateAReportedHang() {
        var state = MainThreadHangProbeState(
            stallThreshold: 8,
            monitorSuspensionThreshold: 3.5
        )

        #expect(state.tick(at: 0) == .ping(1))
        for tick in 1...7 {
            #expect(state.tick(at: TimeInterval(tick)) == nil)
        }
        #expect(state.tick(at: 8) == .capture(stallSeconds: 8))
        #expect(state.tick(at: 20) == nil)
        #expect(state.tick(at: 21) == nil)
        state.acknowledge(1)
        #expect(state.tick(at: 22) == .ping(2))
    }

    @Test func staleAcknowledgementDoesNotClearTheCurrentProbe() {
        var state = MainThreadHangProbeState(
            stallThreshold: 8,
            monitorSuspensionThreshold: 3.5
        )

        #expect(state.tick(at: 0) == .ping(1))
        #expect(state.tick(at: 20) == .ping(2))
        state.acknowledge(1)
        for tick in 21...27 {
            #expect(state.tick(at: TimeInterval(tick)) == nil)
        }
        #expect(state.tick(at: 28) == .capture(stallSeconds: 8))
    }

    @Test func recoveryArmsTheNextIndependentHang() {
        var state = MainThreadHangProbeState(
            stallThreshold: 8,
            monitorSuspensionThreshold: 3.5
        )

        #expect(state.tick(at: 0) == .ping(1))
        for tick in 1...7 {
            #expect(state.tick(at: TimeInterval(tick)) == nil)
        }
        #expect(state.tick(at: 8) == .capture(stallSeconds: 8))
        state.acknowledge(1)
        #expect(state.tick(at: 9) == .ping(2))
        for tick in 10...16 {
            #expect(state.tick(at: TimeInterval(tick)) == nil)
        }
        #expect(state.tick(at: 17) == .capture(stallSeconds: 8))
    }
}
