import CoreMedia
import Testing
@testable import NexGenVideo

@Suite("Production delivery duration")
struct ProductionDeliveryDurationTests {
    @Test("Native clocks preserve the same exact audio end")
    func exactNativeClock() {
        #expect(PipelineDeliveryStore.exactDurationMatches(actual: CMTime(value: 960_002, timescale: 96_000),
            expected: CMTime(value: 480_001, timescale: 48_000)))
    }

    @Test("A covering video frame cannot extend the expected production audio")
    func framePaddingFails() {
        #expect(!PipelineDeliveryStore.exactDurationMatches(actual: CMTime(value: 301, timescale: 30),
            expected: CMTime(value: 480_001, timescale: 48_000)))
        #expect(!PipelineDeliveryStore.exactDurationMatches(actual: CMTime(value: 480_003, timescale: 48_000),
            expected: CMTime(value: 480_001, timescale: 48_000)))
    }
}
