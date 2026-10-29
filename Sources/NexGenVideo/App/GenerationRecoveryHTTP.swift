import Foundation
import os

final class GenerationRecoveryHTTP: URLProtocol, @unchecked Sendable {
    struct Request: Codable, Sendable { let method: String; let url: String; let body: Data }
    struct State: Sendable {
        var resumed = false
        var endpoint = ""
        var output = Data()
        var requests: [Request] = []
        var submissions = 0
        var unexpected: [String] = []
    }
    private static let state = OSAllocatedUnfairLock(initialState: State())
    static var requests: [Request] { state.withLock { $0.requests } }
    static var unexpected: [String] { state.withLock { $0.unexpected } }
    static func install(resumed: Bool, endpoint: String, output: Data) {
        state.withLock { $0 = State(resumed: resumed, endpoint: endpoint, output: output) }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let method = request.httpMethod ?? "GET", url = request.url?.absoluteString ?? ""
        let body = Self.body(request)
        let response: (String, Data)? = Self.state.withLock { state in
            state.requests.append(.init(method: method, url: url, body: body))
            func json(_ object: [String: Any]) -> (String, Data)? {
                (try? JSONSerialization.data(withJSONObject: object)).map { ("application/json", $0) }
            }
            let base = "https://queue.fal.run/fal-ai/elevenlabs/requests/"
            if method == "POST", url == "https://queue.fal.run/" + state.endpoint, !state.resumed {
                state.submissions += 1
                guard state.submissions <= 2 else { state.unexpected.append("Unexpected paid submit " + url); return nil }
                let id = "native-recovery-job-" + String(state.submissions)
                return json(["request_id": id, "status_url": base + id + "/status", "response_url": base + id])
            }
            if method == "GET", url.hasPrefix(base) {
                let id = state.resumed ? "native-recovery-job-2" : "native-recovery-job-" + String(state.submissions)
                if url == base + id + "/status" {
                    return json(["status": state.resumed || id.hasSuffix("1") ? "COMPLETED" : "IN_PROGRESS"])
                }
                if url == base + id, state.resumed || id.hasSuffix("1") {
                    return json(["audio": ["url": "https://media.invalid/" + id + ".wav", "content_type": "audio/wav"]])
                }
            }
            if method == "GET", url == "https://media.invalid/native-recovery-job-1.wav", !state.resumed {
                return ("audio/wav", state.output)
            }
            if method == "GET", url == "https://media.invalid/native-recovery-job-2.wav", state.resumed {
                return ("audio/wav", state.output)
            }
            state.unexpected.append(method + " " + url)
            return nil
        }
        guard let response, let target = request.url,
              let http = HTTPURLResponse(url: target, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": response.0, "Content-Length": String(response.1.count)]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.1)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    private static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { return data }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
}
