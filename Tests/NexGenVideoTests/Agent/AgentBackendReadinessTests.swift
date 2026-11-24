import Foundation
import Testing
@testable import NexGenVideo

@Suite("Agent backend readiness")
@MainActor
struct AgentBackendReadinessTests {
    @Test func claudeCodeSignInReportsReadinessOnce() {
        let service = AgentService(backend: .claudeCode, refreshBackendStatusOnInit: false,
                                   modelCatalogDefaults: AnthropicModelFixtures.isolatedDefaults())
        var ready = 0
        service.onBackendReady = { ready += 1 }
        service.applyClaudeCodeStatus(.init(executableURL: nil, version: "fixture", isAuthenticated: false))
        #expect(ready == 0)
        service.applyClaudeCodeStatus(.init(executableURL: nil, version: "fixture", isAuthenticated: true))
        #expect(ready == 1)
        service.applyClaudeCodeStatus(.init(executableURL: nil, version: "fixture", isAuthenticated: true))
        #expect(ready == 1)
        service.applyClaudeCodeStatus(.init(executableURL: nil, version: "fixture", isAuthenticated: false))
        service.applyClaudeCodeStatus(.init(executableURL: nil, version: "fixture", isAuthenticated: true))
        #expect(ready == 2)
    }

    @Test func loadedAPIKeyReportsReadiness() async throws {
        let service = AgentService(backend: .anthropicAPI, refreshBackendStatusOnInit: false,
                                   modelCatalogDefaults: AnthropicModelFixtures.isolatedDefaults(),
                                   modelDiscoveryTransport: { _ in throw URLError(.notConnectedToInternet) },
                                   apiKeyLoader: { "sk-ant-fixture" })
        var ready = 0
        service.onBackendReady = { ready += 1 }
        #expect(!service.canStream)
        service.reloadAPIKey()
        for _ in 0..<500 where ready == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(service.canStream)
        #expect(ready == 1)
    }

    @Test func editorRetriesItsWorkflowHandoffWhenTheBackendBecomesReady() {
        let service = AgentService(refreshBackendStatusOnInit: false, modelCatalogDefaults: AnthropicModelFixtures.isolatedDefaults())
        let editor = EditorViewModel(agentService: service)
        #expect(service.onBackendReady != nil)
        withExtendedLifetime(editor) {}
    }
}
