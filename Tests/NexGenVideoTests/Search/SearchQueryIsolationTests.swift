import Foundation
import Testing
@testable import NexGenVideo

@Suite("Search queries bind the current model and media")
@MainActor
struct SearchQueryIsolationTests {
    private struct Fixture {
        let root: URL
        let source: URL
        let key: String
        let asset: MediaAsset
        var spec: VisualEmbedder.Spec {
            .init(model: "local-fixture", version: 1, embeddingDim: 2, imageSize: 1, contextLength: 1)
        }
        func write(modelVersion: Int = 1, samplerVersion: Int = FrameSampler.samplerVersion, dimension: Int = 2) throws {
            let vectors: [Float] = dimension == 2 ? [1, 0, 0, 1] : [1, 0, 0, 0, 1, 0]
            try EmbeddingStore.save(header: .init(model: spec.model, modelVersion: modelVersion,
                                                  samplerVersion: samplerVersion, dim: dimension, count: 2),
                                    rows: [.init(time: 1, shotStart: 0, shotEnd: 2), .init(time: 3, shotStart: 2, shotEnd: 4)],
                                    vectors: vectors, key: key)
        }
        func cleanup() {
            try? FileManager.default.removeItem(at: EmbeddingStore.diskURL(key))
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func fixture(write: Bool = true) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("Search fixture.mov")
        try Data("local cache-query fixture, not a semantic encoding proof".utf8).write(to: source)
        let asset = MediaAsset(url: source, type: .video, name: "Search fixture.mov", duration: 4)
        let result = Fixture(root: root, source: source, key: try #require(EmbeddingStore.key(for: source)), asset: asset)
        if write { try result.write() }
        return result
    }

    private func coordinator(_ fixture: Fixture) -> SearchIndexCoordinator {
        let coordinator = SearchIndexCoordinator()
        coordinator.assetsProvider = { [fixture.asset] }
        coordinator.queryEncoderOverride = .init(spec: fixture.spec, encode: { _ in [1, 0] })
        return coordinator
    }

    @Test func readsRealDiskIndexThroughTheProductionRanker() async throws {
        let fixture = try fixture()
        defer { fixture.cleanup() }
        let coordinator = coordinator(fixture)
        let result = await coordinator.searchResult(query: "local test")
        #expect(result.status == .ready)
        #expect(result.unavailableAssetIDs.isEmpty)
        #expect(result.hits.map(\.assetID) == [fixture.asset.id])
        #expect(result.hits.first?.shotStart == 0)
        #expect(result.hits.first?.shotEnd == 2)
        #expect(await coordinator.search(query: "local test") == result.hits)
    }

    @Test func missingStaleAndWrongDimensionIndexesAreNotReportedAsNoMatches() async throws {
        let fixture = try fixture(write: false)
        defer { fixture.cleanup() }
        let coordinator = coordinator(fixture)
        var result = await coordinator.searchResult(query: "local test")
        #expect(result.status == .notIndexed)
        #expect(result.unavailableAssetIDs == [fixture.asset.id])
        for (version, sampler, dim) in [(2, FrameSampler.samplerVersion, 2), (1, 999, 2), (1, FrameSampler.samplerVersion, 3)] {
            try fixture.write(modelVersion: version, samplerVersion: sampler, dimension: dim)
            #expect(VisualIndexer.needsIndex(url: fixture.source, spec: fixture.spec))
            result = await coordinator.searchResult(query: "local test")
            #expect(result.status == .notIndexed)
            #expect(result.hits.isEmpty)
        }
        try fixture.write()
        #expect(!VisualIndexer.needsIndex(url: fixture.source, spec: fixture.spec))
        result = await coordinator.searchResult(query: "local test")
        #expect(result.status == .ready)
        #expect(!result.hits.isEmpty)
    }

    @Test func corruptDiskFailureRemainsVisibleAndValidatedRepairClearsIt() async throws {
        let fixture = try fixture()
        defer { fixture.cleanup() }
        try Data("damaged".utf8).write(to: EmbeddingStore.diskURL(fixture.key), options: .atomic)
        let coordinator = coordinator(fixture)
        let damaged = await coordinator.searchResult(query: "local test")
        #expect(damaged.failedAssetIDs == [fixture.asset.id])
        #expect(coordinator.failedAssetIDs == [fixture.asset.id])
        #expect(coordinator.failures[fixture.asset.id]?.contains("damaged") == true)
        #expect(!coordinator.indexingActive)
        _ = await coordinator.searchResult(query: "different query")
        #expect(coordinator.failedAssetIDs == [fixture.asset.id])
        try fixture.write()
        let repaired = await coordinator.searchResult(query: "local test")
        #expect(repaired.status == .ready)
        #expect(coordinator.failedAssetIDs.isEmpty)
    }

    private enum EncoderFailure: LocalizedError {
        case unavailable
        var errorDescription: String? { "The local fixture text encoder failed." }
    }

    @Test func encoderFailureIsDistinctFromACompletedZeroHitQuery() async throws {
        let fixture = try fixture()
        defer { fixture.cleanup() }
        let coordinator = coordinator(fixture)
        coordinator.queryEncoderOverride = .init(spec: fixture.spec, encode: { _ in throw EncoderFailure.unavailable })
        let failed = await coordinator.searchResult(query: "local test")
        if case .failed(let message) = failed.status { #expect(message.contains("fixture text encoder failed")) }
        else { Issue.record("An encoder error must remain a visible failure.") }
        coordinator.queryEncoderOverride = .init(spec: fixture.spec, encode: { _ in [-1, 0] })
        let noMatch = await coordinator.searchResult(query: "local test")
        #expect(noMatch.status == .ready)
        #expect(noMatch.hits.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func queryCompletionRejectsSourceBytesChangedDuringEncoding() async throws {
        let fixture = try fixture()
        defer { fixture.cleanup() }
        let coordinator = coordinator(fixture)
        let gate = SearchQueryEncoderGate()
        defer { gate.release() }
        coordinator.queryEncoderOverride = .init(spec: fixture.spec, encode: { _ in gate.encode() })
        let query = Task { @MainActor in
            gate.recordQueryEntered()
            let result = await coordinator.searchResult(query: "local test")
            gate.recordQueryOutcome("status=\(result.status), hits=\(result.hits.count), unavailable=\(result.unavailableAssetIDs.sorted()), failed=\(result.failedAssetIDs.sorted())")
            return result
        }
        defer { query.cancel() }
        try gate.installMutation {
            try Data("different source bytes and length".utf8).write(to: fixture.source, options: .atomic)
        }
        let result = await settle(query, gate: gate)
        try gate.requireMutationBeforeEncoderReturn()
        #expect(result.status == .stale)
        #expect(result.hits.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func cancelledQueryDoesNotPublishACompletedResult() async throws {
        let fixture = try fixture()
        defer { fixture.cleanup() }
        let coordinator = coordinator(fixture)
        let gate = SearchQueryEncoderGate()
        defer { gate.release() }
        coordinator.queryEncoderOverride = .init(spec: fixture.spec, encode: { _ in gate.encode() })
        let query = Task { @MainActor in
            gate.recordQueryEntered()
            let result = await coordinator.searchResult(query: "local test")
            gate.recordQueryOutcome("status=\(result.status), hits=\(result.hits.count), unavailable=\(result.unavailableAssetIDs.sorted()), failed=\(result.failedAssetIDs.sorted())")
            return result
        }
        defer { query.cancel() }
        try gate.installMutation { query.cancel() }
        let result = await settle(query, gate: gate)
        try gate.requireMutationBeforeEncoderReturn()
        #expect(result.status == .cancelled)
        #expect(result.hits.isEmpty)
        #expect(coordinator.failures.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func queryCompletionRejectsModelChangesAndAssetRemoval() async throws {
        let fixture = try fixture()
        defer { fixture.cleanup() }
        let coordinator = coordinator(fixture)
        for changeModel in [true, false] {
            let gate = SearchQueryEncoderGate()
            defer { gate.release() }
            coordinator.assetsProvider = { [fixture.asset] }
            coordinator.queryEncoderOverride = .init(spec: fixture.spec, encode: { _ in gate.encode() })
            let query = Task { @MainActor in
                gate.recordQueryEntered()
                let result = await coordinator.searchResult(query: "local test")
                gate.recordQueryOutcome("status=\(result.status), hits=\(result.hits.count), unavailable=\(result.unavailableAssetIDs.sorted()), failed=\(result.failedAssetIDs.sorted())")
                return result
            }
            defer { query.cancel() }
            try gate.installMutation {
                if changeModel { coordinator.queryEncoderOverride = .init(spec: fixture.spec, encode: { _ in [0, 1] }) }
                else { coordinator.assetsProvider = { [] } }
            }
            let result = await settle(query, gate: gate)
            try gate.requireMutationBeforeEncoderReturn()
            #expect(result.status == .stale)
            #expect(result.hits.isEmpty)
        }
    }

    private func settle(_ query: Task<SearchIndexCoordinator.SearchResult, Never>, gate: SearchQueryEncoderGate) async -> SearchIndexCoordinator.SearchResult {
        await withTaskCancellationHandler {
            await query.value
        } onCancel: {
            query.cancel()
            gate.release()
        }
    }
}

private final class SearchQueryEncoderGate: @unchecked Sendable {
    private enum Failure: Error { case invalidInstallation }
    private let condition = NSCondition()
    private var started = false
    private var released = false
    private var queryEntered = false
    private var queryOutcome: String?
    private var mutation: (@MainActor @Sendable () throws -> Void)?
    private var mutationResult: Result<Void, Error>?
    private var encoderReturned = false
    private var mutationBeforeReturn = false

    func recordQueryEntered() {
        condition.lock()
        queryEntered = true
        condition.unlock()
    }
    func recordQueryOutcome(_ value: String) {
        condition.lock()
        queryOutcome = value
        condition.unlock()
    }
    func installMutation(_ value: @escaping @MainActor @Sendable () throws -> Void) throws {
        condition.lock()
        defer { condition.unlock() }
        guard !started, !released, mutation == nil else { throw Failure.invalidInstallation }
        mutation = value
    }
    private func admitsMutation() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return !released
    }
    private func finishMutation(_ result: Result<Void, Error>) {
        condition.lock()
        mutationResult = result
        released = true
        condition.broadcast()
        condition.unlock()
    }
    func encode() -> [Float] {
        condition.lock()
        started = true
        let operation = mutation
        mutation = nil
        condition.unlock()
        let task = operation.map { operation in
            Task { @MainActor [self, operation] in
                guard !Task.isCancelled, admitsMutation() else { return }
                let result = Result { try operation() }
                finishMutation(result)
            }
        }
        condition.lock()
        let deadline = Date().addingTimeInterval(5)
        while !released {
            if !condition.wait(until: deadline) { break }
        }
        mutationBeforeReturn = released && mutationResult != nil
        encoderReturned = true
        released = true
        condition.unlock()
        task?.cancel()
        return [1, 0]
    }
    func release() {
        condition.lock()
        mutation = nil
        released = true
        condition.broadcast()
        condition.unlock()
    }
    func requireMutationBeforeEncoderReturn() throws {
        condition.lock()
        let observation = (queryEntered, started, encoderReturned, mutationBeforeReturn, mutationResult,
            "queryEntered=\(queryEntered), encoderEntered=\(started), encoderReturned=\(encoderReturned), mutationBeforeReturn=\(mutationBeforeReturn), outcome=\(queryOutcome ?? "pending")")
        condition.unlock()
        let comment = Testing.Comment(rawValue: observation.5)
        try #require(observation.0 && observation.1 && observation.2 && observation.3, comment)
        let result = try #require(observation.4, comment)
        try result.get()
    }
}
