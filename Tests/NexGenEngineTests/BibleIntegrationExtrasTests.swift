import Foundation
import Testing
@testable import MusicvideoPlugin
@testable import NexGenEngine

/// bible_integration extra (C1): NO_FRONT_SHEET, the reachable code the initial port dropped. (The
/// Python's NO_ANCHOR is intentionally NOT ported — `Bible.validate()` already forbids an anchorless
/// entity at every construction/decode boundary, so a sanity check for it would be dead code; an
/// anchorless `Bible` can't even be built to test it.)
@Suite("bible_integration extras")
struct BibleIntegrationExtrasTests {
    /// A minimal non-empty, valid shotlist (empty shotlists throw `.emptyShots`; ids must match `^s\d{3}$`).
    private func shotlist() throws -> Shotlist {
        let shot = try Shot(id: "s001", section: "verse", timeStart: 0, timeEnd: 4, durationS: 4,
                            type: .performance, description: "d", visualPrompt: "p", mood: "m")
        return try Shotlist(
            schema_: shotlistSchemaVersion, mode: .beat, project: "p",
            song: try Song(title: "t", audioPath: "audio/s.wav", analysisPath: "analysis/s.json",
                           bpm: 120, tempoMultiplier: 1, durationS: 180),
            generated: "t", generator: "g", shots: [shot])
    }

    @Test("NO_FRONT_SHEET when an (anchored) character has sheets but no 'front'")
    func noFrontSheet() throws {
        // Both characters are anchored (non-empty sheets) so the Bible validates; only c1 lacks 'front'.
        let noFront = try Character(id: "c1", name: "C1", visualPrompt: "p",
                                   sheets: ["back": "bible/refs/c1/back.png"])
        let withFront = try Character(id: "c2", name: "C2", visualPrompt: "p",
                                     sheets: ["front": "bible/refs/c2/front.png"])
        let bible = try Bible(project: "p", generated: "t", generator: "g", characters: [noFront, withFront])
        let findings = try MusicvideoChecks.bibleReferenceIntegrityCheck(
            AuditContext(shotlist: try shotlist(), bible: bible))
        let frontIssues = findings.filter { $0.code == "NO_FRONT_SHEET" }
        #expect(frontIssues.count == 1)
        #expect(frontIssues.first?.message.contains("c1") == true)
        #expect(frontIssues.first?.level == .warn)
    }
}
