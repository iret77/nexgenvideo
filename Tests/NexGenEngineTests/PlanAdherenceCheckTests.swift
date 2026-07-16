import Foundation
import Testing
@testable import MusicvideoPlugin
@testable import NexGenEngine

/// plan_adherence (#231) — the check that compares what the consistency machinery PLANNED against what
/// the render manifests recorded. Fixtures write real manifests to a temp data root; no bible is
/// staged, so the reference planner returns no plan and PLAN_REFS_IGNORED stays silent.
///
/// The `compile_prompt` half is NOT audited: it is prevented at the tool contract (`shotId` required,
/// `"none"` explicit), so there is nothing left to infer — see CompilePromptShotIdTests.
@Suite("plan_adherence")
struct PlanAdherenceCheckTests {
    static func tempRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("planadh-" + UUID().uuidString)
    }

    static func shot(
        _ id: String, at start: Double, camera: CameraSetup? = nil, chained: Bool = false
    ) throws -> Shot {
        try Shot(id: id, section: "verse", timeStart: start, timeEnd: start + 4, durationS: 4,
                 type: .performance, description: "d", visualPrompt: "p", mood: "m",
                 cameraSetup: camera, chainWithPreviousEnd: chained)
    }

    static func shotlist(_ shots: [Shot]) throws -> Shotlist {
        try Shotlist(
            schema_: shotlistSchemaVersion, mode: .beat, project: "p",
            song: try Song(title: "t", audioPath: "audio/s.wav", analysisPath: "analysis/s.json",
                           bpm: 120, tempoMultiplier: 1, durationS: 180),
            generated: "t", generator: "g", shots: shots)
    }

    static func ctx(_ shots: [Shot], root: URL) throws -> AuditContext {
        AuditContext(shotlist: try shotlist(shots), extra: ["data_root": root.path])
    }

    static let camera = CameraSetup(height: .low, angle: .threeQuarterLeft, lensHint: .wide)

    // MARK: - CHAIN_START_FRAME_IGNORED (#196 chain start frame not used)

    /// s002 chains off s001; s001's extracted last frame is recorded. `startFramePath` is what the
    /// render was really conditioned on. The phase name is deliberately a real one the agent uses —
    /// the check discovers phases from disk rather than assuming any fixed name.
    static func chainManifest(startFrame: String?, root: URL, phase: String = "videos_final") throws {
        var m = RenderManifest(project: "p", phase: phase)
        m.entries["s001"] = RenderEntry(
            shotId: "s001", phase: phase, status: .rendered, output: "s001.mp4",
            lastFramePath: "media/s001.last_frame.png")
        m.entries["s002"] = RenderEntry(
            shotId: "s002", phase: phase, status: .rendered, output: "s002.mp4",
            startFramePath: startFrame, referencePaths: [])
        try saveRenderManifest(m, dataRoot: root)
    }

    @Test("phases are discovered from disk, so a manifest under any phase name is audited")
    func discoversAnyPhaseName() throws {
        let root = Self.tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try Self.chainManifest(startFrame: "frames/s002/start.png", root: root, phase: "videos_preview")
        let findings = try MusicvideoChecks.planAdherenceCheck(try Self.ctx([
            try Self.shot("s001", at: 0),
            try Self.shot("s002", at: 4, chained: true),
        ], root: root))
        #expect(findings.contains { $0.code == "CHAIN_START_FRAME_IGNORED" })
    }

    @Test("flags a chained shot that started on something other than its predecessor's last frame")
    func chainIgnored() throws {
        let root = Self.tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try Self.chainManifest(startFrame: "frames/s002/start.png", root: root)
        let findings = try MusicvideoChecks.planAdherenceCheck(try Self.ctx([
            try Self.shot("s001", at: 0),
            try Self.shot("s002", at: 4, chained: true),
        ], root: root))
        #expect(findings.contains { $0.code == "CHAIN_START_FRAME_IGNORED" && $0.shotId == "s002" })
    }

    @Test("passes a chained shot that started on the predecessor's extracted last frame")
    func chainHonored() throws {
        let root = Self.tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try Self.chainManifest(startFrame: "media/s001.last_frame.png", root: root)
        let findings = try MusicvideoChecks.planAdherenceCheck(try Self.ctx([
            try Self.shot("s001", at: 0),
            try Self.shot("s002", at: 4, chained: true),
        ], root: root))
        #expect(!findings.contains { $0.code == "CHAIN_START_FRAME_IGNORED" })
    }

    @Test("path matching is component-anchored: a similarly-named file is not accepted as the frame")
    func pathMatchingIsComponentAnchored() throws {
        let root = Self.tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        // A byte-level hasSuffix would call this a match ("xs001.last_frame.png".hasSuffix("s001…")),
        // silently accepting a different file and hiding a real chain break.
        try Self.chainManifest(startFrame: "media/xs001.last_frame.png", root: root)
        let findings = try MusicvideoChecks.planAdherenceCheck(try Self.ctx([
            try Self.shot("s001", at: 0),
            try Self.shot("s002", at: 4, chained: true),
        ], root: root))
        #expect(findings.contains { $0.code == "CHAIN_START_FRAME_IGNORED" })
    }

    @Test("the same file in different coordinate systems still matches")
    func differentCoordinateSystemsMatch() throws {
        let root = Self.tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        // Recorded paths are project-home-relative, planned/extracted ones may carry a prefix.
        try Self.chainManifest(startFrame: "pipeline/media/s001.last_frame.png", root: root)
        let findings = try MusicvideoChecks.planAdherenceCheck(try Self.ctx([
            try Self.shot("s001", at: 0),
            try Self.shot("s002", at: 4, chained: true),
        ], root: root))
        #expect(!findings.contains { $0.code == "CHAIN_START_FRAME_IGNORED" })
    }

    @Test("a render recorded before the audit fields existed is unknown, not a violation")
    func nilStartFrameIsUnknown() throws {
        let root = Self.tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try Self.chainManifest(startFrame: nil, root: root)
        let findings = try MusicvideoChecks.planAdherenceCheck(try Self.ctx([
            try Self.shot("s001", at: 0),
            try Self.shot("s002", at: 4, chained: true),
        ], root: root))
        #expect(findings.isEmpty)
    }

    // MARK: - Degradation

    @Test("degrades to no findings with no data root and with no manifests")
    func degradesCleanly() throws {
        let root = Self.tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let shots = [try Self.shot("s001", at: 0, camera: Self.camera)]
        #expect(try MusicvideoChecks.planAdherenceCheck(try Self.ctx(shots, root: root)).isEmpty)
        #expect(try MusicvideoChecks.planAdherenceCheck(
            AuditContext(shotlist: try Self.shotlist(shots))).isEmpty)
    }

    @Test("the check is registered on the pack under plan_adherence")
    func registered() {
        let registry = EngineRegistry()
        MusicvideoPack().register(registry)
        #expect(registry.sanityChecks["plan_adherence"] != nil)
    }
}
