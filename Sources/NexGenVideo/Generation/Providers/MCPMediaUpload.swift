import Foundation

enum MCPMediaUpload {
    typealias ReferenceUploader = @Sendable (URL, String) async throws -> String

    private struct ReferenceInput {
        let locator: String
        let mediaType: String
    }

    struct Ticket: Equatable {
        let uploadURL: URL
        let mediaID: String
    }

    enum UploadError: LocalizedError, Equatable {
        case toolsUnavailable
        case localFileMissing(String)
        case invalidTicket
        case invalidUploadResponse
        case uploadRejected(status: Int, detail: String?)

        var errorDescription: String? {
            switch self {
            case .toolsUnavailable:
                return "The provider MCP cannot upload local reference media."
            case .localFileMissing(let path):
                return "Reference media is missing at '\(path)'."
            case .invalidTicket:
                return "The provider MCP returned an invalid media upload ticket."
            case .invalidUploadResponse:
                return "The provider media upload returned no HTTP response."
            case .uploadRejected(let status, let detail):
                let suffix = detail.map { " \($0)" } ?? ""
                return "The provider media upload failed with HTTP \(status).\(suffix)"
            }
        }
    }

    static func prepare(
        _ params: BackendGenerationParams,
        tools: [MCPProviderClient.DiscoveredTool],
        client: any MCPToolCalling,
        referenceUploader: ReferenceUploader? = nil
    ) async throws -> BackendGenerationParams {
        let references = referenceInputs(in: params)
        let localFiles = references.compactMap { localFileURL($0.locator) }
        guard !localFiles.isEmpty else { return params }
        guard let uploadTool = uploadTool(in: tools), let confirmTool = confirmTool(in: tools) else {
            throw UploadError.toolsUnavailable
        }

        var replacements: [String: String] = [:]
        for reference in references where localFileURL(reference.locator) != nil {
            if replacements[reference.locator] != nil { continue }
            let fileURL = localFileURL(reference.locator)!
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                throw UploadError.localFileMissing(fileURL.path)
            }
            if let referenceUploader {
                replacements[reference.locator] = try await referenceUploader(
                    fileURL, reference.mediaType
                )
            } else {
                replacements[reference.locator] = try await upload(
                    fileURL,
                    mediaType: reference.mediaType,
                    uploadTool: uploadTool,
                    confirmTool: confirmTool,
                    client: client
                )
            }
        }
        return replacingReferences(in: params) { replacements[$0] ?? $0 }
    }

    static func uploadTool(
        in tools: [MCPProviderClient.DiscoveredTool]
    ) -> MCPProviderClient.DiscoveredTool? {
        selectTool(in: tools, exact: ["mediaupload", "uploadmedia"], words: ["media", "upload"])
    }

    static func confirmTool(
        in tools: [MCPProviderClient.DiscoveredTool]
    ) -> MCPProviderClient.DiscoveredTool? {
        selectTool(in: tools, exact: ["mediaconfirm", "confirmmedia"], words: ["media", "confirm"])
    }

    static func supportsUploadContract(_ tools: [MCPProviderClient.DiscoveredTool]) -> Bool {
        guard let upload = uploadTool(in: tools), let confirm = confirmTool(in: tools) else {
            return false
        }
        guard (try? MCPGenerationArguments.makeMediaUpload(
            filename: "preflight.jpg",
            mimeType: "image/jpeg",
            mediaType: "image",
            fileSize: 1,
            schema: upload.inputSchema
        )) != nil else { return false }
        return (try? MCPGenerationArguments.makeMediaConfirm(
            mediaID: "preflight-media",
            filename: "preflight.jpg",
            mediaType: "image",
            schema: confirm.inputSchema
        )) != nil
    }

    static func ticket(from payloads: [String]) -> Ticket? {
        let objects = jsonObjects(payloads)
        guard let urlText = firstString(
            keys: ["upload_url", "uploadUrl", "presigned_url", "presignedUrl"],
            in: objects
        ), let url = URL(string: urlText), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else {
            return nil
        }
        guard let mediaID = firstString(
            keys: ["media_id", "mediaId", "pending_id", "pendingId", "upload_id", "uploadId", "id"],
            in: objects
        ), !mediaID.isEmpty else {
            return nil
        }
        return Ticket(uploadURL: url, mediaID: mediaID)
    }

    static func confirmedMediaID(from payloads: [String], fallback: String) -> String {
        firstString(
            keys: ["media_id", "mediaId", "confirmed_id", "confirmedId", "id"],
            in: jsonObjects(payloads)
        ) ?? fallback
    }

    private static func upload(
        _ fileURL: URL,
        mediaType: String,
        uploadTool: MCPProviderClient.DiscoveredTool,
        confirmTool: MCPProviderClient.DiscoveredTool,
        client: any MCPToolCalling
    ) async throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let mimeType = contentType(for: fileURL, fallback: mediaType)
        let uploadArguments = try MCPGenerationArguments.makeMediaUpload(
            filename: fileURL.lastPathComponent,
            mimeType: mimeType,
            mediaType: mediaType,
            fileSize: size,
            schema: uploadTool.inputSchema
        )
        let uploadPayloads = try await client.callTool(
            name: uploadTool.name,
            arguments: uploadArguments
        )
        guard let ticket = ticket(from: uploadPayloads) else { throw UploadError.invalidTicket }

        var request = URLRequest(url: ticket.uploadURL)
        request.httpMethod = "PUT"
        request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: fileURL)
        guard let http = response as? HTTPURLResponse else {
            throw UploadError.invalidUploadResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw UploadError.uploadRejected(
                status: http.statusCode,
                detail: uploadErrorDetail(data)
            )
        }

        let confirmArguments = try MCPGenerationArguments.makeMediaConfirm(
            mediaID: ticket.mediaID,
            filename: fileURL.lastPathComponent,
            mediaType: mediaType,
            schema: confirmTool.inputSchema
        )
        let confirmPayloads = try await client.callTool(
            name: confirmTool.name,
            arguments: confirmArguments
        )
        return confirmedMediaID(from: confirmPayloads, fallback: ticket.mediaID)
    }

    private static func selectTool(
        in tools: [MCPProviderClient.DiscoveredTool],
        exact: Set<String>,
        words: [String]
    ) -> MCPProviderClient.DiscoveredTool? {
        if let match = tools.first(where: { exact.contains(normalize($0.name)) }) { return match }
        return tools.first { tool in
            let haystack = (tool.name + " " + (tool.description ?? "")).lowercased()
            return words.allSatisfy(haystack.contains)
                && !MCPModelDiscovery.isGenerative(name: tool.name, description: tool.description)
        }
    }

    private static func referenceInputs(in params: BackendGenerationParams) -> [ReferenceInput] {
        switch params {
        case .image(let value):
            return value.imageURLs.map { ReferenceInput(locator: $0, mediaType: "image") }
        case .video(let value):
            return [value.sourceVideoURL].compactMap { $0 }.map {
                ReferenceInput(locator: $0, mediaType: "video")
            } + [value.startFrameURL, value.endFrameURL].compactMap { $0 }.map {
                ReferenceInput(locator: $0, mediaType: "image")
            } + value.referenceImageURLs.map {
                ReferenceInput(locator: $0, mediaType: "image")
            } + value.referenceVideoURLs.map {
                ReferenceInput(locator: $0, mediaType: "video")
            } + value.referenceAudioURLs.map {
                ReferenceInput(locator: $0, mediaType: "audio")
            }
        case .audio(let value):
            return value.videoURL.map { [ReferenceInput(locator: $0, mediaType: "video")] } ?? []
        case .upscale(let value):
            return [ReferenceInput(locator: value.sourceURL, mediaType: "file")]
        }
    }

    private static func replacingReferences(
        in params: BackendGenerationParams,
        transform: (String) -> String
    ) -> BackendGenerationParams {
        switch params {
        case .image(let value):
            return .image(ImageGenerationParams(
                prompt: value.prompt,
                aspectRatio: value.aspectRatio,
                resolution: value.resolution,
                quality: value.quality,
                imageURLs: value.imageURLs.map(transform),
                numImages: value.numImages
            ))
        case .video(let value):
            return .video(VideoGenerationParams(
                prompt: value.prompt,
                duration: value.duration,
                aspectRatio: value.aspectRatio,
                resolution: value.resolution,
                sourceVideoURL: value.sourceVideoURL.map(transform),
                startFrameURL: value.startFrameURL.map(transform),
                endFrameURL: value.endFrameURL.map(transform),
                referenceImageURLs: value.referenceImageURLs.map(transform),
                referenceVideoURLs: value.referenceVideoURLs.map(transform),
                referenceAudioURLs: value.referenceAudioURLs.map(transform),
                generateAudio: value.generateAudio
            ))
        case .audio(var value):
            value.videoURL = value.videoURL.map(transform)
            return .audio(value)
        case .upscale(let value):
            return .upscale(UpscaleGenerationParams(
                sourceURL: transform(value.sourceURL),
                durationSeconds: value.durationSeconds
            ))
        }
    }

    private static func localFileURL(_ locator: String) -> URL? {
        if locator.hasPrefix("/") { return URL(fileURLWithPath: locator) }
        guard let url = URL(string: locator), url.isFileURL else { return nil }
        return url
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

    private static func contentType(for url: URL, fallback: String) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "heif": return "image/heif"
        case "gif": return "image/gif"
        case "tif", "tiff": return "image/tiff"
        case "bmp": return "image/bmp"
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "webm": return "video/webm"
        case "mkv": return "video/x-matroska"
        case "avi": return "video/x-msvideo"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "m4a": return "audio/mp4"
        case "aac": return "audio/aac"
        case "ogg", "oga": return "audio/ogg"
        case "aiff", "aif", "aifc": return "audio/aiff"
        case "flac": return "audio/flac"
        default:
            switch fallback {
            case "image": return "image/jpeg"
            case "video": return "video/mp4"
            case "audio": return "audio/mpeg"
            default: return "application/octet-stream"
            }
        }
    }

    private static func uploadErrorDetail(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let fields = ["Code", "Message"].compactMap { tag -> String? in
            let pattern = "<\(tag)>([^<]+)</\(tag)>"
            guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
            let source = text as NSString
            guard let match = expression.firstMatch(
                in: text,
                range: NSRange(location: 0, length: source.length)
            ), match.numberOfRanges > 1 else { return nil }
            return source.substring(with: match.range(at: 1))
        }
        guard !fields.isEmpty else { return nil }
        return fields.joined(separator: ": ").prefix(300).description
    }

    private static func normalize(_ value: String) -> String {
        value.lowercased().filter(\.isLetter)
    }
}
