import Foundation
import Testing
@testable import NexGenVideo

@Suite("ClaudeCodeLaunch")
struct ClaudeCodeLaunchTests {

    private func valueAfter(_ flag: String, _ args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    @Test func mcpConfigJSONShape() {
        #expect(ClaudeCodeLaunch.mcpConfigJSON(port: 19789) ==
            #"{"mcpServers":{"nexgen":{"type":"http","url":"http://127.0.0.1:19789/mcp"}}}"#)
    }

    @Test("#201: claude -p gets the FULL manual as --append-system-prompt (parity with the API agent)")
    func fullManualAppended() {
        // The runtime passes AgentInstructions.serverInstructions; verify that IS the full manual and
        // still carries the presentation contract, so nothing is lost by switching off presentationContract.
        let manual = AgentInstructions.serverInstructions
        #expect(manual.contains(AgentInstructions.presentationContract))
        #expect(manual.count > AgentInstructions.presentationContract.count * 2)
        // And the args builder emits it verbatim.
        let cfg = ClaudeCodeLaunchConfig(workingDirectory: URL(fileURLWithPath: "/tmp/proj"), appendSystemPrompt: manual)
        #expect(valueAfter("--append-system-prompt", ClaudeCodeLaunch.arguments(cfg)) == manual)
    }

    @Test func coreFlagsArePresent() {
        let cfg = ClaudeCodeLaunchConfig(workingDirectory: URL(fileURLWithPath: "/tmp/proj"))
        let args = ClaudeCodeLaunch.arguments(cfg)
        #expect(args.contains("-p"))
        #expect(valueAfter("--input-format", args) == "stream-json")
        #expect(valueAfter("--output-format", args) == "stream-json")
        #expect(args.contains("--verbose"))   // required by --print + stream-json, else claude exits silently
        #expect(args.contains("--strict-mcp-config"))
        #expect(valueAfter("--permission-mode", args) == "bypassPermissions")
        #expect(valueAfter("--tools", args) == "Read")
        #expect(valueAfter("--setting-sources", args) == "project,local")
        #expect(valueAfter("--add-dir", args) == "/tmp/proj")
        #expect(valueAfter("--mcp-config", args)?.contains("19789") == true)
    }

    @Test func settingSourcesRemainConfigurable() {
        let cfg = ClaudeCodeLaunchConfig(
            workingDirectory: URL(fileURLWithPath: "/tmp/proj"),
            settingSources: "user,project,local"
        )
        let args = ClaudeCodeLaunch.arguments(cfg)
        #expect(valueAfter("--permission-mode", args) == "bypassPermissions")
        #expect(valueAfter("--tools", args) == "Read")
        #expect(valueAfter("--setting-sources", args) == "user,project,local")
    }

    @Test func settingSourcesOmittedWhenEmpty() {
        let cfg = ClaudeCodeLaunchConfig(workingDirectory: URL(fileURLWithPath: "/tmp/proj"), settingSources: "")
        #expect(!ClaudeCodeLaunch.arguments(cfg).contains("--setting-sources"))
    }

    @Test func pluginDirectoriesAppendedInOrder() {
        let cfg = ClaudeCodeLaunchConfig(
            workingDirectory: URL(fileURLWithPath: "/tmp/proj"),
            pluginDirectories: [URL(fileURLWithPath: "/core"), URL(fileURLWithPath: "/musicvideo")]
        )
        let args = ClaudeCodeLaunch.arguments(cfg)
        let pluginValues = args.indices.filter { args[$0] == "--plugin-dir" }.map { args[$0 + 1] }
        #expect(pluginValues == ["/core", "/musicvideo"])
    }

    @Test func allowedToolsJoinedWhenPresent() {
        let cfg = ClaudeCodeLaunchConfig(
            workingDirectory: URL(fileURLWithPath: "/tmp/proj"),
            allowedTools: ["mcp__nexgen", "mcp__plugin:musicvideo:musicvideo"]
        )
        let args = ClaudeCodeLaunch.arguments(cfg)
        #expect(valueAfter("--allowedTools", args) == "mcp__nexgen mcp__plugin:musicvideo:musicvideo")
    }

    @Test func allowedToolsOmittedWhenEmpty() {
        let cfg = ClaudeCodeLaunchConfig(workingDirectory: URL(fileURLWithPath: "/tmp/proj"))
        #expect(!ClaudeCodeLaunch.arguments(cfg).contains("--allowedTools"))
    }

    @Test func resumeTakesPrecedenceOverSessionId() {
        let cfg = ClaudeCodeLaunchConfig(
            workingDirectory: URL(fileURLWithPath: "/tmp/proj"),
            sessionId: "new-uuid",
            resumeSessionId: "old-uuid"
        )
        let args = ClaudeCodeLaunch.arguments(cfg)
        #expect(valueAfter("--resume", args) == "old-uuid")
        #expect(!args.contains("--session-id"))
    }

    @Test func sessionIdUsedWhenNoResume() {
        let cfg = ClaudeCodeLaunchConfig(
            workingDirectory: URL(fileURLWithPath: "/tmp/proj"),
            sessionId: "new-uuid"
        )
        let args = ClaudeCodeLaunch.arguments(cfg)
        #expect(valueAfter("--session-id", args) == "new-uuid")
        #expect(!args.contains("--resume"))
    }

    @Test func userMessageLineRoundTrips() {
        let line = ClaudeCodeLaunch.userMessageLine("place the clip at frame 0")
        let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8), options: [])) as? [String: Any]
        #expect(obj?["type"] as? String == "user")
        let message = obj?["message"] as? [String: Any]
        let content = message?["content"] as? [[String: Any]]
        #expect(content?.first?["text"] as? String == "place the clip at frame 0")
    }

    @Test("an attached image rides along as an image block after the text — reaches the subprocess")
    func userMessageLineCarriesImageBlocks() {
        let image: [String: Any] = ["type": "image",
                                    "source": ["type": "base64", "media_type": "image/png", "data": "QUJD"]]
        let line = ClaudeCodeLaunch.userMessageLine("what is in this screenshot?", imageBlocks: [image])
        let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8), options: [])) as? [String: Any]
        let content = (obj?["message"] as? [String: Any])?["content"] as? [[String: Any]]
        #expect(content?.count == 2)
        #expect(content?.first?["text"] as? String == "what is in this screenshot?")
        #expect(content?.last?["type"] as? String == "image")
        let source = content?.last?["source"] as? [String: Any]
        #expect(source?["media_type"] as? String == "image/png")
        #expect(source?["data"] as? String == "QUJD")
    }
}

@Suite("ClaudeCodeLocator")
struct ClaudeCodeLocatorTests {

    @Test func candidatePathsPriorityOrder() {
        let paths = ClaudeCodeLocator.candidatePaths(home: "/Users/x", path: "/usr/bin:/bin")
        #expect(paths.first == "/Users/x/.claude/local/claude")
        #expect(paths.contains("/usr/bin/claude"))
        #expect(paths.contains("/bin/claude"))
        #expect(paths.contains("/opt/homebrew/bin/claude"))
        #expect(paths.contains("/usr/local/bin/claude"))
    }

    @Test func candidatePathsToleratesNilPath() {
        let paths = ClaudeCodeLocator.candidatePaths(home: "/Users/x", path: nil)
        #expect(paths.first == "/Users/x/.claude/local/claude")
        #expect(paths.contains("/opt/homebrew/bin/claude"))
    }

    @Test func parseVersionExtractsSemver() {
        #expect(ClaudeCodeLocator.parseVersion("2.1.191 (Claude Code)") == "2.1.191")
        #expect(ClaudeCodeLocator.parseVersion("  2.1.191\n") == "2.1.191")
        #expect(ClaudeCodeLocator.parseVersion("2.1") == "2.1")
    }

    @Test func parseVersionRejectsGarbage() {
        #expect(ClaudeCodeLocator.parseVersion("not a version") == nil)
        #expect(ClaudeCodeLocator.parseVersion("v2.1.0") == nil)
        #expect(ClaudeCodeLocator.parseVersion("") == nil)
    }

    @Test func locateExecutableFindsExecutableFile() throws {
        let dir = FileManager.default.temporaryDirectory
        let exe = dir.appendingPathComponent("claude-\(UUID().uuidString)")
        FileManager.default.createFile(
            atPath: exe.path,
            contents: Data("#!/bin/sh\n".utf8),
            attributes: [.posixPermissions: 0o755]
        )
        defer { try? FileManager.default.removeItem(at: exe) }

        let found = ClaudeCodeLocator.locateExecutable(candidates: ["/no/such/claude", exe.path])
        #expect(found?.path == exe.path)
    }

    @Test func locateExecutableReturnsNilWhenNoneExist() {
        #expect(ClaudeCodeLocator.locateExecutable(candidates: ["/no/such/claude"]) == nil)
    }
}

@Suite("Agent backend preference")
struct AgentBackendPreferenceTests {
    @Test func explicitPreferenceAndLegacyValueResolveDeterministically() throws {
        let suite = "AgentBackendPreferenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(AgentBackendPreference.selected(in: defaults) == .anthropicAPI)
        defaults.set(true, forKey: AgentBackendPreference.legacyKey)
        #expect(AgentBackendPreference.selected(in: defaults) == .claudeCode)
        defaults.set(AgentBackend.anthropicAPI.rawValue, forKey: AgentBackendPreference.key)
        #expect(AgentBackendPreference.selected(in: defaults) == .anthropicAPI)
    }
}
