import Foundation
import os

final class ManualVideoModesHTTP: URLProtocol, @unchecked Sendable {
    struct Request: Sendable { let method: String; let url: String; let body: Data }
    struct State: Sendable {
        var requestID = "native-video-modes-" + UUID().uuidString
        var endpoint = ""
        var output = Data()
        var requests: [Request] = []
        var uploads: [String: Data] = [:]
        var nextUpload = 0
        var unexpected: [String] = []
    }
    private static let state = OSAllocatedUnfairLock(initialState: State())
    static var snapshot: State { state.withLock { $0 } }
    static func install(endpoint: String, output: Data) {
        state.withLock { $0 = State(endpoint: endpoint, output: output) }
    }
    static func clear() { state.withLock { $0 = State() } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let address = request.url?.absoluteString ?? "", method = request.httpMethod ?? "GET"
        let body = Self.body(request)
        let result = Self.state.withLock { state -> (Data, String)? in
            state.requests.append(Request(method: method, url: address, body: body))
            func json(_ value: [String: Any]) -> (Data, String)? {
                (try? JSONSerialization.data(withJSONObject: value)).map { ($0, "application/json") }
            }
            let base = "https://queue.fal.run/bytedance/seedance-2.5/requests/" + state.requestID
            if method == "POST", address == "https://rest.fal.ai/storage/upload/initiate?storage_type=fal-cdn-v3",
               let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               object["file_name"] is String, object["content_type"] is String {
                state.nextUpload += 1
                let path = "/input-\(state.nextUpload)"
                return json(["upload_url": "https://upload.invalid" + path, "file_url": "https://media.invalid" + path])
            }
            if method == "PUT", let url = request.url, url.host == "upload.invalid",
               let index = Int(url.path.replacingOccurrences(of: "/input-", with: "")), index > 0, index <= state.nextUpload {
                state.uploads["https://media.invalid" + url.path] = body
                return (Data(), "application/octet-stream")
            }
            if method == "POST", !state.endpoint.isEmpty, address == "https://queue.fal.run/" + state.endpoint {
                return json(["request_id": state.requestID, "status_url": base + "/status", "response_url": base])
            }
            if method == "GET", address == base + "/status" { return json(["status": "COMPLETED"]) }
            if method == "GET", address == base { return json(["video": ["url": "https://media.invalid/result.mov"]]) }
            if method == "GET", address == "https://media.invalid/result.mov" { return (state.output, "video/quicktime") }
            state.unexpected.append(method + " " + address)
            return nil
        }
        guard let result, let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": result.1, "Content-Length": String(result.0.count)]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: result.0)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    private static func body(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(), bytes = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = stream.read(&bytes, maxLength: bytes.count)
            if count <= 0 { return data }
            data.append(contentsOf: bytes.prefix(count))
        }
    }
}
