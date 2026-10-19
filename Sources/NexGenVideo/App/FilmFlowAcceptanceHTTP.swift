import Foundation
import MCP
import NexGenEngine

final class FilmFlowAcceptanceHTTP: URLProtocol, @unchecked Sendable {
    enum Scenario: Equatable, Sendable { case normal, noActiveScript, scriptDisappears, metadataChanges }
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var calls: [[String: String]] = []
        var image = Data()
        var holdProjectRead = false
        var holdInitialize = false
        var heldReads = 0
        var cancelledReads = 0
        var scenario: Scenario = .normal
        var projectReads = 0
    }
    private static let state = State()
    static let projectID = "isolated-filmflow-project"
    static let title = "Isolated Harbour Film"
    static let token = "isolated-native-acceptance-not-a-credential"
    private var heldTool: String?

    static func install(image: Data, scenario: Scenario = .normal) { state.lock.withLock {
        state.image = image; state.calls = []; state.holdProjectRead = false; state.heldReads = 0; state.cancelledReads = 0
        state.holdInitialize = false
        state.scenario = scenario; state.projectReads = 0
    } }
    static func holdNextProjectRead() { state.lock.withLock { state.holdProjectRead = true } }
    static func holdNextInitialize() { state.lock.withLock { state.holdInitialize = true } }
    static func heldReadCount() -> Int { state.lock.withLock { state.heldReads } }
    static func cancelledReadCount() -> Int { state.lock.withLock { state.cancelledReads } }
    static func calls() -> [[String: String]] { state.lock.withLock { state.calls } }
    static func connection() -> FilmFlowOAuth.Connection {
        .init(id: UUID(), resource: FilmFlowHTTP.endpoint, issuer: URL(string: "https://issuer.invalid")!,
              tokens: .init(accessToken: token, refreshToken: nil, expiresAt: nil,
                            clientID: "isolated-client", tokenEndpoint: URL(string: "https://issuer.invalid/token")!))
    }
    static func reader(connection: FilmFlowOAuth.Connection) -> FilmFlowReader {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Self.self]
        let client = MCPProviderClient(config: .init(endpoint: FilmFlowHTTP.endpoint, bearerToken: token),
            urlSession: URLSession(configuration: configuration), legacyTransportFactory: { endpoint, _ in
                let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [Self.self]
                return HTTPClientTransport(endpoint: endpoint, configuration: config, streaming: false)
            })
        return FilmFlowReader(connection: connection, client: client, requireConnection: { value in
            guard value.resource == FilmFlowHTTP.endpoint, value.tokens.accessToken == token else {
                throw FilmFlowFailure.message("The isolated FilmFlow connection changed.")
            }
        }, downloadImage: { url in
            guard url.host == "filmflow-fixture.invalid", url.path == "/frame.png" else {
                throw FilmFlowFailure.message("The isolated image is deliberately unavailable.")
            }
            let bytes = state.lock.withLock { state.image }
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
            try bytes.write(to: temporary, options: .atomic)
            return .init(temporaryURL: temporary, response: HTTPURLResponse(url: url, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "image/png"])!)
        })
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url == FilmFlowHTTP.endpoint }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let body = try requestBytes()
            let value = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            let method = value["method"] as? String ?? ""
            let id = value["id"] ?? NSNull()
            let params = value["params"] as? [String: Any] ?? [:]
            var status = 200
            var payload: [String: Any]
            switch method {
            case "server/discover":
                status = 404; payload = ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Legacy transport fixture"]]
            case "initialize":
                if Self.state.lock.withLock({
                    guard Self.state.holdInitialize else { return false }
                    Self.state.holdInitialize = false; Self.state.heldReads += 1; heldTool = "initialize"
                    Self.state.calls.append(["tool": "initialize", "stage": "held-before-response"])
                    return true
                }) { return }
                payload = ["jsonrpc": "2.0", "id": id, "result": ["protocolVersion": Version.latest,
                    "capabilities": ["tools": [:]], "serverInfo": ["name": "isolated-filmflow", "version": "1"]]]
            case "notifications/initialized", "notifications/cancelled":
                status = 202; payload = [:]
            case "tools/list":
                let tools = ["list_projects", "get_project", "list_scenes", "get_shotlist", "list_entities"].map { name -> [String: Any] in
                    let properties: [String: Any] = name == "list_projects" ? [:] : ["projectId": ["type": "string"]]
                    return ["name": name, "description": "Isolated read-only acceptance", "inputSchema": ["type": "object",
                        "properties": properties, "required": name == "list_projects" ? [] : ["projectId"], "additionalProperties": false]]
                }
                payload = ["jsonrpc": "2.0", "id": id, "result": ["tools": tools]]
            case "tools/call":
                guard let name = params["name"] as? String,
                      let arguments = params["arguments"] as? [String: Any],
                      (name == "list_projects" ? arguments.isEmpty : (arguments["projectId"] as? String == Self.projectID && arguments.count == 1)) else {
                    throw FilmFlowFailure.message("The isolated read has different tool arguments.")
                }
                if name == "get_project", Self.state.lock.withLock({
                    guard Self.state.holdProjectRead else { return false }
                    Self.state.holdProjectRead = false; Self.state.heldReads += 1; self.heldTool = name
                    Self.state.calls.append(["tool": name, "stage": "held-before-response"])
                    return true
                }) { return }
                let mode = Self.state.lock.withLock { Self.state.scenario }
                if name == "get_shotlist", mode == .scriptDisappears {
                    payload = ["jsonrpc": "2.0", "id": id, "result": ["content": [["type": "text", "text": "No active script version (NO_ACTIVE_SCRIPT_VERSION)"]], "isError": true]]
                    break
                }
                var bytes = try Self.response(name)
                if name == "get_project" {
                    let count = Self.state.lock.withLock { Self.state.projectReads += 1; return Self.state.projectReads }
                    guard var detail = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
                        throw FilmFlowFailure.message("The isolated project response is not an object.")
                    }
                    if mode == .noActiveScript { detail.removeValue(forKey: "activeScriptVersion"); detail["counts"] = ["scenes": 0, "shots": 0, "entities": 2] }
                    if mode == .metadataChanges, count > 1 { detail["counts"] = ["scenes": 1, "shots": 2, "entities": 2] }
                    bytes = try JSONSerialization.data(withJSONObject: detail, options: [.sortedKeys, .withoutEscapingSlashes])
                }
                Self.state.lock.withLock { Self.state.calls.append(["tool": name, "sdkTextUTF8SHA256": FileDigest.sha256(of: bytes)]) }
                payload = ["jsonrpc": "2.0", "id": id, "result": ["content": [["type": "text", "text": String(decoding: bytes, as: UTF8.self)]], "isError": false]]
            default: throw FilmFlowFailure.message("Unexpected isolated FilmFlow transport request.")
            }
            let bytes = status == 202 ? Data() : try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            let response = HTTPURLResponse(url: FilmFlowHTTP.endpoint, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !bytes.isEmpty { client?.urlProtocol(self, didLoad: bytes) }
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {
        Self.state.lock.withLock {
            guard let heldTool else { return }
            self.heldTool = nil; Self.state.cancelledReads += 1
            Self.state.calls.append(["tool": heldTool, "stage": "transport-cancelled"])
        }
    }

    private func requestBytes() throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0, data.count + count <= 1_024 * 1_024 else { throw FilmFlowFailure.message("Invalid fixture request stream.") }
            if count == 0 { break }; data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    static func response(_ name: String) throws -> Data {
        let version: [String: Any] = ["versionNumber": 1, "label": "Isolated draft", "state": "DRAFT"]
        let summary: [String: Any] = ["projectId": projectID, "title": title, "phase": "STORYBOARD",
            "state": "DRAFT", "role": "OWNER", "updatedAt": "2026-01-01T00:00:00.000Z"]
        let camera: [String: Any] = ["move": "PAN", "moveIntensity": "slow", "moveNotes": "Track the harbour light",
            "lensMm": 50, "height": "eye", "angle": "level", "support": "tripod", "framingNotes": "Keep the doorway visible"]
        let value: Any
        switch name {
        case "list_projects": value = [summary]
        case "get_project":
            var detail = summary; detail.removeValue(forKey: "updatedAt")
            detail.merge(["styleBible": "Quiet blue harbour; preserve practical lights", "aspectRatio": "16:9", "sketchStyle": "PENCIL",
                "shotNumberingScheme": "EU", "documentLanguage": "en", "activeScriptVersion": version,
                "counts": ["scenes": 1, "shots": 1, "entities": 2],
                "unknownSecretURL": "https://filmflow-fixture.invalid/unknown?credential=never-retain"]) { _, new in new }
            value = detail
        case "list_scenes": value = [["sceneNumber": "1A", "heading": "EXT. HARBOUR — NIGHT", "intExt": "EXT",
            "timeOfDay": "NIGHT", "shortTitle": "Harbour light", "pageStart": 1, "pageEnd": 2, "shotCount": 1]]
        case "get_shotlist": value = ["project": ["title": title, "shotNumberingScheme": "EU", "aspectRatio": "16:9", "sketchStyle": "PENCIL"],
            "scriptVersion": version, "scenes": [["sceneNumber": "1A", "heading": "EXT. HARBOUR — NIGHT", "intExt": "EXT", "timeOfDay": "NIGHT",
                "shots": [["shotLabel": "1A.1", "shotType": "WS", "variant": NSNull(), "description": "A lantern crosses the empty doorway.",
                    "camera": camera, "lighting": ["mood": "blue", "complexity": "simple", "notes": "Practical lantern"],
                    "staging": ["intent": "Reveal the doorway", "notes": "Leave the foreground empty"], "durationSeconds": 400,
                    "charactersInFrame": ["Harbour keeper"], "targetEntity": ["name": "Harbour", "type": "LOCATION"],
                    "storyboardImageUrl": "https://filmflow-fixture.invalid/frame.png?signature=discard-after-download"]]]]]
        case "list_entities": value = [
            ["name": "Harbour keeper", "type": "CHARACTER", "aliases": ["Keeper"], "visualDescription": "Blue coat",
             "referenceImageUrl": "https://filmflow-fixture.invalid/frame.png?signature=another", "notes": "Display-only upstream confirmation", "isConfirmed": true],
            ["name": "Harbour keeper", "type": "PROP", "aliases": [], "visualDescription": "Wooden sign",
             "referenceImageUrl": "https://filmflow-fixture.invalid/missing.png?signature=expired", "notes": "Deliberate missing-image case", "isConfirmed": false]]
        default: throw FilmFlowFailure.message("Unknown isolated read tool.")
        }
        return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}
