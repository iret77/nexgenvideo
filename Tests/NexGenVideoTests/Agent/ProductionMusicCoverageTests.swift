import Foundation
import Testing
import NexGenEngine
@testable import NexGenVideo

@Suite("Music Video continuous coverage")
struct ProductionMusicCoverageTests {
    @Test("Overlapping camera tracks do not double-count continuous coverage or bridge a real gap")
    func actualIntervals() throws {
        func placement(_ start: Int64, _ duration: Int64, _ id: String) -> ProductionPlanAssemblyProofV1.Placement {
            .init(shotID: id, trackID: id, clipID: id,
                output: .init(id: id, role: "core.source-footage", path: "sources/\(id).mov", sha256: String(repeating: "0", count: 64)),
                sourceKind: .video, startTicks: start, durationTicks: duration, sourceInTicks: 0, decodedDurationTicks: duration)
        }
        let first = placement(0, 4_000, "camera-a")
        try PipelineProductionMusicCoverage.requireVideo([first])
        let still = ProductionPlanAssemblyProofV1.Placement(shotID: "still", trackID: "still", clipID: "still",
            output: first.output, sourceKind: .stillImage, startTicks: 0, durationTicks: 4_000,
            sourceInTicks: 0, decodedDurationTicks: 4_000)
        #expect(throws: (any Error).self) { try PipelineProductionMusicCoverage.requireVideo([still]) }
        #expect(try PipelineProductionMusicCoverage.longestContinuous([first, placement(0, 4_000, "camera-b")]) == 4_000)
        #expect(try PipelineProductionMusicCoverage.longestContinuous([first, placement(5_000, 4_000, "later")]) == 4_000)
        #expect(try PipelineProductionMusicCoverage.longestContinuous([first, placement(4_000, 4_000, "following")]) == 8_000)
    }
}
