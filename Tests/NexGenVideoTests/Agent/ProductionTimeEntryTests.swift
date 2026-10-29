import NexGenEngine
import XCTest
@testable import NexGenVideo

final class ProductionTimeEntryTests: XCTestCase {
    private let timebase = RationalTimebaseV1(ticksPerSecond: 48000, fpsNumerator: 24)

    func testDecimalAndLocalizedInputRemainExact() throws {
        XCTAssertEqual(try ProductionTimeEntry.ticks("12.5", timebase: timebase), 600000)
        XCTAssertEqual(try ProductionTimeEntry.ticks("12,5", timebase: timebase), 600000)
        XCTAssertEqual(try ProductionTimeEntry.ticks("0.0000105", timebase: timebase), 1)
    }

    func testDisplayedValuesRoundTripWithoutFloatTruncation() throws {
        let ticks: [Int64] = [0, 1, 47999, 48000, 1234567890123456789]
        for tick in ticks {
            XCTAssertEqual(try ProductionTimeEntry.ticks(ProductionTimeEntry.seconds(tick, timebase: timebase), timebase: timebase), tick)
        }
    }

    func testMalformedAndOverflowValuesAreRejected() {
        for input in ["", "-1", "NaN", "1e4", "1,000.2", "1:20", "99999999999999999999999999999999999999"] {
            XCTAssertThrowsError(try ProductionTimeEntry.ticks(input, timebase: timebase))
        }
    }

    func testSourceEndNeverRoundsBeyondAvailableMedia() throws {
        let duration = 1.00002
        let end = try ProductionTimeEntry.containedEndTicks(duration, timebase: timebase)
        XCTAssertEqual(end, 48000)
        XCTAssertLessThanOrEqual(timebase.seconds(for: end), duration)
        XCTAssertEqual(try ProductionTimeEntry.containedEndTicks(12.5, timebase: timebase), 600000)
        for invalid in [Double.nan, .infinity, -1, 0, Double(Int64.max)] {
            XCTAssertThrowsError(try ProductionTimeEntry.containedEndTicks(invalid, timebase: timebase))
        }
    }
}
