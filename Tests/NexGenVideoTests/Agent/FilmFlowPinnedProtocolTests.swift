import Foundation
import Testing
import os

@testable import NexGenVideo

@Suite("FilmFlow pinned protocol delivery", .timeLimit(.minutes(1)))
struct FilmFlowPinnedProtocolTests {
    @Test func successfulLoadDeliversOnceInOrder() async throws {
        let payload = try makePayload()
        let client = Client()
        let adapter = makeAdapter(client: client)
        let operation = try #require(adapter.startLoading(fetch: { _ in (payload.bytes, payload.response) }))
        await operation.value
        #expect(client.events == [.response, .data(payload.bytes), .finish])
    }

    @Test func stopBeforeResponsePublicationSuppressesLateSuccess() async throws {
        let payload = try makePayload()
        let gate = FetchGate()
        let client = Client()
        let adapter = makeAdapter(client: client)
        let operation = try #require(adapter.startLoading(fetch: { _ in
            let value = try await gate.load()
            return (value.bytes, value.response)
        }))
        await gate.waitUntilEntered()
        adapter.stopLoading()
        await gate.resolve(.success(payload))
        await operation.value
        #expect(client.events.isEmpty)
    }

    @Test func stopDuringResponseSuppressesRemainingCallbacks() async throws {
        let payload = try makePayload()
        let client = Client(onResponse: { $0.stopLoading() })
        let adapter = makeAdapter(client: client)
        let operation = try #require(adapter.startLoading(fetch: { _ in (payload.bytes, payload.response) }))
        await operation.value
        #expect(client.events == [.response])
    }

    @Test func errorAfterStopIsSilent() async throws {
        let gate = FetchGate()
        let client = Client()
        let adapter = makeAdapter(client: client)
        let operation = try #require(adapter.startLoading(fetch: { _ in
            let value = try await gate.load()
            return (value.bytes, value.response)
        }))
        await gate.waitUntilEntered()
        adapter.stopLoading()
        await gate.resolve(.failure(URLError(.cannotConnectToHost)))
        await operation.value
        #expect(client.events.isEmpty)
    }

    @Test func ordinaryFetchFailureIsReportedOnce() async throws {
        let client = Client()
        let adapter = makeAdapter(client: client)
        let operation = try #require(adapter.startLoading(fetch: { _ in throw URLError(.cannotConnectToHost) }))
        await operation.value
        #expect(client.events == [.failure])
    }

    @Test func offResourceRequestNeverReachesFetch() async throws {
        let client = Client()
        let adapter = FilmFlowPinnedProtocol(request: URLRequest(url: URL(string: "https://other.invalid/api/mcp")!),
            cachedResponse: nil, client: client)
        let fetches = OSAllocatedUnfairLock(initialState: 0)
        let operation = try #require(adapter.startLoading(fetch: { _ in
            fetches.withLock { $0 += 1 }
            throw URLError(.unknown)
        }))
        await operation.value
        #expect(fetches.withLock { $0 } == 0)
        #expect(client.events == [.failure])
    }

    @Test func synchronousBodyFailureUsesTheSameStopFence() throws {
        for stopped in [false, true] {
            let client = Client()
            var request = URLRequest(url: FilmFlowHTTP.endpoint)
            request.httpBodyStream = InputStream(data: Data(repeating: 0, count: 1_024 * 1_024 + 1))
            let adapter = FilmFlowPinnedProtocol(request: request, cachedResponse: nil, client: client)
            let fetches = OSAllocatedUnfairLock(initialState: 0)
            if stopped { adapter.stopLoading() }
            let operation = adapter.startLoading(fetch: { _ in
                fetches.withLock { $0 += 1 }
                throw URLError(.unknown)
            })
            #expect(operation == nil)
            #expect(fetches.withLock { $0 } == 0)
            #expect(client.events == (stopped ? [] : [.failure]))
        }
    }

    private func makeAdapter(client: Client) -> FilmFlowPinnedProtocol {
        FilmFlowPinnedProtocol(request: URLRequest(url: FilmFlowHTTP.endpoint), cachedResponse: nil, client: client)
    }

    private func makePayload() throws -> Payload {
        Payload(bytes: Data("pinned response".utf8), response: try #require(HTTPURLResponse(
            url: FilmFlowHTTP.endpoint, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)))
    }

    private struct Payload: Sendable {
        let bytes: Data
        let response: HTTPURLResponse
    }

    private actor FetchGate {
        private var entered = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var completion: CheckedContinuation<Payload, any Error>?

        func load() async throws -> Payload {
            entered = true
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
            return try await withCheckedThrowingContinuation { completion = $0 }
        }

        func waitUntilEntered() async {
            if entered { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func resolve(_ result: Result<Payload, any Error>) {
            completion?.resume(with: result)
            completion = nil
        }
    }

    private enum Event: Sendable, Equatable {
        case response
        case data(Data)
        case finish
        case failure
        case unexpected
    }

    private final class Client: NSObject, URLProtocolClient {
        private let recorded = OSAllocatedUnfairLock(initialState: [Event]())
        private let onResponse: @Sendable (URLProtocol) -> Void
        var events: [Event] { recorded.withLock { $0 } }

        init(onResponse: @escaping @Sendable (URLProtocol) -> Void = { _ in }) {
            self.onResponse = onResponse
            super.init()
        }

        private func record(_ event: Event) { recorded.withLock { $0.append(event) } }
        func urlProtocol(_ protocolInstance: URLProtocol, didReceive response: URLResponse, cacheStoragePolicy policy: URLCache.StoragePolicy) {
            record(.response)
            onResponse(protocolInstance)
        }
        func urlProtocol(_ protocolInstance: URLProtocol, didLoad data: Data) { record(.data(data)) }
        func urlProtocolDidFinishLoading(_ protocolInstance: URLProtocol) { record(.finish) }
        func urlProtocol(_ protocolInstance: URLProtocol, didFailWithError error: any Error) { record(.failure) }
        func urlProtocol(_ protocolInstance: URLProtocol, wasRedirectedTo request: URLRequest, redirectResponse: URLResponse) { record(.unexpected) }
        func urlProtocol(_ protocolInstance: URLProtocol, cachedResponseIsValid cachedResponse: CachedURLResponse) { record(.unexpected) }
        func urlProtocol(_ protocolInstance: URLProtocol, didReceive challenge: URLAuthenticationChallenge) { record(.unexpected) }
        func urlProtocol(_ protocolInstance: URLProtocol, didCancel challenge: URLAuthenticationChallenge) { record(.unexpected) }
    }
}
