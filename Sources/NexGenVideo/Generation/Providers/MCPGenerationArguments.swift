import Foundation
import MCP

enum MCPGenerationArguments {
    private static let synchronousCompletionFields = Set([
        "block", "blocking", "sync", "syncmode", "synchronous",
        "wait", "waitforcompletion",
    ])

    enum MappingError: LocalizedError, Equatable {
        case unsupportedRequiredFields([String])
        case unsupportedMediaRoles([String])
        case tooManyMedia(field: String, count: Int)
        case incompatibleField(String)
        case missingPrompt
        case missingModel
        case missingJobID
        case missingMediaID
        case missingFilename

        var errorDescription: String? {
            switch self {
            case .unsupportedRequiredFields(let fields):
                return "Required fields cannot be mapped: \(fields.joined(separator: ", "))."
            case .unsupportedMediaRoles(let roles):
                return "Media roles cannot be mapped without dropping inputs: \(roles.joined(separator: ", "))."
            case .tooManyMedia(let field, let count):
                return "Field '\(field)' accepts one media input but the request contains \(count)."
            case .incompatibleField(let field):
                return "Field '\(field)' has an incompatible schema."
            case .missingPrompt:
                return "The generation tool has no usable prompt field."
            case .missingModel:
                return "The generation tool has no usable model field."
            case .missingJobID:
                return "The job tool has no usable job identifier field."
            case .missingMediaID:
                return "The media tool has no usable media identifier field."
            case .missingFilename:
                return "The media upload tool has no usable filename field."
            }
        }
    }

    private enum Mode: Equatable {
        case generation
        case job
        case mediaUpload
        case mediaConfirm
    }

    private struct MediaInput {
        let key: String
        let locator: String
        let role: String
        let mediaType: String
    }

    static func make(
        for params: BackendGenerationParams,
        model: String?,
        schema: Value,
        mediaRoles: [String]? = nil,
        requestID: String? = nil
    ) throws -> [String: Value] {
        let input = values(
            for: params,
            model: model,
            mediaRoles: Set((mediaRoles ?? []).map { $0.lowercased() }),
            requestID: requestID
        )
        let result = try map(
            candidates: input.candidates,
            media: input.media,
            schema: schema,
            mode: .generation
        )
        if input.candidates["prompt"] != nil, !result.mappedNames.contains("prompt") {
            throw MappingError.missingPrompt
        }
        if model?.isEmpty == false, !result.mappedNames.contains("model") {
            throw MappingError.missingModel
        }
        let missingMedia = input.media.filter { !result.mappedMedia.contains($0.key) }
        if !missingMedia.isEmpty {
            throw MappingError.unsupportedMediaRoles(Array(Set(missingMedia.map(\.role))).sorted())
        }
        return result.arguments
    }

    static func makeJob(jobID: String, schema: Value, sync: Bool? = nil) throws -> [String: Value] {
        var candidates: [String: Value] = [
            "jobid": .string(jobID),
            "jobids": .array([.string(jobID)]),
        ]
        if let sync { candidates["sync"] = .bool(sync) }
        let result = try map(candidates: candidates, media: [], schema: schema, mode: .job)
        guard result.mappedNames.contains("jobid") || result.mappedNames.contains("jobids") else {
            throw MappingError.missingJobID
        }
        return result.arguments
    }

    static func makeMediaUpload(
        filename: String,
        mimeType: String,
        mediaType: String,
        fileSize: Int,
        schema: Value
    ) throws -> [String: Value] {
        let result = try map(
            candidates: [
                "filename": .string(filename),
                "mimetype": .string(mimeType),
                "mediatype": .string(mediaType),
                "filesize": .int(fileSize),
            ],
            media: [],
            schema: schema,
            mode: .mediaUpload
        )
        guard result.mappedNames.contains("filename") else {
            throw MappingError.missingFilename
        }
        return result.arguments
    }

    static func makeMediaConfirm(
        mediaID: String,
        filename: String,
        mediaType: String,
        schema: Value
    ) throws -> [String: Value] {
        let result = try map(
            candidates: [
                "mediaid": .string(mediaID),
                "filename": .string(filename),
                "mediatype": .string(mediaType),
            ],
            media: [],
            schema: schema,
            mode: .mediaConfirm
        )
        guard result.mappedNames.contains("mediaid") else {
            throw MappingError.missingMediaID
        }
        return result.arguments
    }

    private static func map(
        candidates: [String: Value],
        media: [MediaInput],
        schema: Value,
        mode: Mode
    ) throws -> (arguments: [String: Value], mappedNames: Set<String>, mappedMedia: Set<String>) {
        if let object = schemaObject(schema), let alternatives = schemaAlternatives(object) {
            var firstResult: (
                arguments: [String: Value], mappedNames: Set<String>, mappedMedia: Set<String>
            )?
            var firstError: Error?
            for alternative in alternatives {
                do {
                    let result = try map(
                        candidates: candidates,
                        media: media,
                        schema: alternative,
                        mode: mode
                    )
                    if mappingIsComplete(result, candidates: candidates, media: media, mode: mode) {
                        return result
                    }
                    if firstResult == nil { firstResult = result }
                } catch {
                    if firstError == nil { firstError = error }
                }
            }
            if let firstResult { return firstResult }
            if let firstError { throw firstError }
        }
        guard let root = schemaObject(schema), let properties = schemaProperties(root), !properties.isEmpty else {
            guard mode == .generation else {
                throw MappingError.unsupportedRequiredFields(["<tool schema>"])
            }
            var fallback: [String: Value] = [:]
            if let prompt = candidates["prompt"] { fallback["prompt"] = prompt }
            if let model = candidates["model"] { fallback["model"] = model }
            let names = Set(fallback.keys)
            return (fallback, names, [])
        }

        var mappedNames = Set<String>()
        var mappedMedia = Set<String>()
        let arguments = try mapObject(
            root,
            candidates: candidates,
            media: media,
            path: "",
            mode: mode,
            mappedNames: &mappedNames,
            mappedMedia: &mappedMedia
        )
        return (arguments, mappedNames, mappedMedia)
    }

    private static func mappingIsComplete(
        _ result: (arguments: [String: Value], mappedNames: Set<String>, mappedMedia: Set<String>),
        candidates: [String: Value],
        media: [MediaInput],
        mode: Mode
    ) -> Bool {
        switch mode {
        case .generation:
            let prompt = candidates["prompt"] == nil || result.mappedNames.contains("prompt")
            let model = candidates["model"] == nil || result.mappedNames.contains("model")
            return prompt && model && result.mappedMedia.count == media.count
        case .job:
            return result.mappedNames.contains("jobid") || result.mappedNames.contains("jobids")
        case .mediaUpload:
            return result.mappedNames.contains("filename")
        case .mediaConfirm:
            return result.mappedNames.contains("mediaid")
        }
    }

    private static func mapObject(
        _ schema: [String: Value],
        candidates: [String: Value],
        media: [MediaInput],
        path: String,
        mode: Mode,
        mappedNames: inout Set<String>,
        mappedMedia: inout Set<String>
    ) throws -> [String: Value] {
        guard let properties = schemaProperties(schema) else { return [:] }
        var result: [String: Value] = [:]
        let required = Set(requiredFields(schema))
        let fields = properties.keys.sorted {
            let left = (required.contains($0) ? 0 : 1, fieldPriority(normalize($0)))
            let right = (required.contains($1) ? 0 : 1, fieldPriority(normalize($1)))
            if left.0 != right.0 { return left.0 < right.0 }
            if left.1 != right.1 { return left.1 < right.1 }
            return $0 < $1
        }

        for field in fields {
            guard let fieldSchema = properties[field] else { continue }
            let normalized = normalize(field)
            let remainingMedia = media.filter { !mappedMedia.contains($0.key) }
            if isAggregateMediaField(normalized), !remainingMedia.isEmpty {
                result[field] = try aggregateMediaValue(
                    remainingMedia, field: normalized, schema: fieldSchema, path: path + field
                )
                mappedMedia.formUnion(remainingMedia.map(\.key))
                continue
            }
            if let selected = directMedia(for: normalized, from: remainingMedia), !selected.isEmpty {
                result[field] = try directMediaValue(
                    selected, schema: fieldSchema, path: path + field
                )
                mappedMedia.formUnion(selected.map(\.key))
                continue
            }
            if let candidateName = candidateNames(for: normalized, mode: mode)
                .first(where: { candidates[$0] != nil && !mappedNames.contains($0) }),
               let value = candidates[candidateName] {
                result[field] = try coerce(value, for: fieldSchema, path: path + field)
                mappedNames.insert(candidateName)
                continue
            }
            if required.contains(field), let fixed = fixedSchemaValue(fieldSchema) {
                result[field] = fixed
                continue
            }
            if let child = schemaObject(fieldSchema), schemaProperties(child) != nil {
                let nested = try mapObject(
                    child,
                    candidates: candidates,
                    media: media.filter { !mappedMedia.contains($0.key) },
                    path: path + field + ".",
                    mode: mode,
                    mappedNames: &mappedNames,
                    mappedMedia: &mappedMedia
                )
                if !nested.isEmpty { result[field] = .object(nested) }
            }
        }

        let missing = requiredFields(schema).filter { result[$0] == nil }.map { path + $0 }
        if !missing.isEmpty { throw MappingError.unsupportedRequiredFields(missing.sorted()) }
        return result
    }

    private static func values(
        for params: BackendGenerationParams,
        model: String?,
        mediaRoles: Set<String>,
        requestID: String?
    ) -> (candidates: [String: Value], media: [MediaInput]) {
        var values: [String: Value] = [:]
        var media: [MediaInput] = []
        if let model, !model.isEmpty { values["model"] = .string(model) }
        if let requestID, !requestID.isEmpty { values["requestid"] = .string(requestID) }
        values["sync"] = .bool(true)

        func role(_ preferred: [String], fallback: String) -> String {
            if let match = preferred.first(where: mediaRoles.contains) { return match }
            if mediaRoles.count == 1, let only = mediaRoles.first { return only }
            return fallback
        }
        func append(_ locators: [String], role: String, mediaType: String, group: String) {
            for (index, locator) in locators.enumerated() where !locator.isEmpty {
                media.append(MediaInput(
                    key: "\(group):\(index)", locator: locator,
                    role: role, mediaType: mediaType
                ))
            }
        }

        switch params {
        case .image(let value):
            values["prompt"] = .string(value.prompt)
            if !value.aspectRatio.isEmpty { values["aspectratio"] = .string(value.aspectRatio) }
            if let resolution = value.resolution { values["resolution"] = .string(resolution) }
            if let quality = value.quality { values["quality"] = .string(quality) }
            values["numimages"] = .int(value.numImages)
            append(
                value.imageURLs,
                role: role(["image", "image_references"], fallback: "image"),
                mediaType: "image",
                group: "image"
            )
        case .video(let value):
            values["prompt"] = .string(value.prompt)
            switch value.duration {
            case .seconds(let duration): values["duration"] = .int(duration)
            case .automatic: values["duration"] = .string("auto")
            }
            if !value.aspectRatio.isEmpty { values["aspectratio"] = .string(value.aspectRatio) }
            if let resolution = value.resolution { values["resolution"] = .string(resolution) }
            values["generateaudio"] = .bool(value.generateAudio)
            append(
                value.sourceVideoURL.map { [$0] } ?? [],
                role: role(["video", "video_references"], fallback: "video"),
                mediaType: "video",
                group: "sourcevideo"
            )
            append(
                value.startFrameURL.map { [$0] } ?? [],
                role: role(["start_image", "image"], fallback: "start_image"),
                mediaType: "image",
                group: "startimage"
            )
            append(
                value.endFrameURL.map { [$0] } ?? [],
                role: role(["end_image", "image"], fallback: "end_image"),
                mediaType: "image",
                group: "endimage"
            )
            append(
                value.referenceImageURLs,
                role: role(["image", "image_references"], fallback: "image"),
                mediaType: "image",
                group: "referenceimage"
            )
            append(
                value.referenceVideoURLs,
                role: role(["video", "video_references"], fallback: "video"),
                mediaType: "video",
                group: "referencevideo"
            )
            append(
                value.referenceAudioURLs,
                role: role(["audio", "audio_references"], fallback: "audio"),
                mediaType: "audio",
                group: "referenceaudio"
            )
        case .audio(let value):
            values["prompt"] = .string(value.prompt)
            if let voice = value.voice { values["voice"] = .string(voice) }
            if let lyrics = value.lyrics { values["lyrics"] = .string(lyrics) }
            if let style = value.styleInstructions { values["styleinstructions"] = .string(style) }
            values["instrumental"] = .bool(value.instrumental)
            if let duration = value.durationSeconds { values["durationseconds"] = .int(duration) }
            append(
                value.videoURL.map { [$0] } ?? [],
                role: role(["video", "video_references"], fallback: "video"),
                mediaType: "video",
                group: "video"
            )
        case .upscale(let value):
            values["sourceurl"] = .string(value.sourceURL)
            values["durationseconds"] = .int(value.durationSeconds)
        }
        return (values, media)
    }

    private static func candidateNames(for field: String, mode: Mode) -> [String] {
        switch mode {
        case .generation:
            switch field {
            case "prompt", "textprompt", "text", "description": ["prompt"]
            case "model", "modelid", "jobsettype": ["model"]
            case "aspectratio": ["aspectratio"]
            case "resolution": ["resolution"]
            case "quality", "mode": ["quality"]
            case "numimages", "numberofimages", "imagecount", "imagescount", "count", "batchsize": ["numimages"]
            case "duration": ["duration", "durationseconds"]
            case "generateaudio": ["generateaudio"]
            case "voice", "voicename": ["voice"]
            case "lyrics": ["lyrics"]
            case "styleinstructions": ["styleinstructions"]
            case "instrumental": ["instrumental"]
            case "durationseconds": ["durationseconds", "duration"]
            case "sourceurl": ["sourceurl"]
            case "requestid", "clientrequestid", "idempotencykey": ["requestid"]
            case "block", "blocking", "sync", "syncmode", "synchronous",
                 "wait", "waitforcompletion": ["sync"]
            default: []
            }
        case .job:
            switch field {
            case "handle", "id", "jobhandle", "jobid", "jobsetid",
                 "generationid", "taskid", "requestid": ["jobid"]
            case "handles", "ids", "jobhandles", "jobids", "jobsetids",
                 "generationids", "taskids", "requestids": ["jobids"]
            case "sync", "wait", "block": ["sync"]
            default: []
            }
        case .mediaUpload:
            switch field {
            case "filename", "name": ["filename"]
            case "mimetype", "contenttype": ["mimetype"]
            case "mediatype", "type": ["mediatype", "mimetype"]
            case "filesize", "size", "length", "contentlength": ["filesize"]
            default: []
            }
        case .mediaConfirm:
            switch field {
            case "id", "mediaid", "pendingid", "uploadid": ["mediaid"]
            case "filename", "name": ["filename"]
            case "mediatype", "type": ["mediatype"]
            default: []
            }
        }
    }

    private static func directMedia(for field: String, from media: [MediaInput]) -> [MediaInput]? {
        let roles: Set<String>
        switch field {
        case "image", "imageurl", "inputimage", "referenceimage",
             "images", "imageurls", "inputimages", "inputimageurls",
             "imagereferences", "referenceimages", "referenceimageurls":
            roles = ["image", "image_references"]
        case "startimage", "startimageurl", "startframe", "startframeurl":
            roles = ["start_image"]
        case "endimage", "endimageurl", "endframe", "endframeurl":
            roles = ["end_image"]
        case "video", "videourl", "videos", "videourls", "videoreferences", "referencevideourls":
            roles = ["video", "video_references"]
        case "audio", "audiourl", "audios", "audiourls", "audioreferences", "referenceaudiourls":
            roles = ["audio", "audio_references"]
        default:
            return nil
        }
        return media.filter { roles.contains($0.role) }
    }

    private static func directMediaValue(
        _ media: [MediaInput],
        schema: Value,
        path: String
    ) throws -> Value {
        let isArray = schemaAcceptsArray(schema)
        if !isArray, media.count > 1 {
            throw MappingError.tooManyMedia(field: path, count: media.count)
        }
        let raw: Value = isArray
            ? .array(media.map { .string($0.locator) })
            : .string(media[0].locator)
        return try coerce(raw, for: schema, path: path)
    }

    private static func aggregateMediaValue(
        _ media: [MediaInput],
        field: String,
        schema: Value,
        path: String
    ) throws -> Value {
        guard let schemaDictionary = schemaObject(schema) else {
            return .array(media.map { mediaEntry($0, locatorKey: field == "inputfiles" ? "id" : "value") })
        }
        if !schemaAcceptsArray(schema) {
            guard media.count == 1 else {
                throw MappingError.tooManyMedia(field: path, count: media.count)
            }
            return try mediaObjectValue(
                media[0], schema: schema,
                locatorKey: field == "inputfiles" ? "id" : "value",
                path: path
            )
        }
        let itemSchema = schemaDictionary["items"]
        let values = try media.enumerated().map { index, input in
            guard let itemSchema else {
                return mediaEntry(input, locatorKey: field == "inputfiles" ? "id" : "value")
            }
            return try mediaObjectValue(
                input, schema: itemSchema,
                locatorKey: field == "inputfiles" ? "id" : "value",
                path: "\(path)[\(index)]"
            )
        }
        return try coerce(.array(values), for: schema, path: path)
    }

    private static func mediaObjectValue(
        _ input: MediaInput,
        schema: Value,
        locatorKey: String,
        path: String
    ) throws -> Value {
        guard let object = schemaObject(schema),
              let properties = schemaProperties(object), !properties.isEmpty else {
            if case .string("string")? = schemaObject(schema)?["type"] {
                return try coerce(.string(input.locator), for: schema, path: path)
            }
            return try coerce(mediaEntry(input, locatorKey: locatorKey), for: schema, path: path)
        }
        var entry: [String: Value] = [:]
        for (name, propertySchema) in properties {
            switch normalize(name) {
            case "role":
                entry[name] = try coerce(.string(input.role), for: propertySchema, path: path + "." + name)
            case "type", "mediatype":
                entry[name] = try coerce(
                    .string(input.mediaType), for: propertySchema, path: path + "." + name
                )
            case "value", "id", "mediaid", "url", "uri":
                entry[name] = try coerce(
                    .string(input.locator), for: propertySchema, path: path + "." + name
                )
            case "data":
                entry[name] = try mediaData(input, schema: propertySchema, path: path + "." + name)
            default:
                if let fixed = fixedSchemaValue(propertySchema) { entry[name] = fixed }
            }
        }
        let missing = requiredFields(object).filter { entry[$0] == nil }
        if !missing.isEmpty {
            throw MappingError.unsupportedRequiredFields(missing.map { path + "." + $0 }.sorted())
        }
        return try coerce(.object(entry), for: schema, path: path)
    }

    private static func mediaEntry(_ input: MediaInput, locatorKey: String) -> Value {
        .object([locatorKey: .string(input.locator), "role": .string(input.role)])
    }

    private static func mediaData(_ input: MediaInput, schema: Value, path: String) throws -> Value {
        guard let object = schemaObject(schema), let properties = schemaProperties(object), !properties.isEmpty else {
            return .object(["id": .string(input.locator)])
        }
        var data: [String: Value] = [:]
        for (name, childSchema) in properties {
            switch normalize(name) {
            case "id", "mediaid", "value", "url", "uri":
                data[name] = try coerce(
                    .string(input.locator), for: childSchema, path: path + "." + name
                )
            case "type":
                data[name] = try coerce(
                    fixedSchemaValue(childSchema) ?? .string("media_input"),
                    for: childSchema,
                    path: path + "." + name
                )
            default:
                if let fixed = fixedSchemaValue(childSchema) { data[name] = fixed }
            }
        }
        let missing = requiredFields(object).filter { data[$0] == nil }
        if !missing.isEmpty {
            throw MappingError.unsupportedRequiredFields(missing.map { path + "." + $0 }.sorted())
        }
        return .object(data)
    }

    private static func fieldPriority(_ field: String) -> Int {
        if directMedia(for: field, from: []) != nil { return 0 }
        if isAggregateMediaField(field) { return 1 }
        return 2
    }

    private static func isAggregateMediaField(_ field: String) -> Bool {
        ["medias", "media", "inputfiles", "mediainputs"].contains(field)
    }

    private static func normalize(_ field: String) -> String {
        field.lowercased().filter(\.isLetter)
    }

    static func supportsSynchronousCompletion(schema: Value) -> Bool {
        guard let object = schemaObject(schema) else { return false }
        if let alternatives = schemaAlternatives(object),
           alternatives.contains(where: {
               supportsSynchronousCompletion(schema: $0)
           }) {
            return true
        }
        guard let properties = schemaProperties(object) else { return false }
        for (name, child) in properties {
            if synchronousCompletionFields.contains(normalize(name)),
               (try? coerce(.bool(true), for: child, path: name)) != nil {
                return true
            }
            if supportsSynchronousCompletion(schema: child) { return true }
        }
        return false
    }

    static func requestsSynchronousCompletion(
        arguments: [String: Value]
    ) -> Bool {
        arguments.contains { element in
            let (name, value) = element
            if synchronousCompletionFields.contains(normalize(name)) {
                switch value {
                case .bool(true), .string("true"), .int(1): return true
                default: break
                }
            }
            guard case .object(let nested) = value else { return false }
            return requestsSynchronousCompletion(arguments: nested)
        }
    }

    private static func schemaObject(_ value: Value) -> [String: Value]? {
        guard case .object(let object) = value else { return nil }
        return object
    }

    private static func schemaProperties(_ object: [String: Value]) -> [String: Value]? {
        guard case .object(let properties)? = object["properties"] else { return nil }
        return properties
    }

    private static func requiredFields(_ object: [String: Value]) -> [String] {
        guard case .array(let values)? = object["required"] else { return [] }
        return values.compactMap {
            guard case .string(let field) = $0 else { return nil }
            return field
        }
    }

    private static func fixedSchemaValue(_ schema: Value) -> Value? {
        guard let object = schemaObject(schema) else { return nil }
        if let value = object["const"] { return value }
        if let value = object["default"] { return value }
        if case .array(let values)? = object["enum"], values.count == 1 { return values[0] }
        return nil
    }

    private static func coerce(_ value: Value, for schema: Value, path: String) throws -> Value {
        guard let object = schemaObject(schema) else { return value }
        if let alternatives = schemaAlternatives(object) {
            for alternative in alternatives {
                if let converted = try? coerce(value, for: alternative, path: path) { return converted }
            }
            throw MappingError.incompatibleField(path)
        }
        guard case .string(let type)? = object["type"] else {
            return try validateEnum(value, schema: object, path: path)
        }
        let converted: Value
        switch type {
        case "string":
            switch value {
            case .string: converted = value
            case .int(let number): converted = .string(String(number))
            case .double(let number): converted = .string(String(number))
            case .bool(let flag): converted = .string(flag ? "true" : "false")
            case .array(let values) where values.count == 1:
                converted = try coerce(values[0], for: schema, path: path)
            default: throw MappingError.incompatibleField(path)
            }
        case "integer":
            switch value {
            case .int: converted = value
            case .string(let text) where Int(text) != nil: converted = .int(Int(text)!)
            default: throw MappingError.incompatibleField(path)
            }
        case "number":
            switch value {
            case .int(let number): converted = .double(Double(number))
            case .double: converted = value
            case .string(let text) where Double(text) != nil: converted = .double(Double(text)!)
            default: throw MappingError.incompatibleField(path)
            }
        case "boolean":
            switch value {
            case .bool: converted = value
            case .string("true"): converted = .bool(true)
            case .string("false"): converted = .bool(false)
            default: throw MappingError.incompatibleField(path)
            }
        case "array":
            let values: [Value]
            if case .array(let array) = value { values = array }
            else { values = [value] }
            if let minimum = integerConstraint("minItems", in: object), values.count < minimum {
                throw MappingError.incompatibleField(path)
            }
            if let maximum = integerConstraint("maxItems", in: object), values.count > maximum {
                throw MappingError.incompatibleField(path)
            }
            if let itemSchema = object["items"] {
                converted = .array(try values.enumerated().map { index, item in
                    try coerce(item, for: itemSchema, path: "\(path)[\(index)]")
                })
            } else {
                converted = .array(values)
            }
        case "object":
            guard case .object = value else { throw MappingError.incompatibleField(path) }
            converted = value
        default:
            converted = value
        }
        return try validateEnum(converted, schema: object, path: path)
    }

    private static func schemaAlternatives(_ object: [String: Value]) -> [Value]? {
        for key in ["oneOf", "anyOf"] {
            if case .array(let values)? = object[key], !values.isEmpty { return values }
        }
        return nil
    }

    private static func schemaAcceptsArray(_ schema: Value) -> Bool {
        guard let object = schemaObject(schema) else { return false }
        if case .string("array")? = object["type"] { return true }
        return schemaAlternatives(object)?.contains { schemaAcceptsArray($0) } == true
    }

    private static func integerConstraint(_ key: String, in object: [String: Value]) -> Int? {
        switch object[key] {
        case .int(let value): return value
        case .double(let value): return Int(value)
        default: return nil
        }
    }

    private static func validateEnum(
        _ value: Value,
        schema: [String: Value],
        path: String
    ) throws -> Value {
        guard case .array(let allowed)? = schema["enum"], !allowed.isEmpty else { return value }
        guard allowed.contains(value) else { throw MappingError.incompatibleField(path) }
        return value
    }
}
