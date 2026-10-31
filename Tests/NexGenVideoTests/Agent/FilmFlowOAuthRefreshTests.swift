import Foundation
import Testing
@testable import NexGenVideo

@Suite("FilmFlow shared refresh ownership", .timeLimit(.minutes(1)))
struct FilmFlowOAuthRefreshTests {
    @Test func cancelledReaderDoesNotCancelAnotherDocumentsRefresh() async throws {
        let original = originalConnection()
        let storage = FilmFlowRefreshStorage(original)
        let transport = FilmFlowRefreshTransport()
        let auth = makeAuth(storage, transport)
        let first = reader(auth, storage: storage, name: "first")
        let second = reader(auth, storage: storage, name: "second")
        defer { first.cancel(); second.cancel(); transport.release() }
        try await storage.addedReaders.wait(for: 2)
        try await transport.started.wait(for: 1)
        try #require(await auth.pendingRefreshRequests == 2 && transport.refreshRequests.count == 1)
        first.cancel()
        let cancelled = try await readerResult(first, transport)
        #expect(throws: CancellationError.self) { try cancelled.get() }
        #expect(storage.finishedReaders.contains("first"))
        #expect(!storage.finishedReaders.contains("second"))
        #expect(storage.current == original && storage.saved.isEmpty)
        transport.release()
        let replacement = try await readerResult(second, transport).get()
        #expect(replacement.id == original.id && replacement.resource == original.resource)
        #expect(replacement.tokens.accessToken == "fixture-new-access")
        #expect(replacement.tokens.refreshToken == "fixture-new-refresh")
        #expect(storage.current == replacement && storage.saved == [replacement])
        #expect(transport.refreshRequests.count == 1)
        let request = try #require(transport.refreshRequests.first)
        let body = try #require(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        let fields = URLComponents(string: "https://fixture.invalid/?" + body)?.queryItems
        #expect(fields?.first { $0.name == "refresh_token" }?.value == original.tokens.refreshToken)
        #expect(fields?.first { $0.name == "resource" }?.value == FilmFlowHTTP.endpoint.absoluteString)
        #expect(request.url == original.tokens.tokenEndpoint)
    }

    @Test(arguments: [false, true])
    func disconnectAndNewSignInInvalidatePendingReaders(reconnect: Bool) async throws {
        let original = originalConnection()
        let storage = FilmFlowRefreshStorage(original)
        let transport = FilmFlowRefreshTransport()
        let auth = makeAuth(storage, transport)
        let pending = reader(auth, storage: storage, name: "pending")
        defer { pending.cancel(); transport.release() }
        try await storage.addedReaders.wait(for: 1)
        try await transport.started.wait(for: 1)
        try #require(await auth.pendingRefreshRequests == 1 && transport.refreshRequests.count == 1)
        if reconnect {
            let authorization = try await auth.begin()
            #expect(authorization.issuer == FilmFlowOAuth.issuer)
            #expect(authorization.clientID == "fixture-public-client")
        } else { try await auth.disconnect() }
        let result = try await readerResult(pending, transport)
        #expect(storage.finishedReaders.contains("pending"))
        #expect(throws: CancellationError.self) { try result.get() }
        transport.release()
        try await storage.completedRefreshes.wait(for: 1)
        #expect(storage.finishedRefreshes == 1)
        #expect(storage.saved.isEmpty)
        #expect(storage.current == (reconnect ? original : nil))
    }

    private func makeAuth(_ storage: FilmFlowRefreshStorage, _ transport: FilmFlowRefreshTransport) -> FilmFlowOAuth {
        FilmFlowOAuth(dependencies: .init(load: { storage.current }, save: { storage.store($0) },
            delete: { storage.clear(); return true }, request: { try await transport.request($0) },
            didFinishRefresh: { storage.finishRefresh() },
            didAddRefreshWaiter: { storage.addedReaders.signal($0) }))
    }

    private func originalConnection() -> FilmFlowOAuth.Connection {
        .init(id: UUID(), resource: FilmFlowHTTP.endpoint, issuer: FilmFlowOAuth.issuer,
            tokens: .init(accessToken: "fixture-expired-access", refreshToken: "fixture-original-refresh",
                expiresAt: .distantPast, clientID: "fixture-public-client",
                tokenEndpoint: FilmFlowOAuth.issuer.appendingPathComponent("oauth2/token")))
    }

    private func reader(_ auth: FilmFlowOAuth, storage: FilmFlowRefreshStorage, name: String) -> Task<Result<FilmFlowOAuth.Connection, Error>, Never> {
        Task {
            defer { storage.finishReader(name) }
            do { return .success(try await auth.connection()) }
            catch { return .failure(error) }
        }
    }

    private func readerResult(_ task: Task<Result<FilmFlowOAuth.Connection, Error>, Never>, _ transport: FilmFlowRefreshTransport) async throws -> Result<FilmFlowOAuth.Connection, Error> {
        try Task.checkCancellation()
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel(); transport.release() }
        try Task.checkCancellation()
        return result
    }
}

private final class FilmFlowRefreshGate: Sendable {
    private let events = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(1))

    func signal(_ count: Int) { events.continuation.yield(count) }

    func wait(for minimum: Int) async throws {
        try Task.checkCancellation()
        for await count in events.stream {
            try Task.checkCancellation()
            if count >= minimum { return }
        }
        throw CancellationError()
    }
}

private final class FilmFlowRefreshStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: FilmFlowOAuth.Connection?
    private var writes: [FilmFlowOAuth.Connection] = []
    private var readers: Set<String> = []
    private var completions = 0
    let addedReaders = FilmFlowRefreshGate()
    let completedRefreshes = FilmFlowRefreshGate()
    init(_ connection: FilmFlowOAuth.Connection) { self.connection = connection }
    var current: FilmFlowOAuth.Connection? { lock.withLock { connection } }
    var saved: [FilmFlowOAuth.Connection] { lock.withLock { writes } }
    var finishedReaders: Set<String> { lock.withLock { readers } }
    var finishedRefreshes: Int { lock.withLock { completions } }
    func store(_ value: FilmFlowOAuth.Connection) { lock.withLock { connection = value; writes.append(value) } }
    func clear() { lock.withLock { connection = nil } }
    func finishReader(_ name: String) { _ = lock.withLock { readers.insert(name) } }
    func finishRefresh() {
        let count = lock.withLock { completions += 1; return completions }
        completedRefreshes.signal(count)
    }
}

private final class FilmFlowRefreshTransport: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    private var pending: [CheckedContinuation<FilmFlowOAuth.Response, Error>] = []
    private var released = false
    let started = FilmFlowRefreshGate()
    var refreshRequests: [URLRequest] { lock.withLock { requests } }
    private let tokens = FilmFlowOAuth.Response(bytes: Data(#"{"access_token":"fixture-new-access","refresh_token":"fixture-new-refresh","expires_in":3600,"token_type":"Bearer"}"#.utf8), statusCode: 200)

    func request(_ request: URLRequest) async throws -> FilmFlowOAuth.Response {
        let url = request.url?.absoluteString ?? ""
        if url.hasSuffix("/oauth2/token") {
            return try await withCheckedThrowingContinuation { continuation in
                let immediate = lock.withLock {
                    requests.append(request)
                    if released { return true }
                    pending.append(continuation); return false
                }
                started.signal(1)
                if immediate { continuation.resume(returning: tokens) }
            }
        }
        let issuer = FilmFlowOAuth.issuer.absoluteString
        let body: [String: Any]
        if url.contains("oauth-protected-resource") {
            body = ["resource": FilmFlowHTTP.endpoint.absoluteString, "authorization_servers": [issuer],
                    "scopes_supported": FilmFlowOAuth.scope.split(separator: " ").map(String.init)]
        } else if url.contains("oauth-authorization-server") {
            body = ["issuer": issuer, "authorization_endpoint": issuer + "/oauth2/authorize",
                    "token_endpoint": issuer + "/oauth2/token", "registration_endpoint": issuer + "/oauth2/register",
                    "scopes_supported": FilmFlowOAuth.scope.split(separator: " ").map(String.init), "code_challenge_methods_supported": ["S256"]]
        } else if url.hasSuffix("/oauth2/register"), request.httpMethod == "POST" {
            body = ["client_id": "fixture-public-client", "redirect_uris": [OAuthCore.redirectURI], "token_endpoint_auth_method": "none"]
        } else { throw FilmFlowFailure.message("Unexpected fixture-only auth request.") }
        return .init(bytes: try JSONSerialization.data(withJSONObject: body), statusCode: 200)
    }

    func release() {
        let waiting = lock.withLock { released = true; let values = pending; pending.removeAll(); return values }
        for continuation in waiting { continuation.resume(returning: tokens) }
    }
}
