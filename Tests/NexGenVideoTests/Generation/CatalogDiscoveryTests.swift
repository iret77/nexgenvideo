import MCP
import Testing

@testable import NexGenVideo

@Suite("Catalog discovery coordinator")
struct CatalogDiscoveryTests {
    actor StubClient: MCPCatalogClient {
        let tools: [MCPProviderClient.DiscoveredTool]
        let listing: String
        private var calls: [String] = []
        private var didDisconnect = false

        init(tools: [MCPProviderClient.DiscoveredTool], listing: String) {
            self.tools = tools
            self.listing = listing
        }

        func discoverTools() async throws -> [MCPProviderClient.DiscoveredTool] {
            tools
        }

        func callTool(name: String, arguments: [String: Value]) async throws -> [String] {
            calls.append(name)
            guard name == "models_explore" else {
                throw MCPProviderClient.ClientError.toolFailed("Unexpected call to \(name)")
            }
            return [listing]
        }

        func disconnect() async {
            didDisconnect = true
        }

        func snapshot() -> (calls: [String], disconnected: Bool) {
            (calls, didDisconnect)
        }
    }

    @MainActor
    @Test("Higgsfield catalog works without a separate job-status tool")
    func higgsfieldSynchronousMCPModelsRemainAvailable() async throws {
        let generationSchema: Value = .object([
            "properties": .object([
                "params": .object([
                    "properties": .object([
                        "model": .object(["type": .string("string")]),
                        "prompt": .object(["type": .string("string")]),
                    ]),
                    "required": .array([.string("model"), .string("prompt")]),
                ]),
            ]),
            "required": .array([.string("params")]),
        ])
        let tools = [
            MCPProviderClient.DiscoveredTool(
                name: "generate_image",
                description: "Generate an image.",
                inputSchema: generationSchema
            ),
            MCPProviderClient.DiscoveredTool(
                name: "models_explore",
                description: "Find generation models.",
                inputSchema: .object([:])
            ),
        ]
        let listing = #"""
        {"items":[
          {"id":"nano_banana_pro","name":"Nano Banana Pro","output_type":"image","aspect_ratios":["1:1","16:9"]},
          {"id":"gpt_image_2","name":"GPT Image 2","output_type":"image","aspect_ratios":["1:1","16:9"]}
        ],"has_more":false}
        """#
        let client = StubClient(tools: tools, listing: listing)

        let entries = await CatalogDiscovery.discover(.higgsfield, client: client)
        let snapshot = await client.snapshot()

        #expect(Set(entries.map(\.displayName)) == ["Nano Banana Pro", "GPT Image 2"])
        #expect(entries.allSatisfy { $0.kind == .image })
        #expect(entries.allSatisfy { entry in
            entry.offers == [ProviderOffer(
                provider: .higgsfield,
                transport: .mcp,
                providerRef: "generate_image",
                modelParam: entry.id,
                mcpMediaRoles: []
            )]
        })
        #expect(snapshot.calls == ["models_explore"])
        #expect(snapshot.disconnected)
    }

    @MainActor
    @Test("An advertised but unmappable lifecycle remains fail-closed")
    func malformedLifecycleIsNotCataloged() async {
        let tools = [
            MCPProviderClient.DiscoveredTool(
                name: "generate_image",
                description: "Generate an image.",
                inputSchema: .object([:])
            ),
            MCPProviderClient.DiscoveredTool(
                name: "job_status",
                description: "Check generation job status.",
                inputSchema: .object([
                    "properties": .object([
                        "tenant_id": .object(["type": .string("string")]),
                    ]),
                    "required": .array([.string("tenant_id")]),
                ])
            ),
            MCPProviderClient.DiscoveredTool(
                name: "models_explore",
                description: "Find generation models.",
                inputSchema: .object([:])
            ),
        ]
        let client = StubClient(
            tools: tools,
            listing: #"{"items":[{"id":"must_not_surface","output_type":"image"}]}"#
        )

        let entries = await CatalogDiscovery.discover(.higgsfield, client: client)
        let snapshot = await client.snapshot()

        #expect(entries.isEmpty)
        #expect(snapshot.calls.isEmpty)
        #expect(snapshot.disconnected)
    }
}
