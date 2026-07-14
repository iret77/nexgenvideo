import Foundation
import Testing
@testable import MusicvideoPlugin
@testable import NexGenEngine

/// identity_anchor + plan_shot_refs_with_identity_anchors (#195). Ports of
/// `render/identity_anchor.py` + `render/references/__init__.py::plan_shot_refs_with_identity_anchors`.
@Suite("identity anchors")
struct IdentityAnchorTests {
    static func shot(_ id: String, section: String?, start: Double, chars: [String]) throws -> Shot {
        try Shot(id: id, section: section, timeStart: start, timeEnd: start + 4, durationS: 4,
                 type: .performance, description: "d", visualPrompt: "p", mood: "m",
                 characterRefs: chars, keyframeStrategy: .start)
    }

    static func shotlist(_ shots: [Shot]) throws -> Shotlist {
        try Shotlist(
            schema_: shotlistSchemaVersion, mode: .beat, project: "p",
            song: try Song(title: "t", audioPath: "audio/s.wav", analysisPath: "analysis/s.json",
                           bpm: 120, tempoMultiplier: 1, durationS: 180),
            generated: "t", generator: "g", shots: shots)
    }

    @Test("first (section, character) shot is the anchor; later same-section shots inherit it")
    func picksAndInherits() throws {
        let sl = try Self.shotlist([
            try Self.shot("s001", section: "verse", start: 0, chars: ["hero"]),
            try Self.shot("s002", section: "verse", start: 4, chars: ["hero", "rival"]),
            try Self.shot("s003", section: "chorus", start: 8, chars: ["hero"]),
        ])
        let map = IdentityAnchor.pickIdentityAnchors(sl)

        #expect(IdentityAnchor.isAnchorFor(map, shotId: "s001", characterId: "hero"))
        #expect(!IdentityAnchor.isAnchorFor(map, shotId: "s002", characterId: "hero"))
        #expect(IdentityAnchor.isAnchorFor(map, shotId: "s002", characterId: "rival"))

        #expect(IdentityAnchor.inheritedAnchorShots(map, shotId: "s001").isEmpty)
        #expect(IdentityAnchor.inheritedAnchorShots(map, shotId: "s002") == ["s001"])
        // Section change resets — the chorus hero is a fresh anchor, inherits nothing.
        #expect(IdentityAnchor.inheritedAnchorShots(map, shotId: "s003").isEmpty)
    }

    /// A temp project dir populated with the given (empty) relative files.
    static func fixtureDir(_ relPaths: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("anchor-" + UUID().uuidString)
        for rel in relPaths {
            let url = dir.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
        return dir
    }

    @Test("inherited anchor frame is stacked on top of the ref set (score 1.05)")
    func stacksAnchorFrame() throws {
        let dir = try Self.fixtureDir(["b/front.png", "frames/s001-start.png"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let char = try Character(id: "hero", name: "Hero", visualPrompt: "p", sheets: ["front": "b/front.png"])
        let bible = try Bible(project: "p", generated: "t", generator: "g", characters: [char])
        let sl = try Self.shotlist([
            try Self.shot("s001", section: "verse", start: 0, chars: ["hero"]),
            try Self.shot("s002", section: "verse", start: 4, chars: ["hero"]),
        ])
        let manifest = FramesManifest(project: "p", generated: "t", shots: [
            ShotFrames(shotId: "s001", keyframeStrategy: "start",
                       frames: [FrameEntry(role: "start", path: "frames/s001-start.png")]),
        ])
        let plan = ReferencePlanner.planShotRefsWithIdentityAnchors(
            projectDir: dir, bible: bible, shot: sl.shots[1], shotlist: sl,
            framesManifest: manifest, maxRefs: 9, framesBase: dir)

        #expect(plan.refs.first?.entityKind == "identity_anchor")
        #expect(plan.refs.first?.path == "frames/s001-start.png")
        #expect(plan.refs.first?.score == 1.05)
        #expect(plan.refs.contains { $0.entityKind == "character" && $0.view == "front" })
    }

    @Test("no frames manifest → falls back to the plain plan (no anchor stacked)")
    func fallsBackWithoutManifest() throws {
        let dir = try Self.fixtureDir(["b/front.png"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let char = try Character(id: "hero", name: "Hero", visualPrompt: "p", sheets: ["front": "b/front.png"])
        let bible = try Bible(project: "p", generated: "t", generator: "g", characters: [char])
        let sl = try Self.shotlist([
            try Self.shot("s001", section: "verse", start: 0, chars: ["hero"]),
            try Self.shot("s002", section: "verse", start: 4, chars: ["hero"]),
        ])
        let plan = ReferencePlanner.planShotRefsWithIdentityAnchors(
            projectDir: dir, bible: bible, shot: sl.shots[1], shotlist: sl,
            framesManifest: nil, maxRefs: 9, framesBase: dir)
        #expect(!plan.refs.contains { $0.entityKind == "identity_anchor" })
    }
}
