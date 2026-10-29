import Foundation
import NexGenEngine
import Testing
@testable import NexGenVideo

struct ProductionWorkflowInitializationTests {
    @Test func legacyFallbackCannotHideContentInsideTheListedPlaceholderDirectory() throws {
        let home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let root = try ProjectScaffold.initProject(home: home, name: "Retained production", mode: .generic)
        try ProjectPluginSettings.setProductionContract(.current, projectURL: home)
        let placeholder = root.appendingPathComponent("shotlist/.gitkeep")
        try FileManager.default.moveItem(at: placeholder, to: home.appendingPathComponent("scaffold-placeholder"))
        try FileManager.default.createDirectory(at: placeholder, withIntermediateDirectories: true)
        let retained = Data("retained creative content".utf8)
        let artifact = placeholder.appendingPathComponent("retained.json")
        try retained.write(to: artifact)
        let fallback = home.appendingPathComponent("shotlist/.gitkeep")
        try FileManager.default.createDirectory(at: fallback.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: fallback)
        let gateURL = root.appendingPathComponent(PipelineLayout.gatesFile)
        let gates = try Data(contentsOf: gateURL)
        #expect(throws: GateBlocked.self) {
            try PhaseContractRuntime.initializeWorkflowState(dataRoot: root, workflow: HostWorkflowKey.core(.current))
        }
        #expect(try Data(contentsOf: gateURL) == gates)
        #expect(try Data(contentsOf: artifact) == retained)
        #expect(try Data(contentsOf: fallback).isEmpty)
    }
    @Test func actualScaffoldInitializesNewProductionWithItsEmptyPlaceholders() throws {
        let home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let root = try ProjectScaffold.initProject(home: home, name: "New production", mode: .generic)
        try ProjectPluginSettings.setProductionContract(.current, projectURL: home)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("shotlist").path) == [".gitkeep"])
        try PhaseContractRuntime.initializeWorkflowState(dataRoot: root, workflow: HostWorkflowKey.core(.current))
        let gates = try YAMLArtifactStore(dataRoot: root).load(Gates.self, at: PipelineLayout.gatesFile)
        #expect(Set(gates.gates.keys) == Set(["project_init", "brief", "production_design", "treatment", "script",
            "storyboard", "shot_planning", "bible", "shotlist", "sanity", "frames", "render_review", "render"]))
        #expect(gates.gates.values.allSatisfy { !$0.approved && $0.notes == nil })
        #expect(try Data(contentsOf: root.appendingPathComponent("shotlist/.gitkeep")).isEmpty)
        let gateBytes = try Data(contentsOf: root.appendingPathComponent(PipelineLayout.gatesFile))
        let namespaceURL = root.appendingPathComponent(ProductionWorkflowRecoveryMigration.OutputNamespace.relativePath)
        let namespaceBytes = try Data(contentsOf: namespaceURL)
        try PhaseContractRuntime.initializeWorkflowStateIfNeeded(dataRoot: root, workflow: HostWorkflowKey.core(.current))
        #expect(try Data(contentsOf: root.appendingPathComponent(PipelineLayout.gatesFile)) == gateBytes)
        #expect(try Data(contentsOf: namespaceURL) == namespaceBytes)
    }

    @Test func incompleteScaffoldRetriesAndFailedNamespaceRollsBackGateReplacement() throws {
        let home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let root = try ProjectScaffold.initProject(home: home, name: "Interrupted production", mode: .generic)
        try ProjectPluginSettings.setProductionContract(.current, projectURL: home)
        let gateURL = root.appendingPathComponent(PipelineLayout.gatesFile)
        let gates = try Data(contentsOf: gateURL)
        let path = ProductionWorkflowRecoveryMigration.OutputNamespace.relativePath
        let namespaceURL = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: namespaceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let invalid = Data("invalid namespace".utf8)
        try invalid.write(to: namespaceURL)
        #expect(throws: (any Error).self) {
            try PhaseContractRuntime.initializeWorkflowStateIfNeeded(dataRoot: root, workflow: HostWorkflowKey.core(.current))
        }
        #expect(try Data(contentsOf: gateURL) == gates)
        #expect(try Data(contentsOf: namespaceURL) == invalid)
        try FileManager.default.moveItem(at: namespaceURL, to: home.appendingPathComponent("rejected-namespace"))
        try PhaseContractRuntime.initializeWorkflowStateIfNeeded(dataRoot: root, workflow: HostWorkflowKey.core(.current))
        try PhaseContractRuntime.requireInitializedWorkflowState(dataRoot: root, workflow: HostWorkflowKey.core(.current))
        #expect(try Data(contentsOf: gateURL) != gates)
    }

    @Test(arguments: ["shotlist.v1.json", ".gitkeep", ".retained-shot.json"])
    func existingShotContentCannotBeDiscardedDuringInitialization(name: String) throws {
        let home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let root = try ProjectScaffold.initProject(home: home, name: "Existing production", mode: .generic)
        try ProjectPluginSettings.setProductionContract(.current, projectURL: home)
        let retained = Data("retained creative content".utf8)
        let artifact = root.appendingPathComponent("shotlist/" + name)
        try retained.write(to: artifact)
        let gateURL = root.appendingPathComponent(PipelineLayout.gatesFile)
        let originalGates = try Data(contentsOf: gateURL)
        do {
            try PhaseContractRuntime.initializeWorkflowState(dataRoot: root, workflow: HostWorkflowKey.core(.current))
            Issue.record("Existing creative content bypassed the explicit Recovery-copy upgrade")
        } catch let error as GateBlocked {
            #expect(error.message == "Existing creative artifacts require an explicit Recovery-copy upgrade.")
        }
        #expect(try Data(contentsOf: gateURL) == originalGates)
        #expect(try Data(contentsOf: artifact) == retained)
    }
    @Test @MainActor func actualTrustedStartPublishesOnlyItsWorkingCopyAndCanBeAwaited() async throws {
        let home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString + ".ngv")
        try Fixtures.prepareProjectPackage(at: home)
        defer { try? FileManager.default.removeItem(at: home) }
        try ProjectPluginSettings.setProductionContract(.current, projectURL: home)
        let editor = EditorViewModel(agentService: AgentService(backend: .claudeCode, refreshBackendStatusOnInit: false,
            runtimeReadinessOverride: { .upstream("The startup unit fixture does not launch an agent runtime.") }))
        editor.projectURL = home
        defer { editor.releaseWorkingCopy() }
        let working = try #require(editor.workingRoot)
        #expect(editor.declaredProductionContract == .current)
        #expect(DataRootResolver.dataRoot(of: working) == nil)
        editor.startProduction()
        await editor.waitForProductionStartup()
        let root = try #require(DataRootResolver.dataRoot(of: working))
        try PhaseContractRuntime.requireInitializedWorkflowState(dataRoot: root, workflow: HostWorkflowKey.core(.current))
        #expect(!editor.productionStarting)
        #expect(editor.pipelinePhaseRunCoordinator.runningPhase(projectRoot: root) == nil)
        #expect(DataRootResolver.dataRoot(of: home) == nil)
    }

    @Test @MainActor func closeAfterActualStartupPreparationCannotPublishOrRecreateTheWorkingCopy() async throws {
        let home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString + ".ngv")
        try Fixtures.prepareProjectPackage(at: home)
        defer { try? FileManager.default.removeItem(at: home) }
        try ProjectPluginSettings.setProductionContract(.current, projectURL: home)
        let editor = EditorViewModel(agentService: AgentService(backend: .claudeCode, refreshBackendStatusOnInit: false,
            runtimeReadinessOverride: { .upstream("The startup unit fixture does not launch an agent runtime.") }))
        editor.projectURL = home
        defer { editor.releaseWorkingCopy() }
        let working = try #require(editor.workingRoot)
        var reachedPreparation = false
        editor.productionStartupPreparationBarrier = {
            reachedPreparation = true
            try await Task.sleep(for: .seconds(30))
        }
        editor.startProduction()
        for _ in 0..<2000 where !reachedPreparation { try await Task.sleep(for: .milliseconds(5)) }
        try #require(reachedPreparation)
        #expect(DataRootResolver.dataRoot(of: working) == nil)
        editor.releaseWorkingCopy()
        let close = try #require(editor.cancelProductionStartupForClose())
        await close.value
        #expect(editor.workingRoot == nil)
        #expect(!editor.productionStarting)
        #expect(DataRootResolver.dataRoot(of: working) == nil)
        #expect(DataRootResolver.dataRoot(of: home) == nil)
    }

    @Test @MainActor func sourceEditAtTheFinalStartupBoundaryRefusesThePreparedScaffold() async throws {
        let home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString + ".ngv")
        try Fixtures.prepareProjectPackage(at: home)
        defer { try? FileManager.default.removeItem(at: home) }
        try ProjectPluginSettings.setProductionContract(.current, projectURL: home)
        let editor = EditorViewModel(agentService: AgentService(backend: .claudeCode, refreshBackendStatusOnInit: false,
            runtimeReadinessOverride: { .upstream("The startup unit fixture does not launch an agent runtime.") }))
        editor.projectURL = home
        defer { editor.releaseWorkingCopy() }
        let working = try #require(editor.workingRoot)
        let declarationURL = working.appendingPathComponent("ngv.json")
        let original = try Data(contentsOf: declarationURL)
        defer { try? original.write(to: declarationURL, options: .atomic) }
        var reachedPreparation = false
        editor.productionStartupPreparationBarrier = {
            reachedPreparation = true
            var json = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
            json["startupFixtureChange"] = true
            try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: declarationURL, options: .atomic)
        }
        editor.startProduction()
        await editor.waitForProductionStartup()
        #expect(reachedPreparation)
        #expect(!editor.productionStarting)
        #expect(editor.mediaPanelToast != nil)
        #expect(DataRootResolver.dataRoot(of: working) == nil)
        #expect(!FileManager.default.fileExists(atPath: working.appendingPathComponent("pipeline/" + ProductionWorkflowRecoveryMigration.OutputNamespace.relativePath).path))
        #expect(try Data(contentsOf: declarationURL) != original)
    }

    @Test @MainActor func reopeningTheSameProjectCannotAdoptItsPreviousSessionsPreparedStart() async throws {
        let home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString + ".ngv")
        try Fixtures.prepareProjectPackage(at: home)
        defer { try? FileManager.default.removeItem(at: home) }
        try ProjectPluginSettings.setProductionContract(.current, projectURL: home)
        let editor = EditorViewModel(agentService: AgentService(backend: .claudeCode, refreshBackendStatusOnInit: false,
            runtimeReadinessOverride: { .upstream("The startup unit fixture does not launch an agent runtime.") }))
        editor.projectURL = home
        defer { editor.releaseWorkingCopy() }
        let generation = try #require(editor.openWorkingCopyGeneration)
        var reachedPreparation = false
        editor.productionStartupPreparationBarrier = {
            reachedPreparation = true
            editor.releaseWorkingCopy()
            editor.projectURL = nil
            editor.projectURL = home
        }
        editor.startProduction()
        await editor.waitForProductionStartup()
        #expect(reachedPreparation)
        #expect(editor.openWorkingCopyGeneration != generation)
        let reopened = try #require(editor.workingRoot)
        #expect(DataRootResolver.dataRoot(of: reopened) == nil)
        #expect(DataRootResolver.dataRoot(of: home) == nil)
    }

}
