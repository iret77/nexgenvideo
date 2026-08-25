import Foundation

enum MCPGenerationLifecycle {
    struct Submission: Equatable {
        let jobID: String?
        let outputURLs: [String]
    }

    enum Status: Equatable {
        case pending
        case succeeded([String])
        case failed(String)
        case unknown(String?)
    }

    static func submission(from payloads: [String]) -> Submission {
        let objects = jsonObjects(payloads)
        return Submission(
            jobID: firstString(
                keys: ["job_id", "jobId", "generation_id", "generationId", "task_id", "taskId"],
                in: objects
            ) ?? nestedJobID(in: objects) ?? topLevelString(key: "id", in: objects),
            outputURLs: outputURLs(in: objects)
        )
    }

    static func status(from payloads: [String]) -> Status {
        let objects = jsonObjects(payloads)
        guard let raw = firstString(keys: ["status", "state", "phase"], in: objects) else {
            let urls = outputURLs(in: objects)
            return urls.isEmpty ? .unknown(nil) : .succeeded(urls)
        }
        let value = normalize(raw)
        if ["succeeded", "success", "completed", "complete", "ready", "done"].contains(value) {
            return .succeeded(outputURLs(in: objects, allowRootURL: true))
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

    static func resultURLs(from payloads: [String]) -> [String] {
        outputURLs(in: jsonObjects(payloads), allowRootURL: true)
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
            for key in ["jobs", "job"] {
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

    private static func outputURLs(in objects: [Any], allowRootURL: Bool = false) -> [String] {
        var urls: [String] = []
        let context: OutputContext = allowRootURL ? .record : .root
        for object in objects { collectOutputURLs(object, context: context, into: &urls) }
        var seen = Set<String>()
        return urls.filter { seen.insert($0).inserted }
    }

    private static func collectOutputURLs(
        _ value: Any,
        context: OutputContext,
        into urls: inout [String]
    ) {
        if let object = value as? [String: Any] {
            let mediaType = (object["type"] as? String)?.lowercased()
            if mediaType == "media_input" { return }
            let outputURLKeys = [
                "rawUrl", "raw_url", "outputUrl", "output_url", "resultUrl", "result_url",
                "downloadUrl", "download_url", "resourceUrl", "resource_url",
            ]
            for key in outputURLKeys {
                if let url = object[key] as? String, isHTTPURL(url) {
                    urls.append(url)
                    break
                }
            }
            if context != .root {
                for key in ["url", "uri"] {
                    if let url = object[key] as? String, isHTTPURL(url) { urls.append(url) }
                }
            }
            if let mimeType = (object["mimeType"] ?? object["mime_type"]) as? String,
               ["image/", "video/", "audio/"].contains(where: {
                   mimeType.lowercased().hasPrefix($0)
               }) {
                for key in ["uri", "url"] {
                    if let url = object[key] as? String, isHTTPURL(url) { urls.append(url) }
                }
            }
            for key in ["raw", "result", "output"] {
                if let child = object[key] {
                    collectOutputURLs(child, context: .record, into: &urls)
                }
            }
            for key in ["results", "outputs", "files", "images", "videos", "audios"] {
                if let child = object[key] {
                    collectOutputURLs(child, context: .collection, into: &urls)
                }
            }
        } else if let array = value as? [Any] {
            for child in array { collectOutputURLs(child, context: context, into: &urls) }
        } else if context != .root, let string = value as? String, isHTTPURL(string) {
            urls.append(string)
        }
    }

    private static func isHTTPURL(_ value: String) -> Bool {
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "https" || scheme == "http"
    }

    private static func normalize(_ value: String) -> String {
        value.lowercased().filter(\.isLetter)
    }
}
