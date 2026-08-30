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
    struct ProviderResult: Sendable {
        let provider: GenerationProvider
        let mcpConfigured: Bool
        let oauthConnected: Bool
        let entries: [CatalogEntry]
    }

    private static var running = false
    private static var queued = false
    private static var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private static var lastCompletedAt: Date?
    private static var observer: NSObjectProtocol?
    /// Bound the enumeration so a misbehaving or huge provider catalog can't loop or balloon memory.
    private static let maxPagesPerModality = 12
    private static let maxModelsPerProvider = 400

    /// Observe activation changes and run an initial pass. Idempotent — safe to call once at launch.
    static func start() {
        if observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: .providerKeysChanged, object: nil, queue: nil
            ) { _ in
                Task { @MainActor in refresh() }
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
        for provider in providers where provider.mcpCapability?.auth == .oauth {
            ModelCatalog.shared.setProviderDiscoveryState(
                ProviderMCP.hasConfig(provider) ? .checking : .inactive,
                for: provider
            )
        }
        for provider in providers where DirectImageDiscovery.providers.contains(provider) {
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
                var entries: [CatalogEntry] = []
                if mcpConfigured {
                    entries += await discover(provider)
                }
                entries += await DirectImageDiscovery.discover(provider)
                return ProviderResult(
                    provider: provider,
                    mcpConfigured: mcpConfigured,
                    oauthConnected: ProviderOAuthStore.isConnected(provider),
                    entries: entries
                )
            },
            consume: { result in
                let provider = result.provider
                let entries = result.entries
                ModelCatalog.shared.applyDiscovered(entries, for: provider)
                if !entries.isEmpty {
                    providerCount += 1
                    modelCount += entries.count
                }
                if provider.mcpCapability?.auth == .oauth {
                    let state: ProviderDiscoveryState
                    if !result.oauthConnected {
                        state = .actionRequired(
                            "Sign in again to refresh this provider's models."
                        )
                    } else if entries.isEmpty {
                        state = .unavailable(
                            "Model discovery failed. Check the connection or sign in again."
                        )
                    } else {
                        state = .ready(modelCount: entries.count)
                    }
                    ModelCatalog.shared.setProviderDiscoveryState(state, for: provider)
                } else if DirectImageDiscovery.providers.contains(provider) {
                    let state: ProviderDiscoveryState
                    if ProviderKeychain.load(provider) == nil {
                        state = .inactive
                    } else if entries.isEmpty {
                        state = .unavailable(
                            "The saved key could not load an active image-model catalog. Check the key and connection."
                        )
                    } else {
                        state = .ready(modelCount: entries.count)
                    }
                    ModelCatalog.shared.setProviderDiscoveryState(state, for: provider)
                }
                if result.mcpConfigured || ProviderKeychain.load(provider) != nil {
                    Log.generation.notice(
                        "catalog provider=\(provider.rawValue) mcp=\(result.mcpConfigured) models=\(entries.count)"
                    )
                }
            }
        )
        Log.generation.notice(
            "catalog discovery: \(providerCount) provider(s), \(modelCount) model(s)"
        )
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

    private static func discover(_ provider: GenerationProvider) async -> [CatalogEntry] {
        guard let client = await ProviderMCP.client(for: provider) else { return [] }
        return await discover(provider, client: client)
    }

    static func discover(
        _ provider: GenerationProvider,
        client: any MCPCatalogClient
    ) async -> [CatalogEntry] {
        do {
            let tools = try await client.discoverTools()
            let discoveredToolsByModality = MCPModelDiscovery.generateToolsByModality(tools)
            let hasLifecycle = MCPGenerationExecutor.hasUsableLifecycle(tools: tools)
            let toolsByModality = discoveredToolsByModality.filter { _, name in
                guard let tool = tools.first(where: { $0.name == name }) else { return false }
                return hasLifecycle
                    || MCPGenerationExecutor.hasDirectOutputContract(tool)
                    || MCPGenerationArguments.supportsSynchronousCompletion(
                        schema: tool.inputSchema
                    )
                    || MCPGenerationLifecycle.statusTool(in: tools) == nil
            }
            guard !toolsByModality.isEmpty else {
                await client.disconnect()
                return []
            }
            var entries: [CatalogEntry] = []
            var usedModelCatalog = false
            // Some providers advertise the selected model as a free-form field and expose the full
            // catalog through a separate tool; enumerate it before mapping the generation schema.
            if let hint = provider.mcpModelCatalog, tools.contains(where: { $0.name == hint.tool }) {
                usedModelCatalog = true
                let listedModels = await enumerate(
                    provider: provider,
                    client: client,
                    hint: hint,
                    modalities: Array(toolsByModality.keys)
                )
                let models = await enrichMediaContracts(
                    listedModels,
                    provider: provider,
                    client: client,
                    hint: hint
                )
                let schemas = Dictionary(uniqueKeysWithValues: toolsByModality.compactMap { modality, name in
                    tools.first(where: { $0.name == name }).map { (modality, $0.inputSchema) }
                })
                entries = MCPModelDiscovery.catalogEntries(
                    models: models, toolsByModality: toolsByModality,
                    toolSchemasByModality: schemas,
                    allowsLocalMedia: MCPMediaUpload.supportsUploadContract(tools),
                    provider: provider)
            }
            if entries.isEmpty, !usedModelCatalog {
                entries = MCPModelDiscovery.catalogEntriesFromTools(tools, provider: provider)
            }
            await client.disconnect()
            return entries
        } catch {
            await client.disconnect()
            Log.generation.notice("MCP discovery failed for \(provider.rawValue): \(error.localizedDescription)")
            return []
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
    ) async -> [MCPModelDiscovery.ModelItem] {
        var all: [MCPModelDiscovery.ModelItem] = []
        var indexByModelID: [String: Int] = [:]
        for modality in modalities where modality != .upscale {
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
                    Log.generation.notice(
                        "catalog listing failed provider=\(provider.rawValue) modality=\(modality.rawValue): \(error.localizedDescription)"
                    )
                    break
                }
                let parsed = texts.map {
                    MCPModelDiscovery.parseListing(
                        $0,
                        defaultOutputType: modality.rawValue
                    )
                }
                let items = parsed.flatMap { $0.items }
                let cursors = Set(parsed.compactMap { $0.next })
                guard cursors.count <= 1 else {
                    Log.generation.notice(
                        "catalog listing returned conflicting cursors provider=\(provider.rawValue) modality=\(modality.rawValue)"
                    )
                    break
                }
                let next = cursors.first
                if items.isEmpty, next == nil, pages == 0 {
                    Log.generation.notice(
                        "catalog listing returned no models provider=\(provider.rawValue) modality=\(modality.rawValue)"
                    )
                }
                for item in items where !item.id.isEmpty {
                    if let existingIndex = indexByModelID[item.id] {
                        all[existingIndex] = all[existingIndex].merging(
                            item,
                            resolvingMediaDetails: false
                        )
                    } else {
                        indexByModelID[item.id] = all.count
                        all.append(item)
                    }
                }
                if let next, !seenCursors.insert(next).inserted {
                    Log.generation.notice(
                        "catalog listing repeated cursor provider=\(provider.rawValue) modality=\(modality.rawValue)"
                    )
                    cursor = nil
                } else {
                    cursor = next
                }
                pages += 1
            } while cursor != nil && pages < maxPagesPerModality && all.count < maxModelsPerProvider
        }
        return all
    }

    private static func enrichMediaContracts(
        _ models: [MCPModelDiscovery.ModelItem],
        provider: GenerationProvider,
        client: any MCPCatalogClient,
        hint: MCPModelCatalog
    ) async -> [MCPModelDiscovery.ModelItem] {
        guard let detailArgs = hint.detailArgs,
              let detailModelArg = hint.detailModelArg else { return models }
        var enriched = models
        for index in enriched.indices {
            let model = enriched[index]
            guard let modality = MCPModelDiscovery.modalityOf(model),
                  modality == .image || modality == .video else { continue }
            var args = detailArgs
            args[detailModelArg] = model.id
            do {
                let payloads = try await client.callTool(
                    name: hint.tool,
                    arguments: args.mapValues(Value.string)
                )
                let details = payloads.flatMap {
                    MCPModelDiscovery.parseListing(
                        $0,
                        defaultOutputType: model.outputType
                    ).items
                }
                let matching = details.filter { $0.id == model.id }
                guard !matching.isEmpty else {
                    Log.generation.notice(
                        "catalog detail returned no matching model provider=\(provider.rawValue) model=\(model.id)"
                    )
                    continue
                }
                enriched[index] = matching.reduce(model) {
                    $0.merging($1, resolvingMediaDetails: true)
                }
            } catch {
                Log.generation.notice(
                    "catalog detail failed provider=\(provider.rawValue) model=\(model.id): \(error.localizedDescription)"
                )
            }
        }
        return enriched
    }
}
