import Foundation
import MCP

enum MCP20260728 {
    static let version = "2026-07-28"
    static let protocolVersionHeader = "MCP-Protocol-Version"
    static let methodHeader = "Mcp-Method"
    static let nameHeader = "Mcp-Name"
    static let parameterHeaderPrefix = "Mcp-Param-"

    enum WireValue: Codable, Equatable, Sendable {
        case null
        case bool(Bool)
        case int(Int)
        case double(Double)
        case string(String)
        case array([WireValue])
        case object([String: WireValue])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
            } else if let value = try? container.decode(Bool.self) {
                self = .bool(value)
            } else if let value = try? container.decode(Int.self) {
                self = .int(value)
            } else if let value = try? container.decode(Double.self) {
                guard value.isFinite else {
                    throw DecodingError.dataCorruptedError(
                        in: container,
                        debugDescription: "JSON numbers must be finite"
                    )
                }
                self = .double(value)
            } else if let value = try? container.decode(String.self) {
                self = .string(value)
            } else if let value = try? container.decode([WireValue].self) {
                self = .array(value)
            } else {
                self = .object(try container.decode([String: WireValue].self))
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .null: try container.encodeNil()
            case .bool(let value): try container.encode(value)
            case .int(let value): try container.encode(value)
            case .double(let value): try container.encode(value)
            case .string(let value): try container.encode(value)
            case .array(let value): try container.encode(value)
            case .object(let value): try container.encode(value)
            }
        }

        var objectValue: [String: WireValue]? {
            guard case .object(let value) = self else { return nil }
            return value
        }

        var arrayValue: [WireValue]? {
            guard case .array(let value) = self else { return nil }
            return value
        }

        var stringValue: String? {
            guard case .string(let value) = self else { return nil }
            return value
        }

        var boolValue: Bool? {
            guard case .bool(let value) = self else { return nil }
            return value
        }

        static func fromAny(_ value: Any) -> WireValue {
            switch value {
            case is NSNull: return .null
            case let value as Bool: return .bool(value)
            case let value as Int: return .int(value)
            case let value as NSNumber:
                let number = value.doubleValue
                return number.rounded(.towardZero) == number
                    && number >= Double(Int.min)
                    && number <= Double(Int.max)
                    ? .int(value.intValue)
                    : .double(number)
            case let value as Double: return .double(value)
            case let value as String: return .string(value)
            case let value as [Any]: return .array(value.map(fromAny))
            case let value as [String: Any]:
                return .object(value.mapValues { fromAny($0) })
            default: return .null
            }
        }

        static func fromMCP(_ value: Value) -> WireValue {
            switch value {
            case .null: return .null
            case .bool(let value): return .bool(value)
            case .int(let value): return .int(value)
            case .double(let value): return .double(value)
            case .string(let value): return .string(value)
            case .data(let mimeType, let data):
                let type = mimeType ?? "application/octet-stream"
                return .string(
                    "data:\(type);base64,\(data.base64EncodedString())"
                )
            case .array(let values): return .array(values.map(fromMCP))
            case .object(let values):
                return .object(values.mapValues { fromMCP($0) })
            }
        }

        var mcpValue: Value {
            switch self {
            case .null: return .null
            case .bool(let value): return .bool(value)
            case .int(let value): return .int(value)
            case .double(let value): return .double(value)
            case .string(let value): return .string(value)
            case .array(let values): return .array(values.map(\.mcpValue))
            case .object(let values):
                return .object(values.mapValues { $0.mcpValue })
            }
        }

        var anyValue: Any {
            switch self {
            case .null: return NSNull()
            case .bool(let value): return value
            case .int(let value): return value
            case .double(let value): return value
            case .string(let value): return value
            case .array(let values): return values.map(\.anyValue)
            case .object(let values): return values.mapValues { $0.anyValue }
            }
        }
    }

    struct Request: Equatable, Sendable {
        let id: WireValue
        let method: String
        let params: [String: WireValue]
    }

    struct HTTPResult: Sendable {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    enum HandlerResult: Sendable {
        case result([String: WireValue])
        case error(status: Int, code: Int, message: String, data: WireValue? = nil)
    }

    enum ValidationResult: Sendable {
        case success(Request)
        case failure(HTTPResult)
    }

    struct HeaderBinding: Equatable, Sendable {
        enum Primitive: String, Sendable {
            case string
            case integer
            case boolean
        }

        let name: String
        let path: [String]
        let primitive: Primitive
    }

    enum HeaderBindingError: LocalizedError, Equatable, Sendable {
        case invalidPlacement
        case invalidName(String)
        case duplicateName(String)
        case invalidType(String)

        var errorDescription: String? {
            switch self {
            case .invalidPlacement:
                "x-mcp-header is not on a statically reachable object property."
            case .invalidName(let name):
                "x-mcp-header has an invalid HTTP token name: \(name)."
            case .duplicateName(let name):
                "x-mcp-header is duplicated case-insensitively: \(name)."
            case .invalidType(let type):
                "x-mcp-header requires string, integer, or boolean, not \(type)."
            }
        }
    }

    private struct Envelope: Decodable {
        let jsonrpc: String
        let id: WireValue
        let method: String
        let params: [String: WireValue]
    }

    private struct ErrorEnvelope: Decodable {
        struct Payload: Decodable {
            let code: Int
            let message: String
            let data: WireValue?
        }

        let jsonrpc: String
        let id: WireValue?
        let error: Payload
    }

    private struct ResultEnvelope: Decodable {
        let jsonrpc: String
        let id: WireValue
        let result: WireValue
    }

    struct RemoteError: LocalizedError, Sendable {
        let status: Int
        let code: Int?
        let message: String
        let data: WireValue?
        let recognizedModern: Bool

        var errorDescription: String? { message }
    }

    static func isModernRequest(body: Data?, headers: [String: String]) -> Bool {
        if let version = header(headers, named: protocolVersionHeader) {
            return !legacyVersions.contains(version)
        }
        if header(headers, named: methodHeader) != nil { return true }
        guard let body,
              let value = try? JSONDecoder().decode(WireValue.self, from: body),
              let object = value.objectValue
        else { return false }
        if object["method"]?.stringValue == "server/discover" { return true }
        return object["params"]?.objectValue?["_meta"]?.objectValue?[
            "io.modelcontextprotocol/protocolVersion"
        ]?.stringValue == version
    }

    static func handle(
        body: Data?,
        headers: [String: String],
        handler: @Sendable (Request) async -> HandlerResult
    ) async -> HTTPResult {
        let parsed: Request
        switch validate(body: body, headers: headers) {
        case .success(let request):
            parsed = request
        case .failure(let result):
            return result
        }

        switch await handler(parsed) {
        case .result(let fields):
            return success(id: parsed.id, fields: fields)
        case .error(let status, let code, let message, let data):
            return error(
                status: status,
                id: parsed.id,
                code: code,
                message: message,
                data: data
            )
        }
    }

    static func validate(
        body: Data?,
        headers: [String: String]
    ) -> ValidationResult {
        guard let body else {
            return .failure(error(
                status: 400,
                id: .null,
                code: -32700,
                message: "Parse error: request body is missing."
            ))
        }

        guard (try? JSONDecoder().decode(WireValue.self, from: body)) != nil else {
            return .failure(error(
                status: 400,
                id: .null,
                code: -32700,
                message: "Parse error"
            ))
        }

        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: body)
        } catch {
            let parsedID = (try? JSONDecoder().decode(WireValue.self, from: body))?
                .objectValue?["id"] ?? .null
            return .failure(Self.error(
                status: 400,
                id: parsedID,
                code: -32600,
                message: "Invalid Request"
            ))
        }
        guard envelope.jsonrpc == "2.0", isValidRequestID(envelope.id) else {
            return .failure(error(
                status: 400,
                id: isValidRequestID(envelope.id) ? envelope.id : .null,
                code: -32600,
                message: "Invalid Request"
            ))
        }
        guard let meta = envelope.params["_meta"]?.objectValue,
              let bodyVersion = meta[
                "io.modelcontextprotocol/protocolVersion"
              ]?.stringValue,
              meta[
                "io.modelcontextprotocol/clientCapabilities"
              ]?.objectValue != nil
        else {
            return .failure(error(
                status: 400,
                id: envelope.id,
                code: -32602,
                message: "Invalid params: required request metadata is missing."
            ))
        }
        if let clientInfo = meta[
            "io.modelcontextprotocol/clientInfo"
        ] {
            guard let object = clientInfo.objectValue,
                  object["name"]?.stringValue?.isEmpty == false,
                  object["version"]?.stringValue?.isEmpty == false
            else {
                return .failure(error(
                    status: 400,
                    id: envelope.id,
                    code: -32602,
                    message: "Invalid params: clientInfo requires name and version."
                ))
            }
        }

        guard let headerVersion = header(headers, named: protocolVersionHeader),
              headerVersion == bodyVersion
        else {
            return .failure(headerMismatch(
                id: envelope.id,
                message: "Header mismatch: MCP-Protocol-Version must match request metadata."
            ))
        }
        guard bodyVersion == version else {
            return .failure(error(
                status: 400,
                id: envelope.id,
                code: -32022,
                message: "Unsupported protocol version: \(bodyVersion)",
                data: .object(["supportedVersions": .array([.string(version)])])
            ))
        }
        guard header(headers, named: methodHeader) == envelope.method else {
            return .failure(headerMismatch(
                id: envelope.id,
                message: "Header mismatch: Mcp-Method must match the request method."
            ))
        }

        if let sourceKey = nameSourceKey(for: envelope.method) {
            guard let bodyName = envelope.params[sourceKey]?.stringValue else {
                return .failure(error(
                    status: 400,
                    id: envelope.id,
                    code: -32602,
                    message: "Invalid params: \(sourceKey) is required."
                ))
            }
            guard let rawHeader = header(headers, named: nameHeader),
                  let decoded = decodeHeaderValue(rawHeader),
                  decoded == bodyName
            else {
                return .failure(headerMismatch(
                    id: envelope.id,
                    message: "Header mismatch: Mcp-Name must match params.\(sourceKey)."
                ))
            }
        }

        return .success(Request(
            id: envelope.id,
            method: envelope.method,
            params: envelope.params
        ))
    }

    static func success(
        id: WireValue,
        fields: [String: WireValue]
    ) -> HTTPResult {
        var result = fields
        result["resultType"] = result["resultType"] ?? .string("complete")
        var meta = result["_meta"]?.objectValue ?? [:]
        meta["io.modelcontextprotocol/serverInfo"] = .object([
            "name": .string("nexgen"),
            "version": .string("1.0.0"),
        ])
        result["_meta"] = .object(meta)
        return jsonResponse(
            status: 200,
            value: .object([
                "jsonrpc": .string("2.0"),
                "id": id,
                "result": .object(result),
            ])
        )
    }

    static func error(
        status: Int,
        id: WireValue,
        code: Int,
        message: String,
        data: WireValue? = nil
    ) -> HTTPResult {
        var payload: [String: WireValue] = [
            "code": .int(code),
            "message": .string(message),
        ]
        if let data { payload["data"] = data }
        return jsonResponse(
            status: status,
            value: .object([
                "jsonrpc": .string("2.0"),
                "id": id,
                "error": .object(payload),
            ])
        )
    }

    static func requestBody(
        id: WireValue,
        method: String,
        params: [String: WireValue]
    ) throws -> Data {
        var params = params
        var meta = params["_meta"]?.objectValue ?? [:]
        meta["io.modelcontextprotocol/protocolVersion"] = .string(version)
        meta["io.modelcontextprotocol/clientInfo"] = .object([
            "name": .string("nexgen"),
            "version": .string("1.0.0"),
        ])
        meta["io.modelcontextprotocol/clientCapabilities"] = meta[
            "io.modelcontextprotocol/clientCapabilities"
        ] ?? .object([:])
        params["_meta"] = .object(meta)
        return try encode(.object([
            "jsonrpc": .string("2.0"),
            "id": id,
            "method": .string(method),
            "params": .object(params),
        ]))
    }

    static func requestHeaders(
        method: String,
        name: String? = nil,
        parameterHeaders: [String: String] = [:]
    ) -> [String: String] {
        var headers = [
            "Accept": "application/json, text/event-stream",
            "Content-Type": "application/json",
            protocolVersionHeader: version,
            methodHeader: method,
        ]
        if let name { headers[nameHeader] = encodeHeaderValue(name) }
        for (name, value) in parameterHeaders {
            headers[parameterHeaderPrefix + name] = encodeHeaderValue(value)
        }
        return headers
    }

    static func decodeResponse(
        data: Data,
        response: HTTPURLResponse,
        expectedID: WireValue
    ) throws -> WireValue {
        let payload = try responsePayload(data: data, response: response, expectedID: expectedID)
        if let result = try? JSONDecoder().decode(ResultEnvelope.self, from: payload),
           result.jsonrpc == "2.0",
           result.id == expectedID {
            return result.result
        }
        if let failure = try? JSONDecoder().decode(ErrorEnvelope.self, from: payload),
           failure.jsonrpc == "2.0",
           failure.id == nil || failure.id == expectedID {
            throw RemoteError(
                status: response.statusCode,
                code: failure.error.code,
                message: failure.error.message,
                data: failure.error.data,
                recognizedModern: recognizedModernErrorCodes.contains(failure.error.code)
            )
        }
        throw RemoteError(
            status: response.statusCode,
            code: nil,
            message: "The provider returned an invalid MCP response.",
            data: nil,
            recognizedModern: false
        )
    }

    static func headerBindings(in schema: WireValue) throws -> [HeaderBinding] {
        var bindings: [HeaderBinding] = []
        var names: Set<String> = []
        try inspectSchema(
            schema,
            path: [],
            reachable: true,
            bindings: &bindings,
            names: &names
        )
        return bindings.sorted { lhs, rhs in
            if lhs.name.caseInsensitiveCompare(rhs.name) == .orderedSame {
                return lhs.path.lexicographicallyPrecedes(rhs.path)
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    static func parameterHeaders(
        bindings: [HeaderBinding],
        arguments: [String: WireValue]
    ) throws -> [String: String] {
        var result: [String: String] = [:]
        for binding in bindings {
            guard let value = value(at: binding.path, in: arguments),
                  value != .null else { continue }
            let rendered: String
            switch (binding.primitive, value) {
            case (.string, .string(let value)):
                rendered = value
            case (.integer, .int(let value)):
                guard abs(Double(value)) <= 9_007_199_254_740_991 else {
                    throw HeaderBindingError.invalidType("unsafe integer")
                }
                rendered = String(value)
            case (.integer, .double(let value)):
                guard value.isFinite,
                      value.rounded(.towardZero) == value,
                      abs(value) <= 9_007_199_254_740_991,
                      let integer = Int(exactly: value) else {
                    throw HeaderBindingError.invalidType("unsafe integer")
                }
                rendered = String(integer)
            case (.boolean, .bool(let value)):
                rendered = value ? "true" : "false"
            default:
                throw HeaderBindingError.invalidType("argument value")
            }
            result[binding.name] = rendered
        }
        return result
    }

    static func cacheLifetimeMilliseconds(
        in result: [String: WireValue]
    ) -> Double? {
        guard let scope = result["cacheScope"]?.stringValue,
              scope == "public" || scope == "private",
              let ttl = result["ttlMs"] else { return nil }
        let milliseconds: Double
        switch ttl {
        case .int(let value): milliseconds = Double(value)
        case .double(let value): milliseconds = value
        default: return nil
        }
        guard milliseconds.isFinite, milliseconds >= 0 else { return nil }
        return milliseconds
    }

    static func encodeHeaderValue(_ value: String) -> String {
        let scalars = value.unicodeScalars
        let sentinel = value.hasPrefix("=?base64?") && value.hasSuffix("?=")
        let leadingOrTrailingWhitespace = value.first?.isWhitespace == true
            || value.last?.isWhitespace == true
        let plain = !value.isEmpty
            && !sentinel
            && !leadingOrTrailingWhitespace
            && scalars.allSatisfy {
                $0.value == 0x09 || (0x20...0x7e).contains($0.value)
            }
        guard !plain else { return value }
        return "=?base64?\(Data(value.utf8).base64EncodedString())?="
    }

    static func decodeHeaderValue(_ value: String) -> String? {
        let prefix = "=?base64?"
        let suffix = "?="
        if value.hasPrefix(prefix), value.hasSuffix(suffix) {
            let start = value.index(value.startIndex, offsetBy: prefix.count)
            let end = value.index(value.endIndex, offsetBy: -suffix.count)
            guard start <= end,
                  let data = Data(base64Encoded: String(value[start..<end])),
                  let decoded = String(data: data, encoding: .utf8)
            else { return nil }
            return decoded
        }
        guard !value.isEmpty,
              value.unicodeScalars.allSatisfy({
                  $0.value == 0x09 || (0x20...0x7e).contains($0.value)
              })
        else { return nil }
        return value
    }

    static func header(_ headers: [String: String], named name: String) -> String? {
        headers.first {
            $0.key.caseInsensitiveCompare(name) == .orderedSame
        }?.value
    }

    private static let legacyVersions: Set<String> = [
        "2024-11-05",
        "2025-03-26",
        "2025-06-18",
        "2025-11-25",
    ]

    private static let recognizedModernErrorCodes: Set<Int> = [
        -32020,
        -32021,
        -32022,
    ]

    private static func nameSourceKey(for method: String) -> String? {
        switch method {
        case "tools/call", "prompts/get": "name"
        case "resources/read": "uri"
        default: nil
        }
    }

    private static func isValidRequestID(_ id: WireValue) -> Bool {
        switch id {
        case .string, .int, .double: true
        default: false
        }
    }

    private static func headerMismatch(id: WireValue, message: String) -> HTTPResult {
        error(status: 400, id: id, code: -32020, message: message)
    }

    private static func jsonResponse(status: Int, value: WireValue) -> HTTPResult {
        let body = (try? encode(value)) ?? Data()
        return HTTPResult(
            status: status,
            headers: ["Content-Type": "application/json"],
            body: body
        )
    }

    private static func encode(_ value: WireValue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func responsePayload(
        data: Data,
        response: HTTPURLResponse,
        expectedID: WireValue
    ) throws -> Data {
        let contentType = response.value(forHTTPHeaderField: "Content-Type")?
            .lowercased() ?? ""
        guard contentType.contains("text/event-stream") else { return data }

        let text = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
        for event in text.components(separatedBy: "\n\n").reversed() {
            let payload = event.split(separator: "\n", omittingEmptySubsequences: false)
                .compactMap { line -> Substring? in
                    guard line == "data" || line.hasPrefix("data:") else { return nil }
                    var value = line.dropFirst(5)
                    if value.first == " " { value = value.dropFirst() }
                    return value
                }
                .joined(separator: "\n")
            guard !payload.isEmpty else { continue }
            let candidate = Data(payload.utf8)
            if let result = try? JSONDecoder().decode(ResultEnvelope.self, from: candidate),
               result.id == expectedID {
                return candidate
            }
            if let failure = try? JSONDecoder().decode(ErrorEnvelope.self, from: candidate),
               failure.id == nil || failure.id == expectedID {
                return candidate
            }
        }
        throw RemoteError(
            status: response.statusCode,
            code: nil,
            message: "The provider's MCP stream ended without a final response.",
            data: nil,
            recognizedModern: false
        )
    }

    private static func inspectSchema(
        _ value: WireValue,
        path: [String],
        reachable: Bool,
        bindings: inout [HeaderBinding],
        names: inout Set<String>
    ) throws {
        switch value {
        case .array(let values):
            for value in values {
                try inspectSchema(
                    value,
                    path: path,
                    reachable: false,
                    bindings: &bindings,
                    names: &names
                )
            }
        case .object(let object):
            if let annotation = object["x-mcp-header"] {
                guard reachable, !path.isEmpty else {
                    throw HeaderBindingError.invalidPlacement
                }
                guard let name = annotation.stringValue, isHTTPToken(name) else {
                    throw HeaderBindingError.invalidName(
                        annotation.stringValue ?? "<non-string>"
                    )
                }
                let normalized = name.lowercased()
                guard names.insert(normalized).inserted else {
                    throw HeaderBindingError.duplicateName(name)
                }
                guard let rawType = object["type"]?.stringValue,
                      let primitive = HeaderBinding.Primitive(rawValue: rawType)
                else {
                    throw HeaderBindingError.invalidType(
                        object["type"]?.stringValue ?? "unspecified"
                    )
                }
                bindings.append(HeaderBinding(
                    name: name,
                    path: path,
                    primitive: primitive
                ))
            }

            for (key, child) in object {
                if key == "properties", reachable,
                   let properties = child.objectValue {
                    for (property, schema) in properties {
                        try inspectSchema(
                            schema,
                            path: path + [property],
                            reachable: true,
                            bindings: &bindings,
                            names: &names
                        )
                    }
                } else if key != "x-mcp-header" {
                    try inspectSchema(
                        child,
                        path: path,
                        reachable: false,
                        bindings: &bindings,
                        names: &names
                    )
                }
            }
        default:
            break
        }
    }

    private static func isHTTPToken(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        let allowed = CharacterSet(
            charactersIn: "!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
        )
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func value(
        at path: [String],
        in arguments: [String: WireValue]
    ) -> WireValue? {
        guard let first = path.first, var current = arguments[first] else { return nil }
        for key in path.dropFirst() {
            guard let next = current.objectValue?[key] else { return nil }
            current = next
        }
        return current
    }
}
