import Foundation
import NexGenEngine
import Testing
@testable import NexGenVideo

@Suite("Anthropic model discovery")
@MainActor
struct AnthropicModelCatalogTests {
    typealias F = AnthropicModelFixtures

    @Test("discovery follows has_more/last_id pagination with the documented headers")
    func pagination() async throws {
        let recorder = RecordingModelsTransport(pages: [
            .success(try F.page([F.sonnet55, F.opus55], hasMore: true)),
            .success(try F.page([F.haiku55, F.haiku45], hasMore: false)),
        ])
        let models = try await AnthropicModelsAPI.fetchAll(apiKey: "sk-test", transport: recorder.transport)
        #expect(models.map(\.id) == [
            "claude-sonnet-5-5", "claude-opus-5-5", "claude-haiku-5-5", "claude-haiku-4-5-20251001",
        ])
        let requests = recorder.recorded
        #expect(requests.count == 2)
        let first = try #require(requests.first.flatMap { $0.url }.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
        let second = try #require(requests.last.flatMap { $0.url }.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
        #expect(first.path == "/v1/models")
        #expect(first.queryItems?.first(where: { $0.name == "after_id" }) == nil)
        #expect(first.queryItems?.first(where: { $0.name == "limit" })?.value == "1000")
        #expect(second.queryItems?.first(where: { $0.name == "after_id" })?.value == "claude-opus-5-5")
        #expect(requests.first?.value(forHTTPHeaderField: "x-api-key") == "sk-test")
        #expect(requests.first?.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(requests.first?.httpMethod == "GET")
    }

    @Test("a failed page or HTTP error fails discovery instead of returning a partial list")
    func discoveryErrors() async throws {
        let unauthorized = RecordingModelsTransport(pages: [.success(Data("{}".utf8))], status: 401)
        await #expect(throws: AnthropicModelsAPI.DiscoveryError.http(status: 401)) {
            _ = try await AnthropicModelsAPI.fetchAll(apiKey: "sk", transport: unauthorized.transport)
        }
        let empty = RecordingModelsTransport(pages: [.success(try F.page([], hasMore: false))])
        await #expect(throws: AnthropicModelsAPI.DiscoveryError.emptyList) {
            _ = try await AnthropicModelsAPI.fetchAll(apiKey: "sk", transport: empty.transport)
        }
    }

    private func pageWithoutCursor() throws -> Data {
        let body: [String: Any] = ["data": [F.sonnet55], "has_more": true]
        return try JSONSerialization.data(withJSONObject: body)
    }

    @Test("more pages without a usable cursor or past the page limit fail discovery")
    func incompletePaginationFails() async throws {
        let missingCursor = RecordingModelsTransport(pages: [.success(try pageWithoutCursor())])
        await #expect(throws: AnthropicModelsAPI.DiscoveryError.incompletePagination) {
            _ = try await AnthropicModelsAPI.fetchAll(apiKey: "sk", transport: missingCursor.transport)
        }
        let repeatedCursor = RecordingModelsTransport(pages: [
            .success(try F.page([F.sonnet55], hasMore: true)),
            .success(try F.page([F.opus55, F.sonnet55], hasMore: true)),
            .success(try F.page([F.sonnet55], hasMore: true)),
        ])
        await #expect(throws: AnthropicModelsAPI.DiscoveryError.incompletePagination) {
            _ = try await AnthropicModelsAPI.fetchAll(apiKey: "sk", transport: repeatedCursor.transport)
        }
        #expect(repeatedCursor.recorded.count == 2)
        let endless = RecordingModelsTransport(pages: try (0..<AnthropicModelsAPI.maximumPages).map {
            index -> Result<Data, Error> in
            .success(try F.page([F.entry(id: "claude-page-\(index)", name: "Page \(index)",
                created: "2026-01-01T00:00:00Z", line: "page")], hasMore: true))
        })
        await #expect(throws: AnthropicModelsAPI.DiscoveryError.pageLimitReached) {
            _ = try await AnthropicModelsAPI.fetchAll(apiKey: "sk", transport: endless.transport)
        }
        #expect(endless.recorded.count == AnthropicModelsAPI.maximumPages)
    }

    @Test("a page without a boolean has_more is an invalid response")
    func hasMoreIsRequired() async throws {
        for hasMore in [nil, "false", 0] as [Any?] {
            var body: [String: Any] = ["data": [F.sonnet55], "last_id": "claude-sonnet-5-5"]
            if let hasMore { body["has_more"] = hasMore }
            let transport = RecordingModelsTransport(pages: [.success(try JSONSerialization.data(withJSONObject: body))])
            await #expect(throws: AnthropicModelsAPI.DiscoveryError.invalidResponse) {
                _ = try await AnthropicModelsAPI.fetchAll(apiKey: "sk", transport: transport.transport)
            }
        }
        let valid = RecordingModelsTransport(pages: [.success(try F.page([F.sonnet55], hasMore: false))])
        #expect(try await AnthropicModelsAPI.fetchAll(apiKey: "sk", transport: valid.transport).map(\.id)
            == ["claude-sonnet-5-5"])
    }

    @Test("an incomplete model list keeps the cached list and the stored choice")
    func incompleteListIsNotCurrent() async throws {
        let defaults = F.isolatedDefaults()
        let cached = F.models([F.sonnet46, F.opus55])
        AnthropicModelCatalogStore(defaults: defaults).saveCatalog(cached)
        defaults.set("claude-opus-4-8", forKey: "agentModel")
        let partial = RecordingModelsTransport(pages: [.success(try pageWithoutCursor())])
        let service = AgentService(
            refreshBackendStatusOnInit: false,
            modelCatalogDefaults: defaults,
            modelDiscoveryTransport: partial.transport
        )
        await service.refreshModelCatalog(apiKey: "sk-test")
        #expect(!service.modelListIsCurrent)
        #expect(service.availableModels == cached)
        #expect(service.effectiveModel?.id == "claude-opus-4-8")
        #expect(service.modelDiscoveryError != nil)
        #expect(defaults.string(forKey: "agentModel") == "claude-opus-4-8")
        #expect(AnthropicModelCatalogStore(defaults: defaults).cachedModels() == cached)
    }

    @Test("a list fetched with the previous key never becomes current after a key change")
    func keyChangeInvalidatesInFlightDiscovery() async throws {
        let defaults = F.isolatedDefaults()
        let cached = F.models([F.sonnet46, F.opus55])
        AnthropicModelCatalogStore(defaults: defaults).saveCatalog(cached)
        defaults.set("claude-opus-4-8", forKey: "agentModel")
        let transport = GatedModelsTransport()
        let keychain = GatedKeyLoader()
        let service = AgentService(
            refreshBackendStatusOnInit: false,
            modelCatalogDefaults: defaults,
            modelDiscoveryTransport: transport.transport,
            apiKeyLoader: { await keychain.load() }
        )

        let old = Task { await service.refreshModelCatalog(apiKey: "sk-old") }
        await waitUntil { transport.isWaiting("sk-old") }
        service.reloadAPIKey()
        await waitUntil { keychain.isWaiting }
        transport.respond("sk-old", with: .success(try F.page([F.sonnet55, F.opus55], hasMore: false)))
        await old.value
        #expect(!service.modelListIsCurrent)
        #expect(service.availableModels == cached)
        #expect(service.effectiveModel?.id == "claude-opus-4-8")

        keychain.release("sk-new")
        await waitUntil { transport.isWaiting("sk-new") }
        transport.respond("sk-new", with: .failure(URLError(.notConnectedToInternet)))
        await waitUntil { !service.isCheckingAPIKey && !service.isDiscoveringModels && service.modelDiscoveryError != nil }
        #expect(!service.modelListIsCurrent)
        #expect(service.availableModels == cached)
        #expect(service.effectiveModel?.id == "claude-opus-4-8")
        #expect(defaults.string(forKey: "agentModel") == "claude-opus-4-8")
        #expect(AnthropicModelCatalogStore(defaults: defaults).cachedModels() == cached)
    }

    @Test("no discovery uses the previous key while a new key loads; a replaced key's list is never current")
    func staleKeyNeverDiscoversWhileKeyReloads() async throws {
        let defaults = F.isolatedDefaults()
        defaults.set("claude-opus-4-8", forKey: "agentModel")
        let transport = GatedModelsTransport()
        let keychain = GatedKeyLoader()
        let service = AgentService(
            refreshBackendStatusOnInit: false,
            modelCatalogDefaults: defaults,
            modelDiscoveryTransport: transport.transport,
            apiKeyLoader: { await keychain.load() }
        )

        service.reloadAPIKey()
        await waitUntil { keychain.isWaiting }
        keychain.release("sk-old")
        await waitUntil { transport.isWaiting("sk-old") }
        transport.respond("sk-old", with: .success(try F.page([F.sonnet55, F.opus55], hasMore: false)))
        await waitUntil { service.modelListIsCurrent }
        #expect(service.effectiveModel?.id == "claude-opus-5-5")

        service.reloadAPIKey()
        #expect(!service.modelListIsCurrent)
        await waitUntil { keychain.isWaiting }
        let stale = Task { await service.refreshModelCatalog() }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(!transport.isWaiting("sk-old"))
        #expect(transport.requestCount("sk-old") == 1)
        transport.respond("sk-old", with: .failure(URLError(.cancelled)))
        await stale.value
        #expect(!service.modelListIsCurrent)

        keychain.release("")
        await waitUntil { !service.isCheckingAPIKey }
        #expect(!service.hasApiKey)
        #expect(!service.modelListIsCurrent)
        #expect(service.effectiveModel?.id == "claude-opus-4-8")
        #expect(defaults.string(forKey: "agentModel") == "claude-opus-4-8")
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<500 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("Timed out waiting for model discovery")
    }

    @Test("parsing reads line, release date, output limit, and capability leaves")
    func parsing() throws {
        let sonnet = F.info(F.sonnet55)
        #expect(sonnet.family == "sonnet")
        #expect(sonnet.displayName == "Claude Sonnet 5.5")
        #expect(sonnet.maxOutputTokens == 128_000)
        #expect(sonnet.supportsAdaptiveThinking)
        #expect(sonnet.supportsHighEffort)
        #expect(sonnet.createdAt == ISO8601DateFormatter().date(from: "2026-09-29T00:00:00Z"))
        let haiku = F.info(F.haiku45)
        #expect(!haiku.supportsAdaptiveThinking)
        #expect(!haiku.supportsHighEffort)
        #expect(haiku.createdAt != nil)
        var unknownLine = F.entry(id: "claude-fable-5-1", name: "Claude Fable 5.1", created: "1970-01-01T00:00:00Z", line: nil)
        #expect(F.info(unknownLine).family == nil)
        #expect(F.info(unknownLine).createdAt == nil)
        unknownLine.removeValue(forKey: "line")
        unknownLine["capabilities"] = NSNull()
        let legacy = F.info(unknownLine)
        #expect(legacy.family == "fable")
        #expect(!legacy.supportsAdaptiveThinking)
        #expect(!legacy.supportsHighEffort)
    }

    @Test("default selection is the newest Sonnet by release date, not by list order")
    func newestSonnetDefault() {
        let models = F.models([F.sonnet46, F.opus55, F.sonnet55, F.sonnet5, F.haiku55])
        let selected = AnthropicModelSelection.resolve(storedID: nil, storedFamily: nil, models: models)
        #expect(selected?.id == "claude-sonnet-5-5")
        #expect(AnthropicModelSelection.newest(in: models, family: "haiku")?.id == "claude-haiku-5-5")
        #expect(AnthropicModelSelection.newest(in: models, family: "opus")?.id == "claude-opus-5-5")
    }

    @Test("a stored id stays selected while offered and falls back to the newest of its family")
    func storedIDFallback() {
        let models = F.models([F.sonnet55, F.opus55, F.haiku55, F.haiku45])
        #expect(AnthropicModelSelection.resolve(
            storedID: "claude-haiku-4-5-20251001", storedFamily: nil, models: models
        )?.id == "claude-haiku-4-5-20251001")
        #expect(AnthropicModelSelection.resolve(
            storedID: "claude-opus-4-8", storedFamily: nil, models: models
        )?.id == "claude-opus-5-5")
        #expect(AnthropicModelSelection.resolve(
            storedID: "claude-sonnet-4-6", storedFamily: "sonnet", models: models
        )?.id == "claude-sonnet-5-5")
        #expect(AnthropicModelSelection.resolve(
            storedID: "custom-model", storedFamily: nil, models: models
        )?.id == "claude-sonnet-5-5")
        let retired = F.models([F.entry(
            id: "claude-sonnet-4-6", name: "Claude Sonnet 4.6", created: "2026-02-17T00:00:00Z",
            line: "sonnet", lifecycle: "retired"
        ), F.sonnet5])
        #expect(AnthropicModelSelection.resolve(
            storedID: "claude-sonnet-4-6", storedFamily: nil, models: retired
        )?.id == "claude-sonnet-5")
        let offline = AnthropicModelSelection.resolve(storedID: "claude-sonnet-4-6", storedFamily: nil, models: [])
        #expect(offline?.id == "claude-sonnet-4-6")
        #expect(offline?.supportsAdaptiveThinking == false)
        #expect(AnthropicModelSelection.resolve(storedID: nil, storedFamily: nil, models: []) == nil)
    }

    @Test("an active release outranks a newer deprecated one of the same family")
    func activePreferred() {
        let models = F.models([
            F.entry(id: "claude-sonnet-9", name: "Claude Sonnet 9", created: "2026-10-01T00:00:00Z",
                    line: "sonnet", lifecycle: "deprecated"),
            F.sonnet55,
        ])
        #expect(AnthropicModelSelection.newest(in: models, family: "sonnet")?.id == "claude-sonnet-5-5")
    }

    @Test("picker lists the newest model per family first and older releases separately")
    func pickerGroups() {
        let groups = AnthropicModelSelection.pickerGroups(
            F.models([F.sonnet46, F.haiku45, F.opus55, F.sonnet55, F.sonnet5, F.haiku55])
        )
        #expect(groups.current.map(\.id) == ["claude-sonnet-5-5", "claude-opus-5-5", "claude-haiku-5-5"])
        #expect(groups.older.map(\.id) == ["claude-sonnet-5", "claude-sonnet-4-6", "claude-haiku-4-5-20251001"])
        #expect(AnthropicModelSelection.pickerGroups([]).current.isEmpty)
    }

    @Test("the choice and the last discovered list persist as plain values")
    func persistence() throws {
        let defaults = F.isolatedDefaults()
        defaults.set("claude-haiku-4-5-20251001", forKey: "agentModel")
        let store = AnthropicModelCatalogStore(defaults: defaults)
        #expect(store.storedModelID == "claude-haiku-4-5-20251001")
        let models = F.models([F.sonnet55, F.haiku45])
        store.saveCatalog(models)
        #expect(store.cachedModels() == models)
        let service = AgentService(refreshBackendStatusOnInit: false, modelCatalogDefaults: defaults)
        #expect(service.availableModels == models)
        #expect(service.effectiveModel?.id == "claude-haiku-4-5-20251001")
        service.selectModel(models[0])
        #expect(defaults.string(forKey: "agentModel") == "claude-sonnet-5-5")
        #expect(defaults.string(forKey: "agentModelFamily") == "sonnet")
    }

    @Test("offline discovery keeps the cached list; a later success replaces and persists it")
    func offlineFallback() async throws {
        let defaults = F.isolatedDefaults()
        let cached = F.models([F.sonnet46, F.haiku45])
        AnthropicModelCatalogStore(defaults: defaults).saveCatalog(cached)
        let offline = RecordingModelsTransport(pages: [.failure(URLError(.notConnectedToInternet))])
        let service = AgentService(
            refreshBackendStatusOnInit: false,
            modelCatalogDefaults: defaults,
            modelDiscoveryTransport: offline.transport
        )
        await service.refreshModelCatalog(apiKey: "sk-test")
        #expect(service.availableModels == cached)
        #expect(service.effectiveModel?.id == "claude-sonnet-4-6")
        #expect(service.modelDiscoveryError != nil)
        #expect(!service.isDiscoveringModels)

        let online = RecordingModelsTransport(pages: [.success(try F.page([F.sonnet55, F.sonnet46], hasMore: false))])
        let refreshed = AgentService(
            refreshBackendStatusOnInit: false,
            modelCatalogDefaults: defaults,
            modelDiscoveryTransport: online.transport
        )
        await refreshed.refreshModelCatalog(apiKey: "sk-test")
        #expect(refreshed.effectiveModel?.id == "claude-sonnet-5-5")
        #expect(AnthropicModelCatalogStore(defaults: defaults).cachedModels().map(\.id) == [
            "claude-sonnet-5-5", "claude-sonnet-4-6",
        ])
    }

    @Test("a stored id missing from a stale cache stays in use until a current list retires it")
    func storedIDSurvivesStaleCache() async throws {
        let defaults = F.isolatedDefaults()
        AnthropicModelCatalogStore(defaults: defaults).saveCatalog(F.models([F.sonnet46, F.opus55]))
        defaults.set("claude-opus-4-8", forKey: "agentModel")
        let offline = RecordingModelsTransport(pages: [.failure(URLError(.timedOut))])
        let service = AgentService(
            refreshBackendStatusOnInit: false,
            modelCatalogDefaults: defaults,
            modelDiscoveryTransport: offline.transport
        )
        await service.refreshModelCatalog(apiKey: "sk-test")
        #expect(service.effectiveModel?.id == "claude-opus-4-8")
        #expect(service.pickerModels.map(\.id).contains("claude-opus-4-8"))

        let online = RecordingModelsTransport(pages: [.success(try F.page([F.sonnet55, F.opus55], hasMore: false))])
        let current = AgentService(
            refreshBackendStatusOnInit: false,
            modelCatalogDefaults: defaults,
            modelDiscoveryTransport: online.transport
        )
        #expect(current.effectiveModel?.id == "claude-opus-4-8")
        await current.refreshModelCatalog(apiKey: "sk-test")
        #expect(current.effectiveModel?.id == "claude-opus-5-5")
        #expect(!current.pickerModels.map(\.id).contains("claude-opus-4-8"))
    }

    @Test("router families resolve to the newest discovered id; pinned ids stay pinned")
    func routeResolution() throws {
        let store = AnthropicModelCatalogStore(defaults: F.isolatedDefaults())
        #expect(store.resolveRoute("haiku").family == "haiku")
        #expect(store.resolveRoute("haiku").modelID == nil)
        store.saveCatalog(F.models([F.haiku45, F.haiku55, F.opus55]))
        #expect(store.resolveRoute("haiku").modelID == "claude-haiku-5-5")
        #expect(store.resolveRoute("claude-haiku-4-5-20251001").modelID == "claude-haiku-4-5-20251001")
        #expect(store.resolveRoute("claude-opus-4-8").modelID == nil)
        #expect(store.resolveRoute("claude-opus-4-8").family == "opus")
        #expect(store.resolveRoute("sonnet").modelID == nil)
        let data = try NativeCockpitReader.routerJSON(catalog: store)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["tiers"] as? [String: String] == ModelRouter.defaultManifest)
        #expect(object["models"] as? [String: String] == ["fast": "claude-haiku-5-5", "deep": "claude-opus-5-5"])
    }

    @Test("request body follows the selected model's capabilities")
    func requestBodyPerCapability() throws {
        let adaptive = AnthropicRequestBody.build(model: F.info(F.opus55), system: "Edit.", tools: [], messages: [])
        #expect(adaptive["model"] as? String == "claude-opus-5-5")
        #expect(adaptive["max_tokens"] as? Int == 64000)
        #expect(adaptive["thinking"] as? [String: String] == ["type": "adaptive", "display": "summarized"])
        #expect(adaptive["output_config"] as? [String: String] == ["effort": "high"])
        #expect(adaptive["tool_choice"] == nil)

        let small = AnthropicRequestBody.build(
            model: F.info(F.entry(id: "claude-small", name: "Small", created: "2026-01-01T00:00:00Z",
                                  line: "haiku", maxTokens: 32_000, adaptive: true, effort: false)),
            system: "Edit.", tools: [], messages: []
        )
        #expect(small["max_tokens"] as? Int == 32_000)
        #expect(small["thinking"] != nil)
        #expect(small["output_config"] == nil)

        let budgetOnly = AnthropicRequestBody.build(model: F.info(F.haiku45), system: "Edit.", tools: [], messages: [])
        #expect(budgetOnly["thinking"] == nil)
        #expect(budgetOnly["output_config"] == nil)
        #expect(budgetOnly["max_tokens"] as? Int == 64000)

        let unknown = AnthropicRequestBody.build(model: .unlisted("claude-next"), system: "Edit.", tools: [], messages: [])
        #expect(unknown["thinking"] == nil)
        #expect(unknown["output_config"] == nil)
        #expect(unknown["max_tokens"] as? Int == AnthropicRequestBody.unknownModelMaxTokens)
        #expect(unknown["tool_choice"] == nil)
    }
}

private final class GatedModelsTransport: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [String: CheckedContinuation<(Data, URLResponse), Error>] = [:]
    private var requests: [String: Int] = [:]

    var transport: AnthropicModelsAPI.Transport {
        { [self] request in
            let key = request.value(forHTTPHeaderField: "x-api-key") ?? ""
            return try await withCheckedThrowingContinuation { continuation in
                self.park(continuation, key: key)
            }
        }
    }

    func isWaiting(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return waiting[key] != nil
    }

    func requestCount(_ key: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return requests[key, default: 0]
    }

    func respond(_ key: String, with result: Result<Data, Error>) {
        lock.lock()
        let continuation = waiting.removeValue(forKey: key)
        lock.unlock()
        let response = HTTPURLResponse(url: AnthropicModelsAPI.endpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!
        switch result {
        case .success(let data): continuation?.resume(returning: (data, response))
        case .failure(let error): continuation?.resume(throwing: error)
        }
    }

    private func park(_ continuation: CheckedContinuation<(Data, URLResponse), Error>, key: String) {
        lock.lock()
        waiting[key] = continuation
        requests[key, default: 0] += 1
        lock.unlock()
    }
}

private final class GatedKeyLoader: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String?, Never>?

    var isWaiting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return continuation != nil
    }

    func load() async -> String? {
        await withCheckedContinuation { continuation in
            park(continuation)
        }
    }

    func release(_ key: String?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: key)
    }

    private func park(_ continuation: CheckedContinuation<String?, Never>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }
}
