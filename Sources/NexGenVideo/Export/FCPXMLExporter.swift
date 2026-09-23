import AppKit
import CoreText
import CryptoKit
import Foundation
import NexGenEngine

struct FCPXMLMediaBinding: Codable, Sendable, Equatable {
    let assetID: String
    let mediaRef: String
    let mediaRefs: [String]
    let filename: String
    let originalFilename: String
    let sourceURL: String
    let mediaSHA256: String
    let mediaByteCount: Int64
    let stagedProjectMedia: Bool
    let sourceTimecodeOrigin: SourceTimecode.Origin?
    let sourceTimecodeFrame: Int?
    let sourceTimecodeQuanta: Int?
    let sourceTimecodeDropFrame: Bool?
}

struct FCPXMLExportReport: Codable, Sendable, Equatable {
    let version: FCPXMLVersion
    let target: FCPXMLTarget
    let validation: FCPXMLValidationReport
    let warnings: [FCPXMLWarning]
    let mediaBindings: [FCPXMLMediaBinding]
    let outputSHA256: String
    let outputByteCount: Int64
    let mediaByteCount: Int64
    let stagedProjectMediaCount: Int
}

enum FCPXMLExporter {
    private struct MediaEvidence {
        let sha256: [String: String]
        let byteCounts: [String: Int64]
    }

    private struct StagedMedia {
        let urls: [String: URL]
        let sha256: [String: String]
        let byteCounts: [String: Int64]
        let createdFiles: [URL]
        let createdDirectory: URL?
    }

    private enum EmissionSelection {
        static func supports(_ track: Track) -> Bool {
            track.type.isVisual || track.type == .audio
        }

        static func includes(_ clip: Clip, on track: Track, resolver: MediaResolver) -> Bool {
            guard supports(track), clip.durationFrames > 0 else { return false }
            switch clip.mediaType {
            case .text:
                return clip.textContent?.isEmpty == false
            case .audio, .video, .image:
                return resolver.resolveURL(for: clip.mediaRef) != nil
            case .lottie, .document:
                return false
            }
        }

        static func mediaRefs(
            in timeline: Timeline,
            resolver: MediaResolver
        ) -> Set<String> {
            Set(timeline.tracks.flatMap { track in
                track.clips.compactMap { clip in
                    guard clip.mediaType != .text,
                          includes(clip, on: track, resolver: resolver) else { return nil }
                    return clip.mediaRef
                }
            })
        }
    }

    struct RenderedDocument: Sendable, Equatable {
        let data: Data
        let validation: FCPXMLValidationReport
        let warnings: [FCPXMLWarning]
        let mediaBindings: [FCPXMLMediaBinding]
    }

    static func export(
        timeline: Timeline,
        resolver: MediaResolver,
        projectName: String,
        version: FCPXMLVersion = .default,
        target: FCPXMLTarget = .default,
        outputURL: URL,
        isCancelled: @escaping @MainActor @Sendable () -> Bool = { Task.isCancelled },
        progress: @escaping @MainActor @Sendable (Double) -> Void = { _ in }
    ) async throws -> FCPXMLExportReport {
        try validateOutputDestination(outputURL)
        await progress(0)
        let mediaRefs = EmissionSelection.mediaRefs(in: timeline, resolver: resolver)
        try await checkCancellation(isCancelled)
        let timing = await SourceTimingReader.cache(
            mediaRefs: mediaRefs,
            urls: resolver.expectedURLMap(for: mediaRefs)
        )
        await progress(0.08)
        try await checkCancellation(isCancelled)
        let staged = try await stageProjectMedia(
            mediaRefs: mediaRefs,
            resolver: resolver,
            outputURL: outputURL,
            isCancelled: isCancelled,
            progress: { value in progress(0.08 + value * 0.37) }
        )
        do {
            let evidence = try await collectMediaEvidence(
                mediaRefs: mediaRefs,
                resolver: resolver,
                relinkURLs: staged.urls,
                stagedSHA256: staged.sha256,
                stagedByteCounts: staged.byteCounts,
                isCancelled: isCancelled,
                progress: { value in progress(0.45 + value * 0.35) }
            )
            let document = try render(
                timeline: timeline,
                resolver: resolver,
                projectName: projectName,
                version: version,
                target: target,
                sourceTimecodes: timing.compactMapValues(\.timecode),
                sourceDurations: timing.compactMapValues(\.duration),
                relinkURLs: staged.urls,
                mediaSHA256: evidence.sha256,
                mediaByteCounts: evidence.byteCounts
            )
            var mediaByteCount: Int64 = 0
            for binding in document.mediaBindings {
                let (nextCount, overflow) = mediaByteCount.addingReportingOverflow(binding.mediaByteCount)
                guard !overflow else {
                    throw ExportError.xmlTimingInvalid(reason: "The media evidence byte count overflowed 64-bit arithmetic.")
                }
                mediaByteCount = nextCount
            }
            let stagedProjectMediaCount = document.mediaBindings.filter(\.stagedProjectMedia).count
            try await checkCancellation(isCancelled)
            await progress(0.9)
            let persistedOutput = try await writeValidated(
                document.data,
                version: version,
                outputURL: outputURL,
                isCancelled: isCancelled
            )
            await progress(1)
            return .init(
                version: version,
                target: target,
                validation: persistedOutput.validation,
                warnings: document.warnings,
                mediaBindings: document.mediaBindings,
                outputSHA256: FileDigest.sha256(of: persistedOutput.data),
                outputByteCount: Int64(persistedOutput.byteCount),
                mediaByteCount: mediaByteCount,
                stagedProjectMediaCount: stagedProjectMediaCount
            )
        } catch let error as ExportError {
            cleanup(staged)
            throw error
        } catch is CancellationError {
            cleanup(staged)
            throw CancellationError()
        } catch {
            cleanup(staged)
            throw ExportError.xmlWriteFailed(destination: outputURL, reason: error.localizedDescription)
        }
    }

    private static func checkCancellation(
        _ isCancelled: @escaping @MainActor @Sendable () -> Bool
    ) async throws {
        if Task.isCancelled { throw CancellationError() }
        if await isCancelled() { throw CancellationError() }
    }

    private static func validateOutputDestination(_ outputURL: URL) throws {
        let parent = outputURL.deletingLastPathComponent()
        let parentValues = try parent.resourceValues(forKeys: [.isDirectoryKey])
        guard parentValues.isDirectory == true else {
            throw ExportError.xmlWriteFailed(
                destination: outputURL,
                reason: "The destination folder does not exist."
            )
        }
        guard FileManager.default.fileExists(atPath: outputURL.path) else { return }
        let values = try outputURL.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ExportError.xmlWriteFailed(
                destination: outputURL,
                reason: "The destination must be a regular file."
            )
        }
    }

    private static func commit(temporaryOutput: URL, to outputURL: URL) throws {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: temporaryOutput)
        } else {
            try FileManager.default.moveItem(at: temporaryOutput, to: outputURL)
        }
    }

    static func writeValidated(
        _ data: Data,
        version: FCPXMLVersion,
        outputURL: URL,
        isCancelled: @escaping @MainActor @Sendable () -> Bool = { Task.isCancelled }
    ) async throws -> (data: Data, validation: FCPXMLValidationReport, byteCount: Int) {
        try validateOutputDestination(outputURL)
        let temporaryOutput = outputURL.deletingLastPathComponent().appendingPathComponent(
            ".fcpxml-\(UUID().uuidString).tmp"
        )
        defer { try? FileManager.default.removeItem(at: temporaryOutput) }
        try data.write(to: temporaryOutput, options: .atomic)
        let persisted = try Data(contentsOf: temporaryOutput)
        guard persisted == data else {
            throw ExportError.xmlWriteFailed(
                destination: outputURL,
                reason: "The saved bytes did not match the validated export."
            )
        }
        let validation = try FCPXMLSchemaValidator.validate(persisted, version: version)
        let values = try temporaryOutput.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true,
              let byteCount = values.fileSize,
              byteCount == persisted.count else {
            throw ExportError.xmlWriteFailed(
                destination: outputURL,
                reason: "The destination is not a regular file with the expected byte count."
            )
        }
        try await checkCancellation(isCancelled)
        try commit(temporaryOutput: temporaryOutput, to: outputURL)
        return (persisted, validation, byteCount)
    }

    private static func sha256(
        of url: URL,
        byteCount: Int64,
        isCancelled: @escaping @MainActor @Sendable () -> Bool,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var bytesRead: Int64 = 0
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try await checkCancellation(isCancelled)
            hasher.update(data: data)
            let (nextBytesRead, overflow) = bytesRead.addingReportingOverflow(Int64(data.count))
            guard !overflow else {
                throw ExportError.xmlMediaReadFailed(
                    source: url,
                    reason: "The media byte count overflowed 64-bit arithmetic."
                )
            }
            bytesRead = nextBytesRead
            let fraction = byteCount > 0
                ? min(1, Double(bytesRead) / Double(byteCount))
                : 1
            await progress(fraction)
            await Task.yield()
        }
        try await checkCancellation(isCancelled)
        await progress(1)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func stageProjectMedia(
        mediaRefs: Set<String>,
        resolver: MediaResolver,
        outputURL: URL,
        isCancelled: @escaping @MainActor @Sendable () -> Bool,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> StagedMedia {
        let identities = Set(mediaRefs.compactMap { mediaRef -> String? in
            guard resolver.isProjectMedia(mediaRef) else { return nil }
            return resolver.interchangeIdentity(for: mediaRef)
        })
        let sortedIdentities = identities.sorted()
        guard !sortedIdentities.isEmpty else {
            await progress(1)
            return .init(
                urls: [:],
                sha256: [:],
                byteCounts: [:],
                createdFiles: [],
                createdDirectory: nil
            )
        }

        let directory = outputURL.deletingLastPathComponent().appendingPathComponent(
            "\(outputURL.deletingPathExtension().lastPathComponent) Media",
            isDirectory: true
        )
        let directoryExisted = FileManager.default.fileExists(atPath: directory.path)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw ExportError.xmlWriteFailed(destination: directory, reason: error.localizedDescription)
        }

        var result: [String: URL] = [:]
        var digests: [String: String] = [:]
        var byteCounts: [String: Int64] = [:]
        var createdFiles: [URL] = []
        let partialResult: () -> StagedMedia = {
            .init(
                urls: result,
                sha256: digests,
                byteCounts: byteCounts,
                createdFiles: createdFiles,
                createdDirectory: directoryExisted ? nil : directory
            )
        }

        for (index, identity) in sortedIdentities.enumerated() {
            let itemStart = Double(index) / Double(sortedIdentities.count)
            let itemSpan = 1 / Double(sortedIdentities.count)
            do {
                try await checkCancellation(isCancelled)
            } catch {
                cleanup(partialResult())
                throw error
            }
            let referencedRefs = mediaRefs.filter {
                resolver.interchangeIdentity(for: $0) == identity
            }.sorted()
            let preferredRef = referencedRefs.first(where: { resolver.resolveURL(for: $0) != nil })
                ?? resolver.interchangeMediaRefs(sharing: identity).first(where: {
                    resolver.resolveURL(for: $0) != nil
                })
            guard let preferredRef,
                  let unresolvedSource = resolver.resolveURL(for: preferredRef) else { continue }
            let source = unresolvedSource.resolvingSymlinksInPath()
            let readable = resolver.interchangeFilename(for: preferredRef)
            let sourceValues: URLResourceValues
            let sourceDigest: String
            let sourceByteCount: Int64
            do {
                sourceValues = try source.resourceValues(forKeys: [
                    .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
                ])
                guard sourceValues.isRegularFile == true,
                      sourceValues.isSymbolicLink != true,
                      let fileSize = sourceValues.fileSize else {
                    throw ExportError.xmlMediaReadFailed(
                        source: source,
                        reason: "The source media is not a regular file."
                    )
                }
                sourceByteCount = Int64(fileSize)
                sourceDigest = try await sha256(
                    of: source,
                    byteCount: sourceByteCount,
                    isCancelled: isCancelled,
                    progress: { value in progress(itemStart + itemSpan * value * 0.5) }
                )
            } catch let error as ExportError {
                cleanup(partialResult())
                throw error
            } catch is CancellationError {
                cleanup(partialResult())
                throw CancellationError()
            } catch {
                cleanup(partialResult())
                throw ExportError.xmlMediaReadFailed(source: source, reason: error.localizedDescription)
            }
            let destination = directory.appendingPathComponent(
                stableFCPXMLRelinkFilename(
                    readable: readable,
                    identity: identity,
                    contentSHA256: sourceDigest
                )
            )
            do {
                let existingValues = try? destination.resourceValues(forKeys: [
                    .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
                ])
                if existingValues?.isRegularFile == true,
                   existingValues?.isSymbolicLink != true,
                   existingValues?.fileSize == sourceValues.fileSize {
                    let destinationDigest = try await sha256(
                        of: destination,
                        byteCount: sourceByteCount,
                        isCancelled: isCancelled,
                        progress: { value in
                            progress(itemStart + itemSpan * (0.5 + value * 0.25))
                        }
                    )
                    if destinationDigest == sourceDigest {
                        result[identity] = destination
                        digests[identity] = sourceDigest
                        byteCounts[identity] = sourceByteCount
                        await progress(itemStart + itemSpan)
                        continue
                    }
                }

                let temporary = directory.appendingPathComponent(".fcpxml-\(UUID().uuidString).tmp")
                defer { try? FileManager.default.removeItem(at: temporary) }
                try FileManager.default.copyItem(at: source, to: temporary)
                try await checkCancellation(isCancelled)
                if FileManager.default.fileExists(atPath: destination.path) {
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
                } else {
                    try FileManager.default.moveItem(at: temporary, to: destination)
                    createdFiles.append(destination)
                }
                let stagedValues = try destination.resourceValues(forKeys: [
                    .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
                ])
                guard stagedValues.isRegularFile == true,
                      stagedValues.isSymbolicLink != true,
                      stagedValues.fileSize == sourceValues.fileSize else {
                    throw ExportError.xmlWriteFailed(
                        destination: destination,
                        reason: "The staged media did not match the source byte count."
                    )
                }
                let stagedDigest = try await sha256(
                    of: destination,
                    byteCount: sourceByteCount,
                    isCancelled: isCancelled,
                    progress: { value in
                        progress(itemStart + itemSpan * (0.75 + value * 0.25))
                    }
                )
                guard stagedDigest == sourceDigest else {
                    throw ExportError.xmlWriteFailed(
                        destination: destination,
                        reason: "The staged media did not match the source bytes."
                    )
                }
                result[identity] = destination
                digests[identity] = sourceDigest
                byteCounts[identity] = sourceByteCount
                await progress(itemStart + itemSpan)
            } catch is CancellationError {
                cleanup(partialResult())
                throw CancellationError()
            } catch let error as ExportError {
                cleanup(partialResult())
                throw error
            } catch {
                cleanup(partialResult())
                throw ExportError.xmlWriteFailed(destination: destination, reason: error.localizedDescription)
            }
        }
        if result.isEmpty, !directoryExisted {
            cleanup(partialResult())
            await progress(1)
            return .init(
                urls: [:],
                sha256: [:],
                byteCounts: [:],
                createdFiles: [],
                createdDirectory: nil
            )
        }
        await progress(1)
        return partialResult()
    }

    private static func collectMediaEvidence(
        mediaRefs: Set<String>,
        resolver: MediaResolver,
        relinkURLs: [String: URL],
        stagedSHA256: [String: String],
        stagedByteCounts: [String: Int64],
        isCancelled: @escaping @MainActor @Sendable () -> Bool,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> MediaEvidence {
        let identities = Set(mediaRefs.compactMap { resolver.interchangeIdentity(for: $0) }).sorted()
        guard !identities.isEmpty else {
            await progress(1)
            return .init(sha256: [:], byteCounts: [:])
        }
        var digests: [String: String] = [:]
        var byteCounts: [String: Int64] = [:]
        for (index, identity) in identities.enumerated() {
            let itemStart = Double(index) / Double(identities.count)
            let itemSpan = 1 / Double(identities.count)
            if let digest = stagedSHA256[identity],
               let byteCount = stagedByteCounts[identity] {
                digests[identity] = digest
                byteCounts[identity] = byteCount
                await progress(itemStart + itemSpan)
                continue
            }
            let referencedRefs = mediaRefs.filter {
                resolver.interchangeIdentity(for: $0) == identity
            }.sorted()
            guard let preferredRef = referencedRefs.first(where: {
                resolver.resolveURL(for: $0) != nil
            }), let unresolvedURL = relinkURLs[identity] ?? resolver.resolveURL(for: preferredRef) else {
                continue
            }
            let url = unresolvedURL.resolvingSymlinksInPath()
            do {
                let values = try url.resourceValues(forKeys: [
                    .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
                ])
                guard values.isRegularFile == true,
                      values.isSymbolicLink != true,
                      let fileSize = values.fileSize else {
                    throw ExportError.xmlMediaReadFailed(
                        source: url,
                        reason: "The media is not a regular file."
                    )
                }
                let byteCount = Int64(fileSize)
                digests[identity] = try await sha256(
                    of: url,
                    byteCount: byteCount,
                    isCancelled: isCancelled,
                    progress: { value in progress(itemStart + itemSpan * value) }
                )
                byteCounts[identity] = byteCount
            } catch let error as ExportError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw ExportError.xmlMediaReadFailed(source: url, reason: error.localizedDescription)
            }
        }
        await progress(1)
        return .init(sha256: digests, byteCounts: byteCounts)
    }

    private static func cleanup(_ staged: StagedMedia) {
        for url in staged.createdFiles { try? FileManager.default.removeItem(at: url) }
        if let directory = staged.createdDirectory,
           (try? FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty) == true {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    static func render(
        timeline: Timeline,
        resolver: MediaResolver,
        projectName: String = "Timeline Export",
        version: FCPXMLVersion = .default,
        target: FCPXMLTarget = .default,
        sourceTimecodes: [String: SourceTimecode] = [:],
        sourceDurations: [String: RationalSeconds] = [:],
        relinkURLs: [String: URL] = [:],
        mediaSHA256: [String: String] = [:],
        mediaByteCounts: [String: Int64] = [:]
    ) throws -> RenderedDocument {
        let built = try Builder(
            timeline: timeline,
            resolver: resolver,
            projectName: projectName,
            version: version,
            target: target,
            sourceTimecodes: sourceTimecodes,
            sourceDurations: sourceDurations,
            relinkURLs: relinkURLs,
            mediaSHA256: mediaSHA256,
            mediaByteCounts: mediaByteCounts
        ).build()
        guard let data = built.xml.data(using: .utf8) else {
            throw ExportError.xmlEncodingFailed(format: "FCPXML")
        }
        let validation = try FCPXMLSchemaValidator.validate(data, version: version)
        return .init(
            data: data,
            validation: validation,
            warnings: built.warnings,
            mediaBindings: built.mediaBindings
        )
    }

    private final class Builder {
        private let timeline: Timeline
        private let resolver: MediaResolver
        private let projectName: String
        private let version: FCPXMLVersion
        private let target: FCPXMLTarget
        private let sourceTimecodes: [String: SourceTimecode]
        private let sourceDurations: [String: RationalSeconds]
        private let relinkURLs: [String: URL]
        private let mediaSHA256: [String: String]
        private let mediaByteCounts: [String: Int64]
        private let fps: Int
        private let sequenceFormatID = "sequence-format"
        private let titleEffectID = "basic-title"
        private var resourceIndex: [String: Int] = [:]
        private var resources: [MediaResource] = []
        private var nextTextStyleID = 1
        private var linkedAudioForVideo: [String: Clip] = [:]
        private var redundantAudioClipIDs: Set<String> = []
        private var usedCompoundIDs: Set<String> = []
        private var warnings: Set<FCPXMLWarning> = []
        private var timingFailure: String?

        private struct EmittableClip {
            let clip: Clip
            let lane: Int
            let enabled: Bool
        }

        private enum KeyframeLocalTimeline {
            case media(origin: (numerator: Int64, denominator: Int64)?)
            case title
        }

        private struct MediaResource {
            let mediaRefs: [String]
            let assetID: String
            let formatID: String?
            let compoundID: String?
            let entry: MediaManifestEntry
            let url: URL
            let filename: String
            let originalFilename: String
            let duration: RationalSeconds
            let hasVideo: Bool
            let hasAudio: Bool
            let timecode: SourceTimecode?
            let mediaSHA256: String
            let mediaByteCount: Int64
            let stagedProjectMedia: Bool
        }

        init(
            timeline: Timeline,
            resolver: MediaResolver,
            projectName: String,
            version: FCPXMLVersion,
            target: FCPXMLTarget,
            sourceTimecodes: [String: SourceTimecode],
            sourceDurations: [String: RationalSeconds],
            relinkURLs: [String: URL],
            mediaSHA256: [String: String],
            mediaByteCounts: [String: Int64]
        ) {
            self.timeline = timeline
            self.resolver = resolver
            self.projectName = projectName.isEmpty ? "Timeline Export" : projectName
            self.version = version
            self.target = target
            self.sourceTimecodes = sourceTimecodes
            self.sourceDurations = sourceDurations
            self.relinkURLs = relinkURLs
            self.mediaSHA256 = mediaSHA256
            self.mediaByteCounts = mediaByteCounts
            fps = max(1, timeline.fps)
        }

        func build() throws -> (xml: String, warnings: [FCPXMLWarning], mediaBindings: [FCPXMLMediaBinding]) {
            try validateXMLCharacters(projectName, context: "Project name")
            for track in timeline.tracks {
                for clip in track.clips where clip.mediaType == .text {
                    if let content = clip.textContent {
                        try validateXMLCharacters(
                            content,
                            context: "Text clip \"\(clip.id)\" content"
                        )
                    }
                    if let fontName = clip.textStyle?.fontName {
                        try validateXMLCharacters(
                            fontName,
                            context: "Text clip \"\(clip.id)\" font name"
                        )
                    }
                }
            }
            if timeline.fps <= 0 {
                timingFailure = "The timeline frame rate must be positive."
            }
            if timeline.width <= 0 || timeline.height <= 0 {
                timingFailure = "The timeline dimensions must be positive."
            }
            inspectUnsupportedFeatures()
            let clips = emittableClips()
            if clips.contains(where: { !$0.clip.speed.isFinite || $0.clip.speed <= 0 }) {
                timingFailure = "Every exported clip speed must be finite and positive."
            }
            try collectResources(from: clips)
            if resources.contains(where: { $0.timecode != nil && $0.timecode?.rationalSeconds == nil }) {
                timingFailure = "A source timecode origin overflowed 64-bit rational arithmetic."
            }
            if resources.contains(where: \.hasVideo) {
                warnings.insert(.init(
                    code: "color_metadata_not_exported",
                    clipID: nil,
                    message: "Timeline and source color-space metadata was not exported; verify color interpretation in the target editor."
                ))
            }
            indexLinkedPairs(clips)
            markUsedCompounds(clips)
            warnForDuplicateFilenames()
            let hasTitles = clips.contains { $0.clip.mediaType == .text }
            let root = FCPXMLNode(
                name: "fcpxml",
                attributes: [("version", version.rawValue)],
                children: [resourcesNode(hasTitles: hasTitles), libraryNode(clips: clips)]
            )
            if let timingFailure {
                throw ExportError.xmlTimingInvalid(reason: timingFailure)
            }
            let xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE fcpxml>\n"
                + renderFCPXML(root, indent: 0)
            let bindings = resources.map { resource in
                let timecode = resource.timecode
                return FCPXMLMediaBinding(
                    assetID: resource.assetID,
                    mediaRef: resource.mediaRefs.first ?? resource.entry.id,
                    mediaRefs: resource.mediaRefs,
                    filename: resource.filename,
                    originalFilename: resource.originalFilename,
                    sourceURL: resource.url.absoluteString,
                    mediaSHA256: resource.mediaSHA256,
                    mediaByteCount: resource.mediaByteCount,
                    stagedProjectMedia: resource.stagedProjectMedia,
                    sourceTimecodeOrigin: timecode?.origin,
                    sourceTimecodeFrame: timecode?.frame,
                    sourceTimecodeQuanta: timecode?.quanta,
                    sourceTimecodeDropFrame: timecode?.dropFrame
                )
            }
            return (xml, sortedWarnings(), bindings)
        }

        private func validateXMLCharacters(_ value: String, context: String) throws {
            for scalar in value.unicodeScalars where !isValidXMLScalar(scalar.value) {
                let codePoint = String(format: "U+%04X", scalar.value)
                throw ExportError.xmlInvalidCharacter(context: context, codePoint: codePoint)
            }
        }

        private func isValidXMLScalar(_ value: UInt32) -> Bool {
            value == 0x9
                || value == 0xA
                || value == 0xD
                || (0x20...0xD7FF).contains(value)
                || (0xE000...0xFFFD).contains(value)
                || (0x10000...0x10FFFF).contains(value)
        }

        private func inspectUnsupportedFeatures() {
            for track in timeline.tracks {
                for clip in track.clips where clip.durationFrames > 0 {
                    if clip.mediaType == .lottie || clip.sourceClipType == .lottie {
                        warn("lottie_requires_render", clip, "Lottie clip \(clip.id) was omitted. Render it to video before FCPXML export.")
                    }
                    if clip.mediaType == .document || clip.sourceClipType == .document {
                        warn("document_not_timeline_media", clip, "Document clip \(clip.id) was omitted because it has no timeline media representation.")
                    }
                    if clip.sourceClipType != .text,
                       resolver.resolveURL(for: clip.mediaRef) == nil {
                        warn("offline_media", clip, "Clip \(clip.id) was omitted because its media is offline.")
                    }
                    if clip.effects?.contains(where: \.enabled) == true {
                        warn("effects_not_exported", clip, "Effects on clip \(clip.id) were not exported.")
                    }
                    if clip.fadeInFrames > 0 || clip.fadeOutFrames > 0 {
                        warn("fades_not_exported", clip, "Fades on clip \(clip.id) were not exported.")
                    }
                    if clip.cropTrack?.isActive == true {
                        warn("crop_animation_not_exported", clip, "Animated crop on clip \(clip.id) was exported at its static value only.")
                    }
                    if clip.volumeTrack?.isActive == true {
                        warn("volume_animation_not_exported", clip, "Volume automation on clip \(clip.id) was exported at its static gain only.")
                    }
                    if clip.mediaType == .audio
                        || (clip.mediaType == .video && resolver.entry(for: clip.mediaRef)?.hasAudio == true) {
                        warn("audio_channel_layout_not_exported", clip, "Audio channel layout and roles on clip \(clip.id) were not exported; channel discovery is left to the target editor.")
                    }
                    if let sourceFPS = resolver.entry(for: clip.mediaRef)?.sourceFPS,
                       !hasNamedFCPRate(sourceFPS) {
                        warn("nonstandard_source_rate", clip, "Clip \(clip.id) uses the exact nonstandard rate \(formatNumber(sourceFPS)) fps; its FCP format name is left undefined.")
                    }
                    let animated = [
                        clip.opacityTrack?.keyframes.map(\.interpolationOut) ?? [],
                        clip.positionTrack?.keyframes.map(\.interpolationOut) ?? [],
                        clip.scaleTrack?.keyframes.map(\.interpolationOut) ?? [],
                        clip.rotationTrack?.keyframes.map(\.interpolationOut) ?? [],
                    ].flatMap { $0 }
                    if animated.contains(where: { $0 != .linear }) {
                        warn("keyframe_easing_approximated", clip, "Non-linear keyframe easing on clip \(clip.id) uses the target editor's interpolation.")
                    }
                    guard clip.mediaType == .text else { continue }
                    if clip.captionGroupId != nil {
                        warn("caption_exported_as_title", clip, "Caption clip \(clip.id) was exported as an editable Basic Title without caption-role metadata.")
                    }
                    let style = clip.textStyle ?? TextStyle()
                    if style.background.enabled {
                        warn("title_background_not_exported", clip, "The text background on clip \(clip.id) was not exported.")
                    }
                    if style.shadow.enabled {
                        warn("title_shadow_not_exported", clip, "The text shadow on clip \(clip.id) was not exported.")
                    }
                    if style.border.enabled {
                        warn("title_border_not_exported", clip, "The text box border on clip \(clip.id) was not exported.")
                    }
                    if clip.transform.flipHorizontal || clip.transform.flipVertical
                        || abs(clip.transform.rotation) > 0.000_5
                        || abs(clip.transform.width - 1) > 0.000_5
                        || abs(clip.transform.height - 1) > 0.000_5
                        || clip.hasTransformAnimation {
                        warn("title_transform_partial", clip, "Title clip \(clip.id) exports position only; scale, rotation, flip, and transform animation were not exported.")
                    }
                }
            }
        }

        private func warn(_ code: String, _ clip: Clip, _ message: String) {
            warnings.insert(.init(code: code, clipID: clip.id, message: message))
        }

        private func sortedWarnings() -> [FCPXMLWarning] {
            warnings.sorted {
                if $0.code != $1.code { return $0.code < $1.code }
                if $0.clipID != $1.clipID { return ($0.clipID ?? "") < ($1.clipID ?? "") }
                return $0.message < $1.message
            }
        }

        private func resourcesNode(hasTitles: Bool) -> FCPXMLNode {
            var children = [FCPXMLNode(name: "format", attributes: [
                ("id", sequenceFormatID),
                ("name", videoFormatName(width: timeline.width, height: timeline.height, fps: Double(fps))),
                ("frameDuration", frameDuration(forFPS: Double(fps))),
                ("width", "\(timeline.width)"),
                ("height", "\(timeline.height)"),
            ])]
            if hasTitles {
                children.append(FCPXMLNode(name: "effect", attributes: [
                    ("id", titleEffectID),
                    ("name", "Basic Title"),
                    ("uid", ".../Titles.localized/Bumper:Opener.localized/Basic Title.localized/Basic Title.moti"),
                ]))
            }
            children += resources.compactMap(formatNode)
            children += resources.map(assetNode)
            children += resources.compactMap(compoundClipNode)
            return FCPXMLNode(name: "resources", children: children)
        }

        private func libraryNode(clips: [EmittableClip]) -> FCPXMLNode {
            let duration = time(frames: timeline.totalFrames)
            let spine: FCPXMLNode = timeline.totalFrames > 0
                ? FCPXMLNode(name: "spine", children: [
                    FCPXMLNode(name: "gap", attributes: [
                        ("name", "Timeline"),
                        ("offset", "0s"),
                        ("start", "0s"),
                        ("duration", duration),
                    ], children: storyNodes(for: clips)),
                ])
                : FCPXMLNode(name: "spine")
            let sequence = FCPXMLNode(name: "sequence", attributes: [
                ("format", sequenceFormatID),
                ("duration", duration),
                ("tcStart", "0s"),
                ("tcFormat", "NDF"),
            ], children: [spine])
            return FCPXMLNode(name: "library", children: [
                FCPXMLNode(name: "event", attributes: [("name", "NexGenVideo Export")], children: [
                    FCPXMLNode(name: "project", attributes: [("name", projectName)], children: [sequence]),
                ]),
            ])
        }

        private func storyNodes(for clips: [EmittableClip]) -> [FCPXMLNode] {
            clips
                .filter { !redundantAudioClipIDs.contains($0.clip.id) }
                .sorted {
                    if $0.clip.startFrame != $1.clip.startFrame {
                        return $0.clip.startFrame < $1.clip.startFrame
                    }
                    if $0.lane != $1.lane { return $0.lane < $1.lane }
                    return $0.clip.id < $1.clip.id
                }
                .compactMap { item in
                    item.clip.mediaType == .text ? titleNode(for: item) : assetClipNode(for: item)
                }
        }

        private func assetClipNode(for item: EmittableClip) -> FCPXMLNode? {
            let clip = item.clip
            guard let index = resourceIndex[clip.mediaRef] else { return nil }
            let resource = resources[index]
            let linkedAudio = linkedAudioForVideo[clip.id]

            if let compoundID = resource.compoundID, linkedAudio == nil {
                let visual = clip.mediaType != .audio
                let attrs: [(String, String)] = [
                    ("ref", compoundID),
                    ("name", resource.filename),
                    ("lane", "\(item.lane)"),
                    ("offset", time(frames: clip.startFrame)),
                    ("start", clipStart(for: clip)),
                    ("duration", time(frames: clip.durationFrames)),
                    ("enabled", item.enabled ? "1" : "0"),
                    ("srcEnable", visual ? "video" : "audio"),
                ]
                let children: [FCPXMLNode?] = visual
                    ? [timeMapNode(for: clip, mediaDuration: resource.duration),
                       cropNode(for: clip),
                       FCPXMLNode(name: "adjust-conform", attributes: [("type", "fit")]),
                       transformNode(for: clip, localTimeline: .media(origin: nil)),
                       blendNode(for: clip, localTimeline: .media(origin: nil))]
                    : [timeMapNode(for: clip, mediaDuration: resource.duration), volumeNode(for: clip)]
                return FCPXMLNode(name: "ref-clip", attributes: attrs, children: children.compactMap { $0 })
            }

            let visual = clip.mediaType != .audio
            var attrs: [(String, String)] = [
                ("ref", resource.assetID),
                ("name", resource.filename),
                ("lane", "\(item.lane)"),
                ("offset", time(frames: clip.startFrame)),
                ("start", clipStart(for: clip, origin: resource.timecode?.rationalSeconds)),
                ("duration", time(frames: clip.durationFrames)),
                ("enabled", item.enabled ? "1" : "0"),
            ]
            let children: [FCPXMLNode?] = [
                timeMapNode(
                    for: clip,
                    mediaDuration: resource.duration,
                    origin: resource.timecode?.rationalSeconds
                ),
                visual ? cropNode(for: clip) : nil,
                visual ? FCPXMLNode(name: "adjust-conform", attributes: [("type", "fit")]) : nil,
                visual ? transformNode(
                    for: clip,
                    localTimeline: .media(origin: resource.timecode?.rationalSeconds)
                ) : nil,
                visual ? blendNode(
                    for: clip,
                    localTimeline: .media(origin: resource.timecode?.rationalSeconds)
                ) : nil,
                resource.hasAudio ? volumeNode(for: linkedAudio ?? clip) : nil,
            ]
            let name = clip.mediaType == .image ? "video" : "asset-clip"
            if name == "asset-clip", resource.timecode != nil {
                attrs.append(("tcFormat", resource.timecode?.dropFrame == true ? "DF" : "NDF"))
            }
            return FCPXMLNode(name: name, attributes: attrs, children: children.compactMap { $0 })
        }

        private func titleNode(for item: EmittableClip) -> FCPXMLNode? {
            let clip = item.clip
            guard let content = clip.textContent, !content.isEmpty else { return nil }
            let style = clip.textStyle ?? TextStyle()
            let styleID = "text-style-\(nextTextStyleID)"
            nextTextStyleID += 1
            let children: [FCPXMLNode?] = [
                FCPXMLNode(name: "text", children: [
                    FCPXMLNode(name: "text-style", attributes: [("ref", styleID)], text: content),
                ]),
                FCPXMLNode(name: "text-style-def", attributes: [("id", styleID)], children: [
                    FCPXMLNode(name: "text-style", attributes: textStyleAttributes(for: style)),
                ]),
                cropNode(for: clip),
                FCPXMLNode(name: "adjust-conform", attributes: [("type", "fit")]),
                FCPXMLNode(name: "adjust-transform", attributes: [
                    ("scale", "1 1"),
                    ("anchor", "0 0"),
                    ("position", positionValue(for: clip.transform)),
                ]),
            ]
            let concreteChildren = children.compactMap { $0 }
            var finalChildren = concreteChildren
            if let blend = blendNode(for: clip, localTimeline: .title) { finalChildren.append(blend) }
            return FCPXMLNode(name: "title", attributes: [
                ("ref", titleEffectID),
                ("name", content),
                ("lane", "\(item.lane)"),
                ("offset", time(frames: clip.startFrame)),
                ("start", "0s"),
                ("duration", time(frames: clip.durationFrames)),
                ("enabled", item.enabled ? "1" : "0"),
            ], children: finalChildren)
        }

        private func blendNode(
            for clip: Clip,
            localTimeline: KeyframeLocalTimeline
        ) -> FCPXMLNode? {
            let frames = clip.keyframeFrames(for: .opacity)
            guard clip.opacity < 0.999_5 || !frames.isEmpty else { return nil }
            let children = frames.isEmpty ? [] : [
                keyframeParam(
                    name: "amount",
                    base: formatNumber(clip.opacity),
                    clip: clip,
                    property: .opacity,
                    frames: frames,
                    localTimeline: localTimeline
                ) {
                    self.formatNumber(clip.rawOpacityAt(frame: $0))
                },
            ]
            return FCPXMLNode(
                name: "adjust-blend",
                attributes: [("amount", formatNumber(clip.opacity))],
                children: children
            )
        }

        private func transformNode(
            for clip: Clip,
            localTimeline: KeyframeLocalTimeline
        ) -> FCPXMLNode? {
            let transform = clip.transform
            let positionFrames = clip.keyframeFrames(for: .position)
            let rotationFrames = clip.keyframeFrames(for: .rotation)
            let scaleFrames = clip.keyframeFrames(for: .scale)
            let scale = scaleValue(width: transform.width, height: transform.height, for: clip)
            let moved = abs(transform.centerX - 0.5) > 0.000_5 || abs(transform.centerY - 0.5) > 0.000_5
            let rotated = abs(transform.rotation) > 0.005
            guard moved || rotated || scale != "1 1"
                    || !positionFrames.isEmpty || !rotationFrames.isEmpty || !scaleFrames.isEmpty else { return nil }

            let fit = target == .resolve ? fitFractions(for: clip) : (width: 1.0, height: 1.0)
            var attributes: [(String, String)] = [("scale", scale)]
            if rotated || !rotationFrames.isEmpty {
                attributes.append(("rotation", formatNumber(-transform.rotation)))
            }
            attributes.append(("anchor", "0 0"))
            attributes.append(("position", positionValue(for: transform, fit: fit)))

            var parameters: [FCPXMLNode] = []
            if !scaleFrames.isEmpty {
                parameters.append(keyframeParam(
                    name: "scale", base: scale, clip: clip, property: .scale,
                    frames: scaleFrames, localTimeline: localTimeline
                ) { frame in
                    let size = clip.sizeAt(frame: frame)
                    return self.scaleValue(width: size.width, height: size.height, for: clip)
                })
            }
            if !positionFrames.isEmpty {
                parameters.append(keyframeParam(
                    name: "position",
                    base: positionValue(for: transform, fit: fit),
                    clip: clip,
                    property: .position,
                    frames: positionFrames,
                    localTimeline: localTimeline
                ) { self.positionValue(for: clip.transformAt(frame: $0), fit: fit) })
            }
            if !rotationFrames.isEmpty {
                parameters.append(keyframeParam(
                    name: "rotation",
                    base: formatNumber(-transform.rotation),
                    clip: clip,
                    property: .rotation,
                    frames: rotationFrames,
                    localTimeline: localTimeline
                ) { self.formatNumber(-clip.rotationAt(frame: $0)) })
            }
            return FCPXMLNode(name: "adjust-transform", attributes: attributes, children: parameters)
        }

        private func scaleValue(width: Double, height: Double, for clip: Clip) -> String {
            let fit = fitFractions(for: clip)
            var horizontal = width / fit.width
            var vertical = height / fit.height
            if clip.transform.flipHorizontal { horizontal = -horizontal }
            if clip.transform.flipVertical { vertical = -vertical }
            return "\(formatNumber(horizontal)) \(formatNumber(vertical))"
        }

        private func keyframeParam(
            name: String,
            base: String,
            clip: Clip,
            property: AnimatableProperty,
            frames: [Int],
            localTimeline: KeyframeLocalTimeline,
            value: (Int) -> String
        ) -> FCPXMLNode {
            let keyframes = frames.sorted().map { frame -> FCPXMLNode in
                var attributes: [(String, String)] = [(
                    "time",
                    keyframeTime(frame, clip: clip, localTimeline: localTimeline)
                )]
                if clip.interpolation(for: property, atFrame: frame) == .linear {
                    attributes.append(("curve", "linear"))
                }
                attributes.append(("value", value(frame)))
                return FCPXMLNode(name: "keyframe", attributes: attributes)
            }
            return FCPXMLNode(name: "param", attributes: [("name", name), ("value", base)], children: [
                FCPXMLNode(name: "keyframeAnimation", children: keyframes),
            ])
        }

        private func keyframeTime(
            _ frame: Int,
            clip: Clip,
            localTimeline: KeyframeLocalTimeline
        ) -> String {
            let elapsed = frame - clip.startFrame
            if case .title = localTimeline {
                return time(frames: elapsed)
            }
            guard abs(clip.speed - 1) > 0.001 else {
                let (localFrame, overflow) = clip.trimStartFrame.addingReportingOverflow(elapsed)
                guard !overflow else {
                    recordTimingFailure("A keyframe time overflowed integer frame arithmetic.")
                    return "0s"
                }
                guard case .media(let origin) = localTimeline else { return "0s" }
                return time(frames: localFrame, from: origin)
            }
            let speed = rationalSpeed(clip.speed)
            guard let trim = checkedMultiply(Int64(clip.trimStartFrame), speed.denominator),
                  let scaledElapsed = checkedMultiply(Int64(elapsed), speed.numerator),
                  let numerator = checkedAdd(trim, scaledElapsed),
                  let denominator = checkedMultiply(Int64(fps), speed.numerator) else {
                recordTimingFailure("A keyframe time overflowed 64-bit rational arithmetic.")
                return "0s"
            }
            return rationalTime(
                numerator: numerator,
                denominator: denominator
            )
        }

        private func cropNode(for clip: Clip) -> FCPXMLNode? {
            let crop = clip.crop
            guard !crop.isIdentity else { return nil }
            var horizontalUnit = 100.0
            var verticalUnit = 100.0
            if target == .resolve,
               let entry = resolver.entry(for: clip.mediaRef),
               let sourceWidth = entry.sourceWidth,
               let sourceHeight = entry.sourceHeight,
               sourceWidth > 0,
               sourceHeight > 0 {
                let fit = min(
                    Double(timeline.width) / Double(sourceWidth),
                    Double(timeline.height) / Double(sourceHeight)
                )
                horizontalUnit = Double(sourceWidth) * 100 / Double(timeline.height)
                verticalUnit = 100 / fit
            }
            return FCPXMLNode(name: "adjust-crop", attributes: [("mode", "trim")], children: [
                FCPXMLNode(name: "trim-rect", attributes: [
                    ("top", formatNumber(crop.top * verticalUnit)),
                    ("right", formatNumber(crop.right * horizontalUnit)),
                    ("bottom", formatNumber(crop.bottom * verticalUnit)),
                    ("left", formatNumber(crop.left * horizontalUnit)),
                ]),
            ])
        }

        private func volumeNode(for clip: Clip) -> FCPXMLNode? {
            guard abs(clip.volume - 1) > 0.000_5 else { return nil }
            let decibels = clip.volume > 0 ? 20 * log10(clip.volume) : -96
            return FCPXMLNode(name: "adjust-volume", attributes: [("amount", "\(formatNumber(decibels))dB")])
        }

        private func clipStart(
            for clip: Clip,
            origin: (numerator: Int64, denominator: Int64)? = nil
        ) -> String {
            if abs(clip.speed - 1) <= 0.001 {
                return time(frames: clip.trimStartFrame, from: origin)
            }
            let speed = rationalSpeed(clip.speed)
            guard let numerator = checkedMultiply(Int64(clip.trimStartFrame), speed.denominator),
                  let denominator = checkedMultiply(Int64(fps), speed.numerator) else {
                recordTimingFailure("A source trim time overflowed 64-bit rational arithmetic.")
                return "0s"
            }
            return rationalTime(
                numerator: numerator,
                denominator: denominator
            )
        }

        private func timeMapNode(
            for clip: Clip,
            mediaDuration: RationalSeconds,
            origin: (numerator: Int64, denominator: Int64)? = nil
        ) -> FCPXMLNode? {
            guard abs(clip.speed - 1) > 0.001, mediaDuration.numerator > 0 else { return nil }
            let speed = rationalSpeed(clip.speed)
            guard let mappedNumerator = checkedMultiply(mediaDuration.numerator, speed.denominator),
                  let mappedDenominator = checkedMultiply(mediaDuration.denominator, speed.numerator) else {
                recordTimingFailure("A retime range overflowed 64-bit rational arithmetic.")
                return nil
            }
            return FCPXMLNode(name: "timeMap", attributes: [("frameSampling", "floor")], children: [
                FCPXMLNode(name: "timept", attributes: [
                    ("time", "0s"),
                    ("value", rationalTime(origin)),
                    ("interp", "linear"),
                ]),
                FCPXMLNode(name: "timept", attributes: [
                    ("time", rationalTime(
                        numerator: mappedNumerator,
                        denominator: mappedDenominator
                    )),
                    ("value", rationalTime(adding: mediaDuration, to: origin)),
                    ("interp", "linear"),
                ]),
            ])
        }

        private func rationalSpeed(_ speed: Double) -> (numerator: Int64, denominator: Int64) {
            guard speed.isFinite, speed > 0, speed < Double(Int64.max) / 10_000 else {
                recordTimingFailure("A clip speed was not finite, positive, and representable.")
                return (1, 1)
            }
            var best = (numerator: Int64(1), denominator: Int64(1))
            var bestError = Double.infinity
            for denominator in 1...10_000 {
                let candidate = (speed * Double(denominator)).rounded()
                guard candidate.isFinite,
                      candidate > 0,
                      candidate < Double(Int64.max) else { continue }
                let numerator = Int64(candidate)
                guard numerator > 0 else { continue }
                let error = abs(speed - Double(numerator) / Double(denominator))
                if error < bestError {
                    best = (numerator, Int64(denominator))
                    bestError = error
                    if error < 1e-12 { break }
                }
            }
            return best
        }

        private func collectResources(from clips: [EmittableClip]) throws {
            struct Capabilities {
                var hasVideo: Bool
                var hasAudio: Bool
                var fallbackDurationSeconds: Double
                var mediaRefs: Set<String>
            }
            var capabilities: [String: Capabilities] = [:]
            for item in clips {
                let clip = item.clip
                guard clip.mediaType != .text,
                      let identity = resolver.interchangeIdentity(for: clip.mediaRef),
                      let entry = resolver.entry(for: clip.mediaRef),
                      resolver.resolveURL(for: clip.mediaRef) != nil else { continue }
                let isVisual = clip.mediaType != .audio
                let isAudio = clip.mediaType == .audio || (clip.mediaType == .video && entry.hasAudio == true)
                var value = capabilities[identity] ?? .init(
                    hasVideo: false,
                    hasAudio: false,
                    fallbackDurationSeconds: 0,
                    mediaRefs: []
                )
                value.hasVideo = value.hasVideo || isVisual
                value.hasAudio = value.hasAudio || isAudio
                value.mediaRefs.insert(clip.mediaRef)
                value.fallbackDurationSeconds = max(
                    value.fallbackDurationSeconds,
                    fallbackSourceDurationSeconds(for: entry, clip: clip)
                )
                capabilities[identity] = value
            }

            for identity in capabilities.keys.sorted() {
                guard let value = capabilities[identity] else { continue }
                let referencedRefs = value.mediaRefs.sorted()
                let preferredRef = referencedRefs.first(where: {
                    resolver.entry(for: $0) != nil && resolver.resolveURL(for: $0) != nil
                }) ?? referencedRefs[0]
                guard let entry = resolver.entry(for: preferredRef),
                      let resolvedURL = resolver.resolveURL(for: preferredRef) else { continue }
                let digest = FileDigest.sha256(of: Data(identity.utf8))
                let assetID = "asset-\(digest.prefix(16))"
                let formatID = value.hasVideo ? "format-\(digest.prefix(16))" : nil
                let compoundID = value.hasVideo && value.hasAudio ? "media-\(digest.prefix(16))" : nil
                let mediaRefs = referencedRefs
                let originalFilename = resolver.interchangeFilename(for: preferredRef)
                try validateXMLCharacters(
                    originalFilename,
                    context: "Media \"\(preferredRef)\" filename"
                )
                let filename = originalFilename
                let timecode = mediaRefs.compactMap { sourceTimecodes[$0] }.first
                guard let duration = mediaRefs.compactMap({ sourceDurations[$0] }).first
                        ?? RationalSeconds(seconds: value.fallbackDurationSeconds) else {
                    throw ExportError.xmlTimingInvalid(
                        reason: "Media \"\(originalFilename)\" has no finite, representable duration."
                    )
                }
                let mediaURL = relinkURLs[identity] ?? resolvedURL
                let values: URLResourceValues
                let mediaDigest: String
                do {
                    values = try mediaURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                    guard values.isRegularFile == true, values.fileSize != nil else {
                        throw ExportError.xmlMediaReadFailed(source: mediaURL, reason: "The media is not a regular file.")
                    }
                    mediaDigest = mediaSHA256[identity] ?? (try FileDigest.sha256(of: mediaURL))
                } catch let error as ExportError {
                    throw error
                } catch {
                    throw ExportError.xmlMediaReadFailed(source: mediaURL, reason: error.localizedDescription)
                }
                let resource = MediaResource(
                    mediaRefs: mediaRefs,
                    assetID: assetID,
                    formatID: formatID,
                    compoundID: compoundID,
                    entry: entry,
                    url: mediaURL,
                    filename: filename,
                    originalFilename: originalFilename,
                    duration: duration,
                    hasVideo: value.hasVideo,
                    hasAudio: value.hasAudio,
                    timecode: timecode,
                    mediaSHA256: mediaDigest,
                    mediaByteCount: mediaByteCounts[identity] ?? Int64(values.fileSize ?? 0),
                    stagedProjectMedia: relinkURLs[identity] != nil
                )
                for mediaRef in mediaRefs { resourceIndex[mediaRef] = resources.count }
                resources.append(resource)
            }
        }

        private func formatNode(for resource: MediaResource) -> FCPXMLNode? {
            guard let formatID = resource.formatID else { return nil }
            let width = resource.entry.sourceWidth ?? timeline.width
            let height = resource.entry.sourceHeight ?? timeline.height
            let sourceFPS = resource.entry.sourceFPS ?? Double(fps)
            return FCPXMLNode(name: "format", attributes: [
                ("id", formatID),
                ("name", videoFormatName(width: width, height: height, fps: sourceFPS)),
                ("frameDuration", frameDuration(forFPS: sourceFPS)),
                ("width", "\(width)"),
                ("height", "\(height)"),
            ])
        }

        private func assetNode(for resource: MediaResource) -> FCPXMLNode {
            var attributes: [(String, String)] = [
                ("id", resource.assetID),
                ("name", resource.filename),
                ("start", rationalTime(resource.timecode?.rationalSeconds)),
                ("duration", rationalTime(resource.duration)),
            ]
            if resource.hasVideo {
                attributes += [("hasVideo", "1"), ("videoSources", "1")]
                if let formatID = resource.formatID { attributes.append(("format", formatID)) }
            }
            if resource.hasAudio {
                attributes += [
                    ("hasAudio", "1"),
                    ("audioSources", "1"),
                ]
            }
            return FCPXMLNode(name: "asset", attributes: attributes, children: [
                FCPXMLNode(name: "media-rep", attributes: [
                    ("kind", "original-media"),
                    ("src", mediaSourceURL(for: resource)),
                ]),
            ])
        }

        private func compoundClipNode(for resource: MediaResource) -> FCPXMLNode? {
            guard let compoundID = resource.compoundID,
                  usedCompoundIDs.contains(compoundID) else { return nil }
            let duration = rationalTime(resource.duration)
            let sequence = FCPXMLNode(name: "sequence", attributes: [
                ("format", resource.formatID ?? sequenceFormatID),
                ("duration", duration),
                ("tcStart", "0s"),
                ("tcFormat", resource.timecode?.dropFrame == true ? "DF" : "NDF"),
            ], children: [
                FCPXMLNode(name: "spine", children: [
                    FCPXMLNode(name: "asset-clip", attributes: [
                        ("ref", resource.assetID),
                        ("name", resource.filename),
                        ("duration", duration),
                        ("start", rationalTime(resource.timecode?.rationalSeconds)),
                        ("offset", "0s"),
                        ("format", resource.formatID ?? sequenceFormatID),
                    ]),
                ]),
            ])
            return FCPXMLNode(name: "media", attributes: [
                ("id", compoundID),
                ("name", resource.filename),
            ], children: [sequence])
        }

        private func mediaSourceURL(for resource: MediaResource) -> String {
            resource.url.absoluteString.map { character in
                "'!$&()*+,;=".contains(character)
                    ? String(format: "%%%02X", character.asciiValue ?? 0)
                    : String(character)
            }.joined()
        }

        private func fallbackSourceDurationSeconds(for entry: MediaManifestEntry, clip: Clip) -> Double {
            guard entry.duration.isFinite,
                  entry.duration >= 0 else {
                recordTimingFailure("A source media duration was not finite and representable.")
                return Double(max(0, clip.sourceDurationFrames)) / Double(fps)
            }
            return max(
                entry.duration,
                Double(max(0, clip.sourceDurationFrames)) / Double(fps)
            )
        }

        private func emittableClips() -> [EmittableClip] {
            let visualTrackCount = timeline.tracks.count(where: { $0.type.isVisual })
            var visualOrdinal = 0
            var audioOrdinal = 0
            var result: [EmittableClip] = []
            for track in timeline.tracks {
                guard EmissionSelection.supports(track) else { continue }
                let lane: Int
                let enabled: Bool
                if track.type.isVisual {
                    lane = visualTrackCount - visualOrdinal
                    enabled = !track.hidden
                    visualOrdinal += 1
                } else if track.type == .audio {
                    lane = -(audioOrdinal + 1)
                    enabled = !track.muted
                    audioOrdinal += 1
                } else { continue }
                result += track.clips
                    .filter { EmissionSelection.includes($0, on: track, resolver: resolver) }
                    .sorted {
                        if $0.startFrame != $1.startFrame { return $0.startFrame < $1.startFrame }
                        return $0.id < $1.id
                    }
                    .map { .init(clip: $0, lane: lane, enabled: enabled) }
            }
            return result
        }

        private func indexLinkedPairs(_ clips: [EmittableClip]) {
            var byGroup: [String: (video: [EmittableClip], audio: [EmittableClip])] = [:]
            for item in clips {
                guard let group = item.clip.linkGroupId else { continue }
                if item.clip.mediaType == .audio {
                    byGroup[group, default: ([], [])].audio.append(item)
                } else if item.clip.mediaType == .video || item.clip.mediaType == .image {
                    byGroup[group, default: ([], [])].video.append(item)
                }
            }
            for pair in byGroup.values {
                guard pair.video.count == 1, pair.audio.count == 1 else { continue }
                let video = pair.video[0]
                let audio = pair.audio[0]
                guard video.clip.mediaRef == audio.clip.mediaRef,
                      video.enabled == audio.enabled,
                      video.clip.startFrame == audio.clip.startFrame,
                      video.clip.durationFrames == audio.clip.durationFrames,
                      video.clip.trimStartFrame == audio.clip.trimStartFrame,
                      abs(video.clip.speed - audio.clip.speed) < 0.000_1 else { continue }
                linkedAudioForVideo[video.clip.id] = audio.clip
                redundantAudioClipIDs.insert(audio.clip.id)
            }
        }

        private func markUsedCompounds(_ clips: [EmittableClip]) {
            for item in clips where !redundantAudioClipIDs.contains(item.clip.id) {
                guard let index = resourceIndex[item.clip.mediaRef],
                      let compoundID = resources[index].compoundID,
                      linkedAudioForVideo[item.clip.id] == nil else { continue }
                usedCompoundIDs.insert(compoundID)
            }
        }

        private func warnForDuplicateFilenames() {
            let groups = Dictionary(grouping: resources, by: { $0.originalFilename.lowercased() })
            for group in groups.values where group.count > 1 {
                let refs = group.flatMap(\.mediaRefs).sorted().joined(separator: ", ")
                let containsExternalSource = group.contains { !$0.stagedProjectMedia }
                warnings.insert(.init(
                    code: containsExternalSource
                        ? "duplicate_external_filename"
                        : "duplicate_relink_filename",
                    clipID: nil,
                    message: containsExternalSource
                        ? "Multiple assets, including external media, share the filename \(group[0].originalFilename). Their full source URLs remain distinct, but verify them if the target editor asks you to relink: \(refs)."
                        : "Multiple project assets share the original filename \(group[0].originalFilename); deterministic sidecar suffixes preserve distinct relink identities: \(refs)."
                ))
            }
        }

        private func time(frames: Int) -> String {
            rationalTime(numerator: Int64(frames), denominator: Int64(fps))
        }

        private func time(
            frames: Int,
            from origin: (numerator: Int64, denominator: Int64)?
        ) -> String {
            guard let origin else { return time(frames: frames) }
            guard let framesByOrigin = checkedMultiply(Int64(frames), origin.denominator),
                  let originByFPS = checkedMultiply(origin.numerator, Int64(fps)),
                  let numerator = checkedAdd(framesByOrigin, originByFPS),
                  let denominator = checkedMultiply(Int64(fps), origin.denominator) else {
                recordTimingFailure("Source start time overflowed 64-bit rational arithmetic.")
                return "0s"
            }
            return rationalTime(
                numerator: numerator,
                denominator: denominator
            )
        }

        private func rationalTime(_ value: (numerator: Int64, denominator: Int64)?) -> String {
            guard let value else { return "0s" }
            return rationalTime(numerator: value.numerator, denominator: value.denominator)
        }

        private func rationalTime(_ value: RationalSeconds) -> String {
            rationalTime(numerator: value.numerator, denominator: value.denominator)
        }

        private func rationalTime(
            adding duration: RationalSeconds,
            to origin: (numerator: Int64, denominator: Int64)?
        ) -> String {
            guard let origin else { return rationalTime(duration) }
            guard let durationNumerator = checkedMultiply(duration.numerator, origin.denominator),
                  let originNumerator = checkedMultiply(origin.numerator, duration.denominator),
                  let numerator = checkedAdd(durationNumerator, originNumerator),
                  let denominator = checkedMultiply(duration.denominator, origin.denominator) else {
                recordTimingFailure("A source duration overflowed 64-bit rational arithmetic.")
                return "0s"
            }
            return rationalTime(numerator: numerator, denominator: denominator)
        }

        private func rationalTime(numerator: Int64, denominator: Int64) -> String {
            guard numerator != 0 else { return "0s" }
            guard denominator > 0 else {
                recordTimingFailure("A rational time had a non-positive denominator.")
                return "0s"
            }
            let divisor = greatestCommonDivisor(numerator.magnitude, UInt64(denominator))
            let reducedNumerator = numerator / Int64(divisor)
            let reducedDenominator = denominator / Int64(divisor)
            guard reducedDenominator <= Int64(Int32.max) else {
                recordTimingFailure("A reduced rational time denominator exceeded the FCPXML limit.")
                return "0s"
            }
            return reducedDenominator == 1
                ? "\(reducedNumerator)s"
                : "\(reducedNumerator)/\(reducedDenominator)s"
        }

        private func videoFormatName(width: Int, height: Int, fps rawFPS: Double) -> String {
            guard let rate = formatRateSuffix(forFPS: rawFPS) else {
                return "FFVideoFormatRateUndefined"
            }
            switch (width, height) {
            case (1280, 720): return "FFVideoFormat720p\(rate)"
            case (1920, 1080): return "FFVideoFormat1080p\(rate)"
            case (3840, 2160): return "FFVideoFormat3840x2160p\(rate)"
            case (4096, 2160): return "FFVideoFormat4096x2160p\(rate)"
            default: return "FFVideoFormatRateUndefined"
            }
        }

        private func formatRateSuffix(forFPS rawFPS: Double) -> String? {
            guard rawFPS.isFinite, rawFPS > 0, rawFPS <= Double(Int.max / 1_000) else {
                recordTimingFailure("A source frame rate was not finite and positive.")
                return nil
            }
            let rounded = max(1, Int(rawFPS.rounded()))
            let ntsc = Double(rounded) * 1_000 / 1_001
            if abs(rawFPS - ntsc) < 0.001 {
                let hundredths = Int((ntsc * 100).rounded())
                return "\(hundredths / 100)\(String(format: "%02d", hundredths % 100))"
            }
            return abs(rawFPS - Double(rounded)) < 0.000_001 ? "\(rounded)" : nil
        }

        private func hasNamedFCPRate(_ rawFPS: Double) -> Bool {
            guard rawFPS.isFinite, rawFPS > 0, rawFPS <= Double(Int.max / 1_000) else { return false }
            let rounded = max(1, Int(rawFPS.rounded()))
            let ntsc = Double(rounded) * 1_000 / 1_001
            return abs(rawFPS - Double(rounded)) < 0.000_001 || abs(rawFPS - ntsc) < 0.001
        }

        private func frameDuration(forFPS rawFPS: Double) -> String {
            guard rawFPS.isFinite, rawFPS > 0, rawFPS <= Double(Int.max / 1_000) else {
                recordTimingFailure("A source frame rate was not finite and positive.")
                return "0s"
            }
            let rounded = max(1, Int(rawFPS.rounded()))
            let ntsc = Double(rounded) * 1_000 / 1_001
            if abs(rawFPS - ntsc) < 0.001 {
                guard let denominator = checkedMultiply(Int64(rounded), 1_000) else {
                    recordTimingFailure("A source frame rate denominator overflowed.")
                    return "0s"
                }
                return rationalTime(numerator: 1_001, denominator: denominator)
            }
            if abs(rawFPS - Double(rounded)) < 0.000_001 {
                return rationalTime(numerator: 1, denominator: Int64(rounded))
            }
            let scale: Int64 = 1_000_000
            let scaled = (rawFPS * Double(scale)).rounded()
            guard scaled.isFinite, scaled >= 1, scaled <= Double(Int64.max) else {
                recordTimingFailure("A source frame rate could not be represented exactly.")
                return "0s"
            }
            let numerator = Int64(scaled)
            return rationalTime(numerator: scale, denominator: max(1, numerator))
        }

        private func textStyleAttributes(for style: TextStyle) -> [(String, String)] {
            let font = style.resolvedFont(size: CGFloat(style.fontSize))
            let family = font.familyName ?? style.fontName.split(separator: "-", maxSplits: 1).first.map(String.init) ?? style.fontName
            let traits = CTFontGetSymbolicTraits(font as CTFont)
            let bold = traits.contains(.traitBold)
            let italic = traits.contains(.traitItalic)
            let face: String
            switch (bold, italic) {
            case (true, true): face = "Bold Italic"
            case (true, false): face = "Bold"
            case (false, true): face = "Italic"
            case (false, false): face = "Regular"
            }
            let attributes: [(String, String)] = [
                ("font", family),
                ("fontFace", face),
                ("fontSize", formatNumber(style.fontSize * style.fontScale)),
                ("fontColor", colorString(style.color)),
                ("alignment", style.alignment.rawValue),
            ]
            return attributes
        }

        private func colorString(_ color: TextStyle.RGBA) -> String {
            "\(formatNumber(color.r)) \(formatNumber(color.g)) \(formatNumber(color.b)) \(formatNumber(color.a))"
        }

        private func positionValue(
            for transform: Transform,
            fit: (width: Double, height: Double) = (1, 1)
        ) -> String {
            let unit = Double(timeline.height) / 100
            let x = (transform.centerX - 0.5) * Double(timeline.width) / unit / fit.width
            let y = (0.5 - transform.centerY) * Double(timeline.height) / unit / fit.height
            return "\(formatNumber(x)) \(formatNumber(y))"
        }

        private func fitFractions(for clip: Clip) -> (width: Double, height: Double) {
            guard let entry = resolver.entry(for: clip.mediaRef),
                  let sourceWidth = entry.sourceWidth,
                  let sourceHeight = entry.sourceHeight,
                  sourceWidth > 0,
                  sourceHeight > 0 else { return (1, 1) }
            let sourceAspect = Double(sourceWidth) / Double(sourceHeight)
            let frameAspect = Double(timeline.width) / Double(timeline.height)
            return sourceAspect >= frameAspect
                ? (1, frameAspect / sourceAspect)
                : (sourceAspect / frameAspect, 1)
        }

        private func formatNumber(_ value: Double) -> String {
            guard value.isFinite,
                  value >= Double(Int.min),
                  value < Double(Int.max) else {
                recordTimingFailure("A transform or gain value was not finite.")
                return "0"
            }
            let scaled = value * 10_000
            guard scaled.isFinite else {
                recordTimingFailure("A transform or gain value was too large to represent.")
                return "0"
            }
            let rounded = scaled.rounded() / 10_000
            if rounded == rounded.rounded(),
               rounded >= Double(Int.min),
               rounded < Double(Int.max) {
                return "\(Int(rounded))"
            }
            var string = String(format: "%.4f", rounded)
            while string.last == "0" { string.removeLast() }
            if string.last == "." { string.removeLast() }
            return string
        }

        private func greatestCommonDivisor(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
            var x = lhs
            var y = rhs
            while y != 0 {
                let remainder = x % y
                x = y
                y = remainder
            }
            return max(1, x)
        }

        private func checkedMultiply(_ lhs: Int64, _ rhs: Int64) -> Int64? {
            let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
            return overflow ? nil : value
        }

        private func checkedAdd(_ lhs: Int64, _ rhs: Int64) -> Int64? {
            let (value, overflow) = lhs.addingReportingOverflow(rhs)
            return overflow ? nil : value
        }

        private func recordTimingFailure(_ reason: String) {
            if timingFailure == nil { timingFailure = reason }
        }
    }
}

private struct FCPXMLNode {
    let name: String
    var attributes: [(String, String)] = []
    var text: String?
    var children: [FCPXMLNode] = []

    init(
        name: String,
        attributes: [(String, String)] = [],
        text: String? = nil,
        children: [FCPXMLNode] = []
    ) {
        self.name = name
        self.attributes = attributes
        self.text = text
        self.children = children
    }
}

private func renderFCPXML(_ node: FCPXMLNode, indent: Int) -> String {
    let padding = String(repeating: " ", count: indent)
    let attributes = node.attributes.map { " \($0.0)=\"\(escapeFCPXML($0.1))\"" }.joined()
    if let text = node.text {
        return "\(padding)<\(node.name)\(attributes)>\(escapeFCPXML(text))</\(node.name)>"
    }
    guard !node.children.isEmpty else { return "\(padding)<\(node.name)\(attributes)/>" }
    let body = node.children.map { renderFCPXML($0, indent: indent + 2) }.joined(separator: "\n")
    return "\(padding)<\(node.name)\(attributes)>\n\(body)\n\(padding)</\(node.name)>"
}

private func escapeFCPXML(_ value: String) -> String {
    value.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&apos;")
}

private func stableFCPXMLRelinkFilename(
    readable: String,
    identity: String,
    contentSHA256: String
) -> String {
    let sourceName = URL(fileURLWithPath: readable).lastPathComponent
    let sourceURL = URL(fileURLWithPath: sourceName)
    let stem = sourceURL.deletingPathExtension().lastPathComponent.isEmpty
        ? "Media"
        : sourceURL.deletingPathExtension().lastPathComponent
    let identitySuffix = String(FileDigest.sha256(of: Data(identity.utf8)).prefix(8))
    let contentSuffix = String(contentSHA256.prefix(8))
    let ext = sourceURL.pathExtension
    let basename = "\(stem)--\(identitySuffix)-\(contentSuffix)"
    return ext.isEmpty ? basename : "\(basename).\(ext)"
}
