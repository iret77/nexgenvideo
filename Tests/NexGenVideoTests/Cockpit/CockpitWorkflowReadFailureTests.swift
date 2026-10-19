import Foundation
import NexGenEngine
import Testing
@testable import NexGenVideo

struct CockpitWorkflowReadFailureTests {
    @Test func unavailableWorkflowDoesNotBecomeAnEmptyBibleOrDecodeError() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        _ = try ProjectScaffold.initProject(home: home, name: "Unavailable workflow", mode: .generic)
        let binding = try #require(ProjectPackBinding(id: "missing-cockpit-test-pack", version: "1.0.0",
            projectSchema: "missing-cockpit-test-pack/1.0.0"))
        try ProjectPluginSettings.setActivePlugin(binding, projectURL: home)

        let result = await CockpitDataService.bible(projectDir: home)
        guard case .failure(.engine(let message)) = result else {
            Issue.record("An unavailable workflow must refuse the read as a workflow failure.")
            return
        }
        #expect(message.contains("Production workflow unavailable"))
        #expect(message.contains("reopen"))

        try Data("not JSON".utf8).write(to: home.appendingPathComponent(ProjectPluginSettings.filename))
        let corrupt = await CockpitDataService.bible(projectDir: home)
        guard case .failure(.engine(let corruptMessage)) = corrupt else {
            Issue.record("Unreadable project settings must not fall back to an empty Bible.")
            return
        }
        #expect(corruptMessage.contains("Production workflow unavailable"))
    }

    @Test func validEmptyCoreReadsStayEmptyAndTrustedDeclarationStillBlocksMismatch() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        _ = try ProjectScaffold.initProject(home: home, name: "Empty Core", mode: .generic)
        try ProjectPluginSettings.setProductionContract(.current, projectURL: home)

        let bible = try await CockpitDataService.bible(projectDir: home).get()
        #expect(bible == nil)
        let sanity = try await CockpitDataService.sanity(projectDir: home).get()
        #expect(sanity == nil)

        let unbound = ProjectPackGate.MutationDeclaration(packName: nil, binding: nil)
        let result = await CockpitDataService.contract(projectDir: home, declaration: unbound)
        guard case .failure(.engine(let mismatchMessage)) = result else {
            Issue.record("A mismatched trusted declaration must refuse the contract read.")
            return
        }
        #expect(mismatchMessage.contains("Production workflow unavailable"))
    }
}
