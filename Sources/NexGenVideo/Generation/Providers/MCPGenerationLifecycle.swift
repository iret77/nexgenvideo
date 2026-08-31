import Foundation
import MCP

enum MCPGenerationLifecycle {
    static let maxInlineMediaBytes = 100 * 1024 * 1024
    static let maxInlineMediaBase64Characters =
        ((maxInlineMediaBytes + 2) / 3) * 4

    private static let inlineDataFieldNames = ["data", "blob"]
    private static let inlineMIMEFieldNames = [
        "mimeType", "mime_type", "contentType", "content_type",
    ]
    private static let directOutputURLFieldNames = [
        "rawUrl", "raw_url", "outputUrl", "output_url", "resultUrl", "result_url",
        "downloadUrl", "download_url", "resourceUrl", "resource_url",
    ]
    private static let genericOutputURLFieldNames = ["url", "uri"]
    private static let outputEnvelopeFieldNames: Set<String> = [
        "audio", "audios", "data", "file", "files", "image", "images", "job", "jobs",
        "jobset", "jobsets", "media", "medias", "output", "outputs", "payload",
        "payloads", "raw", "resource", "resources", "result", "results", "video",
        "videos",
    ]
    private static let excludedOutputTokens = [
        "argument", "input", "parameter", "params", "prompt", "reference", "request",
        "source", "thumbnail",
    ]

    static func isOutputEnvelopeFieldName(_ value: String) -> Bool {
        outputEnvelopeFieldNames.contains(normalize(value))
            && !isExcludedOutputFieldName(value)
    }

    static func isExcludedOutputFieldName(_ value: String) -> Bool {
        let normalized = normalize(value)
        let tokens = semanticTokens(value)
        return excludedOutputTokens.contains { excluded in
            tokens.contains(excluded) || normalized.hasPrefix(excluded)
        }
    }

    static func inlineMediaStrings(
        in object: [String: Any]
    ) -> (data: String, mimeType: String)? {
        guard let data = firstDeclaredValue(
            in: object,
            fieldNames: inlineDataFieldNames
        ) as? String,
        let mimeType = firstDeclaredValue(
            in: object,
            fieldNames: inlineMIMEFieldNames
        ) as? String else {
            return nil
        }
        return (data, mimeType)
    }

    static func isSupportedInlineMIMEType(_ value: String) -> Bool {
        let normalized = value.lowercased()
        return normalized.hasPrefix("image/") || normalized.hasPrefix("audio/")
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

    static func submission(
        from payloads: [String],
        allowRootURL: Bool = false
    ) -> Submission {
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
            output: output(in: objects, allowRootURL: allowRootURL)
        )
    }

    static func status(
        from payloads: [String],
        allowRootURL: Bool = false
    ) -> Status {
        let objects = jsonObjects(payloads)
        guard let raw = firstString(keys: ["status", "state", "phase"], in: objects) else {
            let output = output(in: objects, allowRootURL: allowRootURL)
            return output.isEmpty ? .unknown(nil) : .succeeded(output)
        }
        let value = normalize(raw)
        if ["succeeded", "success", "completed", "complete", "ready", "done"].contains(value) {
            return .succeeded(output(in: objects, allowRootURL: allowRootURL))
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

    static func outputSchemaAllowsRootURL(_ schema: Value?) -> Bool {
        guard let schema else { return false }
        return schemaAllowsRootURL(schema)
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
            if let mediaType = object["type"] as? String,
               isExcludedOutputFieldName(mediaType) {
                return
            }
            if let marker = object["_ngv_inline_media"] as? [String: Any],
               let encoded = marker["data"] as? String,
               encoded.utf8.count <= maxInlineMediaBase64Characters,
               let mimeType = marker["mime_type"] as? String,
               isSupportedInlineMIMEType(mimeType),
               let data = Data(base64Encoded: encoded),
               data.count <= remainingBytes {
                output.append(.inline(InlineMedia(data: data, mimeType: mimeType)))
                remainingBytes -= data.count
                return
            }
            for key in directOutputURLFieldNames {
                if let url = object[key] as? String, isHTTPURL(url) {
                    output.append(.remoteURL(url))
                    break
                }
            }
            if context != .root {
                for key in genericOutputURLFieldNames {
                    if let url = object[key] as? String, isHTTPURL(url) {
                        output.append(.remoteURL(url))
                    }
                }
            }
            if let mimeType = (object["mimeType"] ?? object["mime_type"]) as? String,
               ["image/", "video/", "audio/"].contains(where: {
                   mimeType.lowercased().hasPrefix($0)
                }) {
                for key in genericOutputURLFieldNames {
                    if let url = object[key] as? String, isHTTPURL(url) {
                        output.append(.remoteURL(url))
                    }
                }
            }
            let declaresInlineMediaShape = object.keys.contains(
                where: resemblesInlineDataFieldName
            ) && object.keys.contains(
                where: resemblesInlineMIMEFieldName
            )
            for key in object.keys.sorted() where isOutputEnvelopeFieldName(key) {
                guard let child = object[key] else { continue }
                if declaresInlineMediaShape,
                   resemblesInlineDataFieldName(key),
                   child is String {
                    continue
                }
                collectOutputMedia(
                    child,
                    context: .record,
                    remainingBytes: &remainingBytes,
                    into: &output
                )
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

    private enum OutputSchemaContext {
        case root
        case envelope
        case structuredEnvelope
    }

    private static func schemaSupportsMedia(
        _ value: Value,
        context: OutputSchemaContext = .root
    ) -> Bool {
        if context == .envelope, schemaAllowsHTTPURL(value) { return true }
        switch value {
        case .object(let object):
            let properties: [String: Value]? = if case .object(let properties)? = object["properties"] {
                properties
            } else {
                nil
            }
            if properties.map(schemaDeclaresExcludedOutputType) == true { return false }
            for key in ["oneOf", "anyOf", "allOf"] {
                if case .array(let alternatives)? = object[key],
                   alternatives.contains(where: {
                       schemaSupportsMedia($0, context: context)
                   }) {
                    return true
                }
            }
            if let items = object["items"],
               schemaSupportsMedia(
                   items,
                   context: context == .structuredEnvelope ? .envelope : context
               ) {
                return true
            }
            if let properties {
                if schemaSupportsInlineMedia(properties) {
                    return true
                }
                let declaresInlineMediaShape = properties.keys.contains(
                    where: resemblesInlineDataFieldName
                ) && properties.keys.contains(
                    where: resemblesInlineMIMEFieldName
                )
                for name in directOutputURLFieldNames + genericOutputURLFieldNames {
                    if let child = properties[name], schemaAllowsHTTPURL(child) {
                        return true
                    }
                }
                for (name, child) in properties where isOutputEnvelopeFieldName(name) {
                    if declaresInlineMediaShape, resemblesInlineDataFieldName(name) {
                        if schemaSupportsMedia(child, context: .structuredEnvelope) {
                            return true
                        }
                        continue
                    }
                    if schemaSupportsMedia(child, context: .envelope) {
                        return true
                    }
                }
            }
            return false
        case .array(let values):
            return values.contains(where: {
                schemaSupportsMedia($0, context: context)
            })
        default:
            return false
        }
    }

    private static func schemaSupportsInlineMedia(
        _ properties: [String: Value]
    ) -> Bool {
        guard let dataSchema = firstDeclaredValue(
            in: properties,
            fieldNames: inlineDataFieldNames
        ), schemaAllowsString(dataSchema),
        let mimeSchema = firstDeclaredValue(
            in: properties,
            fieldNames: inlineMIMEFieldNames
        ), schemaAllowsSupportedInlineMIMEType(mimeSchema) else {
            return false
        }
        return true
    }

    private static func resemblesInlineDataFieldName(_ value: String) -> Bool {
        inlineDataFieldNames.contains { normalize($0) == normalize(value) }
    }

    private static func resemblesInlineMIMEFieldName(_ value: String) -> Bool {
        inlineMIMEFieldNames.contains { normalize($0) == normalize(value) }
    }

    private static func schemaDeclaresExcludedOutputType(
        _ properties: [String: Value]
    ) -> Bool {
        guard let typeSchema = properties["type"],
              let values = explicitStringValues(in: typeSchema),
              !values.isEmpty else {
            return false
        }
        return values.allSatisfy(isExcludedOutputFieldName)
    }

    private static func explicitStringValues(in value: Value) -> [String]? {
        guard case .object(let object) = value else { return nil }
        if case .string(let constant)? = object["const"] { return [constant] }
        if case .array(let enumeration)? = object["enum"] {
            return enumeration.compactMap { value in
                guard case .string(let string) = value else { return nil }
                return string
            }
        }
        return nil
    }

    private static func schemaAllowsRootURL(_ value: Value) -> Bool {
        guard case .object(let object) = value else {
            if case .array(let values) = value {
                return values.contains(where: schemaAllowsRootURL)
            }
            return false
        }
        for key in ["oneOf", "anyOf", "allOf"] {
            if case .array(let alternatives)? = object[key],
               alternatives.contains(where: schemaAllowsRootURL) {
                return true
            }
        }
        if let items = object["items"], schemaAllowsRootURL(items) {
            return true
        }
        guard case .object(let properties)? = object["properties"] else { return false }
        return genericOutputURLFieldNames.contains { key in
            properties[key].map(schemaAllowsHTTPURL) == true
        }
    }

    private static func schemaAllowsString(_ value: Value) -> Bool {
        guard case .object(let object) = value else { return false }
        let provesString = schemaTypeAllowsString(object["type"])
            || object["const"].map(isStringValue) == true
            || enumContainsString(object["enum"])
            || ["oneOf", "anyOf", "allOf"].contains { key in
                guard case .array(let alternatives)? = object[key] else { return false }
                return alternatives.contains(where: schemaAllowsString)
            }
        guard provesString else { return false }
        return !schemaRejectsString(value)
    }

    private static func schemaAllowsSupportedInlineMIMEType(_ value: Value) -> Bool {
        schemaAllowsString(value) && !schemaRejectsAcceptedString(
            value,
            accepted: isSupportedInlineMIMEType
        )
    }

    private static func schemaAllowsHTTPURL(_ value: Value) -> Bool {
        schemaAllowsString(value) && !schemaRejectsAcceptedString(
            value,
            accepted: isHTTPURL
        )
    }

    private static func schemaRejectsString(_ value: Value) -> Bool {
        guard case .object(let object) = value else { return true }
        if let type = object["type"], !schemaTypeAllowsString(type) { return true }
        if let constant = object["const"], !isStringValue(constant) { return true }
        if let enumeration = object["enum"], !enumContainsString(enumeration) { return true }
        for key in ["oneOf", "anyOf"] {
            if case .array(let alternatives)? = object[key],
               !alternatives.isEmpty,
               alternatives.allSatisfy(schemaRejectsString) {
                return true
            }
        }
        if case .array(let constraints)? = object["allOf"],
           constraints.contains(where: schemaRejectsString) {
            return true
        }
        return false
    }

    private static func schemaRejectsAcceptedString(
        _ value: Value,
        accepted: (String) -> Bool
    ) -> Bool {
        guard case .object(let object) = value else { return true }
        if let constant = object["const"] {
            return !isAcceptedStringValue(constant, accepted: accepted)
        }
        if let enumeration = object["enum"] {
            guard case .array(let values) = enumeration else { return true }
            return !values.contains {
                isAcceptedStringValue($0, accepted: accepted)
            }
        }
        for key in ["oneOf", "anyOf"] {
            if case .array(let alternatives)? = object[key],
               !alternatives.isEmpty,
               alternatives.allSatisfy({
                   schemaRejectsAcceptedString($0, accepted: accepted)
               }) {
                return true
            }
        }
        if case .array(let constraints)? = object["allOf"],
           constraints.contains(where: {
               schemaRejectsAcceptedString($0, accepted: accepted)
           }) {
            return true
        }
        return false
    }

    private static func schemaTypeAllowsString(_ value: Value?) -> Bool {
        guard let value else { return false }
        if case .string(let type) = value { return type == "string" }
        guard case .array(let types) = value else { return false }
        return types.contains { type in
            if case .string("string") = type { return true }
            return false
        }
    }

    private static func enumContainsString(_ value: Value?) -> Bool {
        guard case .array(let values)? = value else { return false }
        return values.contains(where: isStringValue)
    }

    private static func isStringValue(_ value: Value) -> Bool {
        if case .string = value { return true }
        return false
    }

    private static func isAcceptedStringValue(
        _ value: Value,
        accepted: (String) -> Bool
    ) -> Bool {
        guard case .string(let string) = value else { return false }
        return accepted(string)
    }

    private static func firstDeclaredValue<ValueType>(
        in object: [String: ValueType],
        fieldNames: [String]
    ) -> ValueType? {
        for fieldName in fieldNames {
            if let value = object[fieldName] { return value }
        }
        return nil
    }

    private static func normalize(_ value: String) -> String {
        value.lowercased().filter(\.isLetter)
    }

    private static func semanticTokens(_ value: String) -> Set<String> {
        var tokens = Set<String>()
        var current = ""
        var previousWasLowercase = false
        func finishToken() {
            if !current.isEmpty { tokens.insert(current) }
            current = ""
            previousWasLowercase = false
        }
        for character in value {
            guard character.isLetter else {
                finishToken()
                continue
            }
            if character.isUppercase, previousWasLowercase { finishToken() }
            current.append(contentsOf: character.lowercased())
            previousWasLowercase = character.isLowercase
        }
        finishToken()
        return tokens
    }
}
