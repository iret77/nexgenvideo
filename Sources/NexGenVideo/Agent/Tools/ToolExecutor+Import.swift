import Foundation

extension ToolExecutor {
    static let importDownloadMaxBytes: Int64 = 1024 * 1024 * 1024
    static let importBytesMaxBase64Length = 15 * 1024 * 1024
    static let importDownloadTimeout: TimeInterval = 120

    private static let importMediaAllowedKeys: Set<String> = ["source", "name", "folderId"]
    private static let importSourceAllowedKeys: Set<String> = ["url", "path", "bytes", "mimeType"]

    func importMedia(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.importMediaAllowedKeys, path: "import_media")
        guard let source = args["source"] as? [String: Any] else {
            throw ToolError("Missing required 'source' object")
        }
        try validateUnknownKeys(source, allowed: Self.importSourceAllowedKeys, path: "source")

        let urlStr = source.string("url")
        let pathStr = source.string("path")
        let bytesStr = source.string("bytes")
        let mimeType = source.string("mimeType")

        let setCount = [urlStr, pathStr, bytesStr].compactMap { $0 }.count
        guard setCount == 1 else {
            throw ToolError("source must set exactly one of 'url', 'path', or 'bytes' (got \(setCount))")
        }

        let folderId = try resolveFolderId(args, editor: editor)
        let providedName = args.string("name")

        if let pathStr {
            return try await importFromPath(editor: editor, path: pathStr, name: providedName, folderId: folderId)
        }
        if let bytesStr {
            guard let mimeType else {
                throw ToolError("source.mimeType is required when source.bytes is set")
            }
            return try await importFromBytes(editor: editor, base64: bytesStr, mimeType: mimeType, name: providedName, folderId: folderId)
        }
        if let urlStr {
            return try await importFromURL(
                editor: editor,
                urlString: urlStr,
                mimeOverride: mimeType,
                name: providedName,
                folderId: folderId
            )
        }
        throw ToolError("unreachable")
    }

    private func importFromPath(editor: EditorViewModel, path: String, name: String?, folderId: String?) async throws -> ToolResult {
        let fileURL = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir) else {
            throw ToolError("File not found: \(path)")
        }
        if isDir.boolValue {
            let summary = await editor.importFinderItems([fileURL], into: folderId)
            if let failure = summary.failure {
                throw ToolError(failure)
            }
            guard summary.assetCount > 0 else {
                throw ToolError("No supported media found in folder: \(path)")
            }
            return .ok("Imported \(summary.assetCount) file(s) into \(summary.folderCount) folder(s) from '\(fileURL.lastPathComponent)', mirroring its structure. Available now in get_media / list_folders.")
        }
        let ext = fileURL.pathExtension.lowercased()
        guard let type = ClipType(fileExtension: ext) else {
            throw ToolError("Unsupported file extension '.\(ext)'. Supported: mov/mp4/m4v, mp3/wav/aac/m4a/aiff/aifc/flac, png/jpg/jpeg/tiff/heic, json (Lottie).")
        }
        let asset = try await importLocalFile(
            editor: editor,
            fileURL: fileURL,
            type: type,
            folderId: folderId
        )
        applyImportMetadata(editor: editor, asset: asset, name: name, folderId: folderId)
        await editor.finalizeImportedAsset(asset)
        return .ok("Imported '\(asset.name)' (id: \(asset.id), type: \(asset.type.rawValue)) from path. Available now in get_media.")
    }

    private func importFromBytes(
        editor: EditorViewModel,
        base64: String,
        mimeType: String,
        name: String?,
        folderId: String?
    ) async throws -> ToolResult {
        guard base64.utf8.count <= Self.importBytesMaxBase64Length else {
            throw ToolError("source.bytes is too large (\(base64.utf8.count) chars; max \(Self.importBytesMaxBase64Length)). Use source.url or source.path for larger files.")
        }
        guard let fileExt = Self.fileExtension(forMime: mimeType) else {
            throw ToolError("Unsupported mimeType '\(mimeType)'. Accepted: video/mp4, video/quicktime, audio/mpeg, audio/wav, audio/aac, audio/mp4, audio/aiff, audio/flac, image/png, image/jpeg, image/tiff, image/heic.")
        }
        guard editor.workingRoot != nil else {
            throw ToolError(MediaImportError.projectMustBeSaved.localizedDescription)
        }
        let temporaryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ngv-inline-\(UUID().uuidString).\(fileExt)"
        )
        let byteCount: Int
        do {
            byteCount = try await Task.detached(priority: .userInitiated) {
                guard let data = Data(
                    base64Encoded: base64,
                    options: [.ignoreUnknownCharacters]
                ), !data.isEmpty else {
                    throw ToolError("source.bytes is not valid non-empty base64")
                }
                try data.write(to: temporaryURL, options: .atomic)
                return data.count
            }.value
        } catch {
            if let error = error as? ToolError { throw error }
            throw ToolError("Failed to stage inline media: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        guard let type = ClipType(fileExtension: fileExt) else {
            throw ToolError("Unsupported file extension '.\(fileExt)'")
        }
        let asset = try await importLocalFile(
            editor: editor,
            fileURL: temporaryURL,
            type: type,
            folderId: folderId
        )
        applyImportMetadata(editor: editor, asset: asset, name: name, folderId: folderId)
        await editor.finalizeImportedAsset(asset)
        return .ok("Imported '\(asset.name)' (id: \(asset.id), type: \(asset.type.rawValue), \(byteCount) bytes). Available now in get_media.")
    }

    private func importLocalFile(
        editor: EditorViewModel,
        fileURL: URL,
        type: ClipType,
        folderId: String?
    ) async throws -> MediaAsset {
        let existingIds = Set(editor.mediaAssets.map(\.id))
        let digest: String
        do {
            digest = try await Task.detached(priority: .userInitiated) {
                try DurableMediaStore.digest(of: fileURL)
            }.value
        } catch {
            throw ToolError(error.localizedDescription)
        }
        let summary = await editor.importFinderItems([fileURL], into: folderId)
        if let failure = summary.failure {
            throw ToolError(failure)
        }
        if let imported = editor.mediaAssets.first(where: {
            !existingIds.contains($0.id) && $0.type == type
        }) {
            return imported
        }
        let source = fileURL.standardizedFileURL.resolvingSymlinksInPath()
        if let existing = editor.mediaAssets.first(where: {
            $0.type == type
                && $0.url.standardizedFileURL.resolvingSymlinksInPath() == source
        }) {
            return existing
        }
        if let existing = editor.mediaAssets.first(where: {
            $0.type == type
                && $0.url.deletingPathExtension().lastPathComponent.lowercased() == digest
        }) {
            return existing
        }
        throw ToolError("The media copy completed but no library asset was registered.")
    }

    private func importFromURL(
        editor: EditorViewModel,
        urlString: String,
        mimeOverride: String?,
        name: String?,
        folderId: String?
    ) async throws -> ToolResult {
        guard let url = URL(string: urlString) else {
            throw ToolError("source.url is not a valid URL")
        }

        let fileExt: String
        if let mimeOverride {
            guard let mapped = Self.fileExtension(forMime: mimeOverride) else {
                throw ToolError("Unsupported mimeType '\(mimeOverride)'. Accepted: video/mp4, video/quicktime, audio/mpeg, audio/wav, audio/aac, audio/mp4, audio/aiff, audio/flac, image/png, image/jpeg, image/tiff, image/heic.")
            }
            fileExt = mapped
        } else {
            let urlExt = url.pathExtension.lowercased()
            guard !urlExt.isEmpty, ClipType(fileExtension: urlExt) != nil else {
                let shown = urlExt.isEmpty ? "(none)" : ".\(urlExt)"
                throw ToolError("Cannot infer media type from URL extension \(shown). Set source.mimeType to disambiguate (e.g. 'video/mp4', 'image/png').")
            }
            fileExt = urlExt
        }
        guard let type = ClipType(fileExtension: fileExt) else {
            throw ToolError("Unsupported file extension '.\(fileExt)'")
        }

        guard let workingRoot = editor.workingRoot,
              let workingCopyKey = editor.openWorkingCopyKey else {
            throw ToolError(MediaImportError.projectMustBeSaved.localizedDescription)
        }

        let download: RemoteMediaDownloader.Download
        do {
            download = try await RemoteMediaDownloader.download(
                url,
                maxBytes: Self.importDownloadMaxBytes,
                timeout: Self.importDownloadTimeout
            )
            try await RemoteMediaPayloadValidator.validate(
                download.temporaryURL,
                expectedType: type
            )
        } catch {
            throw ToolError(error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: download.temporaryURL) }
        guard editor.workingRoot?.standardizedFileURL == workingRoot.standardizedFileURL,
              editor.openWorkingCopyKey == workingCopyKey else {
            throw ToolError("The project changed while remote media was downloading. Import again.")
        }

        let mediaDir: URL
        do {
            mediaDir = try editor.prepareWorkingMediaDirectory()
        } catch {
            throw ToolError(error.localizedDescription)
        }
        let reusableByDigest: [String: URL] = editor.mediaAssets.reduce(
            into: [:]
        ) { result, asset in
            guard asset.type == type else { return }
            let stem = asset.url.deletingPathExtension()
                .lastPathComponent.lowercased()
            if stem.count == 64, stem.allSatisfy(\.isHexDigit) {
                result[stem] = result[stem] ?? asset.url
            }
        }
        let copy: DurableMediaCopy
        do {
            copy = try await Task.detached(priority: .userInitiated) {
                try DurableMediaStore.copy(
                    download.temporaryURL,
                    into: mediaDir,
                    reusableByDigest: reusableByDigest,
                    fileExtension: fileExt
                )
            }.value
        } catch {
            throw ToolError("Couldn't install remote media: \(error.localizedDescription)")
        }
        guard editor.workingRoot?.standardizedFileURL == workingRoot.standardizedFileURL,
              editor.openWorkingCopyKey == workingCopyKey else {
            if copy.created { try? FileManager.default.removeItem(at: copy.url) }
            throw ToolError("The project changed while remote media was being installed. Import again.")
        }

        let displayName: String
        if let name {
            displayName = name
        } else {
            let stem = url.deletingPathExtension().lastPathComponent
            displayName = stem.isEmpty ? "Imported asset" : stem
        }

        let asset: MediaAsset
        if let existing = editor.mediaAssets.first(where: {
            $0.type == type
                && $0.url.standardizedFileURL == copy.url.standardizedFileURL
        }) {
            asset = existing
            applyImportMetadata(
                editor: editor,
                asset: asset,
                name: name,
                folderId: folderId
            )
        } else {
            asset = MediaAsset(
                id: UUID().uuidString,
                url: copy.url,
                type: type,
                name: displayName
            )
            editor.importMediaAsset(asset)
            applyImportMetadata(
                editor: editor,
                asset: asset,
                name: nil,
                folderId: folderId
            )
        }
        await editor.finalizeImportedAsset(asset)
        return .ok(
            "Imported '\(asset.name)' (id: \(asset.id), type: \(asset.type.rawValue)) "
                + "from URL. Available now in get_media."
        )
    }

    private func applyImportMetadata(editor: EditorViewModel, asset: MediaAsset, name: String?, folderId: String?) {
        if let name {
            asset.name = name
            if let idx = editor.mediaManifest.entries.firstIndex(where: { $0.id == asset.id }) {
                editor.mediaManifest.entries[idx].name = name
            }
        }
        if let folderId {
            editor.moveAssetsToFolder(assetIds: [asset.id], folderId: folderId)
        }
    }

    private static func fileExtension(forMime mime: String) -> String? {
        switch mime.lowercased() {
        case "video/mp4", "video/mpeg4": return "mp4"
        case "video/quicktime": return "mov"
        case "audio/mpeg", "audio/mp3": return "mp3"
        case "audio/wav", "audio/x-wav", "audio/wave": return "wav"
        case "audio/aac": return "aac"
        case "audio/mp4", "audio/m4a", "audio/x-m4a": return "m4a"
        case "audio/aiff", "audio/x-aiff": return "aiff"
        case "audio/aifc", "audio/x-aifc": return "aifc"
        case "audio/flac", "audio/x-flac": return "flac"
        case "image/png": return "png"
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/tiff": return "tiff"
        case "image/heic", "image/heif": return "heic"
        case "application/json", "application/vnd.lottie+json": return "json"
        default: return nil
        }
    }
}
