import Foundation
import MCP
import Testing

@testable import NexGenVideo

@Suite("Catalog discovery coordinator", .serialized)
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

        let filtered = ModelCatalog.gatingCompletedDirectImageProviders(
            in: [entry],
            completedProviders: [.fal, .runway, .google]
        )
        let remaining = try #require(filtered.first?.offers)

        #expect(remaining.map(\.provider) == [.higgsfield])
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
        ]
        let client = StubClient(
            tools: tools,
            pages: [
                [
                    #"{"items":[{"id":"first","output_type":"image"}]}"#,
                    #"{"items":[{"id":"first","name":"First","output_type":"image"},{"id":"second","output_type":"image"}]}"#,
                    #"{"next_page_token":"page-2"}"#,
                ],
                [#"{"items":[{"id":"third","output_type":"image"}],"has_more":false}"#],
            ]
        )

        let entries = await CatalogDiscovery.discover(.higgsfield, client: client)

        #expect(entries.map(\.id) == ["first", "second", "third"])
        #expect(entries.first?.displayName == "First")
    }

    @MainActor
    @Test("Model details use a bounded cache and one failed detail does not block the catalog")
    func modelDetailDiscoveryIsBoundedCachedAndFailureIsolated() async {
        CatalogDiscovery.invalidateDetailCache()
        let client = DetailStressClient(
            modelCount: 12,
            failingModelIDs: ["stress-3"]
        )

        let first = await CatalogDiscovery.discover(.higgsfield, client: client)
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
                #expect(model.referenceImageLimit == .providerUnbounded(hostMaximum: 32))
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
                inputSchema: .object([:])
            ),
            MCPProviderClient.DiscoveredTool(
                name: "models_explore",
                description: "Find generation models.",
                inputSchema: .object([:])
            ),
        ]
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
                inputSchema: .object([:])
            ),
            MCPProviderClient.DiscoveredTool(
                name: "models_explore",
                description: "Find generation models.",
                inputSchema: .object([:])
            ),
        ]
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
    @Test("Catalog discovery is independent of the billed generation lifecycle")
    func malformedLifecycleDoesNotHideCatalog() async {
        let tools = [
            MCPProviderClient.DiscoveredTool(
                name: "generate_image",
                description: "Generate an image.",
                inputSchema: .object([
                    "properties": .object([
                        "wait": .object(["type": .string("boolean")]),
                    ]),
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
        #expect(snapshot.calls == ["models_explore"])
        #expect(snapshot.disconnected)
    }

    @MainActor
    @Test("A status-only asynchronous lifecycle remains discoverable without an output schema")
    func statusOnlyLifecycleRemainsDiscoverable() async {
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

        #expect(entries.map(\.id) == ["status-image"])
    }

    @MainActor
    @Test("Schema-free synchronous MCP generators remain discoverable")
    func schemaFreeSynchronousGeneratorRemainsAvailable() async {
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

        #expect(entries.map(\.id) == ["direct-image"])
    }
}
