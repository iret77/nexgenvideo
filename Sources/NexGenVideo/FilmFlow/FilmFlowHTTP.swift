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
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var request = request
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count >= 0, body.count + count <= 1_024 * 1_024 else {
                    client?.urlProtocol(self, didFailWithError: FilmFlowFailure.message("The FilmFlow request body is invalid or too large."))
                    return
                }
                if count == 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
            request.httpBodyStream = nil; request.httpBody = body
        }
        let outgoing = request
        let operation = Task { [self] in
            do {
                guard let url = outgoing.url, FilmFlowHTTP.isResource(url) else {
                    throw FilmFlowFailure.message("The FilmFlow connection changed its resource address.")
                }
                let (data, response) = try await FilmFlowHTTP.data(outgoing)
                guard !Task.isCancelled, lock.withLock({ !stopped }) else { return }
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                guard lock.withLock({ !stopped }) else { return }
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
        lock.withLock { if stopped { operation.cancel() } else { task = operation } }
    }

    override func stopLoading() { lock.withLock { stopped = true; task?.cancel(); task = nil } }
}
