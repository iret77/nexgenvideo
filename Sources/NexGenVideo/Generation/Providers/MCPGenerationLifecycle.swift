import Foundation
import MCP

enum MCPGenerationLifecycle {
    static let maxInlineMediaBytes = 100 * 1024 * 1024
    static let maxInlineMediaBase64Characters =
        ((maxInlineMediaBytes + 2) / 3) * 4

    static func normalizeFieldName(_ value: String) -> String {
        normalize(value)
    }

    struct InlineMedia: Equatable, Hashable, Sendable {
        let data: Data
        let mimeType: String
    }

    enum OutputMedia: Equatable, Hashable, Sendable {
        case remoteURL(String)
        case inline(InlineMedia)
    }

    struct Output: Equatable, Sendable {
        let media: [OutputMedia]

        init(media: [OutputMedia]) {
            self.media = media
        }

        init(urls: [String], inlineMedia: [InlineMedia]) {
            media = urls.map(OutputMedia.remoteURL) + inlineMedia.map(OutputMedia.inline)
        }

        var urls: [String] {
            media.compactMap {
                guard case .remoteURL(let url) = $0 else { return nil }
                return url
            }
        }

        var inlineMedia: [InlineMedia] {
            media.compactMap {
                guard case .inline(let inline) = $0 else { return nil }
                return inline
            }
        }

        var isEmpty: Bool { media.isEmpty }
    }

    struct Submission: Equatable {
        let jobID: String?
        let output: Output

        var outputURLs: [String] { output.urls }
    }

    enum Status: Equatable {
        case pending
        case succeeded(Output)
        case failed(String)
        case unknown(String?)
    }

    static func submission(from payloads: [String]) -> Submission {
        let objects = jsonObjects(payloads)
        return Submission(
            jobID: firstString(
                keys: [
                    "job_set_id", "jobSetId", "job_id", "jobId", "job_handle",
                    "jobHandle", "generation_id", "generationId", "task_id",
                    "taskId",
                ],
                in: objects
            ) ?? nestedJobID(in: objects)
                ?? topLevelString(key: "id", in: objects)
                ?? firstString(keys: ["request_id", "requestId"], in: objects),
            output: output(in: objects)
        )
    }

    static func status(from payloads: [String]) -> Status {
        let objects = jsonObjects(payloads)
        guard let raw = firstString(keys: ["status", "state", "phase"], in: objects) else {
            let output = output(in: objects)
            return output.isEmpty ? .unknown(nil) : .succeeded(output)
        }
        let value = normalize(raw)
        if ["succeeded", "success", "completed", "complete", "ready", "done"].contains(value) {
            return .succeeded(output(in: objects, allowRootURL: true))
        }
        if ["failed", "failure", "error", "cancelled", "canceled", "rejected"].contains(value) {
            let message = firstString(
                keys: ["error_message", "errorMessage", "error", "message", "detail"],
                in: objects
            ) ?? "Provider job failed."
            return .failed(message)
        }
        if ["queued", "waiting", "pending", "running", "processing", "inprogress", "submitted"].contains(value) {
            return .pending
        }
        return .unknown(raw)
    }

    static func resultOutput(from payloads: [String]) -> Output {
        output(in: jsonObjects(payloads), allowRootURL: true)
    }

    static func resultURLs(from payloads: [String]) -> [String] {
        resultOutput(from: payloads).urls
    }

    static func statusTool(
        in tools: [MCPProviderClient.DiscoveredTool]
    ) -> MCPProviderClient.DiscoveredTool? {
        selectTool(
            in: tools,
            exact: ["jobstatus", "generationstatus", "getjobstatus", "taskstatus", "checkjob", "getstatus"],
            required: ["status"],
            context: ["job", "generation", "task"]
        )
    }

    static func resultTool(
        in tools: [MCPProviderClient.DiscoveredTool]
    ) -> MCPProviderClient.DiscoveredTool? {
        selectTool(
            in: tools,
            exact: ["jobdisplay", "jobresult", "generationresult", "getjobresult", "displayjob"],
            required: ["display", "result", "output"],
            context: ["job", "generation", "task"]
        )
    }

    static func cancelTool(
        in tools: [MCPProviderClient.DiscoveredTool]
    ) -> MCPProviderClient.DiscoveredTool? {
        selectTool(
            in: tools,
            exact: [
                "jobcancel", "canceljob", "generationcancel", "cancelgeneration",
                "taskcancel", "canceltask",
            ],
            required: ["cancel"],
            context: ["job", "generation", "task"]
        )
    }

    static func outputSchemaSupportsMedia(_ schema: Value?) -> Bool {
        guard let schema else { return false }
        return schemaSupportsMedia(schema)
    }

    private static func selectTool(
        in tools: [MCPProviderClient.DiscoveredTool],
        exact: Set<String>,
        required: [String],
        context: [String]
    ) -> MCPProviderClient.DiscoveredTool? {
        if let tool = tools.first(where: { exact.contains(normalize($0.name)) }) { return tool }
        return tools.first { tool in
            let haystack = (tool.name + " " + (tool.description ?? "")).lowercased()
            return required.contains(where: haystack.contains)
                && context.contains(where: haystack.contains)
                && !MCPModelDiscovery.isGenerative(name: tool.name, description: tool.description)
        }
    }

    private static func jsonObjects(_ payloads: [String]) -> [Any] {
        payloads.compactMap { payload in
            guard let data = payload.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data)
        }
    }

    private static func firstString(keys: [String], in objects: [Any]) -> String? {
        for key in keys {
            for object in objects {
                if let value = findString(key: key, in: object), !value.isEmpty { return value }
            }
        }
        return nil
    }

    private static func topLevelString(key: String, in objects: [Any]) -> String? {
        for case let object as [String: Any] in objects {
            if let value = object[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    private static func findString(key: String, in value: Any) -> String? {
        if let object = value as? [String: Any] {
            if let found = object[key] as? String { return found }
            for child in object.values {
                if let found = findString(key: key, in: child) { return found }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let found = findString(key: key, in: child) { return found }
            }
        }
        return nil
    }

    private static func nestedJobID(in objects: [Any]) -> String? {
        for object in objects {
            if let found = nestedJobID(in: object) { return found }
        }
        return nil
    }

    private static func nestedJobID(in value: Any) -> String? {
        if let object = value as? [String: Any] {
            for key in ["job_set", "jobSet", "jobs", "job", "request"] {
                if let child = object[key], let id = firstID(in: child) { return id }
            }
            for child in object.values {
                if let id = nestedJobID(in: child) { return id }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let id = nestedJobID(in: child) { return id }
            }
        }
        return nil
    }

    private static func firstID(in value: Any) -> String? {
        if let object = value as? [String: Any] {
            if let id = object["id"] as? String, !id.isEmpty { return id }
            for child in object.values {
                if let id = firstID(in: child) { return id }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let id = firstID(in: child) { return id }
            }
        }
        return nil
    }

    private enum OutputContext: Equatable {
        case root
        case record
        case collection
    }

    private static func output(in objects: [Any], allowRootURL: Bool = false) -> Output {
        var media: [OutputMedia] = []
        var remainingInlineBytes = maxInlineMediaBytes
        let context: OutputContext = allowRootURL ? .record : .root
        for object in objects {
            collectOutputMedia(
                object,
                context: context,
                remainingBytes: &remainingInlineBytes,
                into: &media
            )
        }
        var seen = Set<OutputMedia>()
        return Output(media: media.filter { seen.insert($0).inserted })
    }

    private static func collectOutputMedia(
        _ value: Any,
        context: OutputContext,
        remainingBytes: inout Int,
        into output: inout [OutputMedia]
    ) {
        if let object = value as? [String: Any] {
            let mediaType = (object["type"] as? String)?.lowercased()
            if mediaType == "media_input" { return }
            if let marker = object["_ngv_inline_media"] as? [String: Any],
               let encoded = marker["data"] as? String,
               encoded.utf8.count <= maxInlineMediaBase64Characters,
               let mimeType = marker["mime_type"] as? String,
               (mimeType.lowercased().hasPrefix("image/")
                    || mimeType.lowercased().hasPrefix("audio/")),
               let data = Data(base64Encoded: encoded),
               data.count <= remainingBytes {
                output.append(.inline(InlineMedia(data: data, mimeType: mimeType)))
                remainingBytes -= data.count
                return
            }
            let outputURLKeys = [
                "rawUrl", "raw_url", "outputUrl", "output_url", "resultUrl", "result_url",
                "downloadUrl", "download_url", "resourceUrl", "resource_url",
            ]
            for key in outputURLKeys {
                if let url = object[key] as? String, isHTTPURL(url) {
                    output.append(.remoteURL(url))
                    break
                }
            }
            if context != .root {
                for key in ["url", "uri"] {
                    if let url = object[key] as? String, isHTTPURL(url) {
                        output.append(.remoteURL(url))
                    }
                }
            }
            if let mimeType = (object["mimeType"] ?? object["mime_type"]) as? String,
               ["image/", "video/", "audio/"].contains(where: {
                   mimeType.lowercased().hasPrefix($0)
                }) {
                for key in ["uri", "url"] {
                    if let url = object[key] as? String, isHTTPURL(url) {
                        output.append(.remoteURL(url))
                    }
                }
            }
            for key in ["raw", "result", "output"] {
                if let child = object[key] {
                    collectOutputMedia(
                        child,
                        context: .record,
                        remainingBytes: &remainingBytes,
                        into: &output
                    )
                }
            }
            for key in ["results", "outputs", "files", "images", "videos", "audios"] {
                if let child = object[key] {
                    collectOutputMedia(
                        child,
                        context: .collection,
                        remainingBytes: &remainingBytes,
                        into: &output
                    )
                }
            }
            for key in ["data", "job_set", "jobSet", "jobs"] {
                if let child = object[key] {
                    collectOutputMedia(
                        child,
                        context: .record,
                        remainingBytes: &remainingBytes,
                        into: &output
                    )
                }
            }
        } else if let array = value as? [Any] {
            for child in array {
                collectOutputMedia(
                    child,
                    context: context,
                    remainingBytes: &remainingBytes,
                    into: &output
                )
            }
        } else if context != .root, let string = value as? String, isHTTPURL(string) {
            output.append(.remoteURL(string))
        }
    }

    private static func isHTTPURL(_ value: String) -> Bool {
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "https" || scheme == "http"
    }

    private static func schemaSupportsMedia(_ value: Value) -> Bool {
        switch value {
        case .object(let object):
            if case .object(let properties)? = object["properties"] {
                let names = Set(properties.keys.map(normalize))
                if !names.isDisjoint(with: ["data", "blob"]),
                   !names.isDisjoint(with: ["mimetype", "contenttype"]) {
                    return true
                }
                for (name, child) in properties {
                    let normalized = normalize(name)
                    if [
                        "url", "uri", "rawurl", "outputurl", "resulturl",
                        "downloadurl", "resourceurl",
                    ].contains(normalized), schemaAllowsString(child) {
                        return true
                    }
                    if [
                        "image", "images", "video", "videos", "audio", "audios",
                        "file", "files", "media", "result", "results", "output", "outputs",
                    ].contains(normalized), schemaSupportsMedia(child) {
                        return true
                    }
                }
            }
            return object.values.contains(where: schemaSupportsMedia)
        case .array(let values):
            return values.contains(where: schemaSupportsMedia)
        default:
            return false
        }
    }

    private static func schemaAllowsString(_ value: Value) -> Bool {
        guard case .object(let object) = value else { return false }
        if case .string(let type)? = object["type"], type == "string" { return true }
        for key in ["oneOf", "anyOf", "allOf"] {
            if case .array(let alternatives)? = object[key],
               alternatives.contains(where: schemaAllowsString) {
                return true
            }
        }
        return false
    }

    private static func normalize(_ value: String) -> String {
        value.lowercased().filter(\.isLetter)
    }
}
