import Foundation
import NexGenEngine
import Testing
@testable import NexGenVideo

struct HostWorkflowKeyTests {
    @Test func crossedMusicvideoTuplesFailClosed() throws {
        let valid = try #require(ProjectPackBinding(id: "musicvideo", version: "0.6.0", projectSchema: "musicvideo/3.0.0"))
        let contract = resolved(version: "0.6.0", schema: "musicvideo/3.0.0", contractID: "musicvideo.pipeline.v2", engine: 12)
        #expect(try HostWorkflowKey.resolve(binding: valid, contract: contract).isProductionV2)
        for binding in [
            ProjectPackBinding(id: "musicvideo", version: "0.5.16", projectSchema: "musicvideo/3.0.0"),
            ProjectPackBinding(id: "musicvideo", version: "0.6.0", projectSchema: "musicvideo/2.0.0"),
        ].compactMap({ $0 }) {
            #expect(throws: (any Error).self) { try HostWorkflowKey.resolve(binding: binding, contract: contract) }
        }
        for bad in [
            resolved(version: "0.6.0", schema: "musicvideo/2.0.0", contractID: "musicvideo.pipeline.v2", engine: 12),
            resolved(version: "0.6.0", schema: "musicvideo/3.0.0", contractID: "musicvideo.pipeline.v1", engine: 12),
            resolved(version: "0.6.0", schema: "musicvideo/3.0.0", contractID: "musicvideo.pipeline.v2", engine: 11),
            resolved(version: "0.6.0", schema: "musicvideo/3.0.0", contractID: "musicvideo.pipeline.v2", engine: 10),
            resolved(version: "0.6.0", schema: "musicvideo/3.0.0", contractID: "musicvideo.pipeline.v2", engine: 13),
        ] {
            #expect(throws: (any Error).self) { try HostWorkflowKey.resolve(binding: valid, contract: bad) }
        }
    }

    @Test func legacyPinDoesNotAdoptNewWorkflowFromArtifacts() throws {
        let binding = try #require(ProjectPackBinding(id: "musicvideo", version: "0.5.16", projectSchema: "musicvideo/2.0.0"))
        let key = try HostWorkflowKey.resolve(binding: binding,
            contract: resolved(version: "0.5.16", schema: "musicvideo/2.0.0", contractID: "musicvideo.pipeline.v1", engine: 11))
        #expect(!key.isProductionV2)
        #expect(key.contractID == "musicvideo.pipeline.v1")
        #expect(key.packVersion == "0.5.16")
    }

    @Test func mutableCoreDeclarationCannotEnrollAnUnboundSession() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let root = try ProjectScaffold.initProject(home: home, name: "Workflow", mode: .generic)
        try ProjectPluginSettings.setProductionContract(.current, projectURL: home)
        #expect(throws: (any Error).self) {
            try PhaseContractRuntime.resolveWorkflow(dataRoot: root, expectedPack: nil, expectedProductionContract: nil)
        }
        let trusted = try #require(try PhaseContractRuntime.resolveWorkflow(dataRoot: root,
            expectedPack: nil, expectedProductionContract: .current))
        #expect(trusted.contractID == "core.production.v2")
        try ProjectPluginSettings.setProductionContract(nil, projectURL: home)
        #expect(throws: (any Error).self) {
            try PhaseContractRuntime.resolveWorkflow(dataRoot: root, expectedPack: nil, expectedProductionContract: .current)
        }
    }

    @Test func unconfirmedStoryFileCannotSatisfyV2Intake() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let root = try ProjectScaffold.initProject(home: home, name: "Workflow", mode: .generic)
        try Data("Unassigned library candidate".utf8).write(to: root.appendingPathComponent("import/script.md"))
        let manifest = try HardStepManifest.decode(Data(#"{"schema":"hardsteps/1.0","phases":[{"phase":"brief","steps":[{"id":"brief.script","attachAs":"script","required":false,"title":"Existing story","symbol":"doc","confirmLabel":"Use story"}]}]}"#.utf8))
        let steps = manifest.steps(for: "brief")
        #expect(steps.count == 1)
        #expect(IntakePlanner.next(steps, dataRoot: root, ledger: .init(), workflowID: "musicvideo.pipeline.v2")?.id == "brief.script")
        #expect(IntakePlanner.next(steps, dataRoot: root, ledger: .init(declined: ["brief.script"]), workflowID: "musicvideo.pipeline.v2")?.id == "brief.script")
    }

    private func resolved(version: String, schema: String, contractID: String, engine: Int) -> ResolvedPhaseContract {
        .init(packID: "musicvideo", packVersion: version, engineContract: engine, historicalCompatibility: false,
            manifest: .init(contractID: contractID, packID: "musicvideo", resourceRoot: "MusicvideoPack",
                hardStepsManifestID: "hardsteps/1.0", display: .init(title: "Music Video"), phases: []),
            hardSteps: .empty, resourceRoot: URL(fileURLWithPath: "/unused"), phases: [], projectSchema: schema)
    }
}
