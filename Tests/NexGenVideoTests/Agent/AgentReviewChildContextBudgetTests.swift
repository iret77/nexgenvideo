import Foundation
import Testing
@testable import NexGenVideo

@Suite("Review context budgets and CLI policy")
struct AgentReviewChildContextBudgetTests {
    @Test func textIncludesSystemSchemaAndHistory() throws {
        let body: [String: Any] = ["system": "actual phase", "tools": [["name": "get", "description": "schema explanation"]],
            "messages": [["role": "assistant", "content": [["type": "text", "text": "earlier observation"]]]]]
        let bytes = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
        #expect(try AgentReviewChildContextBudget.estimateRequest(bytes) == bytes.count)
        var changed = body
        changed["system"] = String(repeating: "phase context ", count: 2000)
        #expect(try AgentReviewChildContextBudget.estimateRequest(JSONSerialization.data(withJSONObject: changed)) > bytes.count)
    }

    @Test func invalidImageCannotBecomeAZeroTokenInput() throws {
        let body: [String: Any] = ["content": [["type": "image", "data": "AA==", "mimeType": "image/png"]]]
        #expect(throws: (any Error).self) {
            try AgentReviewChildContextBudget.estimateRequest(JSONSerialization.data(withJSONObject: body))
        }
    }

    @Test func consumerAccountRequiresActualConfigDirectoryAndPlan() throws {
        let root = URL(fileURLWithPath: "/tmp/review-policy-fixture")
        let valid = AgentReviewChildCLIIsolation.Account(loggedIn: true, authMethod: "claude.ai",
            apiProvider: "firstParty", subscriptionType: "max", configDirectory: root.path)
        try AgentReviewChildCLIIsolation.requireConsumerAccount(valid, configDirectory: root)
        for plan in ["team", "enterprise", "unknown", ""] {
            let account = AgentReviewChildCLIIsolation.Account(loggedIn: true, authMethod: "claude.ai",
                apiProvider: "firstParty", subscriptionType: plan, configDirectory: root.path)
            #expect(throws: (any Error).self) {
                try AgentReviewChildCLIIsolation.requireConsumerAccount(account, configDirectory: root)
            }
        }
        #expect(throws: (any Error).self) {
            try AgentReviewChildCLIIsolation.requireConsumerAccount(valid,
                configDirectory: root.appendingPathComponent("another-account"))
        }
    }

    @Test func policyInventoryContainsDeviceAndUserMDMAndRemoteCache() {
        let root = URL(fileURLWithPath: "/tmp/review-policy-fixture")
        let paths = AgentReviewChildCLIIsolation.policyPaths(configDirectory: root)
        #expect(paths.count == 6)
        #expect(paths.filter { $0.lastPathComponent == "com.anthropic.claudecode.plist" }.count == 2)
        #expect(paths.contains(root.appendingPathComponent("remote-settings.json")))
        #expect(paths.contains { $0.lastPathComponent == "managed-settings.d" })
    }

    @Test func evenAnEmptyPolicySourceRefusesTheIsolatedPath() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.trashItem(at: directory, resultingItemURL: nil) }
        let path = directory.appendingPathComponent("managed-settings.json")
        try AgentReviewChildCLIIsolation.requireAbsent([path])
        try Data("{}".utf8).write(to: path)
        #expect(throws: (any Error).self) { try AgentReviewChildCLIIsolation.requireAbsent([path]) }
    }
}
