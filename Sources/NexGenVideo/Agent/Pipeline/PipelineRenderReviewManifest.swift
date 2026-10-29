import Foundation
import ImageIO
import NexGenEngine
import UniformTypeIdentifiers

struct PipelineRenderReviewManifest: Codable, Sendable, Equatable {
    static let schemaVersion = "render-review-manifest/v2"
    static let maximumObservationUTF8Bytes = 512
    static let maximumImagesPerPage = 2
    static let maximumItemsPerPage = 8
    static let maximumResultBytes = 12 * 1_024 * 1_024
    static let maximumEstimatedInputTokens = 16_000
    static let maximumMCPOutputTokens = 25_000
    static let reservedInputTokens = 4_096
    static let maximumTextSegmentBytes = 512

    struct TextSource: Codable, Sendable, Equatable {
        let id: String
        let label: String
        let shotIDs: [String]
        let utf8Bytes: Int
        let sha256: String
        let segmentItemIDs: [String]
    }

    struct TextSegment: Codable, Sendable, Equatable {
        let sourceID: String
        let ordinal: Int
        let count: Int
        let utf8Offset: Int
        let text: String
    }

    struct ImageMapping: Codable, Sendable, Equatable {
        enum Usage: String, Codable, Sendable { case evidence, conditioning, permittedOriginalReference }
        let id: String
        let shotID: String
        let usage: Usage
        let ordinal: Int
        let source: CanonicalArtifactReferenceV1
        let derivativeID: String
    }

    struct Derivative: Codable, Sendable, Equatable {
        let id: String
        let reference: CanonicalArtifactReferenceV1
        let mediaType: String
        let byteCount: Int
        let encodedJSONPayloadBytes: Int
        let width: Int
        let height: Int
    }

    struct SourceEncoding: Codable, Sendable, Equatable {
        enum Mode: String, Codable, Sendable { case passthrough, jpegThumbnail }
        static let algorithm = "ngv.imageio-review-thumbnail-1568-jpeg-85-70-55-40/v1"
        let encoder: String
        let sourceSHA256: String
        let sourceByteCount: Int
        let sourceType: String
        let sourceWidth: Int
        let sourceHeight: Int
        let derivativeID: String
        let mode: Mode
    }

    struct Relation: Codable, Sendable, Equatable {
        enum Kind: String, Codable, Sendable { case adjacent, predecessor }
        let edgeID: String
        let kind: Kind
        let fromShotID: String
        let toShotID: String
        let strategy: String?
        let pairOrdinal: Int
        let pairCount: Int
        let fromImageID: String?
        let toImageID: String?
        let context: [TextSegment]
        let limitation: String
    }

    struct Item: Codable, Sendable, Equatable {
        enum Kind: String, Codable, Sendable { case textSegment, image, relation }
        let id: String
        let kind: Kind
        let shotIDs: [String]
        let textSegment: TextSegment?
        let mappingIDs: [String]
        let imageIDs: [String]
        let relation: Relation?
    }

    struct Page: Codable, Sendable, Equatable {
        let id: String
        let itemIDs: [String]
        let imageIDs: [String]
        let estimatedInputTokens: Int
        let resultByteCount: Int
    }

    struct Prepared: Sendable {
        struct File: Sendable {
            let reference: CanonicalArtifactReferenceV1
            let url: URL
        }
        let manifest: PipelineRenderReviewManifest
        let reference: CanonicalArtifactReferenceV1
        let files: [File]
        private let directory: URL

        fileprivate init(manifest: PipelineRenderReviewManifest, reference: CanonicalArtifactReferenceV1,
                         files: [File], directory: URL) {
            self.manifest = manifest
            self.reference = reference
            self.files = files
            self.directory = directory
        }

        func discard() { try? FileManager.default.removeItem(at: directory) }
    }

    let schema: String
    let id: String
    let snapshot: PipelineRenderReviewWriter.Snapshot
    let textSources: [TextSource]
    let mappings: [ImageMapping]
    let derivatives: [Derivative]
    let sourceEncodings: [SourceEncoding]
    let items: [Item]
    let pages: [Page]

    func page(id: String) throws -> Page {
        guard let page = pages.first(where: { $0.id == id }) else { throw GateBlocked("The review page is not in this manifest.") }
        return page
    }
}

extension PipelineRenderReviewManifest {
    private struct PageTextSource: Encodable {
        let id: String
        let label: String
        let utf8Bytes: Int
        let sha256: String
        let segmentCount: Int
    }

    private struct PageImage: Encodable {
        let id: String
        let mediaType: String
        let width: Int
        let height: Int
        let byteCount: Int
    }

    private struct PageBody: Encodable {
        let manifestID: String
        let pageID: String
        let snapshotFingerprint: String
        let instructions: String
        let items: [Item]
        let textSources: [PageTextSource]
        let mappings: [ImageMapping]
        let images: [PageImage]
    }

    private func pageText(_ page: Page) throws -> String {
        let selected = try page.itemIDs.map { id -> Item in
            guard let item = items.first(where: { $0.id == id }) else { throw GateBlocked("The page includes an unknown review item.") }
            return item
        }
        let sourceIDs = Set(selected.flatMap { item in
            [item.textSegment].compactMap { $0 }.map(\.sourceID) + (item.relation?.context.map(\.sourceID) ?? [])
        })
        let mappingIDs = Set(selected.flatMap(\.mappingIDs))
        guard !selected.isEmpty, selected.count <= Self.maximumItemsPerPage,
              Set(page.itemIDs).count == selected.count,
              Self.orderedUnique(selected.flatMap(\.imageIDs)) == page.imageIDs,
              page.imageIDs.count <= Self.maximumImagesPerPage,
              mappingIDs.isSubset(of: Set(mappings.map(\.id))),
              sourceIDs.isSubset(of: Set(textSources.map(\.id))) else {
            throw GateBlocked("The page does not preserve its complete item and image bindings.")
        }
        let body = PageBody(manifestID: id, pageID: page.id, snapshotFingerprint: snapshot.fingerprint,
            instructions: "Read every labelled item. Return its exact ID and a nonempty observation of at most 512 UTF-8 bytes. "
                + "Keep relation findings bound to their edge and both shots. Text segments preserve original order and byte offsets; "
                + "a segment is not the complete document. Images prove only their visible still content, never motion or sound. "
                + "Conditioning and permitted-original images are reference context, not images of the planned shot or proof of continuity. "
                + "An unavailable image or deferred predecessor recipe is not a visually inspected video.",
            items: selected, textSources: textSources.filter { sourceIDs.contains($0.id) }.map {
                .init(id: $0.id, label: $0.label, utf8Bytes: $0.utf8Bytes, sha256: $0.sha256, segmentCount: $0.segmentItemIDs.count)
            }, mappings: mappings.filter { mappingIDs.contains($0.id) }, images: try page.imageIDs.map { id in
                guard let image = derivatives.first(where: { $0.id == id }) else { throw GateBlocked("A page derivative is missing.") }
                return .init(id: image.id, mediaType: image.mediaType, width: image.width, height: image.height, byteCount: image.byteCount)
            })
        return String(decoding: try PlanningWriterIO.json(body), as: UTF8.self)
    }

    private func content(page: Page, skeleton: Bool = false, imageBytes: (String) throws -> Data) throws -> ToolResult {
        var blocks: [ToolResult.Block] = [.text(try pageText(page))]
        for id in page.imageIDs {
            guard let derivative = derivatives.first(where: { $0.id == id }) else { throw GateBlocked("A page derivative is missing.") }
            blocks.append(.text("Delivered image SHA256: " + id))
            let bytes: Data
            if !skeleton {
                bytes = try imageBytes(id)
                try Self.requireDerivative(derivative, bytes: bytes)
            } else { bytes = Data() }
            blocks.append(.image(base64: bytes.base64EncodedString(), mediaType: derivative.mediaType))
        }
        return ToolResult(content: blocks, isError: false)
    }

    private static func measure(_ result: ToolResult, images: [Derivative], skeleton: Bool = false) throws -> (tokens: Int, bytes: Int) {
        let textBytes = result.content.reduce(0) { sum, block in
            if case .text(let value) = block { return sum + value.utf8.count }
            return sum
        }
        let imageTokens = images.reduce(0) { $0 + (($1.width * $1.height + 749) / 750) + 256 }
        let encodedBytes = try JSONEncoder().encode(result.toMCPResult()).count
        let base64Bytes = skeleton ? images.reduce(0) { $0 + $1.encodedJSONPayloadBytes } : 0
        return (reservedInputTokens + textBytes + imageTokens, encodedBytes + base64Bytes)
    }

    private func paginate(imageBytes: (String) throws -> Data) throws -> [Page] {
        var pages: [Page] = []
        var pending: [Item] = []

        func measured(_ values: [Item]) throws -> Page? {
            let imageIDs = Self.orderedUnique(values.flatMap(\.imageIDs))
            guard imageIDs.count <= Self.maximumImagesPerPage, values.count <= Self.maximumItemsPerPage else { return nil }
            let itemIDs = values.map(\.id)
            let id = try Self.digest([snapshot.fingerprint] + itemIDs + ["images"] + imageIDs)
            let page = Page(id: id, itemIDs: itemIDs, imageIDs: imageIDs, estimatedInputTokens: 0, resultByteCount: 0)
            let measurement = try Self.measure(content(page: page, skeleton: true, imageBytes: { _ in Data() }),
                images: imageIDs.compactMap { id in derivatives.first { $0.id == id } }, skeleton: true)
            guard measurement.tokens <= Self.maximumEstimatedInputTokens,
                  measurement.tokens <= Self.maximumMCPOutputTokens,
                  measurement.bytes + 1_024 <= Self.maximumResultBytes else { return nil }
            return .init(id: id, itemIDs: itemIDs, imageIDs: imageIDs,
                estimatedInputTokens: measurement.tokens, resultByteCount: measurement.bytes)
        }

        for item in items {
            try Task.checkCancellation()
            if try measured(pending + [item]) != nil {
                pending.append(item)
            } else {
                if !pending.isEmpty, let completed = try measured(pending) { pages.append(completed) }
                guard try measured([item]) != nil else {
                    throw GateBlocked("Review item \(item.id) cannot fit the image, byte or token bounds. Its contents have not been truncated.")
                }
                pending = [item]
            }
        }
        if !pending.isEmpty, let completed = try measured(pending) { pages.append(completed) }
        guard pages.flatMap(\.itemIDs) == items.map(\.id),
              Set(pages.flatMap(\.imageIDs)) == Set(derivatives.map(\.id)) else {
            throw GateBlocked("Review pagination did not cover every item and image.")
        }
        for page in pages {
            try Task.checkCancellation()
            let actual = try Self.measure(content(page: page, imageBytes: imageBytes),
                images: page.imageIDs.compactMap { id in derivatives.first { $0.id == id } })
            guard actual.tokens == page.estimatedInputTokens, actual.bytes == page.resultByteCount else {
                throw GateBlocked("The actual encoded review result exceeds its planned transport representation.")
            }
        }
        return pages
    }
}

extension PipelineRenderReviewManifest {
    static func prepare(snapshot: PipelineRenderReviewWriter.Snapshot, dataRoot: URL) throws -> Prepared {
        try Task.checkCancellation()
        try PipelineRenderReviewWriter.requireSnapshot(snapshot, root: dataRoot)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("render-review-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        do {
            var files: [Prepared.File] = []
            var derivatives: [Derivative] = []
            var sourceEncodings: [SourceEncoding] = []
            var bySourceHash: [String: Derivative] = [:]
            for occurrence in try imageOccurrences(snapshot) {
                try Task.checkCancellation()
                let source = occurrence.source
                let sourceURL = try ProjectLocalFile.requireHash(source.sha256, at: source.path, dataRoot: dataRoot)
                if bySourceHash[source.sha256] == nil {
                    let sourceBytes = try Data(contentsOf: sourceURL)
                    guard FileDigest.sha256(of: sourceBytes) == source.sha256 else {
                        throw GateBlocked("A captured image changed before review encoding.")
                    }
                    let encoded = try encode(sourceBytes)
                    let derivative = encoded.derivative
                    sourceEncodings.append(encoded.sourceEncoding)
                    bySourceHash[source.sha256] = derivative
                    if !derivatives.contains(where: { $0.id == derivative.id }) {
                        let url = directory.appendingPathComponent(derivative.id)
                        try encoded.bytes.write(to: url, options: .atomic)
                        files.append(.init(reference: derivative.reference, url: url))
                        derivatives.append(derivative)
                    }
                }
            }
            let mappings = try imageMappings(snapshot: snapshot, derivativeIDsBySourceHash: bySourceHash.mapValues(\.id))
            let urls = Dictionary(uniqueKeysWithValues: files.map { ($0.reference.sha256, $0.url) })
            let manifest = try plan(snapshot: snapshot, mappings: mappings, derivatives: derivatives, sourceEncodings: sourceEncodings) { id in
                guard let url = urls[id] else { throw GateBlocked("The prepared review image is missing.") }
                return try Data(contentsOf: url)
            }
            try PipelineRenderReviewWriter.requireSnapshot(snapshot, root: dataRoot)
            for mapping in mappings { _ = try ProjectLocalFile.requireHash(mapping.source.sha256, at: mapping.source.path, dataRoot: dataRoot) }
            try Task.checkCancellation()
            let bytes = try PlanningWriterIO.json(manifest)
            let reference = PlanningWriterIO.reference("render-review/manifests/\(manifest.id).v2.json",
                id: manifest.id, role: "host.render-review-manifest", bytes: bytes)
            let url = directory.appendingPathComponent("manifest.json")
            try bytes.write(to: url, options: .atomic)
            files.append(.init(reference: reference, url: url))
            try Task.checkCancellation()
            return Prepared(manifest: manifest, reference: reference, files: files, directory: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    static func verify(manifest: Self, snapshot: PipelineRenderReviewWriter.Snapshot, dataRoot: URL) throws {
        try Task.checkCancellation()
        guard try PlanningWriterIO.json(manifest.snapshot) == PlanningWriterIO.json(snapshot) else {
            throw GateBlocked("The manifest belongs to another review snapshot.")
        }
        try PipelineRenderReviewWriter.requireSnapshot(snapshot, root: dataRoot)
        try manifest.requireSourceEncodings(dataRoot: dataRoot)
        try manifest.requirePlan { id in
            guard let derivative = manifest.derivatives.first(where: { $0.id == id }) else {
                throw GateBlocked("A review derivative is missing.")
            }
            return try derivativeBytes(derivative, dataRoot: dataRoot)
        }
        try PipelineRenderReviewWriter.requireSnapshot(snapshot, root: dataRoot)
    }

    func requireSourceEncodings(dataRoot: URL) throws {
        var validatedSources = Set<String>()
        for mapping in mappings {
            let source = mapping.source
            let url = try ProjectLocalFile.requireHash(source.sha256, at: source.path, dataRoot: dataRoot)
            guard let record = sourceEncodings.first(where: { $0.sourceSHA256 == source.sha256 }),
                  record.encoder == SourceEncoding.algorithm, record.derivativeID == mapping.derivativeID,
                  let derivative = derivatives.first(where: { $0.id == record.derivativeID }) else {
                throw GateBlocked("A review image has no exact host encoder provenance.")
            }
            if validatedSources.insert(source.sha256).inserted {
                let bytes = try Data(contentsOf: url)
                guard FileDigest.sha256(of: bytes) == source.sha256 else { throw GateBlocked("A review source changed while reading it.") }
                let sourceDimensions = try Self.dimensions(bytes, maximumEdge: nil)
                let delivered = try Self.derivativeBytes(derivative, dataRoot: dataRoot)
                guard bytes.count == record.sourceByteCount, sourceDimensions.type == record.sourceType,
                      sourceDimensions.width == record.sourceWidth, sourceDimensions.height == record.sourceHeight else {
                    throw GateBlocked("The source bytes or decoded dimensions differ from the host encoder provenance.")
                }
                switch record.mode {
                case .passthrough:
                    guard bytes == delivered, derivative.id == record.sourceSHA256 else {
                        throw GateBlocked("A passthrough review image differs from its exact source bytes.")
                    }
                case .jpegThumbnail:
                    guard derivative.mediaType == "image/jpeg", derivative.id != record.sourceSHA256 else {
                        throw GateBlocked("The recorded review thumbnail is not its encoded JPEG derivative.")
                    }
                }
            }
        }
        guard Self.orderedUnique(mappings.map { $0.source.sha256 }) == sourceEncodings.map(\.sourceSHA256) else {
            throw GateBlocked("The review does not preserve every source encoder record exactly once.")
        }
    }

    func pageContent(pageID: String, dataRoot: URL) throws -> ToolResult {
        try Task.checkCancellation()
        let page = try page(id: pageID)
        let result = try content(page: page) { id in
            guard let derivative = derivatives.first(where: { $0.id == id }) else { throw GateBlocked("A page image is missing.") }
            return try Self.derivativeBytes(derivative, dataRoot: dataRoot)
        }
        let measurement = try Self.measure(result, images: page.imageIDs.compactMap { id in derivatives.first { $0.id == id } })
        guard measurement.tokens == page.estimatedInputTokens, measurement.bytes == page.resultByteCount,
              measurement.tokens <= Self.maximumEstimatedInputTokens, measurement.tokens <= Self.maximumMCPOutputTokens,
              measurement.bytes + 1_024 <= Self.maximumResultBytes else {
            throw GateBlocked("The review page no longer matches its bounded manifest.")
        }
        return result
    }

    func requirePlan(imageBytes: (String) throws -> Data) throws {
        let rebuilt = try Self.plan(snapshot: snapshot, mappings: mappings, derivatives: derivatives,
            sourceEncodings: sourceEncodings, imageBytes: imageBytes)
        guard try PlanningWriterIO.json(rebuilt) == PlanningWriterIO.json(self) else {
            throw GateBlocked("The review manifest omitted or changed its deterministic coverage.")
        }
    }

    struct EncodedImage: Sendable {
        let derivative: Derivative
        let bytes: Data
        let sourceEncoding: SourceEncoding
    }

    static func encode(_ source: Data) throws -> EncodedImage {
        try Task.checkCancellation()
        guard let input = CGImageSourceCreateWithData(source as CFData, nil), CGImageSourceGetCount(input) == 1,
              let encoded = ImageEncoder.encode(data: source) else {
            throw GateBlocked("Review requires a decodable single-frame image; extract an explicit still from animated media first.")
        }
        let dimensions = try dimensions(encoded.data)
        let sourceDimensions = try Self.dimensions(source, maximumEdge: nil)
        let fileExtension: String
        switch encoded.mime {
        case "image/png": fileExtension = "png"
        case "image/jpeg": fileExtension = "jpg"
        case "image/gif": fileExtension = "gif"
        case "image/webp": fileExtension = "webp"
        default: throw GateBlocked("The encoded review image format is unsupported.")
        }
        let hash = FileDigest.sha256(of: encoded.data)
        let reference = PlanningWriterIO.reference("render-review/input-images/\(hash).\(fileExtension)",
            id: "model-image." + hash, role: "host.render-review-delivered-image", bytes: encoded.data)
        return .init(derivative: .init(id: hash, reference: reference, mediaType: encoded.mime,
            byteCount: encoded.data.count, encodedJSONPayloadBytes: try encodedPayloadBytes(encoded.data, mediaType: encoded.mime),
            width: dimensions.width, height: dimensions.height), bytes: encoded.data,
            sourceEncoding: .init(encoder: SourceEncoding.algorithm, sourceSHA256: FileDigest.sha256(of: source),
                sourceByteCount: source.count, sourceType: sourceDimensions.type, sourceWidth: sourceDimensions.width,
                sourceHeight: sourceDimensions.height, derivativeID: hash, mode: source == encoded.data ? .passthrough : .jpegThumbnail))
    }

    private static func dimensions(_ bytes: Data, maximumEdge: Int? = ImageEncoder.maxLongestEdge) throws -> (width: Int, height: Int, type: String) {
        guard let image = CGImageSourceCreateWithData(bytes as CFData, nil), CGImageSourceGetCount(image) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, maximumEdge.map({ max(width, height) <= $0 }) ?? true,
              let type = CGImageSourceGetType(image) as String?,
              let decoded = CGImageSourceCreateImageAtIndex(image, 0, nil), decoded.width == width, decoded.height == height else {
            throw GateBlocked("The delivered review image has invalid dimensions or cannot be decoded.")
        }
        return (width, height, type)
    }

    private static func derivativeBytes(_ derivative: Derivative, dataRoot: URL) throws -> Data {
        let url = try ProjectLocalFile.requireHash(derivative.reference.sha256, at: derivative.reference.path, dataRoot: dataRoot)
        let bytes = try Data(contentsOf: url)
        try requireDerivative(derivative, bytes: bytes)
        return bytes
    }

    private static func requireDerivative(_ derivative: Derivative, bytes: Data) throws {
        let dimensions = try dimensions(bytes)
        guard FileDigest.sha256(of: bytes) == derivative.id, derivative.reference.sha256 == derivative.id,
              bytes.count == derivative.byteCount, bytes.count <= ImageEncoder.maxBytes,
              [UTType.png.identifier: "image/png", UTType.jpeg.identifier: "image/jpeg", UTType.gif.identifier: "image/gif",
               UTType.webP.identifier: "image/webp"][dimensions.type] == derivative.mediaType,
              try encodedPayloadBytes(bytes, mediaType: derivative.mediaType) == derivative.encodedJSONPayloadBytes,
              dimensions.width == derivative.width, dimensions.height == derivative.height else {
            throw GateBlocked("The delivered image bytes or dimensions differ from the review manifest.")
        }
    }

    private static func encodedPayloadBytes(_ bytes: Data, mediaType: String) throws -> Int {
        let full = ToolResult(content: [.image(base64: bytes.base64EncodedString(), mediaType: mediaType)], isError: false)
        let empty = ToolResult(content: [.image(base64: "", mediaType: mediaType)], isError: false)
        return try JSONEncoder().encode(full.toMCPResult()).count - JSONEncoder().encode(empty.toMCPResult()).count
    }
}

extension PipelineRenderReviewManifest {
    private struct ImageOccurrence {
        let shotID: String
        let usage: ImageMapping.Usage
        let ordinal: Int
        let source: CanonicalArtifactReferenceV1

        func mapping(derivativeID: String) throws -> ImageMapping {
            struct Key: Encodable {
                let shotID: String
                let usage: ImageMapping.Usage
                let ordinal: Int
                let source: CanonicalArtifactReferenceV1
            }
            return .init(id: try PipelineRenderReviewManifest.digest(Key(shotID: shotID, usage: usage,
                ordinal: ordinal, source: source)), shotID: shotID, usage: usage, ordinal: ordinal,
                source: source, derivativeID: derivativeID)
        }
    }

    private static func imageOccurrences(_ snapshot: PipelineRenderReviewWriter.Snapshot) throws -> [ImageOccurrence] {
        var result: [ImageOccurrence] = []
        var paths: [String: String] = [:]
        for shot in snapshot.shots {
            for (usage, sources) in [(ImageMapping.Usage.evidence, shot.review.evidence),
                                     (.conditioning, shot.review.conditioning),
                                     (.permittedOriginalReference, shot.review.predecessor?.permittedOriginalReferences ?? [])] {
                for (ordinal, source) in sources.enumerated() {
                    guard ProjectMediaExtensions.images.contains((source.path as NSString).pathExtension.lowercased()) else { continue }
                    guard snapshot.references.contains(where: { $0.path == source.path && $0.sha256 == source.sha256 }),
                          paths[source.path].map({ $0 == source.sha256 }) ?? true else {
                        throw GateBlocked("A review image has no unambiguous exact source in the captured snapshot.")
                    }
                    paths[source.path] = source.sha256
                    result.append(.init(shotID: shot.shotID, usage: usage, ordinal: ordinal, source: source))
                }
            }
        }
        return result
    }

    static func imageMappings(snapshot: PipelineRenderReviewWriter.Snapshot,
                              derivativeIDsBySourceHash: [String: String]) throws -> [ImageMapping] {
        try imageOccurrences(snapshot).map { occurrence in
            guard let id = derivativeIDsBySourceHash[occurrence.source.sha256] else {
                throw GateBlocked("A captured review image has no encoded derivative.")
            }
            return try occurrence.mapping(derivativeID: id)
        }
    }

    static func plan(snapshot: PipelineRenderReviewWriter.Snapshot, mappings: [ImageMapping], derivatives: [Derivative], sourceEncodings: [SourceEncoding],
                     imageBytes: (String) throws -> Data) throws -> Self {
        try Task.checkCancellation()
        let shotIDs = snapshot.shots.map(\.shotID)
        guard !shotIDs.isEmpty, Set(shotIDs).count == shotIDs.count,
              shotIDs == snapshot.projection.shots.map(\.id),
              snapshot.shots.allSatisfy({ $0.shotID == $0.review.shotID }),
              mappings.count == (try imageOccurrences(snapshot)).count,
              Set(derivatives.map(\.id)).count == derivatives.count else {
            throw GateBlocked("The review manifest has inconsistent shot or image coverage.")
        }
        for (occurrence, mapping) in zip(try imageOccurrences(snapshot), mappings) {
            guard try PlanningWriterIO.json(occurrence.mapping(derivativeID: mapping.derivativeID)) == PlanningWriterIO.json(mapping) else {
                throw GateBlocked("The review manifest changed a captured image mapping.")
            }
        }
        guard orderedUnique(mappings.map(\.derivativeID)) == derivatives.map(\.id) else {
            throw GateBlocked("The review manifest omitted or inserted an image derivative.")
        }
        guard orderedUnique(mappings.map { $0.source.sha256 }) == sourceEncodings.map(\.sourceSHA256),
              sourceEncodings.allSatisfy({ record in record.encoder == SourceEncoding.algorithm
                && record.sourceByteCount > 0 && record.sourceWidth > 0 && record.sourceHeight > 0
                && mappings.filter({ $0.source.sha256 == record.sourceSHA256 }).allSatisfy({ $0.derivativeID == record.derivativeID }) }) else {
            throw GateBlocked("The review does not preserve every exact source encoder mapping.")
        }
        for derivative in derivatives { try requireDerivative(derivative, bytes: imageBytes(derivative.id)) }
        var textSources: [TextSource] = []
        var items: [Item] = []
        var shotSegments: [String: [TextSegment]] = [:]

        func appendText(label: String, shotIDs: [String], bytes: Data) throws -> [TextSegment] {
            guard let text = String(data: bytes, encoding: .utf8) else { throw GateBlocked("Review text is not valid UTF-8.") }
            let sourceID = try digest([label, FileDigest.sha256(of: bytes)])
            let chunks = splitText(text)
            var offset = 0
            var segments: [TextSegment] = []
            var itemIDs: [String] = []
            for (ordinal, chunk) in chunks.enumerated() {
                let segment = TextSegment(sourceID: sourceID, ordinal: ordinal, count: chunks.count, utf8Offset: offset, text: chunk)
                let itemID = try digest(segment)
                segments.append(segment)
                itemIDs.append(itemID)
                items.append(.init(id: itemID, kind: .textSegment, shotIDs: shotIDs, textSegment: segment,
                    mappingIDs: [], imageIDs: [], relation: nil))
                offset += chunk.utf8.count
            }
            textSources.append(.init(id: sourceID, label: label, shotIDs: shotIDs, utf8Bytes: bytes.count,
                sha256: FileDigest.sha256(of: bytes), segmentItemIDs: itemIDs))
            return segments
        }

        _ = try appendText(label: "Exact captured review snapshot JSON", shotIDs: [], bytes: PlanningWriterIO.json(snapshot))
        for shot in snapshot.shots {
            struct ShotContext: Encodable {
                let captured: PipelineRenderReviewWriter.CapturedShot
                let execution: ExecutionShotV1
                let timing: ProductionPlanProjectionV1.ShotTiming?
                let editorial: [ProductionPlanProjectionV1.EditorialBinding]
                let chain: [ProductionPlanProjectionV1.ChainBinding]
                let sourceInput: [ProductionPlanProjectionV1.SourceInputRange]
                let limitation: String
            }
            guard let execution = snapshot.projection.shots.first(where: { $0.id == shot.shotID }) else {
                throw GateBlocked("The captured shot is absent from the production plan.")
            }
            let hasImages = mappings.contains { $0.shotID == shot.shotID && $0.usage == .evidence }
            let context = ShotContext(captured: shot, execution: execution, timing: snapshot.projection.timing(for: shot.shotID),
                editorial: snapshot.projection.editorialBindings.filter { $0.shotID == shot.shotID },
                chain: snapshot.projection.chains.filter { $0.shotID == shot.shotID },
                sourceInput: snapshot.projection.sourceInputRanges.filter { $0.shotID == shot.shotID },
                limitation: hasImages ? "Only the supplied evidence stills are visible; motion and sound remain unobserved."
                    : "No evidence image is available for this shot. Conditioning and permitted-original references do not depict its planned outcome. Its video, motion and sound have not been inspected here.")
            let segments = try appendText(label: "Shot \(shot.shotID) complete captured and planned context JSON",
                shotIDs: [shot.shotID], bytes: PlanningWriterIO.json(context))
            shotSegments[shot.shotID] = segments
            let shotMappings = mappings.filter { $0.shotID == shot.shotID }
            let shotImages = orderedUnique(shotMappings.map(\.derivativeID))
            if !shotImages.isEmpty {
                for ordinal in 0..<max(shotImages.count, segments.count) {
                    let imageID = shotImages[ordinal % shotImages.count]
                    let segment = segments[ordinal % segments.count]
                    let mappingIDs = shotMappings.filter { $0.derivativeID == imageID }.map(\.id)
                    let id = try digest(["image", shot.shotID, String(ordinal), imageID, FileDigest.sha256(of: Data(segment.text.utf8))])
                    items.append(.init(id: id, kind: .image, shotIDs: [shot.shotID], textSegment: segment,
                        mappingIDs: mappingIDs, imageIDs: [imageID], relation: nil))
                }
            }
        }

        func appendRelation(kind: Relation.Kind, from: String, to: String, strategy: String?) throws {
            guard let leftContext = shotSegments[from], let rightContext = shotSegments[to] else {
                throw GateBlocked("A review relation references a missing shot.")
            }
            let leftImages = orderedUnique(mappings.filter { $0.shotID == from && $0.usage == .evidence }.map(\.derivativeID))
            let rightImages = orderedUnique(mappings.filter { $0.shotID == to && $0.usage == .evidence }.map(\.derivativeID))
            let edgeID = try digest([kind.rawValue, from, to, strategy ?? ""])
            let imagePairs = max(1, max(leftImages.count, rightImages.count))
            let textPairs = max(leftContext.count, rightContext.count)
            let count = max(imagePairs, textPairs)
            for ordinal in 0..<count {
                let left = leftImages.isEmpty ? nil : leftImages[ordinal % leftImages.count]
                let right = rightImages.isEmpty ? nil : rightImages[ordinal % rightImages.count]
                let context = [leftContext[ordinal % leftContext.count], rightContext[ordinal % rightContext.count]]
                let relation = Relation(edgeID: edgeID, kind: kind, fromShotID: from, toShotID: to, strategy: strategy,
                    pairOrdinal: ordinal, pairCount: count,
                    fromImageID: left, toImageID: right, context: context,
                    limitation: "Compare only these currently available still images and labelled context segments. "
                        + (left == nil || right == nil ? "At least one side has no image; visual continuity is not established. " : "")
                        + (kind == .predecessor ? "This is a deferred predecessor recipe, not an observed final predecessor video. " : "")
                        + "Motion and sound remain unobserved.")
                let imageIDs = orderedUnique([left, right].compactMap { $0 })
                let mappingIDs = [mappings.first { $0.shotID == from && $0.usage == .evidence && $0.derivativeID == left }?.id,
                                  mappings.first { $0.shotID == to && $0.usage == .evidence && $0.derivativeID == right }?.id].compactMap { $0 }
                items.append(.init(id: try digest(relation), kind: .relation, shotIDs: [from, to], textSegment: nil,
                    mappingIDs: mappingIDs, imageIDs: imageIDs, relation: relation))
            }
        }
        for (left, right) in zip(shotIDs, shotIDs.dropFirst()) {
            try appendRelation(kind: .adjacent, from: left, to: right, strategy: nil)
        }
        let recipes = snapshot.shots.compactMap { shot -> (String, RenderReviewV1.PredecessorRecipe)? in
            shot.review.predecessor.map { (shot.shotID, $0) }
        }
        let chainIDs = snapshot.projection.chains.map(\.shotID)
        guard recipes.count == chainIDs.count, Set(chainIDs).count == chainIDs.count,
              Set(recipes.map(\.0)).count == recipes.count, Set(chainIDs) == Set(recipes.map(\.0)) else {
            throw GateBlocked("The review omitted or duplicated a chain relation.")
        }
        for chain in snapshot.projection.chains {
            guard let recipe = recipes.first(where: { $0.0 == chain.shotID })?.1,
                  recipe.predecessorShotID == chain.predecessorShotID,
                  recipe.strategy.rawValue == chain.kind.rawValue else { throw GateBlocked("The review chain recipe changed.") }
            try appendRelation(kind: .predecessor, from: chain.predecessorShotID, to: chain.shotID, strategy: recipe.strategy.rawValue)
        }
        guard Set(items.map(\.id)).count == items.count else { throw GateBlocked("Review item identities are not unique.") }
        let draft = Self(schema: schemaVersion, id: String(repeating: "0", count: 64), snapshot: snapshot,
            textSources: textSources, mappings: mappings, derivatives: derivatives, sourceEncodings: sourceEncodings, items: items, pages: [])
        let pages = try draft.paginate(imageBytes: imageBytes)
        struct Identity: Encodable {
            let schema: String
            let snapshot: PipelineRenderReviewWriter.Snapshot
            let textSources: [TextSource]
            let mappings: [ImageMapping]
            let derivatives: [Derivative]
            let sourceEncodings: [SourceEncoding]
            let items: [Item]
            let pages: [Page]
        }
        let identity = Identity(schema: schemaVersion, snapshot: snapshot, textSources: textSources, mappings: mappings,
            derivatives: derivatives, sourceEncodings: sourceEncodings, items: items, pages: pages)
        return Self(schema: schemaVersion, id: try digest(identity), snapshot: snapshot, textSources: textSources,
            mappings: mappings, derivatives: derivatives, sourceEncodings: sourceEncodings, items: items, pages: pages)
    }

    static func splitText(_ text: String) -> [String] {
        var result: [String] = []
        var segment = String.UnicodeScalarView()
        var count = 0
        for scalar in text.unicodeScalars {
            let size = scalar.utf8.count
            if count + size > maximumTextSegmentBytes {
                result.append(String(segment))
                segment = String.UnicodeScalarView()
                count = 0
            }
            segment.append(scalar)
            count += size
        }
        if !segment.isEmpty || result.isEmpty { result.append(String(segment)) }
        return result
    }

    private static func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func digest<T: Encodable>(_ value: T) throws -> String {
        FileDigest.sha256(of: try PlanningWriterIO.json(value))
    }
}
