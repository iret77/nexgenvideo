import Foundation
import NexGenEngine

struct GenerationReferenceReceipt: Codable, Sendable, Equatable {
    let assetID: String
    let type: String
    let sourceSHA256: String
    let submittedSHA256: String
}

final class GenerationReferenceSnapshot: Sendable {
    struct Source: Sendable {
        let assetID: String
        let type: String
        let url: URL
    }
    let sources: [Source]
    let urls: [URL]
    let receipts: [GenerationReferenceReceipt]
    private let directory: URL

    private init(sources: [Source], urls: [URL], receipts: [GenerationReferenceReceipt], directory: URL) {
        self.sources = sources
        self.urls = urls
        self.receipts = receipts
        self.directory = directory
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    static func capture(sources: [Source], submittedURLs: [URL]? = nil,
                        sourceReceipts: [GenerationReferenceReceipt]? = nil) async throws -> GenerationReferenceSnapshot {
        try Task.checkCancellation()
        let result = try await Task.detached(priority: .utility) {
            let inputs = submittedURLs ?? sources.map(\.url)
            guard inputs.count == sources.count, sourceReceipts == nil || sourceReceipts?.count == sources.count else {
                throw GenerationRequestError.optionsInvalid("Reference preparation changed the input count.")
            }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ngv-inputs-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            do {
                var urls: [URL] = []
                var receipts: [GenerationReferenceReceipt] = []
                for (index, input) in inputs.enumerated() {
                    try Task.checkCancellation()
                    let properties = try input.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard input.isFileURL, properties.isRegularFile == true, properties.isSymbolicLink != true else {
                        throw GenerationRequestError.optionsInvalid("A generation reference must be a regular local file.")
                    }
                    let destination = directory.appendingPathComponent(String(index)).appendingPathExtension(input.pathExtension)
                    try FileManager.default.copyItem(at: input, to: destination)
                    let hash = try FileDigest.sha256(of: destination)
                    guard hash == (try FileDigest.sha256(of: input)) else {
                        throw GenerationRequestError.optionsInvalid("A reference changed while its generation snapshot was prepared. Prepare the request again.")
                    }
                    try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: destination.path)
                    urls.append(destination)
                    receipts.append(.init(assetID: sources[index].assetID, type: sources[index].type,
                        sourceSHA256: sourceReceipts?[index].sourceSHA256 ?? hash, submittedSHA256: hash))
                }
                return GenerationReferenceSnapshot(sources: sources, urls: urls, receipts: receipts, directory: directory)
            } catch {
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
        }.value
        try Task.checkCancellation()
        return result
    }

    func requireUnchanged() async throws {
        try Task.checkCancellation()
        try await Task.detached(priority: .utility) { [self] in
            for index in sources.indices {
                try Task.checkCancellation()
                guard try FileDigest.sha256(of: sources[index].url) == receipts[index].sourceSHA256,
                      FileDigest.sha256(of: urls[index]) == receipts[index].submittedSHA256 else {
                    throw GenerationRequestError.optionsInvalid("An approved reference changed. Prepare and approve the request again.")
                }
            }
        }.value
        try Task.checkCancellation()
    }

    @MainActor
    func requireIdentity(_ references: [MediaAsset]) throws {
        guard references.count == sources.count,
              zip(references, sources).allSatisfy({ pair in
                  pair.0.id == pair.1.assetID && pair.0.type.rawValue == pair.1.type && pair.0.url == pair.1.url
              }) else {
            throw GenerationRequestError.optionsInvalid("The request's reference selection changed after preparation.")
        }
    }

    @MainActor
    static func prepare(references: [MediaAsset], trim: TrimmedSource? = nil,
                        preprocess: (@Sendable (Int, MediaAsset) async throws -> URL?)? = nil,
                        preUploadedURLs: [String]? = nil) async throws -> GenerationReferenceSnapshot {
        let sources = references.map { Source(assetID: $0.id, type: $0.type.rawValue, url: $0.url) }
        if let preUploadedURLs, !preUploadedURLs.isEmpty {
            guard preUploadedURLs == sources.map({ $0.url.path }) else {
                throw GenerationRequestError.optionsInvalid("Generation approval requires local reference bytes. Import remote references before generating.")
            }
        }
        let original = try await capture(sources: sources)
        try original.requireIdentity(references)
        var transformed = original.urls
        var temporary: [URL] = []
        defer {
            for url in temporary where !original.urls.contains(url) { try? FileManager.default.removeItem(at: url) }
        }
        if let trim, trim.hasTrim {
            guard let first = sources.first, trim.sourceURL == first.url, let frozen = original.urls.first else {
                throw GenerationRequestError.optionsInvalid("The trimmed source does not match the first generation reference.")
            }
            let value = try await VideoTrimExtractor.extract(.init(sourceURL: frozen, trimStartFrame: trim.trimStartFrame,
                trimEndFrame: trim.trimEndFrame, sourceFramesConsumed: trim.sourceFramesConsumed, fps: trim.fps))
            transformed[0] = value
            temporary.append(value)
        }
        if let preprocess {
            for (index, asset) in references.enumerated() {
                let frozen = MediaAsset(id: asset.id, url: transformed[index], type: asset.type, name: asset.name,
                    duration: asset.duration, generationInput: asset.generationInput)
                if let replacement = try await preprocess(index, frozen) {
                    transformed[index] = replacement
                    temporary.append(replacement)
                }
            }
        }
        let result: GenerationReferenceSnapshot
        if transformed == original.urls { result = original }
        else { result = try await capture(sources: sources, submittedURLs: transformed, sourceReceipts: original.receipts) }
        try result.requireIdentity(references)
        try await result.requireUnchanged()
        return result
    }
}
