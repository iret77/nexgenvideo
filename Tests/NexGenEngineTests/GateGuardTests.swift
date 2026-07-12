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

    private func writeAnalysis(_ root: URL, beats: [Double], downbeats: [Double], duration: Double,
                              sectionLabels: [[String: String]] = []) throws {
        let dir = root.appendingPathComponent("analysis")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var obj: [String: Any] = ["beats": beats, "downbeats": downbeats, "duration_s": duration]
        if !sectionLabels.isEmpty { obj["interpretation"] = ["section_labels": sectionLabels] }
        try JSONSerialization.data(withJSONObject: obj).write(to: dir.appendingPathComponent("song.json"))
    }

    // MARK: - Fail-closed pack wiring (the triangle Engine↔Plugin↔Agent must be live)

    @Test("requireWiredPack: a generic project (no declared pack) is unaffected")
    func wiringGenericPasses() throws {
        try GateGuard.requireWiredPack(declared: nil, resolved: nil, registry: EngineRegistry())
    }

    @Test("requireWiredPack: a declared pack that didn't wire blocks EVERY approval (P0 fail-closed)")
    func wiringDeclaredButUnwiredBlocks() {
        // Package declares musicvideo but the runtime resolved nil / built an empty registry — no step
        // may be approved, or the pipeline would advance ungated masquerading as generic.
        #expect(throws: GateBlocked.self) {
            try GateGuard.requireWiredPack(declared: "musicvideo", resolved: nil, registry: EngineRegistry())
        }
        #expect(throws: GateBlocked.self) {
            try GateGuard.requireWiredPack(declared: "musicvideo", resolved: "musicvideo", registry: EngineRegistry())
        }
    }

    @Test("requireWiredPack: a genuinely wired pack passes")
    func wiringWiredPasses() throws {
        let registry = EngineRegistry()
        registry.registerWiringProbe { PackWiring.token(pack: "musicvideo", nonce: $0) }
        try GateGuard.requireWiredPack(declared: "musicvideo", resolved: "musicvideo", registry: registry)
    }

    @Test("analysis gate requires real rhythm data AND an A2 interpretation")
    func analysisRequirement() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // No artifact → blocked.
        #expect(throws: GateBlocked.self) { try MusicvideoGateChecks.requireRealAnalysis(dataRoot: root) }

        // Degenerate artifact (no beats/downbeats) → blocked.
        try writeAnalysis(root, beats: [], downbeats: [], duration: 0)
        #expect(throws: GateBlocked.self) { try MusicvideoGateChecks.requireRealAnalysis(dataRoot: root) }

        // Real rhythm data but NO interpretation yet (A2 not done) → still blocked.
        try writeAnalysis(root, beats: [0.5, 1.0, 1.5], downbeats: [0.5, 2.5], duration: 12.0)
        #expect(throws: GateBlocked.self) { try MusicvideoGateChecks.requireRealAnalysis(dataRoot: root) }

        // Measured + interpreted (section labels) → passes.
        try writeAnalysis(root, beats: [0.5, 1.0, 1.5], downbeats: [0.5, 2.5], duration: 12.0,
                          sectionLabels: [["index": "0", "label": "intro"]])
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

    @Test("requirePriorApproved enforces in-order approval")
    func priorApproved() throws {
        var gates = Gates(project: "p")
        // The first phase has no predecessors — always approvable.
        try GateGuard.requirePriorApproved(gates, order: coreGatePhases, phase: "project_init")
        // brief needs project_init first.
        #expect(throws: GateBlocked.self) {
            try GateGuard.requirePriorApproved(gates, order: coreGatePhases, phase: "brief")
        }
        GatesOperations.approve(&gates, phase: "project_init")
        try GateGuard.requirePriorApproved(gates, order: coreGatePhases, phase: "brief")
    }
}
