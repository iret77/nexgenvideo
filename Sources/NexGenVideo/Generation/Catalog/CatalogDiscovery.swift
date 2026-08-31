import Foundation
import MCP

protocol MCPCatalogClient: MCPToolCalling {
    func discoverTools() async throws -> [MCPProviderClient.DiscoveredTool]
    func disconnect() async
}

extension MCPProviderClient: MCPCatalogClient {}

/// Runtime model discovery — the layer that makes activation, not a hardcoded list, decide what the
/// catalog offers. Two sources, one write:
///
/// - **MCP providers** (#163): NGV connects as the MCP client, learns the provider's generate tools
///   (`tools/list`), enumerates its models. The pure mapping is `MCPModelDiscovery`.
/// - **Direct-API image providers** (#212): the provider's own model list decides which registry
///   entries are really reachable on this key (`DirectImageDiscovery`).
///
/// Each provider publishes its own discovered slice as soon as it finishes. This prevents a slow
/// provider from hiding already-runnable models from the open generation and approval surfaces.
///
/// Self-correcting: each refresh rediscovers every activated provider, so a signed-out provider's (or
/// a revoked key's) models vanish (usable-only, #159). Runs at launch and on every
/// `.providerKeysChanged` (sign-in / sign-out / key change), coalescing overlapping runs.
@MainActor
enum CatalogDiscovery {
    struct MCPDiscoveryResult: Sendable {
        let entries: [CatalogEntry]
        let modelListingIsComplete: Bool
        let detailEnrichmentIsComplete: Bool
    }

    enum MCPListingPublicationDecision: Equatable, Sendable {
        case publish
        case withholdIncompleteFirstRefresh
        case preserveLastKnownGood
    }

    private struct EnumerationResult: Sendable {
        let models: [MCPModelDiscovery.ModelItem]
        let isComplete: Bool
    }

    private struct EnrichmentResult: Sendable {
        let models: [MCPModelDiscovery.ModelItem]
        let isComplete: Bool
    }

    private struct DetailCacheKey: Hashable, Sendable {
        let provider: GenerationProvider
        let modelID: String
    }

    private struct DetailCacheValue: Sendable {
        let listedModel: MCPModelDiscovery.ModelItem
        let details: [MCPModelDiscovery.ModelItem]
    }

    private struct DetailRequest: Sendable {
        let index: Int
        let key: DetailCacheKey
        let cacheGeneration: UInt64
        let model: MCPModelDiscovery.ModelItem
        let arguments: [String: String]
        let staleDetails: [MCPModelDiscovery.ModelItem]
    }

    private enum DetailResponse: Sendable {
        case success(DetailRequest, [MCPModelDiscovery.ModelItem])
        case failure(DetailRequest, String)
    }

    struct ProviderResult: Sendable {
        let provider: GenerationProvider
        let mcpConfigured: Bool
        let oauthConnected: Bool
        let entries: [CatalogEntry]
        let directResult: DirectImageDiscovery.Result
        let mcpModelListingIsComplete: Bool
        let mcpDetailEnrichmentIsComplete: Bool

        init(
            provider: GenerationProvider,
            mcpConfigured: Bool,
            oauthConnected: Bool,
            entries: [CatalogEntry],
            directResult: DirectImageDiscovery.Result = .inactive,
            mcpModelListingIsComplete: Bool = true,
            mcpDetailEnrichmentIsComplete: Bool = true
        ) {
            self.provider = provider
            self.mcpConfigured = mcpConfigured
            self.oauthConnected = oauthConnected
            self.entries = entries
            self.directResult = directResult
            self.mcpModelListingIsComplete = mcpModelListingIsComplete
            self.mcpDetailEnrichmentIsComplete = mcpDetailEnrichmentIsComplete
        }
    }

    private static var running = false
    private static var queued = false
    private static var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private static var lastCompletedAt: Date?
    private static var observer: NSObjectProtocol?
    private static var detailCache: [DetailCacheKey: DetailCacheValue] = [:]
    private static var detailCacheGeneration: UInt64 = 0
    /// Bound the enumeration so a misbehaving or huge provider catalog can't loop or balloon memory.
    private static let maxPagesPerModality = 12
    private static let maxModelsPerProvider = 400
    private static let maxConcurrentDetailRequests = 4

    /// Observe activation changes and run an initial pass. Idempotent — safe to call once at launch.
    static func start() {
        if observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: .providerKeysChanged, object: nil, queue: nil
            ) { _ in
                Task { @MainActor in
                    invalidateDetailCache()
                    refresh()
                }
            }
        }
        refresh()
    }

    /// Re-discover all activated MCP providers. Coalesces: a trigger during a run schedules exactly one
    /// more run after it finishes, so a burst of notifications collapses to a single follow-up.
    static func refresh() {
        guard !running else { queued = true; return }
        running = true
        Task { @MainActor in
            repeat {
                queued = false
                await runOnce()
            } while queued
            running = false
            lastCompletedAt = Date()
            let completedWaiters = waiters.values
            waiters.removeAll()
            for waiter in completedWaiters { waiter.resume() }
        }
    }

    static func invalidateDetailCache() {
        detailCacheGeneration &+= 1
        detailCache.removeAll()
    }

    static func ensureCurrent(
        maxAge: TimeInterval = 60,
        maxWait: TimeInterval = 60
    ) async {
        if let lastCompletedAt,
           !running,
           Date().timeIntervalSince(lastCompletedAt) <= maxAge {
            return
        }
        let waiterID = UUID()
        await withCheckedContinuation { continuation in
            waiters[waiterID] = continuation
            if !running { refresh() }
            Task { @MainActor in
                let boundedWait = maxWait.isFinite ? max(0, min(maxWait, 60)) : 10
                if boundedWait > 0 {
                    try? await Task.sleep(
                        nanoseconds: UInt64(boundedWait * 1_000_000_000)
                    )
                }
                guard let waiter = waiters.removeValue(forKey: waiterID) else { return }
                Log.generation.notice(
                    "catalog readiness wait ended after \(boundedWait)s; discovery continues"
                )
                waiter.resume()
            }
        }
    }

    private static func runOnce() async {
        let providers = GenerationProvider.allCases
        let configuredOAuthProviders = Set(providers.filter { provider in
            guard provider.mcpCapability?.auth == .oauth else { return false }
            if ProviderMCP.hasConfig(provider) || ProviderOAuthStore.load(provider) != nil {
                return true
            }
            if ModelCatalog.shared.discoveredModelCount(for: provider) > 0 {
                return true
            }
            switch ModelCatalog.shared.providerDiscovery[provider] {
            case .checking, .ready, .stale, .actionRequired, .unavailable:
                return true
            case .inactive, .none:
                return false
            }
        })
        for provider in providers where provider.mcpCapability?.auth == .oauth {
            ModelCatalog.shared.setProviderDiscoveryState(
                ProviderMCP.hasConfig(provider) ? .checking : .inactive,
                for: provider
            )
        }
        for provider in providers where DirectImageDiscovery.providers.contains(provider) {
            if ProviderKeychain.load(provider) != nil {
                ModelCatalog.shared.beginDirectDiscovery(for: provider)
            }
            ModelCatalog.shared.setProviderDiscoveryState(
                ProviderKeychain.load(provider) == nil ? .inactive : .checking,
                for: provider
            )
        }
        var modelCount = 0
        var providerCount = 0
        await forEachProviderResult(
            providers,
            operation: { provider in
                let mcpConfigured = ProviderMCP.hasConfig(provider)
                var mcpResult = MCPDiscoveryResult(
                    entries: [],
                    modelListingIsComplete: true,
                    detailEnrichmentIsComplete: true
                )
                if mcpConfigured {
                    mcpResult = await discoverResult(provider)
                }
                return ProviderResult(
                    provider: provider,
                    mcpConfigured: mcpConfigured,
                    oauthConnected: ProviderOAuthStore.isConnected(provider),
                    entries: mcpResult.entries,
                    directResult: await DirectImageDiscovery.discover(provider),
                    mcpModelListingIsComplete: mcpResult.modelListingIsComplete,
                    mcpDetailEnrichmentIsComplete: mcpResult.detailEnrichmentIsComplete
                )
            },
            consume: { result in
                let provider = result.provider
                var publishedEntries = result.entries
                var directState: ProviderDiscoveryState?
                let retainedCount = ModelCatalog.shared.discoveredModelCount(for: provider)
                switch result.directResult {
                case .inactive:
                    break
                case .success(let entries):
                    publishedEntries += entries
                    directState = .ready(modelCount: entries.count)
                case .authenticationFailure(let message):
                    directState = .actionRequired(message)
                case .unavailableFailure(let message):
                    directState = .unavailable(message)
                case .transientFailure(let message):
                    if retainedCount > 0 {
                        directState = .stale(modelCount: retainedCount, message: message)
                    } else {
                        directState = .unavailable(message)
                    }
                }
                let preserveDirectCatalog = DirectImageDiscovery.preservesLastKnownGood(
                    after: result.directResult,
                    currentModelCount: retainedCount
                )
                let mcpPublicationDecision = result.mcpConfigured && result.oauthConnected
                    ? mcpListingPublicationDecision(
                        listingIsComplete: result.mcpModelListingIsComplete,
                        retainedModelCount: retainedCount
                    )
                    : .publish
                if result.mcpConfigured,
                   provider.mcpCapability?.auth == .oauth,
                   !result.oauthConnected {
                    publishedEntries = []
                }
                if preserveDirectCatalog || mcpPublicationDecision != .publish {
                    publishedEntries = []
                } else {
                    ModelCatalog.shared.applyDiscovered(publishedEntries, for: provider)
                }
                let visibleCount = publishedEntries.isEmpty
                    ? ModelCatalog.shared.discoveredModelCount(for: provider)
                    : publishedEntries.count
                if visibleCount > 0 {
                    providerCount += 1
                    modelCount += visibleCount
                }
                if provider.mcpCapability?.auth == .oauth {
                    let state: ProviderDiscoveryState
                    if !result.oauthConnected {
                        state = oauthDisconnectedState(
                            wasConfigured: configuredOAuthProviders.contains(provider)
                        )
                    } else if mcpPublicationDecision == .preserveLastKnownGood {
                        state = .stale(
                            modelCount: retainedCount,
                            message: "Model refresh is incomplete. The last verified catalog remains available."
                        )
                    } else if mcpPublicationDecision == .withholdIncompleteFirstRefresh {
                        state = .unavailable(
                            "Model refresh is incomplete. Check the connection and try again."
                        )
                    } else if publishedEntries.isEmpty {
                        state = .unavailable(
                            "Model discovery failed. Check the connection or sign in again."
                        )
                    } else if !result.mcpDetailEnrichmentIsComplete {
                        state = .stale(
                            modelCount: publishedEntries.count,
                            message: "Some model details could not be refreshed. Try again later."
                        )
                    } else {
                        state = .ready(modelCount: publishedEntries.count)
                    }
                    ModelCatalog.shared.setProviderDiscoveryState(state, for: provider)
                } else if DirectImageDiscovery.providers.contains(provider) {
                    let state = ProviderKeychain.load(provider) == nil
                        ? ProviderDiscoveryState.inactive
                        : directState ?? .unavailable(
                            "The saved key could not load an active image-model catalog. Check the key and connection."
                        )
                    ModelCatalog.shared.setProviderDiscoveryState(state, for: provider)
                }
                if result.mcpConfigured || ProviderKeychain.load(provider) != nil {
                    Log.generation.notice(
                        "catalog provider=\(provider.rawValue) mcp=\(result.mcpConfigured) models=\(visibleCount)"
                    )
                }
            }
        )
        Log.generation.notice(
            "catalog discovery: \(providerCount) provider(s), \(modelCount) model(s)"
        )
    }

    static func oauthDisconnectedState(
        wasConfigured: Bool
    ) -> ProviderDiscoveryState {
        wasConfigured
            ? .actionRequired("Sign in again to refresh this provider's models.")
            : .inactive
    }

    static func mcpListingPublicationDecision(
        listingIsComplete: Bool,
        retainedModelCount: Int
    ) -> MCPListingPublicationDecision {
        guard !listingIsComplete else { return .publish }
        return retainedModelCount > 0
            ? .preserveLastKnownGood
            : .withholdIncompleteFirstRefresh
    }

    static func forEachProviderResult(
        _ providers: [GenerationProvider],
        operation: @escaping @Sendable @MainActor (GenerationProvider) async -> ProviderResult,
        consume: @MainActor (ProviderResult) -> Void
    ) async {
        await withTaskGroup(of: ProviderResult.self) { group in
            for provider in providers {
                group.addTask {
                    await operation(provider)
                }
            }
            for await result in group {
                consume(result)
            }
        }
    }

    private static func discoverResult(_ provider: GenerationProvider) async -> MCPDiscoveryResult {
        guard let client = await ProviderMCP.client(for: provider) else {
            return MCPDiscoveryResult(
                entries: [],
                modelListingIsComplete: false,
                detailEnrichmentIsComplete: false
            )
        }
        return await discoverResult(provider, client: client)
    }

    static func discover(
        _ provider: GenerationProvider,
        client: any MCPCatalogClient
    ) async -> [CatalogEntry] {
        await discoverResult(provider, client: client).entries
    }

    static func discoverResult(
        _ provider: GenerationProvider,
        client: any MCPCatalogClient
    ) async -> MCPDiscoveryResult {
        do {
            let tools = try await client.discoverTools()
            let discoveredToolsByModality = MCPModelDiscovery.generateToolsByModality(tools)
            let toolsByModality = discoveredToolsByModality.filter { _, name in
                guard let tool = tools.first(where: { $0.name == name }) else { return false }
                return MCPGenerationExecutor.hasProvenResultPath(
                    generationTool: tool,
                    tools: tools
                )
            }
            guard !toolsByModality.isEmpty else {
                await client.disconnect()
                return MCPDiscoveryResult(
                    entries: [],
                    modelListingIsComplete: true,
                    detailEnrichmentIsComplete: true
                )
            }
            var entries: [CatalogEntry] = []
            var modelListingIsComplete = true
            var detailEnrichmentIsComplete = true
            var usedModelCatalog = false
            // Some providers advertise the selected model as a free-form field and expose the full
            // catalog through a separate tool; enumerate it before mapping the generation schema.
            if let hint = provider.mcpModelCatalog, tools.contains(where: { $0.name == hint.tool }) {
                usedModelCatalog = true
                let enumeration = await enumerate(
                    provider: provider,
                    client: client,
                    hint: hint,
                    modalities: Array(toolsByModality.keys)
                )
                let enrichment: EnrichmentResult
                if enumeration.isComplete {
                    enrichment = await enrichMediaContracts(
                        enumeration.models,
                        provider: provider,
                        client: client,
                        hint: hint
                    )
                } else {
                    enrichment = EnrichmentResult(
                        models: enumeration.models,
                        isComplete: false
                    )
                }
                modelListingIsComplete = enumeration.isComplete
                detailEnrichmentIsComplete = enrichment.isComplete
                let schemas = Dictionary(uniqueKeysWithValues: toolsByModality.compactMap { modality, name in
                    tools.first(where: { $0.name == name }).map { (modality, $0.inputSchema) }
                })
                entries = MCPModelDiscovery.catalogEntries(
                    models: enrichment.models, toolsByModality: toolsByModality,
                    toolSchemasByModality: schemas,
                    allowsLocalMedia: MCPMediaUpload.supportsUploadContract(tools),
                    provider: provider)
            }
            if entries.isEmpty, !usedModelCatalog {
                let usableGenerationTools = tools.filter { tool in
                    toolsByModality.values.contains(tool.name)
                }
                entries = MCPModelDiscovery.catalogEntriesFromTools(
                    usableGenerationTools,
                    provider: provider
                )
            }
            await client.disconnect()
            return MCPDiscoveryResult(
                entries: entries,
                modelListingIsComplete: modelListingIsComplete,
                detailEnrichmentIsComplete: detailEnrichmentIsComplete
            )
        } catch {
            await client.disconnect()
            Log.generation.notice("MCP discovery failed for \(provider.rawValue): \(error.localizedDescription)")
            return MCPDiscoveryResult(
                entries: [],
                modelListingIsComplete: false,
                detailEnrichmentIsComplete: false
            )
        }
    }

    /// Page the provider's model-catalog tool, once per modality that has a generate tool (upscale is
    /// excluded — it has no catalog `type` and stays a REST/workflow op). Stops at the page/model caps
    /// or the first failing page.
    private static func enumerate(
        provider: GenerationProvider,
        client: any MCPCatalogClient,
        hint: MCPModelCatalog,
        modalities: [MCPModelDiscovery.Modality]
    ) async -> EnumerationResult {
        var all: [MCPModelDiscovery.ModelItem] = []
        var indexByModelID: [String: Int] = [:]
        var isComplete = true
        modalityLoop: for modality in modalities where modality != .upscale {
            guard all.count < maxModelsPerProvider else {
                isComplete = false
                Log.generation.notice(
                    "catalog listing reached model limit before modality provider=\(provider.rawValue) modality=\(modality.rawValue) limit=\(maxModelsPerProvider)"
                )
                break modalityLoop
            }
            var cursor: String?
            var seenCursors = Set<String>()
            var pages = 0
            repeat {
                var args = hint.listArgs
                if let typeArg = hint.typeArg { args[typeArg] = modality.rawValue }
                if let cursorArg = hint.cursorArg, let cursor { args[cursorArg] = cursor }
                let texts: [String]
                do {
                    texts = try await client.callTool(
                        name: hint.tool,
                        arguments: args.mapValues(Value.string)
                    )
                }
                catch {
                    isComplete = false
                    Log.generation.notice(
                        "catalog listing failed provider=\(provider.rawValue) modality=\(modality.rawValue): \(error.localizedDescription)"
                    )
                    break
                }
                let parsed = texts.map {
                    MCPModelDiscovery.parseListingResult(
                        $0,
                        defaultOutputType: modality.rawValue
                    )
                }
                let catalogPayloads = parsed.filter(\.isCatalogPayload)
                if catalogPayloads.isEmpty {
                    isComplete = false
                    Log.generation.notice(
                        "catalog listing returned no decodable catalog payload provider=\(provider.rawValue) modality=\(modality.rawValue)"
                    )
                } else if catalogPayloads.contains(where: {
                    !$0.structuralAndDecodeIsComplete
                }) {
                    isComplete = false
                    Log.generation.notice(
                        "catalog listing was only partially decoded provider=\(provider.rawValue) modality=\(modality.rawValue)"
                    )
                }
                let items = catalogPayloads.flatMap(\.items)
                let pageIsStructurallyComplete = !catalogPayloads.isEmpty
                    && catalogPayloads.allSatisfy(\.structuralAndDecodeIsComplete)
                let pagination = MCPModelDiscovery.PaginationEvidence.aggregating(
                    catalogPayloads.map(\.pagination)
                )
                if !pagination.isComplete {
                    isComplete = false
                    Log.generation.notice(
                        "catalog listing returned conflicting pagination provider=\(provider.rawValue) modality=\(modality.rawValue)"
                    )
                }
                var next = pageIsStructurallyComplete && pagination.isComplete
                    ? pagination.next
                    : nil
                if items.isEmpty, next != nil {
                    isComplete = false
                    next = nil
                    Log.generation.notice(
                        "catalog listing returned an empty page with continuation provider=\(provider.rawValue) modality=\(modality.rawValue)"
                    )
                }
                if items.isEmpty, next == nil, pages == 0 {
                    Log.generation.notice(
                        "catalog listing returned no models provider=\(provider.rawValue) modality=\(modality.rawValue)"
                    )
                }
                var exceededModelLimit = false
                for item in items where !item.id.isEmpty {
                    if let existingIndex = indexByModelID[item.id] {
                        all[existingIndex] = all[existingIndex].merging(
                            item,
                            resolvingMediaDetails: false
                        )
                    } else {
                        guard all.count < maxModelsPerProvider else {
                            exceededModelLimit = true
                            isComplete = false
                            Log.generation.notice(
                                "catalog listing exceeded model limit provider=\(provider.rawValue) limit=\(maxModelsPerProvider)"
                            )
                            break
                        }
                        indexByModelID[item.id] = all.count
                        all.append(item)
                    }
                }
                if exceededModelLimit { break modalityLoop }
                if let next, !seenCursors.insert(next).inserted {
                    isComplete = false
                    Log.generation.notice(
                        "catalog listing repeated cursor provider=\(provider.rawValue) modality=\(modality.rawValue)"
                    )
                    cursor = nil
                } else {
                    cursor = next
                }
                pages += 1
            } while cursor != nil && pages < maxPagesPerModality && all.count < maxModelsPerProvider
            if cursor != nil {
                isComplete = false
                if all.count >= maxModelsPerProvider { break modalityLoop }
            }
        }
        return EnumerationResult(models: all, isComplete: isComplete)
    }

    private static func enrichMediaContracts(
        _ models: [MCPModelDiscovery.ModelItem],
        provider: GenerationProvider,
        client: any MCPCatalogClient,
        hint: MCPModelCatalog
    ) async -> EnrichmentResult {
        guard let detailArgs = hint.detailArgs,
              let detailModelArg = hint.detailModelArg else {
            return EnrichmentResult(models: models, isComplete: true)
        }
        var enriched = models
        var pending: [DetailRequest] = []
        for (index, model) in enriched.enumerated() {
            guard let modality = MCPModelDiscovery.modalityOf(model),
                  modality == .image || modality == .video else { continue }
            let key = DetailCacheKey(provider: provider, modelID: model.id)
            if let cached = detailCache[key], cached.listedModel == model {
                enriched[index] = cached.details.reduce(model) {
                    $0.merging($1, resolvingMediaDetails: true)
                }
                continue
            }
            var args = detailArgs
            args[detailModelArg] = model.id
            pending.append(DetailRequest(
                index: index,
                key: key,
                cacheGeneration: detailCacheGeneration,
                model: model,
                arguments: args,
                staleDetails: detailCache[key]?.details ?? []
            ))
        }
        var isComplete = true
        for batchStart in stride(
            from: 0,
            to: pending.count,
            by: maxConcurrentDetailRequests
        ) {
            let batchEnd = min(batchStart + maxConcurrentDetailRequests, pending.count)
            let batch = Array(pending[batchStart..<batchEnd])
            let responses = await withTaskGroup(
                of: DetailResponse.self,
                returning: [DetailResponse].self
            ) { group in
                for request in batch {
                    group.addTask {
                        await fetchDetail(request, tool: hint.tool, client: client)
                    }
                }
                var fetched: [DetailResponse] = []
                for await response in group { fetched.append(response) }
                return fetched
            }
            for response in responses {
                switch response {
                case .success(let request, let details) where !details.isEmpty:
                    if request.cacheGeneration == detailCacheGeneration {
                        detailCache[request.key] = DetailCacheValue(
                            listedModel: request.model,
                            details: details
                        )
                    }
                    enriched[request.index] = details.reduce(request.model) {
                        $0.merging($1, resolvingMediaDetails: true)
                    }
                case .success(let request, _):
                    isComplete = false
                    Log.generation.notice(
                        "catalog detail returned no matching model provider=\(provider.rawValue) model=\(request.model.id)"
                    )
                    enriched[request.index] = request.staleDetails.reduce(request.model) {
                        $0.merging($1, resolvingMediaDetails: true)
                    }
                case .failure(let request, let message):
                    isComplete = false
                    Log.generation.notice(
                        "catalog detail failed provider=\(provider.rawValue) model=\(request.model.id): \(message)"
                    )
                    enriched[request.index] = request.staleDetails.reduce(request.model) {
                        $0.merging($1, resolvingMediaDetails: true)
                    }
                }
            }
        }
        return EnrichmentResult(models: enriched, isComplete: isComplete)
    }

    private static func fetchDetail(
        _ request: DetailRequest,
        tool: String,
        client: any MCPCatalogClient
    ) async -> DetailResponse {
        do {
            let payloads = try await client.callTool(
                name: tool,
                arguments: request.arguments.mapValues(Value.string)
            )
            let parsed = payloads.map {
                MCPModelDiscovery.parseListingResult(
                    $0,
                    defaultOutputType: request.model.outputType,
                    context: .detail
                )
            }
            let catalogPayloads = parsed.filter(\.isCatalogPayload)
            guard !catalogPayloads.isEmpty else {
                return .failure(request, "No decodable model-detail payload")
            }
            guard catalogPayloads.allSatisfy(\.isComplete) else {
                return .failure(request, "Model-detail payload was only partially decoded")
            }
            let details = catalogPayloads.flatMap(\.items).filter { $0.id == request.model.id }
            return .success(request, details)
        } catch {
            return .failure(request, error.localizedDescription)
        }
    }
}
