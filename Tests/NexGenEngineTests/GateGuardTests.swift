import Foundation
import Testing
@testable import NexGenEngine
@testable import MusicvideoPlugin

/// Deterministic hard-gate enforcement: the port of the predecessor's require-chain that physically
/// stops the agent from advancing a phase whose real artifact (measured beats/downbeats) is missing.
@Suite("Hard gates")
struct GateGuardTests {
    private func tempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("audio"), withIntermediateDirectories: true)
        try Data("stub".utf8).write(to: root.appendingPathComponent("audio").appendingPathComponent("song.wav"))
        return root
    }

    private func writeAnalysis(_ root: URL, beats: [Double], downbeats: [Double], duration: Double) throws {
        let dir = root.appendingPathComponent("analysis")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let obj: [String: Any] = ["beats": beats, "downbeats": downbeats, "duration_s": duration]
        try JSONSerialization.data(withJSONObject: obj).write(to: dir.appendingPathComponent("song.json"))
    }

    @Test("analysis gate is blocked without real rhythm data, allowed with it")
    func analysisRequirement() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // No artifact → blocked.
        #expect(throws: GateBlocked.self) { try MusicvideoGateChecks.requireRealAnalysis(dataRoot: root) }

        // Degenerate artifact (no beats/downbeats) → blocked.
        try writeAnalysis(root, beats: [], downbeats: [], duration: 0)
        #expect(throws: GateBlocked.self) { try MusicvideoGateChecks.requireRealAnalysis(dataRoot: root) }

        // Real measured data → passes.
        try writeAnalysis(root, beats: [0.5, 1.0, 1.5], downbeats: [0.5, 2.5], duration: 12.0)
        try MusicvideoGateChecks.requireRealAnalysis(dataRoot: root)
    }

    @Test("musicvideo registers a hard-gate requirement for analysis only")
    func requirementRegistered() {
        PackCatalog.register(MusicvideoPack())
        let registry = PackCatalog.registry(activePack: "musicvideo")
        #expect(registry.gateRequirements["analysis"] != nil)
        #expect(registry.gateRequirements["brief"] == nil)
    }

    @Test("checkApprovable passes with no requirement and rethrows a blocked one")
    func checkApprovable() throws {
        let root = FileManager.default.temporaryDirectory
        try GateGuard.checkApprovable(phase: "brief", dataRoot: root, requirement: nil)
        #expect(throws: GateBlocked.self) {
            try GateGuard.checkApprovable(phase: "analysis", dataRoot: root, requirement: { _ in throw GateBlocked("nope") })
        }
    }

    @Test("requireChain blocks until every upstream gate is approved")
    func requireChainBlocks() throws {
        var gates = Gates(project: "p")
        GatesOperations.approve(&gates, phase: "project_init")
        #expect(throws: GateBlocked.self) {
            try GateGuard.requireChain(gates, order: coreGatePhases, through: "brief")
        }
        GatesOperations.approve(&gates, phase: "brief")
        try GateGuard.requireChain(gates, order: coreGatePhases, through: "brief")
    }
}
