import Foundation
import os

final class NativeNewMusicvideoHTTP: URLProtocol, @unchecked Sendable {
    private struct State {
        var catalogURL = ""
        var zipURL = ""
        var catalog = Data()
        var zip = Data()
        var catalogs = 0
        var zips = 0
        var unexpected: [String] = []
    }
    private static let state = OSAllocatedUnfairLock(initialState: State())
    static var catalogRequests: Int { state.withLock { $0.catalogs } }
    static var zipRequests: Int { state.withLock { $0.zips } }
    static var unexpectedRequests: [String] { state.withLock { $0.unexpected } }
    static func install(catalogURL: URL, catalog: Data, zipURL: URL, zip: Data) {
        state.withLock { $0 = State(catalogURL: catalogURL.absoluteString, zipURL: zipURL.absoluteString, catalog: catalog, zip: zip) }
    }
    static func clear() { state.withLock { $0 = State() } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body = Self.state.withLock { state -> (Data, String)? in
            guard request.httpMethod == "GET", request.url?.scheme == "https" else {
                state.unexpected.append(request.url?.absoluteString ?? "missing URL"); return nil
            }
            if request.url?.absoluteString == state.catalogURL { state.catalogs += 1; return (state.catalog, "application/json") }
            if request.url?.absoluteString == state.zipURL { state.zips += 1; return (state.zip, "application/zip") }
            state.unexpected.append(request.url?.absoluteString ?? "missing URL"); return nil
        }
        guard let (bytes, type) = body, let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": type]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: bytes)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
