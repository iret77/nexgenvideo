import Foundation
import MCP

enum MCPGenerationArguments {
    enum MappingError: LocalizedError, Equatable {
        case unsupportedRequiredFields([String])
        case missingPrompt
        case missingModel

        var errorDescription: String? {
            switch self {
            case .unsupportedRequiredFields(let fields):
                return "The provider requires unsupported generation fields: \(fields.joined(separator: ", "))."
            case .missingPrompt:
                return "The provider's generation tool has no usable prompt field."
            case .missingModel:
                return "The provider's generation tool has no usable model field."
            }
        }
    }

    static func make(
        for params: BackendGenerationParams,
        model: String?,
        schema: Value
    ) throws -> [String: Value] {
        let candidates = values(for: params, model: model)
        guard let root = schemaObject(schema), let properties = schemaProperties(root), !properties.isEmpty else {
            var fallback: [String: Value] = [:]
            if let prompt = candidates["prompt"] { fallback["prompt"] = prompt }
            if let model = candidates["model"] { fallback["model"] = model }
            return fallback
        }

        var mappedNames = Set<String>()
        let arguments = try mapObject(
            root,
            candidates: candidates,
            path: "",
            mappedNames: &mappedNames
        )
        if candidates["prompt"] != nil, !mappedNames.contains("prompt") {
            throw MappingError.missingPrompt
        }
        if model?.isEmpty == false, !mappedNames.contains("model") {
            throw MappingError.missingModel
        }
        return arguments
    }

    private static func mapObject(
        _ schema: [String: Value],
        candidates: [String: Value],
        path: String,
        mappedNames: inout Set<String>
    ) throws -> [String: Value] {
        guard let properties = schemaProperties(schema) else { return [:] }
        var result: [String: Value] = [:]

        for (field, fieldSchema) in properties {
            let normalized = normalize(field)
            if let candidateName = candidateNames(for: normalized).first(where: { candidates[$0] != nil }),
               let value = candidates[candidateName] {
                result[field] = coerce(value, for: fieldSchema)
                mappedNames.insert(candidateName)
                continue
            }
            if let child = schemaObject(fieldSchema), schemaProperties(child) != nil {
                let nested = try mapObject(
                    child,
                    candidates: candidates,
                    path: path + field + ".",
                    mappedNames: &mappedNames
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
        model: String?
    ) -> [String: Value] {
        var values: [String: Value] = [:]
        if let model, !model.isEmpty { values["model"] = .string(model) }

        switch params {
        case .image(let value):
            values["prompt"] = .string(value.prompt)
            if !value.aspectRatio.isEmpty { values["aspectratio"] = .string(value.aspectRatio) }
            if let resolution = value.resolution { values["resolution"] = .string(resolution) }
            if let quality = value.quality { values["quality"] = .string(quality) }
            if !value.imageURLs.isEmpty {
                values["imageurls"] = .array(value.imageURLs.map(Value.string))
            }
            values["numimages"] = .int(value.numImages)
        case .video(let value):
            values["prompt"] = .string(value.prompt)
            switch value.duration {
            case .seconds(let duration): values["duration"] = .int(duration)
            case .automatic: values["duration"] = .string("auto")
            }
            if !value.aspectRatio.isEmpty { values["aspectratio"] = .string(value.aspectRatio) }
            if let resolution = value.resolution { values["resolution"] = .string(resolution) }
            if let source = value.sourceVideoURL { values["sourcevideourl"] = .string(source) }
            if let start = value.startFrameURL { values["startframeurl"] = .string(start) }
            if let end = value.endFrameURL { values["endframeurl"] = .string(end) }
            if !value.referenceImageURLs.isEmpty {
                values["referenceimageurls"] = .array(value.referenceImageURLs.map(Value.string))
            }
            if !value.referenceVideoURLs.isEmpty {
                values["referencevideourls"] = .array(value.referenceVideoURLs.map(Value.string))
            }
            if !value.referenceAudioURLs.isEmpty {
                values["referenceaudiourls"] = .array(value.referenceAudioURLs.map(Value.string))
            }
            values["generateaudio"] = .bool(value.generateAudio)
        case .audio(let value):
            values["prompt"] = .string(value.prompt)
            if let voice = value.voice { values["voice"] = .string(voice) }
            if let lyrics = value.lyrics { values["lyrics"] = .string(lyrics) }
            if let style = value.styleInstructions { values["styleinstructions"] = .string(style) }
            values["instrumental"] = .bool(value.instrumental)
            if let duration = value.durationSeconds { values["durationseconds"] = .int(duration) }
            if let video = value.videoURL { values["videourl"] = .string(video) }
        case .upscale(let value):
            values["sourceurl"] = .string(value.sourceURL)
            values["durationseconds"] = .int(value.durationSeconds)
        }
        return values
    }

    private static func candidateNames(for field: String) -> [String] {
        switch field {
        case "prompt", "textprompt", "text", "description": ["prompt"]
        case "model", "modelid": ["model"]
        case "aspectratio": ["aspectratio"]
        case "resolution": ["resolution"]
        case "quality", "mode": ["quality"]
        case "numimages", "numberofimages", "imagecount", "imagescount", "count": ["numimages"]
        case "imageurls", "referenceimageurls", "inputimageurls": ["imageurls", "referenceimageurls"]
        case "duration": ["duration"]
        case "sourcevideourl": ["sourcevideourl"]
        case "startframeurl", "startimageurl": ["startframeurl"]
        case "endframeurl", "endimageurl": ["endframeurl"]
        case "referencevideourls": ["referencevideourls"]
        case "referenceaudiourls": ["referenceaudiourls"]
        case "generateaudio": ["generateaudio"]
        case "voice", "voicename": ["voice"]
        case "lyrics": ["lyrics"]
        case "styleinstructions": ["styleinstructions"]
        case "instrumental": ["instrumental"]
        case "durationseconds": ["durationseconds"]
        case "videourl": ["videourl"]
        case "sourceurl": ["sourceurl"]
        default: []
        }
    }

    private static func normalize(_ field: String) -> String {
        field.lowercased().filter(\.isLetter)
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

    private static func coerce(_ value: Value, for schema: Value) -> Value {
        guard let object = schemaObject(schema), case .string(let type)? = object["type"] else {
            return value
        }
        if type == "string" {
            switch value {
            case .int(let number): return .string(String(number))
            case .double(let number): return .string(String(number))
            case .bool(let flag): return .string(flag ? "true" : "false")
            default: return value
            }
        }
        return value
    }
}
