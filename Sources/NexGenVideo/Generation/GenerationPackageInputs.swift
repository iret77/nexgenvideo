import Foundation
import ImageIO
import NexGenEngine

struct GenerationPackageInputs: Codable, Sendable, Equatable {
    let packageID: String
    let paths: [String]

    @MainActor
    static func persist(package: GenerationPackageV1, snapshot: GenerationReferenceSnapshot,
                        editor: EditorViewModel) async throws {
        try package.validate()
        guard let home = editor.workingRoot, snapshot.receipts == package.payload.references else {
            throw GenerationRequestError.storage("The prepared input archive does not match its generation package.")
        }
        let scope = try GenerationProjectMutationScope(projectHome: home, editor: editor)
        try await requireCurrentReferences(package: package, editor: editor)
        try await snapshot.requireUnchanged()
        guard let key = editor.openWorkingCopyKey else { throw GenerationRequestError.storage("Generation inputs need a recoverable project.") }
        try ProjectWorkingCopy.markDirty(key: key)
        let directoryPath = Project.mediaDirectoryName + "/generation-inputs/" + package.id
        let paths = snapshot.urls.enumerated().map { index, url in
            directoryPath + "/" + String(index) + (url.pathExtension.isEmpty ? ".bin" : "." + url.pathExtension)
        }
        let record = Self(packageID: package.id, paths: paths)
        try await Task.detached(priority: .utility) {
            do {
                _ = try ProjectLocalFile.ensureDirectory(directoryPath, dataRoot: home)
            } catch {
                throw GenerationRequestError.storage(
                    "Generation input storage is not a safe project-local directory."
                )
            }
            for (index, path) in paths.enumerated() {
                let destination = home.appendingPathComponent(path)
                if !FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.copyItem(at: snapshot.urls[index], to: destination)
                }
                _ = try ProjectLocalFile.requireHash(package.payload.references[index].submittedSHA256, at: path, dataRoot: home)
            }
        }.value
        try Task.checkCancellation()
        try scope.requireCurrent(editor: editor)
        try await snapshot.requireUnchanged()
        try await requireCurrentReferences(package: package, editor: editor)
        try scope.requireCurrent(editor: editor)
        try package.persist(editor: editor)
        let path = manifestPath(package.id)
        let file = home.appendingPathComponent(path)
        let bytes = try GenerationPackageV1.canonicalData(record)
        if FileManager.default.fileExists(atPath: file.path) {
            guard try Data(contentsOf: ProjectLocalFile.resolve(path, dataRoot: home)) == bytes else {
                throw GenerationRequestError.storage("The immutable generation input archive changed.")
            }
        } else { try bytes.write(to: file, options: .withoutOverwriting) }
    }

    @MainActor
    static func restore(package: GenerationPackageV1, editor: EditorViewModel) async throws -> GenerationReferenceSnapshot {
        guard let home = editor.workingRoot else { throw GenerationRequestError.storage("The generation project is closed.") }
        let scope = try GenerationProjectMutationScope(projectHome: home, editor: editor)
        let urls = try await archivedURLs(package: package, editor: editor)
        let sources = try resolvedSources(package: package, editor: editor)
        let snapshot = try await GenerationReferenceSnapshot.capture(sources: sources, submittedURLs: urls,
            sourceReceipts: package.payload.references)
        guard snapshot.receipts == package.payload.references else {
            throw GenerationRequestError.gate("The saved generation inputs differ from their approved bytes.")
        }
        try await snapshot.requireUnchanged()
        try scope.requireCurrent(editor: editor)
        return snapshot
    }

    @MainActor
    static func validate(package: GenerationPackageV1, editor: EditorViewModel) async throws {
        _ = try await archivedURLs(package: package, editor: editor)
    }

    @MainActor
    private static func archivedURLs(package: GenerationPackageV1, editor: EditorViewModel) async throws -> [URL] {
        guard let home = editor.workingRoot else { throw GenerationRequestError.storage("The generation project is closed.") }
        let scope = try GenerationProjectMutationScope(projectHome: home, editor: editor)
        _ = try resolveReferences(package: package, editor: editor)
        let file = try ProjectLocalFile.resolve(manifestPath(package.id), dataRoot: home)
        let record = try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
        guard record.packageID == package.id, record.paths.count == package.payload.references.count else {
            throw GenerationRequestError.storage("The generation input archive is incomplete.")
        }
        let urls = try await Task.detached(priority: .utility) {
            try zip(record.paths, package.payload.references).map { path, receipt in
                try Task.checkCancellation()
                do { return try ProjectLocalFile.requireHash(receipt.submittedSHA256, at: path, dataRoot: home) }
                catch {
                    throw GenerationRequestError.gate("Archived input for ‘\(receipt.displayName ?? "Unnamed reference")’ is missing or changed. Prepare the request again.")
                }
            }
        }.value
        try await requireCurrentReferences(package: package, editor: editor)
        try scope.requireCurrent(editor: editor)
        return urls
    }

    @MainActor
    static func resolveReferences(package: GenerationPackageV1, editor: EditorViewModel) throws -> [MediaAsset] {
        try package.payload.references.map { reference in
            try resolveReference(reference, package: package, editor: editor)
        }
    }

    @MainActor
    static func resolveReference(_ reference: GenerationReferenceReceipt, package: GenerationPackageV1,
                                 editor: EditorViewModel) throws -> MediaAsset {
        guard package.payload.references.contains(reference) else {
            throw GenerationRequestError.gate("The reference is not part of this generation request.")
        }
        let label = reference.displayName ?? "Unnamed reference"
        if !reference.assetID.hasPrefix("pipeline-reference:"), !reference.assetID.hasPrefix("frame-reference:") {
            guard let asset = editor.mediaAssets.first(where: { $0.id == reference.assetID && $0.type.rawValue == reference.type }) else {
                throw GenerationRequestError.gate("Reference ‘\(label)’ is no longer in the media library. Restore it or revise the request.")
            }
            if let routing = package.payload.routing {
                guard let binding = routing.orderedBindings.first(where: {
                    $0.mediaAssetID == reference.assetID && $0.modalityID == reference.type
                        && $0.sha256 == reference.sourceSHA256
                }), let home = editor.workingRoot, let root = DataRootResolver.dataRoot(of: home),
                    let planned = try? ProjectLocalFile.resolve(binding.path, dataRoot: root),
                    planned.standardizedFileURL.resolvingSymlinksInPath() == asset.url.standardizedFileURL.resolvingSymlinksInPath() else {
                    throw GenerationRequestError.gate("Reference ‘\(label)’ no longer matches its approved project path. Prepare the request again.")
                }
            }
            return asset
        }
        guard let home = editor.workingRoot, let root = DataRootResolver.dataRoot(of: home) else {
            throw GenerationRequestError.gate("Reference ‘\(label)’ is no longer in the media library. Restore it or revise the request.")
        }
        let path: String?
        if reference.assetID.hasPrefix("pipeline-reference:") {
            if let routing = package.payload.routing {
                guard let binding = routing.orderedBindings.first(where: {
                    $0.mediaAssetID == reference.assetID && $0.modalityID == reference.type
                        && $0.sha256 == reference.sourceSHA256
                        && reference.assetID == "pipeline-reference:\($0.path)"
                }) else {
                    throw GenerationRequestError.gate("Reference ‘\(label)’ no longer matches its approved project path. Prepare the request again.")
                }
                path = binding.path
            } else {
                path = reference.type == "image" ? String(reference.assetID.dropFirst("pipeline-reference:".count)) : nil
            }
        } else if let plan = package.payload.generationInput.frameReferencePlan,
                  let binding = plan.bindings.enumerated().first(where: {
                      "frame-reference:\($0.offset):\($0.element.sha256)" == reference.assetID
                          && $0.element.sha256 == reference.sourceSHA256 && reference.type == "image"
                  })?.element {
            path = binding.path
        } else {
            path = nil
        }
        guard let path else {
            throw GenerationRequestError.gate("Reference ‘\(label)’ is no longer in the media library. Restore it or revise the request.")
        }
        let url: URL
        do { url = try ProjectLocalFile.resolve(path, dataRoot: root) }
        catch {
            throw GenerationRequestError.gate("Project reference ‘\(label)’ is missing or unreadable. Restore it or revise the request.")
        }
        guard let type = ClipType(rawValue: reference.type),
              ClipType(fileExtension: url.pathExtension.lowercased()) == type else {
            throw GenerationRequestError.gate("Project reference ‘\(label)’ has the wrong media type. Revise the request.")
        }
        if type == .image {
            guard let image = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(image) > 0 else {
                throw GenerationRequestError.gate("Project reference ‘\(label)’ is not a readable image. Revise the request.")
            }
        }
        return MediaAsset(id: reference.assetID, url: url, type: type, name: label,
            originalFilename: reference.displayName)
    }

    @MainActor
    static func requireCurrentReferences(package: GenerationPackageV1, editor: EditorViewModel) async throws {
        let sources = try resolvedSources(package: package, editor: editor)
        let receipts = package.payload.references
        try await Task.detached(priority: .utility) {
            for (source, receipt) in zip(sources, receipts) {
                try Task.checkCancellation()
                guard (try? FileDigest.sha256(of: source.url)) == receipt.sourceSHA256 else {
                    throw GenerationRequestError.gate("Reference ‘\(receipt.displayName ?? "Unnamed reference")’ is missing or changed. Restore its reviewed bytes or prepare the request again.")
                }
            }
        }.value
        let current = try resolvedSources(package: package, editor: editor)
        guard current.map(\.url) == sources.map(\.url) else {
            throw GenerationRequestError.gate("The reference selection changed during review. Prepare the request again.")
        }
    }

    @MainActor
    private static func resolvedSources(package: GenerationPackageV1, editor: EditorViewModel) throws -> [GenerationReferenceSnapshot.Source] {
        try zip(resolveReferences(package: package, editor: editor), package.payload.references).map { asset, receipt in
            .init(assetID: asset.id, displayName: receipt.displayName, type: receipt.type, url: asset.url)
        }
    }

    private static func manifestPath(_ id: String) -> String { "generation-packages/\(id).inputs.json" }
}
