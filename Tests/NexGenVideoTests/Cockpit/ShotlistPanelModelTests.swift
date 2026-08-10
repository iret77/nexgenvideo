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
            ("imported", .imported),
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

    @Test("production-plan presence is available to source-mode controls")
    func productionPlanPresence() throws {
        let planned = try decodeShots(
            #"{"shots":[{"id":"s1","production_plan":{"primary_action":"walk"}}]}"#
        )
        let unplanned = try decodeShots(#"{"shots":[{"id":"s2"}]}"#)
        #expect(planned[0].hasProductionPlan)
        #expect(!unplanned[0].hasProductionPlan)
    }

    @Test("SourceModeTag maps to the specified SF Symbols and engine mode")
    func tagSymbolsAndEngineMode() {
        #expect(SourceModeTag.generated.symbol == "sparkles")
        #expect(SourceModeTag.imported.symbol == "square.and.arrow.down")
        #expect(SourceModeTag.aiEnhanced.symbol == "wand.and.rays")
        #expect(SourceModeTag.generated.engineMode == .generated)
        #expect(SourceModeTag.imported.engineMode == .imported)
        #expect(SourceModeTag.aiEnhanced.engineMode == .aiEnhanced)
        // Raw values are shared with the engine enum.
        #expect(SourceModeTag.allCases.map(\.rawValue) == SourceMode.allCases.map(\.rawValue))
    }
}
