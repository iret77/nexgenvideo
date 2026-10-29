import Foundation
import MCP

enum FilmFlowFailure: LocalizedError, Equatable {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

enum FilmFlowHTTP {
    static let endpoint = URL(string: "https://app.filmflow.pro/api/mcp")!
    static let maximumBytes = 32 * 1_024 * 1_024

    static func isResource(_ url: URL) -> Bool {
        url.absoluteString == endpoint.absoluteString
    }

    static func requireHTTPS(_ url: URL) throws {
        guard let value = URLComponents(url: url, resolvingAgainstBaseURL: false),
              value.scheme == "https", let host = value.host, !host.isEmpty,
              value.user == nil, value.password == nil, value.fragment == nil,
              value.port == nil || value.port == 443,
              !host.contains(":"), host != "localhost", !host.hasSuffix(".local"),
              !host.split(separator: ".").allSatisfy({ Int($0) != nil }) else {
            throw FilmFlowFailure.message("FilmFlow returned an unsupported secure address.")
        }
    }

    final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 90
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    static func data(_ request: URLRequest, limit: Int = maximumBytes) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw FilmFlowFailure.message("The FilmFlow request has no address.") }
        try requireHTTPS(url)
        _ = try RemoteMediaPolicy.validate(url)
        let connection = session()
        defer { connection.invalidateAndCancel() }
        let (stream, response) = try await connection.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.url == url,
              !(300..<400).contains(http.statusCode), http.expectedContentLength <= Int64(limit) else {
            throw FilmFlowFailure.message("FilmFlow redirected the request or exceeded its transfer limit.")
        }
        var data = Data()
        for try await byte in stream {
            guard data.count < limit else { throw FilmFlowFailure.message("The FilmFlow response exceeds its transfer limit.") }
            data.append(byte)
            if data.count.isMultiple(of: 65_536) { try Task.checkCancellation() }
        }
        try Task.checkCancellation()
        return (data, http)
    }

    static func transport(endpoint: URL, token: String?) -> HTTPClientTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FilmFlowPinnedProtocol.self]
        return HTTPClientTransport(endpoint: endpoint, configuration: configuration, streaming: false,
            requestModifier: { request in
                var request = request
                request.setValue(nil, forHTTPHeaderField: "Authorization")
                if let url = request.url, isResource(url), let token {
                    request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
                }
                return request
            })
    }
}

// The SDK's public transport takes a configuration, not a redirect-controlling URLSession.
final class FilmFlowPinnedProtocol: URLProtocol, @unchecked Sendable {
    // Client callbacks can synchronously reenter stopLoading().
    private let lock = NSRecursiveLock()
    private var requestTask: Task<Void, Never>?
    private var stopped = false
    private var finished = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        _ = startLoading(fetch: { try await FilmFlowHTTP.data($0) })
    }

    func startLoading(fetch: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)) -> Task<Void, Never>? {
        var request = request
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count >= 0, body.count + count <= 1_024 * 1_024 else {
                    notifyClient(terminal: true) {
                        $0.urlProtocol(self, didFailWithError: FilmFlowFailure.message("The FilmFlow request body is invalid or too large."))
                    }
                    return nil
                }
                if count == 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
            request.httpBodyStream = nil; request.httpBody = body
        }
        let outgoing = request
        let load: @Sendable () async -> Void = { [self, outgoing, fetch] in
            do {
                guard let url = outgoing.url, FilmFlowHTTP.isResource(url) else {
                    throw FilmFlowFailure.message("The FilmFlow connection changed its resource address.")
                }
                try Task.checkCancellation()
                let (data, response) = try await fetch(outgoing)
                notifyClient { $0.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed) }
                notifyClient { $0.urlProtocol(self, didLoad: data) }
                notifyClient(terminal: true) { $0.urlProtocolDidFinishLoading(self) }
            } catch {
                notifyClient(terminal: true) { $0.urlProtocol(self, didFailWithError: error) }
            }
        }
        let operation = Task(operation: load)
        let shouldCancel = lock.withLock {
            guard !stopped, !finished else { return true }
            requestTask = operation
            return false
        }
        if shouldCancel { operation.cancel() }
        return operation
    }

    override func stopLoading() {
        let operation = lock.withLock {
            stopped = true
            let operation = requestTask
            requestTask = nil
            return operation
        }
        operation?.cancel()
    }

    private func notifyClient(terminal: Bool = false, _ notify: (any URLProtocolClient) -> Void) {
        lock.withLock {
            guard !stopped, !finished, !Task.isCancelled, let client else { return }
            if terminal { finished = true; requestTask = nil }
            notify(client)
        }
    }
}
