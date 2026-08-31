import Foundation
import MCP
import Testing

@testable import NexGenVideo

@Suite("Catalog discovery coordinator", .serialized)
struct CatalogDiscoveryTests {
    private var mappableHiggsfieldResultLifecycle: [MCPProviderClient.DiscoveredTool] {
        [
            MCPProviderClient.DiscoveredTool(
                name: "job_status",
                description: "Check a generation job.",
                inputSchema: .object([
                    "properties": .object([
                        "job_set_id": .object(["type": .string("string")]),
                    ]),
                    "required": .array([.string("job_set_id")]),
                ])
            ),
            MCPProviderClient.DiscoveredTool(
                name: "job_display",
                description: "Display completed generation output.",
                inputSchema: .object([
                    "properties": .object([
                        "ids": .object([
                            "type": .string("array"),
                            "items": .object(["type": .string("string")]),
                        ]),
                    ]),
                    "required": .array([.string("ids")]),
                ])
            ),
        ]
    }

    private var mappableHiggsfieldGenerationSchema: Value {
        .object([
            "properties": .object([
                "job_set_type": .object(["type": .string("string")]),
                "prompt": .object(["type": .string("string")]),
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
            "required": .array([.string("job_set_type"), .string("prompt")]),
        ])
    }

    private var mappableHiggsfieldMediaUpload: [MCPProviderClient.DiscoveredTool] {
        [
            MCPProviderClient.DiscoveredTool(
                name: "media_upload",
                description: "Create a media upload.",
                inputSchema: .object([
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
            ),
            MCPProviderClient.DiscoveredTool(
                name: "media_confirm",
                description: "Confirm uploaded media.",
                inputSchema: .object([
                    "properties": .object([
                        "media_id": .object(["type": .string("string")]),
                        "type": .object(["type": .string("string")]),
                    ]),
                    "required": .array([.string("media_id"), .string("type")]),
                ])
            ),
        ]
    }

    private func listingPage(
        _ range: Range<Int>,
        hasMore: Bool,
        cursor: String? = nil
    ) -> String {
        let items = range.map { #"{"id":"limit-\#($0)"}"# }.joined(separator: ",")
        let cursorField = cursor.map { ",\"next_page_token\":\"\($0)\"" } ?? ""
        return "{\"items\":[\(items)]\(cursorField),\"has_more\":\(hasMore)}"
    }

    @Test("Higgsfield job-set lifecycle proves an asynchronous media result path")
    func higgsfieldJobSetLifecycleProvesResultPath() {
        let generate = MCPProviderClient.DiscoveredTool(
            name: "generate_image",
            description: "Generate an image.",
            inputSchema: mappableHiggsfieldGenerationSchema
        )
        let tools = [generate] + mappableHiggsfieldResultLifecycle

        #expect(MCPGenerationExecutor.hasProvenResultPath(
            generationTool: generate,
            tools: tools
        ))
    }

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

    @MainActor
    @Test("Completed direct discovery replaces stale base image offers for every direct provider")
    func directImageDiscoveryReplacesBaseOffers() throws {
        let entry = CatalogEntry(
            id: "shared-image",
            kind: .image,
            displayName: "Shared image",
            allowedEndpoints: ["shared-image"],
            responseShape: .images,
            uiCapabilities: .image(ImageCaps(
                resolutions: nil,
                aspectRatios: ["1:1"],
                qualities: nil,
                supportsImageReference: false,
                maxReferenceImages: 0,
                maxImages: 1
            )),
            offers: [
                ProviderOffer(provider: .fal),
                ProviderOffer(provider: .runway),
                ProviderOffer(provider: .higgsfield, transport: .mcp),
            ]
        )

        let filtered = ModelCatalog.gatingCompletedDirectProviders(
            in: [entry],
            completedProviders: [.fal, .runway, .google]
        )
        let remaining = try #require(filtered.first?.offers)

        #expect(remaining.map(\.provider) == [.higgsfield])
    }

    @MainActor
    @Test("Runway entitlement discovery replaces stale base offers for every modality")
    func runwayDiscoveryReplacesBaseVideoOffers() throws {
        let shared = CatalogEntry(
            id: "shared-video",
            kind: .video,
            displayName: "Shared video",
            allowedEndpoints: ["shared-video"],
            responseShape: .video,
            uiCapabilities: .video(VideoCaps(
                durations: [5],
                resolutions: nil,
                aspectRatios: ["16:9"],
                supportsFirstFrame: true,
                supportsLastFrame: false,
                maxReferenceImages: 1,
                maxReferenceVideos: 0,
                maxReferenceAudios: 0,
                maxTotalReferences: 1,
                maxCombinedVideoRefSeconds: nil,
                maxCombinedAudioRefSeconds: nil,
                framesAndReferencesExclusive: false,
                referenceTagNoun: "image",
                requiresSourceVideo: false,
                requiresReferenceImage: false
            )),
            offers: [
                ProviderOffer(provider: .runway),
                ProviderOffer(provider: .fal),
                ProviderOffer(provider: .higgsfield, transport: .mcp),
            ]
        )
        var runwayOnly = shared
        runwayOnly.offers = [ProviderOffer(provider: .runway)]

        let filtered = ModelCatalog.gatingCompletedDirectProviders(
            in: [shared, runwayOnly],
            completedProviders: [.fal, .runway]
        )
        let remaining = try #require(filtered.first?.offers)

        #expect(filtered.count == 1)
        #expect(remaining.map(\.provider) == [.fal, .higgsfield])
    }

    actor StubClient: MCPCatalogClient {
        let tools: [MCPProviderClient.DiscoveredTool]
        let pages: [[String]]
        let details: [String: [String]]
        private var calls: [String] = []
        private var didDisconnect = false

        init(
            tools: [MCPProviderClient.DiscoveredTool],
            listing: String,
            details: [String: String] = [:]
        ) {
            self.tools = tools
            self.pages = [[listing]]
            self.details = details.mapValues { [$0] }
        }

        init(
            tools: [MCPProviderClient.DiscoveredTool],
            listing: String,
            detailPayloads: [String: [String]]
        ) {
            self.tools = tools
            self.pages = [[listing]]
            self.details = detailPayloads
        }

        init(tools: [MCPProviderClient.DiscoveredTool], pages: [[String]]) {
            self.tools = tools
            self.pages = pages
            self.details = [:]
        }

        func discoverTools() async throws -> [MCPProviderClient.DiscoveredTool] {
            tools
        }

        func callTool(name: String, arguments: [String: Value]) async throws -> [String] {
            calls.append(name)
            guard name == "models_explore" else {
                throw MCPProviderClient.ClientError.toolFailed("Unexpected call to \(name)")
            }
            if arguments["action"] == .string("get"),
               case .string(let modelID)? = arguments["model_id"],
               let detail = details[modelID] {
                return detail
            }
            let page = min(
                calls.filter { $0 == "models_explore" }.count - 1,
                pages.count - 1
            )
            return pages[page]
        }

        func disconnect() async {
            didDisconnect = true
        }

        func snapshot() -> (calls: [String], disconnected: Bool) {
            (calls, didDisconnect)
        }
    }

    actor DetailStressClient: MCPCatalogClient {
        let tools: [MCPProviderClient.DiscoveredTool]
        private let modelCount: Int
        private let failingModelIDs: Set<String>
        private var firstModelName: String?
        private var detailCalls = 0
        private var activeDetails = 0
        private var maximumActiveDetails = 0

        init(modelCount: Int, failingModelIDs: Set<String>) {
            tools = [
                MCPProviderClient.DiscoveredTool(
                    name: "generate_image",
                    description: "Generate an image.",
                    inputSchema: .object([:])
                ),
                MCPProviderClient.DiscoveredTool(
                    name: "models_explore",
                    description: "Find generation models.",
                    inputSchema: .object([:])
                ),
                MCPProviderClient.DiscoveredTool(
                    name: "job_status",
                    description: "Check a generation job.",
                    inputSchema: .object([
                        "properties": .object([
                            "job_set_id": .object(["type": .string("string")]),
                        ]),
                        "required": .array([.string("job_set_id")]),
                    ])
                ),
                MCPProviderClient.DiscoveredTool(
                    name: "job_display",
                    description: "Display completed generation output.",
                    inputSchema: .object([
                        "properties": .object([
                            "ids": .object([
                                "type": .string("array"),
                                "items": .object(["type": .string("string")]),
                            ]),
                        ]),
                        "required": .array([.string("ids")]),
                    ])
                ),
            ]
            self.modelCount = modelCount
            self.failingModelIDs = failingModelIDs
        }

        func discoverTools() async throws -> [MCPProviderClient.DiscoveredTool] { tools }

        func callTool(name: String, arguments: [String: Value]) async throws -> [String] {
            guard name == "models_explore" else {
                throw MCPProviderClient.ClientError.toolFailed("Unexpected call to \(name)")
            }
            guard arguments["action"] == .string("get"),
                  case .string(let modelID)? = arguments["model_id"] else {
                let items = (0..<modelCount).map { index in
                    let name = index == 0 ? firstModelName.map { ",\"name\":\"\($0)\"" } ?? "" : ""
                    return #"{"id":"stress-\#(index)","output_type":"image"\#(name)}"#
                }.joined(separator: ",")
                return ["{\"items\":[\(items)]}"]
            }
            detailCalls += 1
            activeDetails += 1
            maximumActiveDetails = max(maximumActiveDetails, activeDetails)
            try? await Task.sleep(nanoseconds: 5_000_000)
            activeDetails -= 1
            if failingModelIDs.contains(modelID) {
                throw MCPProviderClient.ClientError.toolFailed("Detail unavailable")
            }
            return [#"{"id":"\#(modelID)","constraints":["At most 4 image references are allowed."]}"#]
        }

        func disconnect() async {}

        func renameFirstModel(_ name: String) { firstModelName = name }

        func snapshot() -> (detailCalls: Int, maximumActiveDetails: Int) {
            (detailCalls, maximumActiveDetails)
        }
    }

    @MainActor
    @Test("OAuth discovery distinguishes inactive providers from disconnected providers")
    func oauthDiscoveryStateRequiresConfigurationHistory() {
        #expect(CatalogDiscovery.oauthDisconnectedState(wasConfigured: false) == .inactive)
        #expect(CatalogDiscovery.oauthDisconnectedState(wasConfigured: true) == .actionRequired(
            "Sign in again to refresh this provider's models."
        ))
    }

    @MainActor
    @Test("Catalog discovery combines models and cursor data from every MCP content block")
    func catalogDiscoveryCombinesContentBlocks() async {
        let tools = [
            MCPProviderClient.DiscoveredTool(
                name: "generate_image",
                description: "Generate an image.",
                inputSchema: .object([:])
            ),
            MCPProviderClient.DiscoveredTool(
                name: "models_explore",
                description: "Find generation models.",
                inputSchema: .object([:])
            ),
        ] + mappableHiggsfieldResultLifecycle
        let client = StubClient(
            tools: tools,
            pages: [
                [
                    "Model catalog follows.",
                    #"{"items":[{"id":"first","output_type":"image"}]}"#,
                    #"{"items":[{"id":"first","name":"First","output_type":"image"},{"id":"second","output_type":"image"}]}"#,
                    #"{"next_page_token":"page-2"}"#,
                ],
                [#"{"items":[{"id":"third","output_type":"image"}],"has_more":false}"#],
            ]
        )

        let result = await CatalogDiscovery.discoverResult(.higgsfield, client: client)
        let entries = result.entries

        #expect(entries.map(\.id) == ["first", "second", "third"])
        #expect(entries.first?.displayName == "First")
        #expect(result.modelListingIsComplete)
    }

    @MainActor
    @Test("A partially decoded MCP model page is never publishable")
    func partiallyDecodedModelPageIsIncomplete() async {
        let tools = [
            MCPProviderClient.DiscoveredTool(
                name: "generate_image",
                description: "Generate an image.",
                inputSchema: .object([:])
            ),
            MCPProviderClient.DiscoveredTool(
                name: "models_explore",
                description: "Find generation models.",
                inputSchema: .object([:])
            ),
        ] + mappableHiggsfieldResultLifecycle
        let client = StubClient(
            tools: tools,
            listing: #"{"items":[{"id":"kept","output_type":"image"},{"id":7,"output_type":"image"}]}"#
        )

        let result = await CatalogDiscovery.discoverResult(.higgsfield, client: client)

        #expect(result.entries.map(\.id) == ["kept"])
        #expect(!result.modelListingIsComplete)
        #expect(CatalogDiscovery.mcpListingPublicationDecision(
            listingIsComplete: result.modelListingIsComplete,
            retainedModelCount: 0
        ) == .withholdIncompleteFirstRefresh)
        #expect(CatalogDiscovery.mcpListingPublicationDecision(
            listingIsComplete: result.modelListingIsComplete,
            retainedModelCount: 4
        ) == .preserveLastKnownGood)
    }

    @MainActor
    @Test("Has-more evidence accepts one cursor from another content block")
    func splitHasMoreAndCursorContinuesPagination() async {
        let tools = [
            MCPProviderClient.DiscoveredTool(
                name: "generate_image",
                description: "Generate an image.",
                inputSchema: .object([:])
            ),
            MCPProviderClient.DiscoveredTool(
                name: "models_explore",
                description: "Find generation models.",
                inputSchema: .object([:])
            ),
        ] + mappableHiggsfieldResultLifecycle
        let client = StubClient(
            tools: tools,
            pages: [
                [
                    #"{"items":[{"id":"split-first","output_type":"image"}],"has_more":true}"#,
                    #"{"next_page_token":"page-2"}"#,
                ],
                [#"{"items":[{"id":"split-second","output_type":"image"}],"has_more":false}"#],
            ]
        )

        let result = await CatalogDiscovery.discoverResult(.higgsfield, client: client)

        #expect(result.entries.map(\.id) == ["split-first", "split-second"])
        #expect(result.modelListingIsComplete)
        #expect(CatalogDiscovery.mcpListingPublicationDecision(
            listingIsComplete: result.modelListingIsComplete,
            retainedModelCount: 2
        ) == .publish)
    }

    @MainActor
    @Test("Terminal evidence in one content block rejects a cursor from another block")
    func splitTerminalCursorPreservesLastKnownGood() async {
        let tools = [
            MCPProviderClient.DiscoveredTool(
                name: "generate_image",
                description: "Generate an image.",
                inputSchema: .object([:])
            ),
            MCPProviderClient.DiscoveredTool(
                name: "models_explore",
                description: "Find generation models.",
                inputSchema: .object([:])
            ),
        ] + mappableHiggsfieldResultLifecycle
        let client = StubClient(
            tools: tools,
            pages: [[
                #"{"items":[{"id":"split-terminal","output_type":"image"}],"has_more":false}"#,
                #"{"next_page_token":"unexpected"}"#,
            ]]
        )

        let result = await CatalogDiscovery.discoverResult(.higgsfield, client: client)
        let snapshot = await client.snapshot()

        #expect(result.entries.map(\.id) == ["split-terminal"])
        #expect(!result.modelListingIsComplete)
        #expect(CatalogDiscovery.mcpListingPublicationDecision(
            listingIsComplete: result.modelListingIsComplete,
            retainedModelCount: 0
        ) == .withholdIncompleteFirstRefresh)
        #expect(CatalogDiscovery.mcpListingPublicationDecision(
            listingIsComplete: result.modelListingIsComplete,
            retainedModelCount: 6
        ) == .preserveLastKnownGood)
        #expect(snapshot.calls == ["models_explore"])
    }

    @MainActor
    @Test("A truncated cursor content block withholds the page and preserves last-known-good")
    func truncatedCursorBlockPreservesLastKnownGood() async {
        let tools = [
            MCPProviderClient.DiscoveredTool(
                name: "generate_image",
                description: "Generate an image.",
                inputSchema: .object([:])
            ),
            MCPProviderClient.DiscoveredTool(
                name: "models_explore",
                description: "Find generation models.",
                inputSchema: .object([:])
            ),
        ] + mappableHiggsfieldResultLifecycle
        let client = StubClient(
            tools: tools,
            pages: [[
                #"{"items":[{"id":"valid-item","output_type":"image"}]}"#,
                #"{"cursor":"must-not-follow""#,
            ]]
        )

        let result = await CatalogDiscovery.discoverResult(.higgsfield, client: client)
        let snapshot = await client.snapshot()

        #expect(result.entries.map(\.id) == ["valid-item"])
        #expect(!result.modelListingIsComplete)
        #expect(CatalogDiscovery.mcpListingPublicationDecision(
            listingIsComplete: result.modelListingIsComplete,
            retainedModelCount: 0
        ) == .withholdIncompleteFirstRefresh)
        #expect(CatalogDiscovery.mcpListingPublicationDecision(
            listingIsComplete: result.modelListingIsComplete,
            retainedModelCount: 8
        ) == .preserveLastKnownGood)
        #expect(snapshot.calls == ["models_explore"])
    }

    @MainActor
    @Test("Conflicting has-more evidence across content blocks stops pagination")
    func splitConflictingHasMoreStopsPagination() async {
        let tools = [
            MCPProviderClient.DiscoveredTool(
                name: "generate_image",
                description: "Generate an image.",
                inputSchema: .object([:])
            ),
            MCPProviderClient.DiscoveredTool(
                name: "models_explore",
                description: "Find generation models.",
                inputSchema: .object([:])
            ),
        ] + mappableHiggsfieldResultLifecycle
        let client = StubClient(
            tools: tools,
            pages: [[
                #"{"items":[{"id":"split-conflict","output_type":"image"}],"has_more":true}"#,
                #"{"has_more":false}"#,
                #"{"next_page_token":"must-not-follow"}"#,
            ]]
        )

        let result = await CatalogDiscovery.discoverResult(.higgsfield, client: client)
        let snapshot = await client.snapshot()

        #expect(result.entries.map(\.id) == ["split-conflict"])
        #expect(!result.modelListingIsComplete)
        #expect(CatalogDiscovery.mcpListingPublicationDecision(
            listingIsComplete: result.modelListingIsComplete,
            retainedModelCount: 2
        ) == .preserveLastKnownGood)
        #expect(snapshot.calls == ["models_explore"])
    }

    @MainActor
    @Test("A valid cursor cannot bypass a truncated catalog sibling")
    func validCursorWithTruncatedCatalogSiblingPreservesLastKnownGood() async {
        let tools = [
            MCPProviderClient.DiscoveredTool(
                name: "generate_image",
                description: "Generate an image.",
                inputSchema: .object([:])
            ),
            MCPProviderClient.DiscoveredTool(
                name: "models_explore",
                description: "Find generation models.",
                inputSchema: .object([:])
            ),
        ] + mappableHiggsfieldResultLifecycle
        let client = StubClient(
            tools: tools,
            pages: [[
                #"{"items":[{"id":"valid-before-loss","output_type":"image"}]}"#,
                #"{"next_page_token":"must-not-follow"}"#,
                #"{"items":["#,
            ]]
        )

        let result = await CatalogDiscovery.discoverResult(.higgsfield, client: client)
        let snapshot = await client.snapshot()

        #expect(result.entries.map(\.id) == ["valid-before-loss"])
        #expect(!result.modelListingIsComplete)
        #expect(CatalogDiscovery.mcpListingPublicationDecision(
            listingIsComplete: result.modelListingIsComplete,
            retainedModelCount: 0
        ) == .withholdIncompleteFirstRefresh)
        #expect(CatalogDiscovery.mcpListingPublicationDecision(
            listingIsComplete: result.modelListingIsComplete,
            retainedModelCount: 10
        ) == .preserveLastKnownGood)
        #expect(snapshot.calls == ["models_explore"])
    }

    @MainActor
    @Test("A nested terminal marker rejects an outer collection cursor")
    func nestedTerminalRejectsOuterCursor() async {
        let tools = [
            MCPProviderClient.DiscoveredTool(
                name: "generate_image",
                description: "Generate an image.",
                inputSchema: .object([:])
            ),
            MCPProviderClient.DiscoveredTool(
                name: "models_explore",
                description: "Find generation models.",
                inputSchema: .object([:])
            ),
        ] + mappableHiggsfieldResultLifecycle
        let client = StubClient(
            tools: tools,
            listing: #"{"items":[{"id":"outer-cursor","output_type":"image"}],"next_page_token":"unexpected","data":{"has_more":false}}"#
        )

        let result = await CatalogDiscovery.discoverResult(.higgsfield, client: client)
        let snapshot = await client.snapshot()

        #expect(result.entries.map(\.id) == ["outer-cursor"])
        #expect(!result.modelListingIsComplete)
        #expect(CatalogDiscovery.mcpListingPublicationDecision(
            listingIsComplete: result.modelListingIsComplete,
            retainedModelCount: 7
        ) == .preserveLastKnownGood)
        #expect(snapshot.calls == ["models_explore"])
    }

    @MainActor
    @Test("An outer terminal marker rejects a nested sibling cursor")
    func outerTerminalRejectsNestedCursor() async {
        let tools = [
            MCPProviderClient.DiscoveredTool(
                name: "generate_image",
                description: "Generate an image.",
                inputSchema: .object([:])
            ),
            MCPProviderClient.DiscoveredTool(
                name: "models_explore",
                description: "Find generation models.",
                inputSchema: .object([:])
            ),
        ] + mappableHiggsfieldResultLifecycle
        let client = StubClient(
            tools: tools,
            listing: #"{"items":[{"id":"outer-terminal","output_type":"image"}],"has_more":false,"result":{"next_page_token":"unexpected"}}"#
        )

        let result = await CatalogDiscovery.discoverResult(.higgsfield, client: client)
        let snapshot = await client.snapshot()

        #expect(result.entries.map(\.id) == ["outer-terminal"])
        #expect(!result.modelListingIsComplete)
        #expect(CatalogDiscovery.mcpListingPublicationDecision(
            listingIsComplete: result.modelListingIsComplete,
            retainedModelCount: 0
        ) == .withholdIncompleteFirstRefresh)
        #expect(CatalogDiscovery.mcpListingPublicationDecision(
            listingIsComplete: result.modelListingIsComplete,
            retainedModelCount: 7
        ) == .preserveLastKnownGood)
        #expect(snapshot.calls == ["models_explore"])
    }

    @MainActor
    @Test("An incomplete first model-list pagination is withheld")
    func incompleteFirstPaginationIsWithheld() async {
        let tools = [
            MCPProviderClient.DiscoveredTool(
                name: "generate_image",
                description: "Generate an image.",
                inputSchema: .object([:])
            ),
            MCPProviderClient.DiscoveredTool(
                name: "models_explore",
                description: "Find generation models.",
                inputSchema: .object([:])
            ),
        ] + mappableHiggsfieldResultLifecycle
        let client = StubClient(
            tools: tools,
            pages: [
                [#"{"items":[{"id":"partial-first","output_type":"image"}],"next_page_token":"repeat"}"#],
                [#"{"items":[{"id":"partial-second","output_type":"image"}],"next_page_token":"repeat"}"#],
            ]
        )

        let result = await CatalogDiscovery.discoverResult(.higgsfield, client: client)
        let decision = CatalogDiscovery.mcpListingPublicationDecision(
            listingIsComplete: result.modelListingIsComplete,
            retainedModelCount: 0
        )

        #expect(result.entries.map(\.id) == ["partial-first", "partial-second"])
        #expect(!result.modelListingIsComplete)
        #expect(decision == .withholdIncompleteFirstRefresh)
    }

    @MainActor
    @Test("An empty page with continuation stops without following the cursor")
    func emptyPageWithContinuationPreservesLastKnownGood() async {
        let tools = [
            MCPProviderClient.DiscoveredTool(
                name: "generate_image",
                description: "Generate an image.",
                inputSchema: .object([:])
            ),
            MCPProviderClient.DiscoveredTool(
                name: "models_explore",
                description: "Find generation models.",
                inputSchema: .object([:])
            ),
        ] + mappableHiggsfieldResultLifecycle
        let client = StubClient(
            tools: tools,
            pages: [
                [#"{"items":[],"has_more":true,"next_page_token":"page-2"}"#],
                [#"{"items":[{"id":"must-not-load","output_type":"image"}],"has_more":false}"#],
            ]
        )

        let result = await CatalogDiscovery.discoverResult(.higgsfield, client: client)
        let snapshot = await client.snapshot()

        #expect(result.entries.isEmpty)
        #expect(!result.modelListingIsComplete)
        #expect(CatalogDiscovery.mcpListingPublicationDecision(
            listingIsComplete: result.modelListingIsComplete,
            retainedModelCount: 5
        ) == .preserveLastKnownGood)
        #expect(snapshot.calls == ["models_explore"])
    }

    @MainActor
    @Test("An empty terminal page remains a complete listing")
    func emptyTerminalPageIsComplete() async {
        let tools = [
            MCPProviderClient.DiscoveredTool(
                name: "generate_image",
                description: "Generate an image.",
                inputSchema: .object([:])
            ),
            MCPProviderClient.DiscoveredTool(
                name: "models_explore",
                description: "Find generation models.",
                inputSchema: .object([:])
            ),
        ] + mappableHiggsfieldResultLifecycle
        let client = StubClient(
            tools: tools,
            listing: #"{"items":[],"has_more":false}"#
        )

        let result = await CatalogDiscovery.discoverResult(.higgsfield, client: client)
        let snapshot = await client.snapshot()

        #expect(result.entries.isEmpty)
        #expect(result.modelListingIsComplete)
        #expect(snapshot.calls == ["models_explore"])
    }

    @MainActor
    @Test("An incomplete later model-list pagination preserves the last-known-good catalog")
    func incompleteLaterPaginationPreservesLastKnownGood() async {
        let tools = [
            MCPProviderClient.DiscoveredTool(
                name: "generate_image",
                description: "Generate an image.",
                inputSchema: .object([:])
            ),
            MCPProviderClient.DiscoveredTool(
                name: "models_explore",
                description: "Find generation models.",
                inputSchema: .object([:])
            ),
        ] + mappableHiggsfieldResultLifecycle
        let client = StubClient(
            tools: tools,
            pages: [
                [#"{"items":[{"id":"partial-first","output_type":"image"}],"next_page_token":"repeat"}"#],
                [#"{"items":[{"id":"partial-second","output_type":"image"}],"next_page_token":"repeat"}"#],
            ]
        )

        let result = await CatalogDiscovery.discoverResult(.higgsfield, client: client)
        let decision = CatalogDiscovery.mcpListingPublicationDecision(
            listingIsComplete: result.modelListingIsComplete,
            retainedModelCount: 3
        )

        #expect(!result.modelListingIsComplete)
        #expect(decision == .preserveLastKnownGood)
    }

    @MainActor
    @Test("A terminal page with a cursor is withheld and preserves the last-known-good catalog")
    func contradictoryTerminalPaginationPreservesLastKnownGood() async {
        let tools = [
            MCPProviderClient.DiscoveredTool(
                name: "generate_image",
                description: "Generate an image.",
                inputSchema: .object([:])
            ),
            MCPProviderClient.DiscoveredTool(
                name: "models_explore",
                description: "Find generation models.",
                inputSchema: .object([:])
            ),
        ] + mappableHiggsfieldResultLifecycle
        let client = StubClient(
            tools: tools,
            listing: #"{"items":[{"id":"contradictory","output_type":"image"}],"has_more":false,"next_page_token":"unexpected"}"#
        )

        let result = await CatalogDiscovery.discoverResult(.higgsfield, client: client)
        let snapshot = await client.snapshot()

        #expect(result.entries.map(\.id) == ["contradictory"])
        #expect(!result.modelListingIsComplete)
        #expect(CatalogDiscovery.mcpListingPublicationDecision(
            listingIsComplete: result.modelListingIsComplete,
            retainedModelCount: 0
        ) == .withholdIncompleteFirstRefresh)
        #expect(CatalogDiscovery.mcpListingPublicationDecision(
            listingIsComplete: result.modelListingIsComplete,
            retainedModelCount: 5
        ) == .preserveLastKnownGood)
        #expect(snapshot.calls == ["models_explore"])
    }

    @MainActor
    @Test("A single oversized terminal page is withheld and preserves the last-known-good catalog")
    func oversizedTerminalPagePreservesLastKnownGood() async {
        let tools = [
            MCPProviderClient.DiscoveredTool(
                name: "generate_image",
                description: "Generate an image.",
                inputSchema: .object([:])
            ),
            MCPProviderClient.DiscoveredTool(
                name: "models_explore",
                description: "Find generation models.",
                inputSchema: .object([:])
            ),
        ] + mappableHiggsfieldResultLifecycle
        let client = StubClient(
            tools: tools,
            listing: listingPage(0..<401, hasMore: false)
        )

        let result = await CatalogDiscovery.discoverResult(.higgsfield, client: client)
        let snapshot = await client.snapshot()

        #expect(result.entries.count == 400)
        #expect(!result.modelListingIsComplete)
        #expect(CatalogDiscovery.mcpListingPublicationDecision(
            listingIsComplete: result.modelListingIsComplete,
            retainedModelCount: 0
        ) == .withholdIncompleteFirstRefresh)
        #expect(CatalogDiscovery.mcpListingPublicationDecision(
            listingIsComplete: result.modelListingIsComplete,
            retainedModelCount: 9
        ) == .preserveLastKnownGood)
        #expect(snapshot.calls == ["models_explore"])
    }

    @MainActor
    @Test("The provider model limit stops listing before another modality")
    func providerModelLimitStopsBeforeAnotherModality() async {
        let tools = [
            MCPProviderClient.DiscoveredTool(
                name: "generate_image",
                description: "Generate an image.",
                inputSchema: .object([:])
            ),
            MCPProviderClient.DiscoveredTool(
                name: "generate_video",
                description: "Generate a video.",
                inputSchema: .object([:])
            ),
            MCPProviderClient.DiscoveredTool(
                name: "models_explore",
                description: "Find generation models.",
                inputSchema: .object([:])
            ),
        ] + mappableHiggsfieldResultLifecycle
        let client = StubClient(
            tools: tools,
            pages: [
                [listingPage(0..<250, hasMore: true, cursor: "page-2")],
                [listingPage(250..<401, hasMore: false)],
            ]
        )

        let result = await CatalogDiscovery.discoverResult(.higgsfield, client: client)
        let snapshot = await client.snapshot()

        #expect(result.entries.count == 400)
        #expect(!result.modelListingIsComplete)
        #expect(CatalogDiscovery.mcpListingPublicationDecision(
            listingIsComplete: result.modelListingIsComplete,
            retainedModelCount: 4
        ) == .preserveLastKnownGood)
        #expect(snapshot.calls == ["models_explore", "models_explore"])
    }

    @MainActor
    @Test("An exactly full terminal modality prevents listing another modality")
    func exactProviderModelLimitStopsBeforeAnotherModality() async {
        let tools = [
            MCPProviderClient.DiscoveredTool(
                name: "generate_image",
                description: "Generate an image.",
                inputSchema: .object([:])
            ),
            MCPProviderClient.DiscoveredTool(
                name: "generate_video",
                description: "Generate a video.",
                inputSchema: .object([:])
            ),
            MCPProviderClient.DiscoveredTool(
                name: "models_explore",
                description: "Find generation models.",
                inputSchema: .object([:])
            ),
        ] + mappableHiggsfieldResultLifecycle
        let client = StubClient(
            tools: tools,
            listing: listingPage(0..<400, hasMore: false)
        )

        let result = await CatalogDiscovery.discoverResult(.higgsfield, client: client)
        let snapshot = await client.snapshot()

        #expect(result.entries.count == 400)
        #expect(!result.modelListingIsComplete)
        #expect(CatalogDiscovery.mcpListingPublicationDecision(
            listingIsComplete: result.modelListingIsComplete,
            retainedModelCount: 3
        ) == .preserveLastKnownGood)
        #expect(snapshot.calls == ["models_explore"])
    }

    @MainActor
    @Test("Model details use a bounded cache and one failed detail does not block the catalog")
    func modelDetailDiscoveryIsBoundedCachedAndFailureIsolated() async {
        CatalogDiscovery.invalidateDetailCache()
        let client = DetailStressClient(
            modelCount: 12,
            failingModelIDs: ["stress-3"]
        )

        let firstResult = await CatalogDiscovery.discoverResult(.higgsfield, client: client)
        let first = firstResult.entries
        let firstSnapshot = await client.snapshot()
        let second = await CatalogDiscovery.discover(.higgsfield, client: client)
        let secondSnapshot = await client.snapshot()
        await client.renameFirstModel("Changed")
        let third = await CatalogDiscovery.discover(.higgsfield, client: client)
        let thirdSnapshot = await client.snapshot()
        CatalogDiscovery.invalidateDetailCache()
        let fourth = await CatalogDiscovery.discover(.higgsfield, client: client)
        let fourthSnapshot = await client.snapshot()

        #expect(first.count == 12)
        #expect(firstResult.modelListingIsComplete)
        #expect(!firstResult.detailEnrichmentIsComplete)
        #expect(CatalogDiscovery.mcpListingPublicationDecision(
            listingIsComplete: firstResult.modelListingIsComplete,
            retainedModelCount: 12
        ) == .publish)
        #expect(second.count == 12)
        #expect(third.count == 12)
        #expect(fourth.count == 12)
        #expect(firstSnapshot.detailCalls == 12)
        #expect(firstSnapshot.maximumActiveDetails > 1)
        #expect(firstSnapshot.maximumActiveDetails <= 4)
        #expect(secondSnapshot.detailCalls == 13)
        #expect(thirdSnapshot.detailCalls == 15)
        #expect(fourthSnapshot.detailCalls == 27)
        CatalogDiscovery.invalidateDetailCache()
    }

    @MainActor
    @Test("A truncated job-set detail sibling preserves the cached detail contract")
    func truncatedJobSetDetailSiblingPreservesCachedDetails() async throws {
        CatalogDiscovery.invalidateDetailCache()
        defer { CatalogDiscovery.invalidateDetailCache() }
        let tools = [
            MCPProviderClient.DiscoveredTool(
                name: "generate_image",
                description: "Generate an image.",
                inputSchema: .object([:])
            ),
            MCPProviderClient.DiscoveredTool(
                name: "models_explore",
                description: "Find generation models.",
                inputSchema: .object([:])
            ),
        ] + mappableHiggsfieldResultLifecycle + mappableHiggsfieldMediaUpload
        let initialClient = StubClient(
            tools: tools,
            listing: #"{"items":[{"id":"detail-jobset","name":"Initial","output_type":"image"}]}"#,
            detailPayloads: [
                "detail-jobset": [
                    #"{"id":"detail-jobset","constraints":["At most 4 image references are allowed."]}"#,
                ],
            ]
        )

        let initial = await CatalogDiscovery.discoverResult(
            .higgsfield,
            client: initialClient
        )
        let refreshClient = StubClient(
            tools: tools,
            listing: #"{"items":[{"id":"detail-jobset","name":"Changed","output_type":"image"}]}"#,
            detailPayloads: [
                "detail-jobset": [
                    #"{"id":"detail-jobset","constraints":["At most 9 image references are allowed."]}"#,
                    #"{"job_set_type":"detail-jobset""#,
                ],
            ]
        )

        let refreshed = await CatalogDiscovery.discoverResult(
            .higgsfield,
            client: refreshClient
        )
        let entry = try #require(refreshed.entries.first)
        guard case .image(let caps) = entry.uiCapabilities else {
            Issue.record("Expected image capabilities")
            return
        }

        #expect(initial.modelListingIsComplete)
        #expect(initial.detailEnrichmentIsComplete)
        #expect(refreshed.modelListingIsComplete)
        #expect(!refreshed.detailEnrichmentIsComplete)
        #expect(entry.displayName == "Changed")
        #expect(ImageModelConfig(entry: entry, caps: caps).referenceImageLimit == .bounded(4))
    }

    @MainActor
    @Test("Malformed constraints preserve the cached detail contract")
    func malformedConstraintsPreserveCachedDetails() async throws {
        CatalogDiscovery.invalidateDetailCache()
        defer { CatalogDiscovery.invalidateDetailCache() }
        let tools = [
            MCPProviderClient.DiscoveredTool(
                name: "generate_image",
                description: "Generate an image.",
                inputSchema: .object([:])
            ),
            MCPProviderClient.DiscoveredTool(
                name: "models_explore",
                description: "Find generation models.",
                inputSchema: .object([:])
            ),
        ] + mappableHiggsfieldResultLifecycle + mappableHiggsfieldMediaUpload
        let initialClient = StubClient(
            tools: tools,
            listing: #"{"items":[{"id":"detail-constraints","name":"Initial","output_type":"image"}]}"#,
            detailPayloads: [
                "detail-constraints": [
                    #"{"id":"detail-constraints","constraints":["At most 4 image references are allowed."]}"#,
                ],
            ]
        )

        let initial = await CatalogDiscovery.discoverResult(
            .higgsfield,
            client: initialClient
        )
        let refreshClient = StubClient(
            tools: tools,
            listing: #"{"items":[{"id":"detail-constraints","name":"Changed","output_type":"image"}]}"#,
            detailPayloads: [
                "detail-constraints": [
                    #"{"id":"detail-constraints","constraints":["At most 9 image references are allowed.",7]}"#,
                ],
            ]
        )

        let refreshed = await CatalogDiscovery.discoverResult(
            .higgsfield,
            client: refreshClient
        )
        let entry = try #require(refreshed.entries.first)
        guard case .image(let caps) = entry.uiCapabilities else {
            Issue.record("Expected image capabilities")
            return
        }

        #expect(initial.detailEnrichmentIsComplete)
        #expect(refreshed.modelListingIsComplete)
        #expect(!refreshed.detailEnrichmentIsComplete)
        #expect(entry.displayName == "Changed")
        #expect(ImageModelConfig(entry: entry, caps: caps).referenceImageLimit == .bounded(4))
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
    @Test("Higgsfield's current catalog supports reference image requests")
    func higgsfieldCurrentMCPModelsRemainAvailable() async throws {
        let generationSchema: Value = .object([
            "properties": .object([
                "job_set_type": .object(["type": .string("string")]),
                "prompt": .object(["type": .string("string")]),
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
            "required": .array([.string("job_set_type"), .string("prompt")]),
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
                name: "job_status",
                description: "Check a generation job.",
                inputSchema: .object([
                    "properties": .object([
                        "job_set_id": .object(["type": .string("string")]),
                    ]),
                    "required": .array([.string("job_set_id")]),
                ])
            ),
            MCPProviderClient.DiscoveredTool(
                name: "job_display",
                description: "Display completed generation output.",
                inputSchema: .object([
                    "properties": .object([
                        "ids": .object([
                            "type": .string("array"),
                            "items": .object(["type": .string("string")]),
                        ]),
                    ]),
                    "required": .array([.string("ids")]),
                ])
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
        {"data":{"models":[
          {"job_set_type":"nano_banana_2","name":"Nano Banana Pro","type":"image","aspect_ratios":["1:1","16:9"],
           "medias":[{"name":"medias","type":"image","roles":["image"],"min":0}]},
          {"job_set_type":"gpt_image_2","name":"GPT Image 2","type":"image","aspect_ratios":["1:1","16:9"]}
        ],"has_more":false}}
        """#
        let client = StubClient(
            tools: tools,
            listing: listing,
            details: [
                "nano_banana_2": #"{"job_set_type":"nano_banana_2","type":"image","constraints":["At most 14 image references are allowed."],"medias":[{"name":"medias","type":"image","roles":["image"],"min":0}]}"#,
                "gpt_image_2": #"{"job_set_type":"gpt_image_2","type":"image","medias":[{"name":"medias","type":"image","roles":["image"],"min":0}]}"#,
            ]
        )

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
                mcpMediaRoles: ["image"]
            )]
        })
        for entry in entries {
            guard case .image(let caps) = entry.uiCapabilities else {
                Issue.record("Expected image capabilities")
                continue
            }
            let model = ImageModelConfig(entry: entry, caps: caps)
            if entry.id == "nano_banana_2" {
                #expect(model.referenceImageLimit == .bounded(14))
            } else {
                guard case .capabilityProfile(let maximum) = model.referenceImageLimit else {
                    Issue.record("Expected the intrinsic capability profile to bound references")
                    continue
                }
                #expect(maximum >= 4)
            }
            #expect(model.validate(
                aspectRatio: "16:9",
                resolution: nil,
                quality: nil,
                imageRefCount: 4,
                numImages: 1
            ) == nil)
        }
        #expect(snapshot.calls == ["models_explore", "models_explore", "models_explore"])
        #expect(snapshot.disconnected)
    }

    @MainActor
    @Test("Higgsfield video detail contracts preserve every reference class")
    func higgsfieldVideoReferenceContractsRemainAvailable() async throws {
        let tools = [
            MCPProviderClient.DiscoveredTool(
                name: "generate_video",
                description: "Generate a video.",
                inputSchema: mappableHiggsfieldGenerationSchema
            ),
            MCPProviderClient.DiscoveredTool(
                name: "models_explore",
                description: "Find generation models.",
                inputSchema: .object([:])
            ),
        ] + mappableHiggsfieldResultLifecycle + mappableHiggsfieldMediaUpload
        let client = StubClient(
            tools: tools,
            listing: #"{"items":[{"id":"seedance_2_0","name":"Seedance 2.0","output_type":"video"},{"id":"cinematic_studio_video_3_5","name":"Cinematic Studio 3.5","output_type":"video"},{"id":"gemini_omni","name":"Gemini Omni","output_type":"video"}]}"#,
            detailPayloads: [
                "seedance_2_0": [
                    #"{"id":"seedance_2_0","output_type":"video","constraints":["At most 9 image references are allowed (counting start_image and end_image).","At most 3 video_references are allowed.","At most 3 audio_references are allowed.","At most 12 reference files are allowed in total across images, videos, and audios."],"medias":[{"name":"medias","type":"image","roles":["image","start_image","end_image"]}]}"#,
                    #"{"id":"seedance_2_0","output_type":"video","medias":[{"name":"medias","type":"video","roles":["video"]}]}"#,
                    #"{"id":"seedance_2_0","output_type":"video","medias":[{"name":"medias","type":"audio","roles":["audio"]}]}"#,
                ],
                "cinematic_studio_video_3_5": [
                    #"{"id":"cinematic_studio_video_3_5","output_type":"video","constraints":["At most 15 media references are allowed in total (image_references + start_image + end_image + video_references + audio_references)."],"medias":[{"name":"medias","type":"image","roles":["image","start_image","end_image"]},{"name":"medias","type":"video","roles":["video"]},{"name":"medias","type":"audio","roles":["audio"]}]}"#,
                ],
                "gemini_omni": [
                    #"{"id":"gemini_omni","output_type":"video","constraints":["At most 1 video_references entry is allowed.","When a video reference is provided, at most 5 image_references are allowed.","At most 7 image_references are allowed."],"medias":[{"name":"medias","type":"image","roles":["image"]},{"name":"medias","type":"video","roles":["video"]}]}"#,
                ],
            ]
        )

        let entries = await CatalogDiscovery.discover(.higgsfield, client: client)
        let entry = try #require(entries.first(where: { $0.id == "seedance_2_0" }))
        guard case .video(let caps) = entry.uiCapabilities else {
            Issue.record("Expected video capabilities")
            return
        }

        #expect(caps.supportsFirstFrame)
        #expect(caps.supportsLastFrame)
        #expect(caps.maxReferenceImages == 9)
        #expect(caps.maxReferenceVideos == 3)
        #expect(caps.maxReferenceAudios == 3)
        #expect(caps.maxTotalReferences == 12)
        #expect(caps.framesCountTowardImageReferenceLimit)
        #expect(caps.framesCountTowardTotalReferenceLimit)

        let model = VideoModelConfig(entry: entry, caps: caps)
        func asset(_ id: String, _ type: ClipType) -> MediaAsset {
            MediaAsset(
                id: id,
                url: URL(fileURLWithPath: "/tmp/\(id)"),
                type: type,
                name: id
            )
        }
        let frames = [asset("start.png", .image), asset("end.png", .image)]
        let validImages = (0..<7).map { asset("image-\($0).png", .image) }
        let excessImages = validImages + [asset("image-7.png", .image)]
        #expect(VideoGenerationSubmission.InputAssets(
            frames: frames,
            imageRefs: validImages
        ).validate(for: model) == nil)
        #expect(VideoGenerationSubmission.InputAssets(
            frames: frames,
            imageRefs: excessImages
        ).validate(for: model) != nil)

        let cinematicEntry = try #require(entries.first {
            $0.id == "cinematic_studio_video_3_5"
        })
        guard case .video(let cinematicCaps) = cinematicEntry.uiCapabilities else {
            Issue.record("Expected Cinematic Studio video capabilities")
            return
        }
        #expect(cinematicCaps.maxTotalReferences == 15)
        #expect(!cinematicCaps.framesCountTowardImageReferenceLimit)
        #expect(cinematicCaps.framesCountTowardTotalReferenceLimit)

        let geminiEntry = try #require(entries.first { $0.id == "gemini_omni" })
        guard case .video(let geminiCaps) = geminiEntry.uiCapabilities else {
            Issue.record("Expected Gemini Omni video capabilities")
            return
        }
        #expect(geminiCaps.maxReferenceImages == 7)
        #expect(geminiCaps.maxReferenceImagesWhenVideoPresent == 5)
        let geminiModel = VideoModelConfig(entry: geminiEntry, caps: geminiCaps)
        let sixImages = (0..<6).map { asset("gemini-image-\($0).png", .image) }
        #expect(VideoGenerationSubmission.InputAssets(
            imageRefs: sixImages
        ).validate(for: geminiModel) == nil)
        #expect(VideoGenerationSubmission.InputAssets(
            imageRefs: sixImages,
            videoRefs: [asset("gemini-video.mp4", .video)]
        ).validate(for: geminiModel) != nil)
    }

    @MainActor
    @Test("A detail response resolves only the media classes it actually declares")
    func detailResolutionIsScopedPerMediaClass() async throws {
        let tools = [
            MCPProviderClient.DiscoveredTool(
                name: "generate_image",
                description: "Generate an image.",
                inputSchema: mappableHiggsfieldGenerationSchema
            ),
            MCPProviderClient.DiscoveredTool(
                name: "models_explore",
                description: "Find generation models.",
                inputSchema: .object([:])
            ),
        ] + mappableHiggsfieldResultLifecycle + mappableHiggsfieldMediaUpload
        let client = StubClient(
            tools: tools,
            listing: #"{"items":[{"id":"partial-image","output_type":"image","medias":[{"name":"medias","type":"image","roles":["image"]}]}]}"#,
            details: [
                "partial-image": #"{"id":"partial-image","output_type":"image","medias":[{"name":"medias","type":"audio","roles":["audio"]}]}"#,
            ]
        )

        let entries = await CatalogDiscovery.discover(.higgsfield, client: client)
        let entry = try #require(entries.first)
        guard case .image(let caps) = entry.uiCapabilities else {
            Issue.record("Expected image capabilities")
            return
        }

        #expect(caps.referenceImageLimit == .unknown)
        #expect(!caps.supportsImageReference)
    }

    @MainActor
    @Test("Catalog discovery uses a proven sync path without invoking lifecycle tools")
    func malformedLifecycleDoesNotHideCatalog() async {
        let tools = [
            MCPProviderClient.DiscoveredTool(
                name: "generate_image",
                description: "Generate an image.",
                inputSchema: .object([
                    "properties": .object([
                        "model": .object(["type": .string("string")]),
                        "prompt": .object(["type": .string("string")]),
                        "wait": .object(["type": .string("boolean")]),
                    ]),
                    "required": .array([.string("model"), .string("prompt")]),
                ])
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
            listing: #"{"items":[{"id":"listed-image","output_type":"image"}]}"#
        )

        let entries = await CatalogDiscovery.discover(.higgsfield, client: client)
        let snapshot = await client.snapshot()

        #expect(entries.map(\.id) == ["listed-image"])
        #expect(snapshot.calls == ["models_explore", "models_explore"])
        #expect(MCPGenerationExecutor.hasProvenResultPath(
            generationTool: tools[0],
            tools: tools
        ))
        #expect(snapshot.disconnected)
    }

    @MainActor
    @Test("Status-only lifecycle without a declared media result is rejected")
    func statusOnlyLifecycleWithoutMediaResultIsRejected() async {
        let tools = [
            MCPProviderClient.DiscoveredTool(
                name: "generate_image",
                description: "Generate an image.",
                inputSchema: .object([
                    "properties": .object([
                        "model": .object(["type": .string("string")]),
                        "prompt": .object(["type": .string("string")]),
                    ]),
                    "required": .array([.string("model"), .string("prompt")]),
                ])
            ),
            MCPProviderClient.DiscoveredTool(
                name: "job_status",
                description: "Check generation job status.",
                inputSchema: .object([
                    "properties": .object([
                        "job_id": .object(["type": .string("string")]),
                    ]),
                    "required": .array([.string("job_id")]),
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
            listing: #"{"items":[{"id":"status-image","output_type":"image"}]}"#
        )

        let entries = await CatalogDiscovery.discover(.higgsfield, client: client)
        let snapshot = await client.snapshot()

        #expect(entries.isEmpty)
        #expect(snapshot.calls.isEmpty)
        #expect(snapshot.disconnected)
    }

    @MainActor
    @Test("No-status schema-free generator is rejected without a direct or sync contract")
    func schemaFreeNoStatusGeneratorIsRejected() async {
        let tools = [
            MCPProviderClient.DiscoveredTool(
                name: "generate_image",
                description: "Generate and return an image.",
                inputSchema: .object([
                    "properties": .object([
                        "model": .object(["type": .string("string")]),
                        "prompt": .object(["type": .string("string")]),
                    ]),
                    "required": .array([.string("model"), .string("prompt")]),
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
            listing: #"{"items":[{"id":"direct-image","output_type":"image"}]}"#
        )

        let entries = await CatalogDiscovery.discover(.higgsfield, client: client)
        let snapshot = await client.snapshot()

        #expect(entries.isEmpty)
        #expect(snapshot.calls.isEmpty)
        #expect(snapshot.disconnected)
    }

    @MainActor
    @Test("Status output schema proves an asynchronous media result path")
    func declaredStatusMediaOutputRemainsDiscoverable() async {
        let mediaOutputSchema: Value = .object([
            "type": .string("object"),
            "properties": .object([
                "result": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "url": .object(["type": .string("string")]),
                    ]),
                ]),
            ]),
        ])
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
                        "job_id": .object(["type": .string("string")]),
                    ]),
                    "required": .array([.string("job_id")]),
                ]),
                outputSchema: mediaOutputSchema
            ),
            MCPProviderClient.DiscoveredTool(
                name: "models_explore",
                description: "Find generation models.",
                inputSchema: .object([:])
            ),
        ]
        let client = StubClient(
            tools: tools,
            listing: #"{"items":[{"id":"status-image","output_type":"image"}]}"#
        )

        let entries = await CatalogDiscovery.discover(.higgsfield, client: client)

        #expect(entries.map(\.id) == ["status-image"])
    }

    @MainActor
    @Test("Higgsfield's schema-free mappable result tool is an explicit result path")
    func mappableHiggsfieldResultToolRemainsDiscoverable() async {
        let tools = [
            MCPProviderClient.DiscoveredTool(
                name: "generate_image",
                description: "Generate an image.",
                inputSchema: .object([:])
            ),
            MCPProviderClient.DiscoveredTool(
                name: "models_explore",
                description: "Find generation models.",
                inputSchema: .object([:])
            ),
        ] + mappableHiggsfieldResultLifecycle
        let client = StubClient(
            tools: tools,
            listing: #"{"items":[{"id":"higgsfield-image","output_type":"image"}]}"#
        )

        let entries = await CatalogDiscovery.discover(.higgsfield, client: client)

        #expect(entries.map(\.id) == ["higgsfield-image"])
    }

    @MainActor
    @Test("A result tool that declares no media output cannot publish a model")
    func declaredNonMediaResultToolIsRejected() async {
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
                        "job_id": .object(["type": .string("string")]),
                    ]),
                    "required": .array([.string("job_id")]),
                ])
            ),
            MCPProviderClient.DiscoveredTool(
                name: "job_result",
                description: "Read generation result.",
                inputSchema: .object([
                    "properties": .object([
                        "job_id": .object(["type": .string("string")]),
                    ]),
                    "required": .array([.string("job_id")]),
                ]),
                outputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "message": .object(["type": .string("string")]),
                    ]),
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
            listing: #"{"items":[{"id":"unreachable-image","output_type":"image"}]}"#
        )

        let entries = await CatalogDiscovery.discover(.higgsfield, client: client)

        #expect(entries.isEmpty)
    }

    @MainActor
    @Test("Tool-only fallback excludes generation modalities without a usable lifecycle")
    func toolOnlyFallbackUsesLifecycleFilteredGenerators() async {
        let mediaOutputSchema: Value = .object([
            "type": .string("object"),
            "properties": .object([
                "result": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "url": .object(["type": .string("string")]),
                    ]),
                ]),
            ]),
        ])
        let tools = [
            MCPProviderClient.DiscoveredTool(
                name: "generate_image",
                description: "Generate an image.",
                inputSchema: .object([:]),
                outputSchema: mediaOutputSchema
            ),
            MCPProviderClient.DiscoveredTool(
                name: "generate_video",
                description: "Generate a video.",
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
        ]
        let client = StubClient(tools: tools, listing: "{}")

        let entries = await CatalogDiscovery.discover(.openart, client: client)

        #expect(entries.map(\.id) == ["generate_image"])
    }
}
