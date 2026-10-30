import Darwin
import Foundation

public struct BpyClockReading: Codable, Equatable, Sendable {
    public let awake: TimeInterval
    public let continuous: TimeInterval
    public let uncertainty: TimeInterval

    public init(awake: TimeInterval, continuous: TimeInterval, uncertainty: TimeInterval = 0) {
        self.awake = awake
        self.continuous = continuous
        self.uncertainty = uncertainty
    }

    public var isValid: Bool {
        awake.isFinite && continuous.isFinite && uncertainty.isFinite
            && awake >= 0 && continuous >= awake && uncertainty >= 0
    }

    public var sleepOffset: TimeInterval { continuous - awake }
}

public enum BpyRuntimeClock {
    private static let secondsPerTick: Double? = {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.numer > 0, info.denom > 0 else { return nil }
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()

    public static func read() -> BpyClockReading? {
        guard let secondsPerTick else { return nil }
        let before = mach_continuous_time()
        let awake = mach_absolute_time()
        let after = mach_continuous_time()
        guard after >= before, after >= awake else { return nil }
        let reading = BpyClockReading(awake: Double(awake) * secondsPerTick,
            continuous: Double(after) * secondsPerTick,
            uncertainty: Double(after - before) * secondsPerTick)
        return reading.isValid ? reading : nil
    }

    public static func awakeSeconds() throws -> TimeInterval {
        guard let reading = read() else { throw POSIXError(.EIO) }
        return reading.awake
    }
}
