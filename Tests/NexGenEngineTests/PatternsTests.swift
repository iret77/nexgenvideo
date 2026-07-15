import Foundation
import Testing
@testable import NexGenEngine
@testable import MusicvideoPlugin

/// Port of `plugins/musicvideo/tests/test_patterns.py`.
@Suite("Musicvideo Patterns", .serialized)
struct PatternsTests {
    @Test("PatternTempoBand raw values")
    func tempoBandValues() {
        #expect(PatternTempoBand.slow.rawValue == "slow")
        #expect(PatternTempoBand.fast.rawValue == "fast")
    }

    @Test("tempo band thresholds")
    func tempoBandThresholds() {
        #expect(patternTempoBand(70) == .slow)
        #expect(patternTempoBand(95) == .medium)
        #expect(patternTempoBand(120) == .uptempo)
        #expect(patternTempoBand(160) == .fast)
    }

    @Test("pattern library loads and validates")
    func libraryLoadsAndValidates() throws {
        let library = try Patterns.loadAllPatterns()
        #expect(library.count >= 1)
        #expect(library.count == 23)
    }
}
