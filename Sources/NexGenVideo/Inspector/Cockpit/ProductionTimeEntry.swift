import Foundation
import NexGenEngine

enum ProductionTimeEntry {
    static func containedEndTicks(_ duration: Double, timebase: RationalTimebaseV1) throws -> Int64 {
        try timebase.validate()
        guard duration.isFinite, duration > 0,
              var seconds = Decimal(string: String(duration), locale: Locale(identifier: "en_US_POSIX")) else {
            throw ToolError("The source video has no valid duration.")
        }
        var scale = Decimal(timebase.ticksPerSecond)
        var product = Decimal()
        guard NSDecimalMultiply(&product, &seconds, &scale, .down) == .noError else {
            throw ToolError("This source duration is outside the supported range.")
        }
        var rounded = Decimal()
        NSDecimalRound(&rounded, &product, 0, .down)
        guard rounded >= 0, rounded <= Decimal(Int64.max) else {
            throw ToolError("This source duration is outside the supported range.")
        }
        return NSDecimalNumber(decimal: rounded).int64Value
    }

    static func ticks(_ text: String, timebase: RationalTimebaseV1) throws -> Int64 {
        try timebase.validate()
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        guard normalized.range(of: #"^[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil,
              let seconds = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")) else {
            throw ToolError("Enter a non-negative time in seconds, such as 12.5.")
        }
        var product = Decimal()
        var secondsValue = seconds
        var scale = Decimal(timebase.ticksPerSecond)
        guard NSDecimalMultiply(&product, &secondsValue, &scale, .plain) == .noError else {
            throw ToolError("This time is outside the supported range.")
        }
        var rounded = Decimal()
        NSDecimalRound(&rounded, &product, 0, .plain)
        guard rounded >= 0, rounded <= Decimal(Int64.max) else {
            throw ToolError("This time is outside the supported range.")
        }
        return NSDecimalNumber(decimal: rounded).int64Value
    }

    static func seconds(_ ticks: Int64, timebase: RationalTimebaseV1) -> String {
        guard timebase.ticksPerSecond > 0 else { return "" }
        var value = Decimal(ticks) / Decimal(timebase.ticksPerSecond)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 12, .plain)
        return NSDecimalNumber(decimal: rounded).stringValue
    }
}
