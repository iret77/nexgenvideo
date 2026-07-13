import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import MusicvideoPlugin
@testable import NexGenEngine

/// frame_ratio / frame_size / builder_bypass — read the `FramesManifest` off a temp
/// data root. ratio/size need real pixel dims, so the fixtures write actual PNGs.
@Suite("frame manifest checks")
struct FrameChecksTests {
    static func tempRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("framechk-" + UUID().uuidString)
    }

    /// Write a real PNG of the given pixel size to `url` (so ImageIO reads its dims).
    static func writePNG(_ width: Int, _ height: Int, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let img = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    static func writeManifest(_ shots: [ShotFrames], dataRoot: URL) throws {
        try saveFramesManifest(FramesManifest(project: "p", generated: "t", shots: shots), dataRoot: dataRoot)
    }

    static func brief(_ aspect: AspectRatio) throws -> Brief {
        try Brief(project: "p", generated: "t", mission: .demo, targetPlatform: "web", aspectRatio: aspect,
                  projectMode: "beat", conceptType: .abstract, visualMedium: .liveActionRealistic,
                  figures: .none, lyricsIntegration: .ignored)
    }

    static func shot(_ id: String, mode: SeedanceInputMode = .keyframe) throws -> Shot {
        try Shot(id: id, section: "verse", timeStart: 0, timeEnd: 4, durationS: 4, type: .performance,
                 description: "d", visualPrompt: "p", mood: "m", keyframeStrategy: .start, seedanceInputMode: mode)
    }

    static func shotlist(_ shots: [Shot]) throws -> Shotlist {
        try Shotlist(
            schema_: shotlistSchemaVersion, mode: .beat, project: "p",
            song: try Song(title: "t", audioPath: "audio/s.wav", analysisPath: "analysis/s.json",
                           bpm: 120, tempoMultiplier: 1, durationS: 180),
            generated: "t", generator: "g", shots: shots)
    }

    @Test("frame_ratio flags a frame whose aspect deviates from the brief, passes a matching one")
    func ratio() throws {
        let root = Self.tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try Self.writePNG(1000, 1000, to: root.appendingPathComponent("frames/s001/start.png"))  // 1:1
        try Self.writePNG(1920, 1080, to: root.appendingPathComponent("frames/s002/start.png"))  // 16:9
        try Self.writeManifest([
            ShotFrames(shotId: "s001", keyframeStrategy: "start", frames: [FrameEntry(role: "start", path: "frames/s001/start.png")]),
            ShotFrames(shotId: "s002", keyframeStrategy: "start", frames: [FrameEntry(role: "start", path: "frames/s002/start.png")]),
        ], dataRoot: root)
        let ctx = AuditContext(shotlist: try Self.shotlist([try Self.shot("s001"), try Self.shot("s002")]),
                               brief: try Self.brief(.landscape16x9), extra: ["data_root": root.path])
        let findings = try MusicvideoChecks.frameRatioCheck(ctx)
        #expect(findings.contains { $0.code == "FRAME_RATIO_MISMATCH" && $0.shotId == "s001" })
        #expect(!findings.contains { $0.shotId == "s002" })   // 16:9 frame matches the brief
    }

    @Test("frame_ratio errors when the brief aspect can't be resolved")
    func aspectUnresolved() throws {
        let root = Self.tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try Self.writeManifest([], dataRoot: root)
        // aspect "other" with an unparseable free-form → Aspect.Unresolvable.
        let brief = try Brief(project: "p", generated: "t", mission: .demo, targetPlatform: "web",
                              aspectRatio: .other, aspectRatioOther: "widescreen-ish", projectMode: "beat",
                              conceptType: .abstract, visualMedium: .liveActionRealistic, figures: .none, lyricsIntegration: .ignored)
        let findings = try MusicvideoChecks.frameRatioCheck(
            AuditContext(shotlist: try Self.shotlist([try Self.shot("s001")]), brief: brief, extra: ["data_root": root.path]))
        #expect(findings.contains { $0.code == "BRIEF_ASPECT_UNRESOLVED" })
    }

    @Test("frame_size flags a short-edge < 1024 frame, passes a large one")
    func size() throws {
        let root = Self.tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try Self.writePNG(800, 600, to: root.appendingPathComponent("frames/s001/start.png"))    // short edge 600
        try Self.writePNG(1920, 1080, to: root.appendingPathComponent("frames/s002/start.png"))  // short edge 1080
        try Self.writeManifest([
            ShotFrames(shotId: "s001", keyframeStrategy: "start", frames: [FrameEntry(role: "start", path: "frames/s001/start.png")]),
            ShotFrames(shotId: "s002", keyframeStrategy: "start", frames: [FrameEntry(role: "start", path: "frames/s002/start.png")]),
        ], dataRoot: root)
        let findings = try MusicvideoChecks.frameSizeCheck(
            AuditContext(shotlist: try Self.shotlist([try Self.shot("s001"), try Self.shot("s002")]), extra: ["data_root": root.path]))
        #expect(findings.contains { $0.code == "FRAME_TOO_SMALL" && $0.shotId == "s001" })
        #expect(!findings.contains { $0.shotId == "s002" })
    }

    @Test("builder_bypass flags empty provider_prompt except for reference-mode shots")
    func bypass() throws {
        let root = Self.tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try Self.writeManifest([
            ShotFrames(shotId: "s001", keyframeStrategy: "start", frames: [FrameEntry(role: "start", path: "frames/s001/start.png", providerPrompt: "")]),
            ShotFrames(shotId: "s002", keyframeStrategy: "start", frames: [FrameEntry(role: "start", path: "frames/s002/start.png", providerPrompt: "")]),
            ShotFrames(shotId: "s003", keyframeStrategy: "start", frames: [FrameEntry(role: "start", path: "frames/s003/start.png", providerPrompt: "cinematic wide, warm light")]),
        ], dataRoot: root)
        let shots = [try Self.shot("s001"), try Self.shot("s002", mode: .reference), try Self.shot("s003")]
        let findings = try MusicvideoChecks.builderBypassCheck(
            AuditContext(shotlist: try Self.shotlist(shots), extra: ["data_root": root.path]))
        #expect(findings.contains { $0.code == "BUILDER_BYPASS_DETECTED" && $0.shotId == "s001" })
        #expect(!findings.contains { $0.shotId == "s002" })   // reference-mode → exempt
        #expect(!findings.contains { $0.shotId == "s003" })   // has a provider_prompt
    }

    @Test("all three degrade to no findings when no manifest exists")
    func noManifest() throws {
        let root = Self.tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let ctx = AuditContext(shotlist: try Self.shotlist([try Self.shot("s001")]),
                               brief: try Self.brief(.landscape16x9), extra: ["data_root": root.path])
        #expect(try MusicvideoChecks.frameRatioCheck(ctx).isEmpty)
        #expect(try MusicvideoChecks.frameSizeCheck(ctx).isEmpty)
        #expect(try MusicvideoChecks.builderBypassCheck(ctx).isEmpty)
    }
}
