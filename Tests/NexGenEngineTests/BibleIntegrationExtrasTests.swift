import Foundation
import Testing
@testable import MusicvideoPlugin
@testable import NexGenEngine

/// bible_integration extras (C1): NO_ANCHOR + NO_FRONT_SHEET, the two codes the initial port dropped.
@Suite("bible_integration extras")
struct BibleIntegrationExtrasTests {
    private func emptyShotlist() throws -> Shotlist {
        try Shotlist(
            schema_: shotlistSchemaVersion, mode: .beat, project: "p",
            song: try Song(title: "t", audioPath: "audio/s.wav", analysisPath: "analysis/s.json",
                           bpm: 120, tempoMultiplier: 1, durationS: 180),
            generated: "t", generator: "g", shots: [])
    }

    @Test("NO_ANCHOR for an entity without any image anchor; anchored entities pass")
    func noAnchor() throws {
        let anchorless = try Character(id: "c1", name: "C1", visualPrompt: "p")
        let anchored = try Character(id: "c2", name: "C2", visualPrompt: "p",
                                    referenceImages: ["bible/refs/c2/front.png"])
        let bible = try Bible(project: "p", generated: "t", generator: "g", characters: [anchorless, anchored])
        let findings = try MusicvideoChecks.bibleReferenceIntegrityCheck(
            AuditContext(shotlist: try emptyShotlist(), bible: bible))
        let anchors = findings.filter { $0.code == "NO_ANCHOR" }
        #expect(anchors.count == 1)
        #expect(anchors.first?.message.contains("c1") == true)
        #expect(anchors.first?.level == .error)
    }

    @Test("NO_FRONT_SHEET when a character has sheets but no 'front'")
    func noFrontSheet() throws {
        let noFront = try Character(id: "c1", name: "C1", visualPrompt: "p",
                                   sheets: ["back": "bible/refs/c1/back.png"])
        let withFront = try Character(id: "c2", name: "C2", visualPrompt: "p",
                                     sheets: ["front": "bible/refs/c2/front.png"])
        let bible = try Bible(project: "p", generated: "t", generator: "g", characters: [noFront, withFront])
        let findings = try MusicvideoChecks.bibleReferenceIntegrityCheck(
            AuditContext(shotlist: try emptyShotlist(), bible: bible))
        let frontIssues = findings.filter { $0.code == "NO_FRONT_SHEET" }
        #expect(frontIssues.count == 1)
        #expect(frontIssues.first?.message.contains("c1") == true)
        #expect(frontIssues.first?.level == .warn)
        // A character with sheets is anchored — no NO_ANCHOR for either here.
        #expect(!findings.contains { $0.code == "NO_ANCHOR" })
    }
}
