import BpyRuntimeProtocol
import Foundation

nonisolated struct BpyFootprintProbe: Sendable {
    enum Observation: Equatable { case continuing, proven, unsafe }
    static let chunk: UInt64 = 4 * 1_024 * 1_024
    static let delta: UInt64 = 128 * 1_024 * 1_024
    static let maximum: UInt64 = 256 * 1_024 * 1_024
    let baseline: BpyObservedProcess
    let threshold: UInt64
    let safety: UInt64
    let deadline: TimeInterval

    init(baseline: BpyObservedProcess, deadline: TimeInterval) throws {
        let threshold = baseline.footprint.addingReportingOverflow(Self.delta)
        let safety = baseline.footprint.addingReportingOverflow(Self.maximum)
        guard baseline.pid > 1, baseline.start > 0, deadline.isFinite, deadline > 0,
              !threshold.overflow, !safety.overflow else { throw SpatialSceneError.changed }
        self.baseline = baseline; self.deadline = deadline
        self.threshold = threshold.partialValue; self.safety = safety.partialValue
    }

    func observe(_ current: BpyObservedProcess, requested: UInt64, capReached: Bool,
                 at now: TimeInterval) -> Observation {
        guard current.pid == baseline.pid, current.start == baseline.start,
              current.executable == baseline.executable, now.isFinite, now < deadline,
              !capReached, requested < Self.maximum, requested.isMultiple(of: Self.chunk),
              current.footprint < safety else { return .unsafe }
        guard requested > 0 else { return .continuing }
        return current.footprint >= threshold ? .proven : .continuing
    }
}
