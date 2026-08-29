import MCP
import Testing

@testable import NexGenVideo

@Suite("Catalog discovery coordinator")
struct CatalogDiscoveryTests {
    actor AsyncGate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }

        func open() {
            isOpen = true
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }
    }

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
    @Test("A slow provider does not delay another provider's catalog publication")
    func providerResultsPublishIndependently() async {
        let slowProvider = AsyncGate()
        let fastProviderPublished = AsyncGate()
        var published: [GenerationProvider] = []
        let run = Task { @MainActor in
            await CatalogDiscovery.forEachProviderResult(
                [.higgsfield, .fal],
                operation: { provider in
                    if provider == .higgsfield { await slowProvider.wait() }
                    return CatalogDiscovery.ProviderResult(
                        provider: provider,
                        mcpConfigured: false,
                        oauthConnected: false,
                        entries: []
                    )
                },
                consume: { result in
                    published.append(result.provider)
                    if result.provider == .fal {
                        Task { await fastProviderPublished.open() }
                    }
                }
            )
        }

        await fastProviderPublished.wait()
        #expect(published == [.fal])

        await slowProvider.open()
        await run.value
        #expect(published == [.fal, .higgsfield])
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
                "medias": .object([
                    "type": .string("array"),
                    "items": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "value": .object(["type": .string("string")]),
                            "role": .object(["type": .string("string")]),
                        ]),
                        "required": .array([.string("value"), .string("role")]),
                    ]),
                ]),
            ]),
            "required": .array([.string("params")]),
        ])
        let uploadSchema: Value = .object([
            "properties": .object([
                "filename": .object(["type": .string("string")]),
                "type": .object(["type": .string("string")]),
                "length": .object(["type": .string("integer")]),
                "content_type": .object(["type": .string("string")]),
            ]),
            "required": .array([
                .string("filename"), .string("type"), .string("length"),
                .string("content_type"),
            ]),
        ])
        let confirmSchema: Value = .object([
            "properties": .object([
                "media_id": .object(["type": .string("string")]),
                "type": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("media_id"), .string("type")]),
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
            MCPProviderClient.DiscoveredTool(
                name: "media_upload",
                description: "Create a media upload.",
                inputSchema: uploadSchema
            ),
            MCPProviderClient.DiscoveredTool(
                name: "media_confirm",
                description: "Confirm uploaded media.",
                inputSchema: confirmSchema
            ),
        ]
        let listing = #"""
        {"items":[
          {"id":"nano_banana_2","name":"Nano Banana Pro","output_type":"image","aspect_ratios":["1:1","16:9"],
           "medias":[{"name":"medias","type":"image","roles":["image_references"],"min":0,"max":14}]},
          {"id":"gpt_image_2","name":"GPT Image 2","output_type":"image","aspect_ratios":["1:1","16:9"],
           "medias":[{"name":"medias","type":"image","roles":["image_references"],"min":0,"max":16}]}
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
                mcpMediaRoles: ["image_references"]
            )]
        })
        for entry in entries {
            guard case .image(let caps) = entry.uiCapabilities else {
                Issue.record("Expected image capabilities")
                continue
            }
            #expect(caps.maxReferenceImages >= 14)
            let model = ImageModelConfig(entry: entry, caps: caps)
            #expect(model.validate(
                aspectRatio: "16:9",
                resolution: nil,
                quality: nil,
                imageRefCount: 4,
                numImages: 1
            ) == nil)
        }
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
