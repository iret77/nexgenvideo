import AVFoundation
import Testing
@testable import NexGenVideo

@Suite("Production assembly source coverage")
struct ProductionAssemblySourceRangeTests {
    @Test("The last visual frame does not extend or discard non-frame-exact audio")
    func exactAudioEnd() throws {
        let end = CMTime(value: 480_001, timescale: 48_000)
        let range = try CompositionBuilder.availableSourceRange(start: .zero,
            requestedDuration: CMTime(value: 301, timescale: 30),
            available: CMTimeRange(start: .zero, duration: end), coverage: CMTime(value: 1, timescale: 30))
        #expect(CMTimeCompare(range.end, end) == 0)
        #expect(CMTimeCompare(range.duration, end) == 0)
    }

    @Test("A source selection outside the real track fails instead of silently skipping its clip")
    func invalidSourceRange() {
        let available = CMTimeRange(start: .zero, duration: CMTime(value: 10, timescale: 1))
        #expect(throws: (any Error).self) {
            try CompositionBuilder.availableSourceRange(start: CMTime(value: 10, timescale: 1),
                requestedDuration: CMTime(value: 1, timescale: 1), available: available,
                coverage: CMTime(value: 1, timescale: 30))
        }
        #expect(throws: (any Error).self) {
            try CompositionBuilder.availableSourceRange(start: .zero,
                requestedDuration: CMTime(value: 11, timescale: 1), available: available,
                coverage: CMTime(value: 1, timescale: 30))
        }
    }
}
