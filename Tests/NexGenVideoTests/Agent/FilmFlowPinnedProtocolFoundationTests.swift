import Foundation
import Testing
import os

@testable import NexGenVideo

@Suite("FilmFlow pinned protocol Foundation lifecycle", .timeLimit(.minutes(1)))
struct FilmFlowPinnedProtocolFoundationTests {
    @Test func foundationReceivesTheActualPinnedResponse() async throws {
        let payload = try makePayload()
        let scope = Scope(fetch: { _ in (payload.bytes, payload.response) })
        let run = makeRun(scope: scope)
        defer { run.session.invalidateAndCancel() }
        run.task.resume()
        let completion = try #require(await run.completions.first(where: { _ in true }))
        try #require(completion.errorCode == nil)
        let operation = try #require(await scope.operations.first(where: { _ in true }))
        await operation.value
        #expect(completion.bytes == payload.bytes)
        #expect(completion.status == 200)
        #expect(scope.observation.events == ["response", "data", "finish"])
        #expect(scope.observation.starts == 1)
        #expect(scope.observation.bindingFailures == 0)
    }

    @Test func foundationCancellationStopsTheActualPinnedLoad() async throws {
        let payload = try makePayload()
        let gate = FetchGate()
        let scope = Scope(fetch: { _ in
            let value = try await gate.load()
            return (value.bytes, value.response)
        })
        let run = makeRun(scope: scope)
        defer { run.session.invalidateAndCancel() }
        run.task.resume()
        await gate.waitUntilEntered()
        let operation = await scope.operations.first(where: { _ in true })
        run.task.cancel()
        let stopped = await scope.stops.first(where: { _ in true })
        await gate.resolve(payload)
        await operation?.value
        let completion = await run.completions.first(where: { _ in true })
        #expect(operation != nil)
        #expect(operation?.isCancelled == true)
        #expect(stopped != nil)
        #expect(completion?.errorDomain == NSURLErrorDomain)
        #expect(completion?.errorCode == URLError.cancelled.rawValue)
        #expect(scope.observation.events.isEmpty)
        #expect(scope.observation.starts == 1)
        #expect(scope.observation.bindingFailures == 0)
    }

    private func makePayload() throws -> Payload {
        Payload(bytes: Data("Foundation pinned response".utf8), response: try #require(HTTPURLResponse(
            url: FilmFlowHTTP.endpoint, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)))
    }

    private func makeRun(scope: Scope) -> Run {
        let request = NSMutableURLRequest(url: URL(string: "filmflow-pinned-fixture://\(UUID().uuidString)/response")!)
        URLProtocol.setProperty(scope, forKey: FixtureProtocol.scopeKey, in: request)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        let (completions, continuation) = AsyncStream<Completion>.makeStream()
        let task = session.dataTask(with: request as URLRequest) { bytes, response, error in
            continuation.yield(Completion(bytes: bytes, status: (response as? HTTPURLResponse)?.statusCode,
                errorDomain: (error as NSError?)?.domain, errorCode: (error as NSError?)?.code))
            continuation.finish()
        }
        return Run(session: session, task: task, completions: completions)
    }

    private struct Run {
        let session: URLSession
        let task: URLSessionDataTask
        let completions: AsyncStream<Completion>
    }

    private struct Completion: Sendable {
        let bytes: Data?
        let status: Int?
        let errorDomain: String?
        let errorCode: Int?
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

        func resolve(_ payload: Payload) {
            completion?.resume(returning: payload)
            completion = nil
        }
    }

    private struct Observation: Sendable {
        var child: ObjectIdentifier?
        var owner: ObjectIdentifier?
        var events: [String] = []
        var starts = 0
        var bindingFailures = 0
    }

    private final class Scope: Sendable {
        let fetch: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
        private let recorded = OSAllocatedUnfairLock(initialState: Observation())
        private let operationChannel = AsyncStream<Task<Void, Never>>.makeStream()
        private let stopChannel = AsyncStream<Bool>.makeStream()
        var operations: AsyncStream<Task<Void, Never>> { operationChannel.stream }
        var stops: AsyncStream<Bool> { stopChannel.stream }
        var observation: Observation { recorded.withLock { $0 } }

        init(fetch: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)) { self.fetch = fetch }
        func bind(child: URLProtocol, owner: URLProtocol) {
            let childID = ObjectIdentifier(child), ownerID = ObjectIdentifier(owner)
            recorded.withLock {
                $0.child = childID
                $0.owner = ownerID
                $0.starts += 1
            }
        }
        func record(_ event: String, child: URLProtocol, owner: URLProtocol) {
            let childID = ObjectIdentifier(child), ownerID = ObjectIdentifier(owner)
            recorded.withLock {
                if $0.child != childID || $0.owner != ownerID { $0.bindingFailures += 1 }
                $0.events.append(event)
            }
        }
        func bindingFailure() { recorded.withLock { $0.bindingFailures += 1 } }
        func publish(_ operation: Task<Void, Never>?) {
            if let operation { operationChannel.continuation.yield(operation) }
            operationChannel.continuation.finish()
        }
        func didStop() {
            stopChannel.continuation.yield(true)
            stopChannel.continuation.finish()
        }
    }

    private final class FixtureProtocol: URLProtocol, @unchecked Sendable {
        static let scopeKey = "FilmFlowPinnedProtocolFoundationTests.scope"
        private struct State: Sendable {
            var child: FilmFlowPinnedProtocol?
            var forwarder: Forwarder?
            var scope: Scope?
            var stopped = false
        }
        private let state = OSAllocatedUnfairLock(initialState: State())
        override class func canInit(with request: URLRequest) -> Bool { request.url?.scheme == "filmflow-pinned-fixture" }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let scope = URLProtocol.property(forKey: Self.scopeKey, in: request) as? Scope, let client else {
                client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
                return
            }
            let forwarder = Forwarder(owner: self, scope: scope, client: client)
            let child = FilmFlowPinnedProtocol(request: URLRequest(url: FilmFlowHTTP.endpoint), cachedResponse: nil, client: forwarder)
            scope.bind(child: child, owner: self)
            let stopped = state.withLock {
                $0.child = child; $0.forwarder = forwarder; $0.scope = scope
                return $0.stopped
            }
            if stopped { child.stopLoading(); scope.didStop() }
            scope.publish(child.startLoading(fetch: scope.fetch))
        }

        override func stopLoading() {
            let snapshot = state.withLock {
                $0.stopped = true
                return ($0.child, $0.scope)
            }
            snapshot.0?.stopLoading()
            snapshot.1?.didStop()
        }
    }

    private enum Delivery: Sendable {
        case response(URLResponse), data(Data), finish, failure(any Error)
    }

    private final class Forwarder: NSObject, URLProtocolClient {
        private let deliver: @Sendable (URLProtocol, Delivery) -> Void

        init(owner: FixtureProtocol, scope: Scope, client: any URLProtocolClient) {
            deliver = { [weak owner, scope, client] child, event in
                guard let owner else { scope.bindingFailure(); return }
                switch event {
                case .response(let response):
                    scope.record("response", child: child, owner: owner)
                    client.urlProtocol(owner, didReceive: response, cacheStoragePolicy: .notAllowed)
                case .data(let bytes):
                    scope.record("data", child: child, owner: owner)
                    client.urlProtocol(owner, didLoad: bytes)
                case .finish:
                    scope.record("finish", child: child, owner: owner)
                    client.urlProtocolDidFinishLoading(owner)
                case .failure(let error):
                    scope.record("failure", child: child, owner: owner)
                    client.urlProtocol(owner, didFailWithError: error)
                }
            }
            super.init()
        }

        func urlProtocol(_ protocolInstance: URLProtocol, didReceive response: URLResponse, cacheStoragePolicy policy: URLCache.StoragePolicy) {
            deliver(protocolInstance, .response(response))
        }
        func urlProtocol(_ protocolInstance: URLProtocol, didLoad data: Data) { deliver(protocolInstance, .data(data)) }
        func urlProtocolDidFinishLoading(_ protocolInstance: URLProtocol) { deliver(protocolInstance, .finish) }
        func urlProtocol(_ protocolInstance: URLProtocol, didFailWithError error: any Error) { deliver(protocolInstance, .failure(error)) }
        func urlProtocol(_ protocolInstance: URLProtocol, wasRedirectedTo request: URLRequest, redirectResponse: URLResponse) { unexpected(protocolInstance) }
        func urlProtocol(_ protocolInstance: URLProtocol, cachedResponseIsValid cachedResponse: CachedURLResponse) { unexpected(protocolInstance) }
        func urlProtocol(_ protocolInstance: URLProtocol, didReceive challenge: URLAuthenticationChallenge) { unexpected(protocolInstance) }
        func urlProtocol(_ protocolInstance: URLProtocol, didCancel challenge: URLAuthenticationChallenge) { unexpected(protocolInstance) }
        private func unexpected(_ protocolInstance: URLProtocol) { deliver(protocolInstance, .failure(URLError(.unsupportedURL))) }
    }
}
