import Foundation

/// Runtime MCP model discovery (#163): for every activated MCP provider, NGV connects as the MCP
/// client, learns the provider's generate tools (`tools/list`), enumerates its models, and layers
/// them onto the catalog — so one "Sign in" makes the provider's models simply appear, gated and
/// runnable. The pure mapping is `MCPModelDiscovery`; this is the I/O + wiring around it.
///
/// Self-correcting: each refresh rediscovers every activated provider and replaces the discovered set
/// wholesale, so a signed-out provider's models vanish (usable-only, #159). Runs at launch and on
/// every `.providerKeysChanged` (sign-in / sign-out / key change), coalescing overlapping runs.
@MainActor
enum MCPCatalogDiscovery {
    private static var running = false
    private static var queued = false
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
        }
    }

    private static func runOnce() async {
        var result: [GenerationProvider: [CatalogEntry]] = [:]
        for provider in GenerationProvider.allCases where ProviderMCP.hasConfig(provider) {
            let entries = await discover(provider)
            if !entries.isEmpty { result[provider] = entries }
        }
        ModelCatalog.shared.setDiscovered(result)
        Log.generation.notice("MCP discovery: \(result.count) provider(s), \(result.values.map(\.count).reduce(0, +)) model(s)")
    }

    private static func discover(_ provider: GenerationProvider) async -> [CatalogEntry] {
        guard let client = await ProviderMCP.client(for: provider) else { return [] }
        do {
            let tools = try await client.discoverTools()
            let toolsByModality = MCPModelDiscovery.generateToolsByModality(tools)
            guard !toolsByModality.isEmpty else {
                await client.disconnect()
                return []
            }
            var entries: [CatalogEntry] = []
            // A provider whose generate tools take a free-form `model` id (Higgsfield) advertises its
            // full catalog through a separate tool; enumerate it. Otherwise (or if that yields nothing)
            // map the discovered generate tools directly.
            if let hint = provider.mcpModelCatalog, tools.contains(where: { $0.name == hint.tool }) {
                let models = await enumerate(client: client, hint: hint,
                                             modalities: Array(toolsByModality.keys))
                entries = MCPModelDiscovery.catalogEntries(
                    models: models, toolsByModality: toolsByModality, provider: provider)
            }
            if entries.isEmpty {
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
        client: MCPProviderClient, hint: MCPModelCatalog, modalities: [MCPModelDiscovery.Modality]
    ) async -> [MCPModelDiscovery.ModelItem] {
        var all: [MCPModelDiscovery.ModelItem] = []
        for modality in modalities where modality != .upscale {
            var cursor: String?
            var pages = 0
            repeat {
                var args = hint.listArgs
                if let typeArg = hint.typeArg { args[typeArg] = modality.rawValue }
                if let cursorArg = hint.cursorArg, let cursor { args[cursorArg] = cursor }
                let texts: [String]
                do { texts = try await client.callTool(name: hint.tool, arguments: args) }
                catch { break }
                let (items, next) = MCPModelDiscovery.parseListing(texts.first ?? "")
                all.append(contentsOf: items)
                cursor = next
                pages += 1
            } while cursor != nil && pages < maxPagesPerModality && all.count < maxModelsPerProvider
        }
        return all
    }
}
