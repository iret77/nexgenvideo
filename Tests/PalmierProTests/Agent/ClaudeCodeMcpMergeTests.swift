import Testing
import Foundation
@testable import PalmierPro

// Gap A: a plugin's own MCP server (e.g. musicvideo's stdio server) must be merged into the inline
// --mcp-config so it survives --strict-mcp-config alongside `nexgen`. These lock in that merge.

@Suite("ClaudeCodeLaunch — MCP config merge")
struct ClaudeCodeMcpMergeTests {
    private func parse(_ json: String) throws -> [String: Any] {
        try #require((try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any])
    }

    @Test func emptyPluginServersIsNexgenOnly() throws {
        let root = try parse(ClaudeCodeLaunch.mcpConfigJSON(port: 19789))
        let servers = try #require(root["mcpServers"] as? [String: Any])
        #expect(servers.count == 1)
        let nexgen = try #require(servers["nexgen"] as? [String: Any])
        #expect(nexgen["type"] as? String == "http")
        #expect(nexgen["url"] as? String == "http://127.0.0.1:19789/mcp")
    }

    @Test func mergesPluginStdioServer() throws {
        let json = ClaudeCodeLaunch.mcpConfigJSON(
            port: 19789,
            pluginServers: ["musicvideo": #"{"command":"/p/scripts/mv-mcp-launch.sh","args":[]}"#]
        )
        let servers = try #require(try parse(json)["mcpServers"] as? [String: Any])
        #expect(servers["nexgen"] != nil)
        let mv = try #require(servers["musicvideo"] as? [String: Any])
        #expect(mv["command"] as? String == "/p/scripts/mv-mcp-launch.sh")
        #expect((mv["args"] as? [Any])?.count == 0)
    }

    @Test func argumentsCarryMergedConfig() throws {
        let cfg = ClaudeCodeLaunchConfig(
            workingDirectory: URL(fileURLWithPath: "/tmp/proj"),
            pluginMcpServers: ["musicvideo": #"{"command":"/p/run.sh","args":[]}"#]
        )
        let args = ClaudeCodeLaunch.arguments(cfg)
        let idx = try #require(args.firstIndex(of: "--mcp-config"))
        let servers = try #require(try parse(args[idx + 1])["mcpServers"] as? [String: Any])
        #expect(servers["nexgen"] != nil)
        #expect(servers["musicvideo"] != nil)
        // The merged config must still be paired with --strict-mcp-config.
        #expect(args.contains("--strict-mcp-config"))
    }
}
