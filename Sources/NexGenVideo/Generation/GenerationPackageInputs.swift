import Foundation
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
        try await snapshot.requireUnchanged()
        guard let key = editor.openWorkingCopyKey else { throw GenerationRequestError.storage("Generation inputs need a recoverable project.") }
        try ProjectWorkingCopy.markDirty(key: key)
        let directoryPath = Project.mediaDirectoryName + "/generation-inputs/" + package.id
        let paths = snapshot.urls.enumerated().map { index, url in
            directoryPath + "/" + String(index) + (url.pathExtension.isEmpty ? ".bin" : "." + url.pathExtension)
        }
        let record = Self(packageID: package.id, paths: paths)
        try await Task.detached(priority: .utility) {
            let directory = home.appendingPathComponent(directoryPath, isDirectory: true)
            guard directory.resolvingSymlinksInPath() == home.resolvingSymlinksInPath().appendingPathComponent(directoryPath) else {
                throw GenerationRequestError.storage("Generation input storage cannot traverse symbolic links.")
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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
        let file = try ProjectLocalFile.resolve(manifestPath(package.id), dataRoot: home)
        let record = try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
        guard record.packageID == package.id, record.paths.count == package.payload.references.count else {
            throw GenerationRequestError.storage("The generation input archive is incomplete.")
        }
        let sources = try package.payload.references.map { reference -> GenerationReferenceSnapshot.Source in
            guard let asset = editor.mediaAssets.first(where: { $0.id == reference.assetID }),
                  asset.type.rawValue == reference.type else {
                throw GenerationRequestError.gate("An approved generation reference is no longer in the project.")
            }
            return .init(assetID: asset.id, displayName: reference.displayName, type: reference.type, url: asset.url)
        }
        let urls = try record.paths.map { try ProjectLocalFile.resolve($0, dataRoot: home) }
        let snapshot = try await GenerationReferenceSnapshot.capture(sources: sources, submittedURLs: urls,
            sourceReceipts: package.payload.references)
        guard snapshot.receipts == package.payload.references else {
            throw GenerationRequestError.gate("The saved generation inputs differ from their approved bytes.")
        }
        try await snapshot.requireUnchanged()
        try scope.requireCurrent(editor: editor)
        return snapshot
    }

    private static func manifestPath(_ id: String) -> String { "generation-packages/\(id).inputs.json" }
}
