import Darwin
import Foundation

enum AgentReviewChildCLIIsolation {
    struct Account: Decodable, Sendable {
        let loggedIn: Bool
        let authMethod: String
        let apiProvider: String
        let subscriptionType: String?
        let configDirectory: String?
    }

    @MainActor
    static func preflight(executable: URL, workingDirectory: URL) async throws {
        let account = try await accountStatus(executable: executable, workingDirectory: workingDirectory)
        let config = AgentReviewChildCLIRuntime.environmentForIsolation()["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        try requireConsumerAccount(account, configDirectory: config)
    }

    @MainActor
    static func accountStatus(executable: URL, workingDirectory: URL) async throws -> Account {
        let environment = AgentReviewChildCLIRuntime.environmentForIsolation()
        let expectedConfig = environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        try await Task.detached(priority: .userInitiated) {
            try requirePolicyAbsent(configDirectory: expectedConfig)
            guard try FileManager.default.contentsOfDirectory(atPath: workingDirectory.path).isEmpty else {
                throw ToolError("The isolated review directory is no longer empty.")
            }
        }.value
        let data = try await probe(executable: executable, arguments: ["--safe-mode", "--setting-sources", "",
            "--settings", "{\"disableAllHooks\":true}", "auth", "status", "--json"],
            directory: workingDirectory, environment: environment)
        let account: Account
        do { account = try JSONDecoder().decode(Account.self, from: data) }
        catch { throw ToolError("Claude Code did not return a verifiable account status for isolated review.") }
        try requireSubscriptionAccount(account, configDirectory: expectedConfig)
        try await Task.detached(priority: .userInitiated) {
            try requirePolicyAbsent(configDirectory: expectedConfig)
        }.value
        return account
    }

    static func requireConsumerAccount(_ account: Account, configDirectory: URL) throws {
        try requireSubscriptionAccount(account, configDirectory: configDirectory)
        guard let subscription = account.subscriptionType, ["pro", "max"].contains(subscription) else {
            throw ToolError("Isolated Claude Code review requires a verified Pro or Max account. Ordinary chat remains available.")
        }
    }

    static func requireSubscriptionAccount(_ account: Account, configDirectory: URL) throws {
        guard account.loggedIn, ["claude.ai", "oauth_token"].contains(account.authMethod), account.apiProvider == "firstParty",
              let subscription = account.subscriptionType, !subscription.isEmpty,
              let path = account.configDirectory,
              URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
                == configDirectory.standardizedFileURL.resolvingSymlinksInPath() else {
            throw ToolError("Claude Code could not verify subscription authentication for the isolated configuration.")
        }
    }

    static func requirePolicyAbsent(configDirectory: URL) throws {
        try requireAbsent(policyPaths(configDirectory: configDirectory))
    }

    static func policyPaths(configDirectory: URL) -> [URL] {
        let managed = URL(fileURLWithPath: "/Library/Application Support/ClaudeCode", isDirectory: true)
        let preferences = URL(fileURLWithPath: "/Library/Managed Preferences", isDirectory: true)
        return [managed.appendingPathComponent("managed-settings.json"),
            managed.appendingPathComponent("managed-settings.d"), managed.appendingPathComponent("managed-mcp.json"),
            preferences.appendingPathComponent("com.anthropic.claudecode.plist"),
            preferences.appendingPathComponent(NSUserName(), isDirectory: true).appendingPathComponent("com.anthropic.claudecode.plist"),
            configDirectory.appendingPathComponent("remote-settings.json")]
    }

    static func requireAbsent(_ paths: [URL]) throws {
        for path in paths {
            var info = stat()
            if lstat(path.path, &info) == 0 {
                throw ToolError("Isolated Claude Code review cannot verify hook-free execution while \(path.lastPathComponent) is present. Ordinary chat remains available; the policy has not been changed.")
            }
            guard errno == ENOENT else {
                throw ToolError("The Claude Code managed-policy location could not be checked. Isolated review has stopped; ordinary chat remains available.")
            }
        }
    }

    @MainActor
    private static func probe(executable: URL, arguments: [String], directory: URL,
                              environment: [String: String]) async throws -> Data {
        let process = ClaudeCodeProcess()
        let stream = try process.start(executableURL: executable, arguments: arguments,
            workingDirectory: directory, environment: environment)
        process.closeStdin()
        let reader = Task { @MainActor in
            var bytes = Data()
            for try await line in stream {
                try Task.checkCancellation()
                guard bytes.count + line.utf8.count < 65_536 else {
                    throw ToolError("Claude Code account status exceeded its diagnostic bound.")
                }
                bytes.append(contentsOf: line.utf8)
                bytes.append(10)
            }
            return bytes
        }
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            reader.cancel()
            await process.shutdownAndWait()
        }
        do {
            let bytes = try await withTaskCancellationHandler {
                try await reader.value
            } onCancel: { reader.cancel(); process.terminate() }
            deadline.cancel()
            await deadline.value
            await process.shutdownAndWait()
            try Task.checkCancellation()
            guard process.exitStatus == 0 else {
                throw ToolError("Claude Code account verification did not finish successfully.")
            }
            return bytes
        } catch {
            deadline.cancel()
            reader.cancel()
            await process.shutdownAndWait()
            await deadline.value
            throw error
        }
    }
}
