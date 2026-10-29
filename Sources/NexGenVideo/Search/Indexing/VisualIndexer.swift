import CoreGraphics
import Foundation
import ImageIO

/// Indexes one asset: sampled frames → embeddings → EmbeddingStore. Idempotent per (file, model, sampler).
enum VisualIndexer {
    enum IndexError: LocalizedError {
        case unreadableImage, noFrames, sourceChanged, sourceUnavailable
        var errorDescription: String? {
            switch self {
            case .unreadableImage: "The image could not be decoded. Check the file, then retry indexing."
            case .noFrames: "No video frames could be decoded. Check the file, then retry indexing."
            case .sourceChanged: "The media changed during indexing. Retry with the current file."
            case .sourceUnavailable: "The source file is unavailable. Relink it, then retry indexing."
            }
        }
    }

    static func needsIndex(url: URL, spec: VisualEmbedder.Spec) -> Bool {
        guard let key = EmbeddingStore.key(for: url) else { return true }
        return !EmbeddingStore.isCurrent(
            key: key, model: spec.model, modelVersion: spec.version,
            samplerVersion: FrameSampler.samplerVersion, dimension: spec.embeddingDim
        )
    }

    static func index(
        url: URL,
        duration: Double,
        model: VisualEmbedder,
        options: FrameSampler.Options = .init(),
        progress: (@Sendable (Double) -> Void)? = nil,
        force: Bool = false
    ) async throws {
        guard let key = EmbeddingStore.key(for: url) else { throw IndexError.sourceUnavailable }
        let spec = model.spec
        guard force || needsIndex(url: url, spec: spec) else { return }

        var times: [Double] = []
        var shotIndices: [Int] = []
        var shotStarts: [Double] = []
        var vectors: [Float] = []

        for try await frame in FrameSampler.frames(url: url, duration: duration, options: options) {
            try Task.checkCancellation()
            try await ExportCoordinator.waitWhileExportActive()
            if frame.isNewShot {
                shotStarts.append(shotStarts.isEmpty ? 0 : frame.time)
            }
            vectors += try model.encode(image: frame.image)
            times.append(frame.time)
            shotIndices.append(shotStarts.count - 1)
            if duration > 0 { progress?(min(frame.time / duration, 1)) }
        }
        try Task.checkCancellation()
        let rows = zip(times, shotIndices).map { time, shot in
            EmbeddingStore.Row(
                time: time,
                shotStart: shotStarts[shot],
                shotEnd: shot + 1 < shotStarts.count ? shotStarts[shot + 1] : duration
            )
        }
        guard !rows.isEmpty else { throw IndexError.noFrames }
        guard EmbeddingStore.key(for: url) == key else { throw IndexError.sourceChanged }
        try save(rows: rows, vectors: vectors, spec: spec, key: key)
    }

    /// Stills skip the sampler: one embedding, zero-length shot range.
    static func indexImage(url: URL, model: VisualEmbedder, force: Bool = false) async throws {
        guard let key = EmbeddingStore.key(for: url) else { throw IndexError.sourceUnavailable }
        guard force || needsIndex(url: url, spec: model.spec) else { return }
        try await ExportCoordinator.waitWhileExportActive()

        let image = try requireImage(url)
        let vectors = try model.encode(image: image)
        let rows = [EmbeddingStore.Row(time: 0, shotStart: 0, shotEnd: 0)]
        try Task.checkCancellation()
        guard EmbeddingStore.key(for: url) == key else { throw IndexError.sourceChanged }
        try save(rows: rows, vectors: vectors, spec: model.spec, key: key)
    }

    static func requireImage(_ url: URL) throws -> CGImage {
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 512,
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { throw IndexError.unreadableImage }
        return image
    }

    private static func save(rows: [EmbeddingStore.Row], vectors: [Float], spec: VisualEmbedder.Spec, key: String) throws {
        let header = EmbeddingStore.Header(
            model: spec.model, modelVersion: spec.version,
            samplerVersion: FrameSampler.samplerVersion,
            dim: spec.embeddingDim, count: rows.count
        )
        try EmbeddingStore.save(header: header, rows: rows, vectors: vectors, key: key)
    }
}
