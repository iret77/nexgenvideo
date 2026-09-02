import Foundation
import Testing

@testable import NexGenVideo

@Suite("MCP 2026-07-28 protocol")
struct MCP20260728Tests {
    @Test("a valid request carries metadata and matching routing headers")
    func validRequest() throws {
        let id = MCP20260728.WireValue.string("request-1")
        let body = try MCP20260728.requestBody(
            id: id,
            method: "tools/call",
            params: [
                "name": .string("generate 世界"),
                "arguments": .object(["prompt": .string("A quiet harbor")]),
            ]
        )
        let headers = MCP20260728.requestHeaders(
            method: "tools/call",
            name: "generate 世界"
        )

        guard case .success(let request) = MCP20260728.validate(
            body: body,
            headers: headers
        ) else {
            Issue.record("The valid modern request was rejected")
            return
        }
        #expect(request.id == id)
        #expect(request.method == "tools/call")
        #expect(request.params["name"] == .string("generate 世界"))
        #expect(
            headers[MCP20260728.nameHeader]
                == "=?base64?Z2VuZXJhdGUg5LiW55WM?="
        )
    }

    @Test("routing header mismatch is a 400 HeaderMismatch response")
    func headerMismatch() throws {
        let body = try MCP20260728.requestBody(
            id: .int(7),
            method: "resources/read",
            params: ["uri": .string("nexgen://models/video")]
        )
        var headers = MCP20260728.requestHeaders(
            method: "resources/read",
            name: "nexgen://models/video"
        )
        headers[MCP20260728.nameHeader] = "nexgen://models/image"

        guard case .failure(let response) = MCP20260728.validate(
            body: body,
            headers: headers
        ) else {
            Issue.record("The mismatched routing header was accepted")
            return
        }
        #expect(response.status == 400)
        let object = try #require(
            try JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        )
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32020)
        #expect(object["id"] as? Int == 7)
    }

    @Test("unsupported versions advertise the one implemented revision")
    func unsupportedVersion() throws {
        let bodyValue = try #require(
            try JSONSerialization.jsonObject(
                with: MCP20260728.requestBody(
                    id: .string("version"),
                    method: "server/discover",
                    params: [:]
                )
            ) as? [String: Any]
        )
        var mutated = bodyValue
        var params = try #require(mutated["params"] as? [String: Any])
        var meta = try #require(params["_meta"] as? [String: Any])
        meta["io.modelcontextprotocol/protocolVersion"] = "2099-01-01"
        params["_meta"] = meta
        mutated["params"] = params
        let body = try JSONSerialization.data(withJSONObject: mutated)
        var headers = MCP20260728.requestHeaders(method: "server/discover")
        headers[MCP20260728.protocolVersionHeader] = "2099-01-01"

        guard case .failure(let response) = MCP20260728.validate(
            body: body,
            headers: headers
        ) else {
            Issue.record("The unsupported protocol version was accepted")
            return
        }
        let object = try #require(
            try JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        )
        let error = try #require(object["error"] as? [String: Any])
        let data = try #require(error["data"] as? [String: Any])
        #expect(error["code"] as? Int == -32022)
        #expect(data["supportedVersions"] as? [String] == [MCP20260728.version])
    }

    @Test("all results identify the server and declare their result type")
    func resultMetadata() throws {
        let response = MCP20260728.success(
            id: .int(11),
            fields: ["tools": .array([])]
        )
        let object = try #require(
            try JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        )
        let result = try #require(object["result"] as? [String: Any])
        let meta = try #require(result["_meta"] as? [String: Any])
        let server = try #require(
            meta["io.modelcontextprotocol/serverInfo"] as? [String: Any]
        )
        #expect(result["resultType"] as? String == "complete")
        #expect(server["name"] as? String == "nexgen")
        #expect(server["version"] as? String == "1.0.0")
    }

    @Test("cache metadata accepts only nonnegative lifetimes and defined scopes")
    func cacheMetadata() {
        #expect(MCP20260728.cacheLifetimeMilliseconds(in: [
            "ttlMs": .double(1_500.5),
            "cacheScope": .string("private"),
        ]) == 1_500.5)
        #expect(MCP20260728.cacheLifetimeMilliseconds(in: [
            "ttlMs": .int(-1),
            "cacheScope": .string("private"),
        ]) == nil)
        #expect(MCP20260728.cacheLifetimeMilliseconds(in: [
            "ttlMs": .int(1),
            "cacheScope": .string("shared"),
        ]) == nil)
    }

    @Test("event streams yield the matching final JSON-RPC response")
    func eventStreamResponse() throws {
        let id = MCP20260728.WireValue.string("stream-1")
        let stream = Data(
            "event: progress\r\ndata: {\"progress\":0.5}\r\n\r\nevent: message\r\ndata: {\"jsonrpc\":\"2.0\",\"id\":\"stream-1\",\"result\":{\"resultType\":\"complete\",\"content\":[]}}\r\n\r\n".utf8
        )
        let response = try #require(HTTPURLResponse(
            url: URL(string: "https://provider.example/mcp")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        ))

        let decoded = try MCP20260728.decodeResponse(
            data: stream,
            response: response,
            expectedID: id
        )

        #expect(decoded.objectValue?["resultType"] == .string("complete"))
    }

    @Test("nested primitive header annotations mirror exact argument paths")
    func customParameterHeaders() throws {
        let schema = MCP20260728.WireValue.object([
            "type": .string("object"),
            "properties": .object([
                "routing": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "region": .object([
                            "type": .string("string"),
                            "x-mcp-header": .string("Region"),
                        ]),
                    ]),
                ]),
                "priority": .object([
                    "type": .string("integer"),
                    "x-mcp-header": .string("Priority"),
                ]),
                "dry_run": .object([
                    "type": .string("boolean"),
                    "x-mcp-header": .string("Dry-Run"),
                ]),
            ]),
        ])
        let bindings = try MCP20260728.headerBindings(in: schema)
        let headers = try MCP20260728.parameterHeaders(
            bindings: bindings,
            arguments: [
                "routing": .object(["region": .string("eu-west-1")]),
                "priority": .int(4),
                "dry_run": .bool(true),
            ]
        )

        #expect(bindings.count == 3)
        #expect(headers == [
            "Region": "eu-west-1",
            "Priority": "4",
            "Dry-Run": "true",
        ])
    }

    @Test("annotations behind composition keywords invalidate only that tool")
    func unreachableHeaderAnnotation() {
        let schema = MCP20260728.WireValue.object([
            "type": .string("object"),
            "oneOf": .array([.object([
                "properties": .object([
                    "region": .object([
                        "type": .string("string"),
                        "x-mcp-header": .string("Region"),
                    ]),
                ]),
            ])]),
        ])

        #expect(throws: MCP20260728.HeaderBindingError.invalidPlacement) {
            try MCP20260728.headerBindings(in: schema)
        }
    }

    @Test("header values use the exact base64 sentinel safety rules")
    func headerValueEncoding() {
        let values = [
            "plain": "plain",
            " padded ": "=?base64?IHBhZGRlZCA=?=",
            "line1\nline2": "=?base64?bGluZTEKbGluZTI=?=",
            "=?base64?literal?=": "=?base64?PT9iYXNlNjQ/bGl0ZXJhbD89?=",
        ]
        for (original, expected) in values {
            let encoded = MCP20260728.encodeHeaderValue(original)
            #expect(encoded == expected)
            #expect(MCP20260728.decodeHeaderValue(encoded) == original)
        }
    }
}
