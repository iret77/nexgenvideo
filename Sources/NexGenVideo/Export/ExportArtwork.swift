import AppKit
import AVFoundation
import ImageIO
import NexGenEngine
import UniformTypeIdentifiers

struct ExportArtworkSelection: Codable, Sendable, Equatable {
    enum Source: String, Codable, Sendable { case filmFrame, projectImage }
    let source: Source
    let timelineSHA256: String
    let frame: Int?
    let assetID: String?
    let sourceSHA256: String?
    let displayName: String
}

struct ExportArtworkSnapshot: Codable, Sendable, Equatable {
    let schema: String
    let selection: ExportArtworkSelection
    let pngPath: String
    let pngSHA256: String
    let width: Int
    let height: Int
}

enum ExportArtwork {
    static let schema = "export-artwork/v1"
    static let directory = "delivery/artwork"

    static func outputURL(for video: URL) -> URL {
        video.deletingPathExtension().appendingPathExtension("poster.png")
    }

    @MainActor static func filmFrame(editor: EditorViewModel) throws -> ExportArtworkSelection {
        guard editor.timeline.totalFrames > 0 else { throw ToolError("Add video to the timeline before choosing an export image.") }
        let frame = min(max(0, editor.currentFrame), editor.timeline.totalFrames - 1)
        return .init(source: .filmFrame, timelineSHA256: try timelineHash(editor.timeline), frame: frame,
            assetID: nil, sourceSHA256: nil, displayName: "Film frame \(frame)")
    }

    @MainActor static func projectImage(asset: MediaAsset, editor: EditorViewModel) async throws -> ExportArtworkSelection {
        guard asset.type == .image, let url = editor.mediaResolver.resolveURL(for: asset.id) else {
            throw ToolError("The selected project image is unavailable.")
        }
        let owner = editor.openWorkingCopyKey
        let timelineSHA256 = try timelineHash(editor.timeline)
        let hash = try await Task.detached(priority: .utility) { try FileDigest.sha256(of: url) }.value
        guard owner == editor.openWorkingCopyKey, timelineSHA256 == (try timelineHash(editor.timeline)) else {
            throw ToolError("The film changed while choosing its export image. Choose the image again.")
        }
        return .init(source: .projectImage, timelineSHA256: timelineSHA256, frame: nil, assetID: asset.id,
            sourceSHA256: hash, displayName: asset.libraryDisplayName)
    }

    @MainActor static func prepare(_ selection: ExportArtworkSelection, editor: EditorViewModel) async throws -> [String] {
        try Task.checkCancellation()
        guard let home = editor.workingRoot,
              let owner = editor.openWorkingCopyKey else { throw ToolError("Open a project before preparing an export image.") }
        _ = try ProjectPackGate.requireLiveMutation(projectURL: home, declaredPack: editor.declaredPluginName,
            declaredBinding: editor.declaredPluginBinding, declaredProductionContract: editor.declaredProductionContract)
        let root = try ExportDataRoot.resolve(in: home)
        let timeline = editor.timeline
        let resolver = editor.mediaResolver.snapshot()
        guard selection.timelineSHA256 == (try timelineHash(timeline)) else {
            throw ToolError("The film changed after its export image was chosen. Choose the image again.")
        }
        let cgImage: CGImage
        switch selection.source {
        case .filmFrame:
            guard let frame = selection.frame, frame >= 0, frame < timeline.totalFrames else {
                throw ToolError("The selected export frame is outside the film.")
            }
            let result = try await CompositionBuilder.build(timeline: timeline,
                resolveURL: { resolver.resolveURL(for: $0) }, renderSize: CGSize(width: timeline.width, height: timeline.height))
            guard result.offlineMediaRefs.isEmpty, result.unprocessableMediaRefs.isEmpty else {
                throw ToolError("The export frame contains unavailable media. Relink the film sources first.")
            }
            let generator = AVAssetImageGenerator(asset: result.composition)
            generator.videoComposition = result.videoComposition
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let image = try await generator.image(at: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(timeline.fps))).image
            guard let opaque = OpaqueImage.flatten(image) else { throw ToolError("The export frame could not be rendered.") }
            cgImage = opaque
        case .projectImage:
            guard let id = selection.assetID, let url = resolver.resolveURL(for: id) else {
                throw ToolError("The selected export image is offline.")
            }
            let bytes = try Data(contentsOf: url)
            guard FileDigest.sha256(of: bytes) == selection.sourceSHA256,
                  let image = CGImageSourceCreateWithData(bytes as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  let decoded = CGImageSourceCreateThumbnailAtIndex(image, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(width, height),
                  ] as CFDictionary) else {
                throw ToolError("The selected export image changed or is unreadable. Choose it again.")
            }
            cgImage = decoded
        }
        guard let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]),
              owner == editor.openWorkingCopyKey, editor.workingRoot == home,
              selection.timelineSHA256 == (try timelineHash(editor.timeline)) else {
            throw ToolError("The film changed while preparing its export image.")
        }
        let hash = FileDigest.sha256(of: png)
        let pngPath = "\(directory)/\(hash).png"
        let snapshot = ExportArtworkSnapshot(schema: schema, selection: selection, pngPath: pngPath,
            pngSHA256: hash, width: cgImage.width, height: cgImage.height)
        let data = try PipelineAssemblyStore.canonical(snapshot)
        let path = "\(directory)/\(FileDigest.sha256(of: data)).v1.json"
        _ = try ProjectPackGate.requireLiveMutation(projectURL: home, declaredPack: editor.declaredPluginName,
            declaredBinding: editor.declaredPluginBinding, declaredProductionContract: editor.declaredProductionContract)
        guard try ExportDataRoot.resolve(in: home) == root else {
            throw ToolError("The project changed while preparing its export image.")
        }
        let folder = root.appendingPathComponent(directory)
        guard folder.resolvingSymlinksInPath() == root.resolvingSymlinksInPath().appendingPathComponent(directory) else {
            throw ToolError("Export artwork cannot traverse symbolic links.")
        }
        try Task.checkCancellation()
        try ProjectWorkingCopy.markDirty(key: owner)
        if !FileManager.default.fileExists(atPath: root.path) {
            _ = try ProjectLocalFile.ensureDirectory(DataRootResolver.pipelineDirname, dataRoot: home)
        }
        _ = try ProjectLocalFile.ensureDirectory(directory, dataRoot: root)
        try writeImmutable(png, to: root.appendingPathComponent(pngPath))
        try writeImmutable(data, to: root.appendingPathComponent(path))
        editor.onPipelineChanged?()
        return [path, pngPath]
    }

    static func load(spec: DeliverySpecV1, dataRoot: URL, timelineSHA256: String) throws -> ExportArtworkSnapshot? {
        let paths = spec.extensionRefs.filter { $0.hasPrefix(directory + "/") && $0.hasSuffix(".v1.json") }
        guard spec.extensionRefs.contains(where: { $0.hasPrefix(directory + "/") }) else { return nil }
        guard paths.count == 1 else { throw ToolError("A video export can bind only one poster image.") }
        let bytes = try Data(contentsOf: ProjectLocalFile.resolve(paths[0], dataRoot: dataRoot))
        let snapshot = try JSONDecoder().decode(ExportArtworkSnapshot.self, from: bytes)
        guard paths[0] == "\(directory)/\(FileDigest.sha256(of: bytes)).v1.json",
              snapshot.schema == schema, snapshot.selection.timelineSHA256 == timelineSHA256,
              snapshot.pngSHA256.count == 64, snapshot.pngSHA256.allSatisfy({ $0.isHexDigit }),
              snapshot.pngPath == "\(directory)/\(snapshot.pngSHA256).png",
              spec.extensionRefs.filter({ $0.hasPrefix(directory + "/") }).sorted() == [paths[0], snapshot.pngPath].sorted() else {
            throw ToolError("The export image is not bound to this film and delivery.")
        }
        switch snapshot.selection.source {
        case .filmFrame:
            guard let frame = snapshot.selection.frame, frame >= 0,
                  snapshot.selection.assetID == nil, snapshot.selection.sourceSHA256 == nil else {
                throw ToolError("The export image has an invalid film-frame binding.")
            }
        case .projectImage:
            guard let id = snapshot.selection.assetID, !id.isEmpty, snapshot.selection.frame == nil,
                  let hash = snapshot.selection.sourceSHA256, hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) else {
                throw ToolError("The export image has an invalid project-image binding.")
            }
        }
        try verifyPNG(at: ProjectLocalFile.resolve(snapshot.pngPath, dataRoot: dataRoot), snapshot: snapshot)
        return snapshot
    }

    static func verifyPNG(at url: URL, snapshot: ExportArtworkSnapshot) throws {
        let bytes = try Data(contentsOf: url)
        guard FileDigest.sha256(of: bytes) == snapshot.pngSHA256,
              let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == snapshot.width, image.height == snapshot.height,
              image.width > 0, image.height > 0 else {
            throw ToolError("The bound export poster is missing, changed or unreadable.")
        }
    }

    static func timelineHash(_ timeline: Timeline) throws -> String {
        FileDigest.sha256(of: try PipelineAssemblyStore.canonical(timeline))
    }

    private static func writeImmutable(_ data: Data, to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            guard try Data(contentsOf: url) == data else { throw ToolError("An immutable export image snapshot changed.") }
        } else { try data.write(to: url, options: .atomic) }
    }
}
