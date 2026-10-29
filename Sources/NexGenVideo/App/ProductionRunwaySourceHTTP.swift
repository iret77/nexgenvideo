import Foundation
import os

final class ProductionRunwaySourceHTTP: URLProtocol, @unchecked Sendable {
    enum Operation: String, Sendable { case transform, extend }
    struct Request: Sendable { let method: String; let url: String; let body: Data }
    private struct State: Sendable {
        var operation: Operation?
        var output = Data()
        var requests: [Request] = []
        var unexpected: [String] = []
        var uploaded = false
        var submitted = false
    }
    static let requestID = "native-source-simulator-task"
    static let sourceURI = "runway://native-source-simulator-upload"
    private static let state = OSAllocatedUnfairLock(initialState: State())
    static var requests: [Request] { state.withLock { $0.requests } }
    static var unexpectedRequests: [String] { state.withLock { $0.unexpected } }

    static func install(operation: Operation, output: Data) {
        state.withLock { $0 = State(operation: operation, output: output) }
    }

    static func clear() { state.withLock { $0 = State() } }

    static var submittedBody: [String: Any]? {
        guard let request = requests.first(where: { $0.method == "POST" && $0.url == "https://api.dev.runwayml.com/v1/video_to_video" }) else { return nil }
        return try? JSONSerialization.jsonObject(with: request.body) as? [String: Any]
    }

    static var uploadedBytes: Data? {
        guard let request = requests.first(where: { $0.method == "POST" && $0.url == "https://upload.invalid/native-source" }),
              let header = request.body.range(of: Data("name=\"file\"; filename=\"".utf8)),
              let start = request.body.range(of: Data("\r\n\r\n".utf8), in: header.upperBound..<request.body.endIndex),
              let end = request.body.range(of: Data("\r\n--ngv-".utf8), options: .backwards, in: start.upperBound..<request.body.endIndex) else { return nil }
        return request.body.subdata(in: start.upperBound..<end.lowerBound)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url?.absoluteString ?? "missing URL"
        let method = request.httpMethod ?? "GET"
        let bytes = Self.body(request)
        let answer: (status: Int, type: String, bytes: Data)? = Self.state.withLock { value in
            value.requests.append(.init(method: method, url: url, body: bytes))
            guard let operation = value.operation else {
                value.unexpected.append(method + " " + url); return nil
            }
            func json(_ value: [String: Any]) -> (Int, String, Data)? {
                guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return nil }
                return (200, "application/json", data)
            }
            let authenticated = request.value(forHTTPHeaderField: "Authorization") == "Bearer simulator-only-key"
            switch (method, url) {
            case ("GET", "https://api.dev.runwayml.com/v1/organization") where authenticated:
                let modelID = operation == .extend ? "seedance2_5" : "aleph2"
                return json(["tier": ["models": [modelID: [:]]]])
            case ("POST", "https://api.dev.runwayml.com/v1/uploads") where authenticated:
                guard let input = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                      Set(input.keys) == Set(["filename", "numberOfParts", "type"]),
                      let filename = input["filename"] as? String, !filename.isEmpty,
                      input["numberOfParts"] as? Int == 1, input["type"] as? String == "ephemeral" else { break }
                return json(["uploadUrl": "https://upload.invalid/native-source", "fields": ["key": "native-source"], "runwayUri": Self.sourceURI])
            case ("POST", "https://upload.invalid/native-source"):
                guard !value.uploaded, request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=ngv-") == true,
                      bytes.range(of: Data("name=\"file\"; filename=\"".utf8)) != nil else { break }
                value.uploaded = true
                return (204, "application/octet-stream", Data())
            case ("POST", "https://api.dev.runwayml.com/v1/video_to_video") where authenticated:
                guard value.uploaded, !value.submitted,
                      let input = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                      let prompt = input["promptText"] as? String, !prompt.isEmpty else { break }
                if operation == .extend {
                    guard Set(input.keys) == Set(["model", "mode", "promptVideo", "promptText", "duration", "audio"]),
                          input["model"] as? String == "seedance2_5", input["mode"] as? String == "extend",
                          input["promptVideo"] as? String == Self.sourceURI, let duration = input["duration"] as? Int,
                          (4...30).contains(duration), input["audio"] as? Bool == false else { break }
                } else {
                    guard Set(input.keys) == Set(["model", "videoUri", "promptText", "ratio"]),
                          input["model"] as? String == "aleph2", input["videoUri"] as? String == Self.sourceURI,
                          input["ratio"] as? String == "1280:720" else { break }
                }
                value.submitted = true
                return json(["id": Self.requestID])
            case ("GET", "https://api.dev.runwayml.com/v1/tasks/" + Self.requestID) where authenticated && value.submitted:
                return json(["id": Self.requestID, "status": "SUCCEEDED", "output": ["https://media.invalid/native-source-output.mov"]])
            case ("GET", "https://media.invalid/native-source-output.mov") where value.submitted:
                return (200, "video/quicktime", value.output)
            default: break
            }
            value.unexpected.append(method + " " + url)
            return nil
        }
        guard let answer, let target = request.url,
              let response = HTTPURLResponse(url: target, statusCode: answer.status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": answer.type, "Content-Length": String(answer.bytes.count)]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.bytes)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func body(_ request: URLRequest) -> Data {
        if let value = request.httpBody { return value }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { return result }
            result.append(contentsOf: buffer.prefix(count))
        }
    }
}
