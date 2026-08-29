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
        maxWait: TimeInterval = 10
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
            let toolsByModality = MCPModelDiscovery.generateToolsByModality(tools)
            guard !toolsByModality.isEmpty else {
                await client.disconnect()
                return []
            }
            do {
                try MCPGenerationExecutor.validateLifecycleIfAdvertised(tools: tools)
            } catch {
                await client.disconnect()
                Log.generation.notice(
                    "MCP discovery rejected \(provider.rawValue)'s lifecycle contract: \(error.localizedDescription)"
                )
                return []
            }
            var entries: [CatalogEntry] = []
            var usedModelCatalog = false
            // A provider whose generate tools take a free-form `model` id (Higgsfield) advertises its
            // full catalog through a separate tool; enumerate it. Otherwise (or if that yields nothing)
            // map the discovered generate tools directly.
            if let hint = provider.mcpModelCatalog, tools.contains(where: { $0.name == hint.tool }) {
                usedModelCatalog = true
                let models = await enumerate(provider: provider, client: client, hint: hint,
                                             modalities: Array(toolsByModality.keys))
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
                let parsed = texts.map(MCPModelDiscovery.parseListing)
                let page = parsed.first(where: { !$0.items.isEmpty || $0.next != nil })
                    ?? (items: [], next: nil)
                let (items, next) = page
                if items.isEmpty, next == nil, pages == 0 {
                    Log.generation.notice(
                        "catalog listing returned no models provider=\(provider.rawValue) modality=\(modality.rawValue)"
                    )
                }
                all.append(contentsOf: items)
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
}
