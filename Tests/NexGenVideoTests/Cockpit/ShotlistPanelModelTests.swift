import Foundation
import Testing

@testable import NexGenVideo
import NexGenEngine

/// The cockpit shotlist read-model decodes the engine's `source_mode` (hybrid production, issue #129)
/// and maps it to the shared `SourceModeTag` UI descriptor. Absent/unknown → generated (default).
@Suite("ShotlistPanelModel — source_mode")
struct ShotlistPanelModelTests {

    private func decodeShots(_ json: String) throws -> [ShotSummary] {
        try JSONDecoder().decode(ShotlistData.self, from: Data(json.utf8)).shots
    }

    @Test("each source_mode value decodes onto the ShotSummary",
          arguments: [
            ("generated", SourceModeTag.generated),
            ("live_action", .liveAction),
            ("ai_enhanced", .aiEnhanced),
          ])
    func decodesEachMode(_ raw: String, _ expected: SourceModeTag) throws {
        let shots = try decodeShots(#"{"shots":[{"id":"s1","source_mode":"\#(raw)"}]}"#)
        #expect(shots[0].sourceMode == raw)
        #expect(shots[0].sourceModeTag == expected)
    }

    @Test("a shot without source_mode defaults to generated")
    func absentDefaultsToGenerated() throws {
        let shots = try decodeShots(#"{"shots":[{"id":"s1"}]}"#)
        #expect(shots[0].sourceModeTag == .generated)
    }

    @Test("an unknown source_mode value falls back to generated")
    func unknownFallsBackToGenerated() throws {
        let shots = try decodeShots(#"{"shots":[{"id":"s1","source_mode":"wat"}]}"#)
        #expect(shots[0].sourceModeTag == .generated)
    }

    @Test("SourceModeTag maps to the specified SF Symbols and engine mode")
    func tagSymbolsAndEngineMode() {
        #expect(SourceModeTag.generated.symbol == "sparkles")
        #expect(SourceModeTag.liveAction.symbol == "video")
        #expect(SourceModeTag.aiEnhanced.symbol == "wand.and.rays")
        #expect(SourceModeTag.generated.engineMode == .generated)
        #expect(SourceModeTag.liveAction.engineMode == .liveAction)
        #expect(SourceModeTag.aiEnhanced.engineMode == .aiEnhanced)
        // Raw values are shared with the engine enum.
        #expect(SourceModeTag.allCases.map(\.rawValue) == SourceMode.allCases.map(\.rawValue))
    }
}
