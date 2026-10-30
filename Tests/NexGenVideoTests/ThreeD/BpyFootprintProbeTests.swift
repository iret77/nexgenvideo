import BpyRuntimeProtocol
import Foundation
import Testing
@testable import NexGenVideo

struct BpyFootprintProbeTests {
    private func process(_ footprint: UInt64, pid: Int32 = 55, start: UInt64 = 99) -> BpyObservedProcess {
        .init(pid: pid, start: start, parent: 44, executable: "/owned/probe", footprint: footprint)
    }

    @Test func baselineAbove128MiBUsesDeltasInsteadOfAnAbsoluteCutoff() throws {
        let mib: UInt64 = 1_024 * 1_024
        let probe = try BpyFootprintProbe(baseline: process(200 * mib), deadline: 30)
        #expect(probe.observe(process(256 * mib), requested: 64 * mib, capReached: false, at: 1) == .continuing)
        #expect(probe.observe(process(329 * mib), requested: 128 * mib, capReached: false, at: 2) == .proven)
        #expect(probe.observe(process(456 * mib), requested: 128 * mib, capReached: false, at: 3) == .unsafe)
    }

    @Test func identityArithmeticDeadlineAndIndependentAllocationCapFailClosed() throws {
        let probe = try BpyFootprintProbe(baseline: process(200_000_000), deadline: 30)
        #expect(probe.observe(process(400_000_000, pid: 56), requested: 134_217_728, capReached: false, at: 1) == .unsafe)
        #expect(probe.observe(process(400_000_000, start: 100), requested: 134_217_728, capReached: false, at: 1) == .unsafe)
        #expect(probe.observe(process(400_000_000), requested: 134_217_728, capReached: false, at: 30) == .unsafe)
        #expect(probe.observe(process(400_000_000), requested: 268_435_456, capReached: true, at: 1) == .unsafe)
        #expect(throws: (any Error).self) { _ = try BpyFootprintProbe(baseline: process(UInt64.max), deadline: 30) }
    }
}
